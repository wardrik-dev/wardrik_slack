defmodule WardrikSlack.Rooms do
  @moduledoc """
  Binds agents to Slack channels, as `WardrikChannel.Rooms` sets out, and shows the binding there.

  When the bot is invited into a Slack channel, it posts where things stand:

    * One agent offered - the agent answers there from now on. A button switches between every
      message and mentions only. A menu switches agents or stops it.
    * Several offered - a button for each.
    * None offered - how to offer one.

  Removing the bot unbinds the room.
  """

  alias WardrikChannel.Binding
  alias WardrikChannel.Offer
  alias WardrikChannel.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks
  alias WardrikSlack.Messages

  @max_buttons 5

  @doc "Handles `bot`, the app's member ID, joining or leaving a Slack channel."
  @spec event(Workspace.t(), map(), String.t()) :: :ok | :ignored | {:error, term()}
  def event(
        workspace,
        %{"type" => "member_joined_channel", "user" => bot, "channel" => room} = event,
        bot
      ) do
    by = person(workspace, event["inviter"])

    workspace
    |> WardrikChannel.Rooms.joined(room, by)
    |> message(workspace, bot)
    |> post(workspace, room)
  end

  def event(workspace, %{"type" => type, "channel" => room} = event, _bot)
      when type in ["channel_left", "group_left"],
      do: WardrikChannel.Rooms.left(workspace, room, person(workspace, event["actor_id"]))

  def event(_workspace, _event, _bot), do: :ignored

  @doc "Handles a room's button press or menu choice, then posts where things stand."
  @spec answer(Workspace.t(), map()) :: :ok | :ignored
  def answer(
        workspace,
        %{"actions" => [%{"action_id" => "wardrik_room_" <> action} = pressed | _rest]} = payload
      ) do
    room = get_in(payload, ["channel", "id"])

    by = %WardrikChannel.Member{
      id: get_in(payload, ["user", "id"]),
      name: get_in(payload, ["user", "username"])
    }

    reply =
      case act(action, value(pressed), workspace, room, by) do
        {:error, text} -> Blocks.ephemeral(text)
        shown -> Map.put(message(shown, workspace, nil), :replace_original, true)
      end

    API.respond(payload["response_url"], reply, API.req_options(workspace.channel))
  end

  def answer(_workspace, _payload), do: :ignored

  defp act("agent", agent, workspace, room, by) do
    case WardrikChannel.Rooms.chose(workspace, room, agent, by) do
      {:ok, binding, offer} -> {:bound, binding, offer}
      {:error, :not_offered} -> {:error, "That agent isn't offered here anymore."}
    end
  end

  defp act("answers", answers, workspace, room, by) do
    case WardrikChannel.Rooms.answers(workspace, room, answers(answers), by) do
      {:ok, binding} -> {:bound, binding, offer(workspace, binding.agent)}
      {:error, :not_bound} -> WardrikChannel.Rooms.choices(workspace)
    end
  end

  defp act("more", "stop", workspace, room, by) do
    :ok = WardrikChannel.Rooms.left(workspace, room, by)
    :stopped
  end

  defp act("more", _choose, workspace, _room, _by), do: WardrikChannel.Rooms.choices(workspace)

  defp answers("everything"), do: :everything
  defp answers(_mentions), do: :mentions

  defp offer(workspace, agent),
    do: Enum.find(Workspace.offered(workspace), %Offer{agent: agent}, &(&1.agent == agent))

  defp value(%{"value" => value}), do: value
  defp value(%{"selected_option" => %{"value" => value}}), do: value
  defp value(_pressed), do: nil

  @doc "Returns the message that shows a room's binding."
  @spec message(WardrikChannel.Rooms.shown() | :stopped, Workspace.t(), String.t() | nil) ::
          %{text: String.t(), blocks: [map()]}
  def message({:bound, %Binding{agent: agent, answers: answers}, offer}, workspace, bot) do
    text = ":wave: *#{shown(workspace, agent)}* answers here now."

    %{
      text: text,
      blocks:
        [Blocks.section(text)] ++
          described(offer) ++
          [
            Blocks.section(how(answers, bot) <> " " <> approving(workspace)),
            Blocks.actions("wardrik_room", [toggle(answers), more()])
          ]
    }
  end

  def message({:choose, offers}, workspace, _bot) do
    text =
      "Which agent should answer here? It answers when mentioned, and you can change that after."

    %{text: text, blocks: [Blocks.section(text) | choose(offers, workspace)]}
  end

  def message(:none, %Workspace{channel: channel}, _bot) do
    text = "No agent answers here yet. " <> channel.offering
    look = Blocks.button("Look again", "wardrik_room_more", "choose")
    %{text: text, blocks: [Blocks.section(text), Blocks.actions("wardrik_room", [look])]}
  end

  def message(:stopped, _workspace, _bot) do
    text = "No agent answers here now."
    choose = Blocks.button("Choose an agent", "wardrik_room_more", "choose")
    %{text: text, blocks: [Blocks.section(text), Blocks.actions("wardrik_room", [choose])]}
  end

  defp how(:everything, _bot), do: "It answers every message here, each in a thread of its own."
  defp how(:mentions, nil), do: "Mention the app, and it answers in a thread under your message."

  defp how(:mentions, bot),
    do: "Mention <@#{bot}>, and it answers in a thread under your message."

  defp toggle(:everything),
    do: Blocks.button("Answer only when mentioned", "wardrik_room_answers", "mentions")

  defp toggle(:mentions),
    do: Blocks.button("Answer every message", "wardrik_room_answers", "everything")

  defp approving(%Workspace{installation: %{approvers: :anyone}}),
    do: "Anyone here may approve a call that needs it."

  defp approving(%Workspace{installation: %{approvers: []}}),
    do: "A call that needs approval waits in its thread for whoever asked."

  defp approving(%Workspace{installation: %{approvers: approvers}}),
    do:
      "A call that needs approval is sent to #{WardrikSlack.Waiting.named(approvers)} to approve, " <>
        "and the thread says so."

  defp described(%Offer{description: description}) when is_binary(description),
    do: [Blocks.context("_#{description}_")]

  defp described(_offer), do: []

  defp choose(offers, workspace) when length(offers) <= @max_buttons do
    for %Offer{agent: agent, description: description} <- offers do
      line =
        if description,
          do: "*#{shown(workspace, agent)}*\n#{description}",
          else: "*#{shown(workspace, agent)}*"

      Map.put(Blocks.section(line), :accessory, Blocks.button("Use", "wardrik_room_agent", agent))
    end
  end

  defp choose(offers, workspace) do
    options =
      for %Offer{agent: agent} <- offers,
          do: %{text: Blocks.plain(shown(workspace, agent)), value: agent}

    select = %{
      type: "static_select",
      action_id: "wardrik_room_agent",
      placeholder: Blocks.plain("Choose an agent"),
      options: options
    }

    [Blocks.actions("wardrik_room", [select])]
  end

  defp more do
    %{
      type: "overflow",
      action_id: "wardrik_room_more",
      options: [
        %{text: Blocks.plain("Use another agent"), value: "choose"},
        %{text: Blocks.plain("Stop answering here"), value: "stop"}
      ]
    }
  end

  @doc "Returns `agent` without the workspace owner's prefix, as `triage` for `acme/triage`."
  @spec shown(Workspace.t(), String.t()) :: String.t()
  def shown(%Workspace{installation: installation}, agent),
    do: String.replace_prefix(agent, installation.owner <> "/", "")

  defp person(_workspace, nil), do: nil
  defp person(workspace, id), do: Messages.sender(workspace, id)

  defp post(message, workspace, room) do
    case API.post_in(workspace, "chat.postMessage", Map.put(message, :channel, room)) do
      {:ok, _posted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
