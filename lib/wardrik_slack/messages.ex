defmodule WardrikSlack.Messages do
  @moduledoc """
  Hands a message posted in a Slack channel to `WardrikChannel.received/2`, and marks it. A
  message the agent is asked gets :eyes:, which turns to :white_check_mark: once the agent
  answers. One it couldn't be asked gets a reply in its thread saying why.

  It leaves alone edits, deletions, bots' messages and the app's own, direct messages, and
  messages from people in another workspace.
  """

  alias WardrikChannel.Inbound
  alias WardrikChannel.Member
  alias WardrikChannel.Workspace
  alias WardrikSlack.API

  @posted [nil, "thread_broadcast", "file_share"]

  @doc "Asks the room's agent what a `message` event says, as the bot `bot` hears it, or leaves it."
  @spec event(Workspace.t(), map(), String.t()) ::
          {:asked, String.t()} | :ignored | {:error, String.t()}
  def event(workspace, %{"type" => "message", "user" => user} = event, bot)
      when is_binary(user) do
    if posted?(workspace, event, bot), do: ask(workspace, event, bot), else: :ignored
  end

  def event(_workspace, _event, _bot), do: :ignored

  defp posted?(%Workspace{installation: installation}, event, bot) do
    event["subtype"] in @posted and is_nil(event["bot_id"]) and event["user"] != bot and
      event["channel_type"] in ["channel", "group"] and
      (event["user_team"] || event["team"] || installation.workspace) == installation.workspace
  end

  defp ask(workspace, %{"channel" => room, "ts" => ts} = event, bot) do
    mention = "<@#{bot}>"
    text = Map.get(event, "text", "")

    inbound = %Inbound{
      room: room,
      thread: thread(event["thread_ts"], ts),
      id: ts,
      sender: sender(workspace, event["user"]),
      text: text |> String.replace(mention, "") |> String.trim(),
      mentioned?: String.contains?(text, mention)
    }

    case WardrikChannel.received(workspace, inbound) do
      {:asked, conversation} ->
        react(workspace, "reactions.add", room, ts, "eyes")
        {:asked, conversation}

      :ignored ->
        :ignored

      {:error, message} ->
        say(workspace, room, inbound.thread || ts, ":warning: " <> message)
        {:error, message}
    end
  end

  defp thread(nil, _ts), do: nil
  defp thread(ts, ts), do: nil
  defp thread(thread, _ts), do: thread

  @doc "Marks the messages `ids` an answer answers with :white_check_mark: in place of :eyes:."
  @spec answered(Workspace.t(), String.t(), [String.t()]) :: :ok
  def answered(workspace, room, ids) do
    for ts <- ids do
      react(workspace, "reactions.remove", room, ts, "eyes")
      react(workspace, "reactions.add", room, ts, "white_check_mark")
    end

    :ok
  end

  @doc "Takes :eyes: from the messages `ids` a run stopped before it answered."
  @spec stopped(Workspace.t(), String.t(), [String.t()]) :: :ok
  def stopped(workspace, room, ids) do
    for ts <- ids, do: react(workspace, "reactions.remove", room, ts, "eyes")
    :ok
  end

  @doc "Returns who `user` is, with the name Slack shows for them."
  @spec sender(Workspace.t(), String.t()) :: Member.t()
  def sender(workspace, user) do
    case API.read_in(workspace, "users.info", %{user: user}) do
      {:ok, %{"user" => found}} -> %Member{id: user, name: name(found)}
      _unknown -> %Member{id: user}
    end
  end

  defp name(user) do
    profile = Map.get(user, "profile", %{})

    Enum.find(
      [profile["display_name"], profile["real_name"], user["name"]],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp react(workspace, method, room, ts, name) do
    _reacted = API.post_in(workspace, method, %{channel: room, timestamp: ts, name: name})
    :ok
  end

  defp say(workspace, room, thread, text) do
    _said =
      API.post_in(workspace, "chat.postMessage", %{channel: room, thread_ts: thread, text: text})

    :ok
  end
end
