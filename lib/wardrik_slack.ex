defmodule WardrikSlack do
  @moduledoc """
  Wardrik in Slack: a `WardrikChannel` adapter for a Slack app of your own. Agents answer in
  threads, and ask there, with Approve and Deny, before a call they can't make alone.

      channels: [
        slack:
          {WardrikSlack,
           token: "xoxb-...",
           app_token: "xapp-...",
           owner: "acme",
           approvers: ["@maria"]}
      ]

  It takes WardrikChannel's options, and Slack's own:

    * `:token` - the app's bot token, `xoxb-...`, which adds it to the one workspace it reaches
    * `:signing_secret` - what Slack signs its requests with, to take them over HTTP at
      `/v1/channels/{channel}/events` and `/v1/channels/{channel}/actions`
    * `:app_token` - an app-level token, `xapp-...`, with `connections:write`, to take them over
      Socket Mode instead, with no public address; for testing
    * `:client_id`, `:client_secret` and `:redirect_uri` - to add one app to many workspaces;
      see `WardrikSlack.Install`
    * `:req_options` - merged into every request to Slack

  Over Socket Mode, give Wardrik a Slack app of its own. Slack spreads an app's events across every
  connection open for it.

  `approvers` are named by `@handle`, email address or Slack member ID. A call an agent waits on is
  sent to each of them in the app's Messages tab, with a link to its thread, and the thread says
  who it waits on. Where none of them can be reached, it's asked in the thread. While an agent works, its
  thread shows what it's doing as the app's status. A message the agent takes gets :eyes:, and
  :white_check_mark: once it's answered.

  Reach for this when your people talk in Slack.
  """

  use WardrikChannel

  require Logger

  alias WardrikChannel.Channel
  alias WardrikChannel.Outbound
  alias WardrikChannel.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Approvers
  alias WardrikSlack.Blocks
  alias WardrikSlack.Messages
  alias WardrikSlack.Rooms

  @impl Wardrik.Channel
  def request(opts, request),
    do: __MODULE__ |> WardrikChannel.channel(opts) |> WardrikSlack.HTTP.request(request)

  @impl WardrikChannel
  def children(%Channel{options: options} = channel) do
    socket =
      if Keyword.has_key?(options, :app_token), do: [{WardrikSlack.Socket, channel}], else: []

    [{Task.Supervisor, name: tasks(channel)} | socket]
  end

  @doc """
  Checks the tokens a channel's options give Slack: its bot `:token`, with `auth.test`, and its
  `:app_token`, by opening a Socket Mode connection's URL. Returns where the bot posts, or why
  Slack refused. A channel with no `:token` keeps one for each workspace, which it doesn't check.

      WardrikSlack.check(token: "xoxb-...", app_token: "xapp-...")
      #=> {:ok, "posts as @wardrik in Acme"}
  """
  @spec check(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def check(opts) do
    req_options = [retry: false] ++ Keyword.get(opts, :req_options, [])

    with {:ok, said} <- bot(opts[:token], req_options),
         :ok <- app(opts[:app_token], req_options),
         do: {:ok, said}
  end

  defp bot(nil, _req_options), do: {:ok, "keeps a token for each workspace it's added to"}

  defp bot(token, req_options) do
    case API.post("auth.test", token, %{}, req_options) do
      {:ok, %{"user" => user, "team" => team}} -> {:ok, "posts as @#{user} in #{team}"}
      {:error, why} -> {:error, "Slack refused its token: #{inspect(why)}"}
    end
  end

  defp app(nil, _req_options), do: :ok

  defp app(token, req_options) do
    case API.post("apps.connections.open", token, %{}, req_options) do
      {:ok, _url} -> :ok
      {:error, why} -> {:error, "Slack refused its app_token: #{inspect(why)}"}
    end
  end

  @doc "Returns the task supervisor the channel acts on what Slack sends under."
  @spec tasks(Channel.t()) :: atom()
  def tasks(%Channel{wardrik: wardrik, name: name}),
    do: Module.concat([wardrik, "Channels", name, "Tasks"])

  @doc "Returns whether `names`, each a `@handle`, an email address or a member ID, include `member`."
  @impl WardrikChannel
  def include?(channel, installation, names, member) do
    member.id in names or
      Enum.any?(
        names,
        &(&1 in known_as(%Workspace{channel: channel, installation: installation}, member.id))
      )
  end

  @doc "Returns where someone acting for `owner` adds the app to a workspace. See `WardrikSlack.Install`."
  @impl WardrikChannel
  def install_url(channel, owner, opts), do: WardrikSlack.Install.url(channel, owner, opts)

  @doc "Adds the app to the workspace Slack sent someone back from. See `WardrikSlack.Install`."
  @impl WardrikChannel
  def installed(channel, owner, query), do: WardrikSlack.Install.installed(channel, owner, query)

  @doc """
  Asks Slack to uninstall the app from `workspace`, which it confirms with an `app_uninstalled`
  event, and forgets the workspace either way.
  """
  @impl WardrikChannel
  def uninstall(channel, workspace) do
    with {:ok, installation} <- Channel.installation(channel, workspace) do
      credentials = %{
        client_id: channel.options[:client_id],
        client_secret: channel.options[:client_secret]
      }

      _asked =
        API.read("apps.uninstall", installation.token, credentials, API.req_options(channel))
    end

    Channel.uninstall(channel, workspace)
  end

  defp known_as(workspace, id) do
    case API.read_in(workspace, "users.info", %{user: id}) do
      {:ok, %{"user" => user}} -> ["@" <> user["name"], get_in(user, ["profile", "email"])]
      _unknown -> []
    end
  end

  @impl WardrikChannel
  def deliver(channel, %Outbound{installation: installation} = outbound) do
    workspace = %Workspace{channel: channel, installation: installation}

    with {:ok, _posted} <- posted(workspace, outbound), do: :ok
  end

  defp posted(workspace, %Outbound{room: room, thread: thread, body: {:status, label}}),
    do:
      API.post_in(workspace, "assistant.threads.setStatus", %{
        channel_id: room,
        thread_ts: thread,
        status: label
      })

  defp posted(workspace, %Outbound{room: room, body: {:stopped, answering}} = outbound) do
    :ok = Messages.stopped(workspace, room, answering)
    posted(workspace, %{outbound | body: {:status, ""}})
  end

  defp posted(workspace, %Outbound{room: room, body: {:reply, text, answering}} = outbound) do
    with {:ok, posted} <- message(workspace, outbound, reply(text)) do
      :ok = Messages.answered(workspace, room, answering)
      {:ok, posted}
    end
  end

  defp posted(
         workspace,
         %Outbound{body: {:waiting, calls}, approvers: [_ | _] = approvers} = outbound
       ) do
    agent = waiting_agent(workspace, calls)
    from = from(workspace, outbound, agent)
    message = WardrikSlack.Waiting.message(calls, approvers)

    case Enum.filter(
           Approvers.members(workspace, approvers),
           &asked?(workspace, &1, message, from, agent)
         ) do
      [] ->
        Logger.warning(
          "Slack reached none of #{inspect(approvers)}, so they're asked in the thread."
        )

        message(workspace, outbound, message)

      _asked ->
        message(workspace, outbound, %{text: message.text})
    end
  end

  defp posted(workspace, %Outbound{body: {:waiting, calls}, approvers: approvers} = outbound),
    do: message(workspace, outbound, WardrikSlack.Waiting.message(calls, approvers))

  defp posted(workspace, %Outbound{body: {:failed, reason}} = outbound),
    do: message(workspace, outbound, %{text: ":warning: It stopped with an error: #{reason}"})

  defp posted(
         workspace,
         %Outbound{body: {:notice, %{kind: :parked} = notice}, approvers: [_ | _] = approvers} =
           outbound
       ) do
    agent = Rooms.shown(workspace, notice.agent)
    message = WardrikSlack.Notices.message(notice, approvers, agent)

    with {:ok, %{"ts" => ts} = posted} <- message(workspace, outbound, message) do
      from = from(workspace, %{outbound | thread: ts}, agent, "a notice")

      Enum.each(
        Approvers.members(workspace, approvers),
        &asked?(workspace, &1, message, from, agent)
      )

      {:ok, posted}
    end
  end

  defp posted(workspace, %Outbound{body: {:notice, notice}, approvers: approvers} = outbound),
    do:
      message(
        workspace,
        outbound,
        WardrikSlack.Notices.message(notice, approvers, Rooms.shown(workspace, notice.agent))
      )

  defp posted(workspace, %Outbound{body: {:said, text}} = outbound),
    do: message(workspace, outbound, %{text: text, blocks: [Blocks.context(text)]})

  defp asked?(_workspace, {approver, :error}, _message, _from, _agent) do
    Logger.warning("Slack has no member #{approver}, so they aren't asked directly.")
    false
  end

  defp asked?(workspace, {approver, {:ok, member}}, %{blocks: [heading | rest]}, from, agent) do
    message = %{
      channel: member,
      text: "`#{agent}` is waiting on you.",
      blocks: [heading, from | rest]
    }

    case API.post_in(workspace, "chat.postMessage", message) do
      {:ok, _posted} ->
        true

      {:error, reason} ->
        Logger.warning("Slack couldn't message #{approver}: #{inspect(reason)}")
        false
    end
  end

  defp from(workspace, %Outbound{room: room, thread: thread}, agent, what \\ "a thread") do
    case API.read_in(workspace, "chat.getPermalink", %{channel: room, message_ts: thread}) do
      {:ok, %{"permalink" => link}} ->
        Blocks.context("From `#{agent}`, in <#{link}|#{what}> in <##{room}>.")

      _unlinked ->
        Blocks.context("From `#{agent}`, in #{what} in <##{room}>.")
    end
  end

  defp waiting_agent(workspace, [%WardrikChannel.Waiting{conversation: conversation} | _rest]),
    do: Rooms.shown(workspace, Wardrik.AgentID.agent(conversation))

  defp reply(""), do: %{text: "_It answered nothing._"}
  defp reply(text), do: %{text: Blocks.clip(text, 3_000), blocks: [Blocks.markdown(text)]}

  defp message(workspace, %Outbound{room: room, thread: nil}, message),
    do: API.post_in(workspace, "chat.postMessage", Map.put(message, :channel, room))

  defp message(workspace, %Outbound{room: room, thread: thread}, message),
    do:
      API.post_in(
        workspace,
        "chat.postMessage",
        Map.merge(message, %{channel: room, thread_ts: thread})
      )
end
