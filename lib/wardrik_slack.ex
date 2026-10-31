defmodule WardrikSlack do
  @schema NimbleOptions.new!(
            signing_secret: [
              type: {:or, [:string, nil]},
              doc: """
              Takes Slack's requests over HTTP, at `/v1/channels/{channel}/events` and
              `/v1/channels/{channel}/actions`. See `WardrikSlack.HTTP`.
              """
            ],
            app_token: [
              type: {:or, [:string, nil]},
              doc: """
              An app-level token, `xapp-...`, with `connections:write`. Takes Slack's requests over
              Socket Mode instead, with no public address. For testing. See `WardrikSlack.Socket`.
              """
            ],
            client_id: [
              type: {:or, [:string, nil]},
              doc:
                "Adds one app to many workspaces, with `:client_secret`. See `WardrikSlack.Install`."
            ],
            client_secret: [type: {:or, [:string, nil]}, doc: "The app's client secret."],
            redirect_uri: [
              type: :string,
              doc: "Where Slack sends someone once they've added the app."
            ],
            req_options: [
              type: :keyword_list,
              default: [],
              doc: "Merged into every request to Slack."
            ]
          )

  @moduledoc """
  Slack for Wardrik. A `WardrikChannel` adapter for a Slack app of your own.

  Agents answer in threads. Before a call they can't make alone, they ask there, with Approve and
  Deny buttons.

      config :my_app, MyApp.AgentRuntime,
        channels: [
          slack:
            {WardrikSlack,
             token: "xoxb-...",
             signing_secret: "...",
             owner: "acme",
             approvers: ["@maria"]}
        ]

  ## Options

  Takes `WardrikChannel`'s options, such as `:owner` and `:approvers`. Its `:token` is the bot
  token, `xoxb-...`. And these:

  #{NimbleOptions.docs(@schema)}

  Over Socket Mode, give Wardrik a Slack app of its own. Slack spreads an app's events across
  every open connection.

  ## Approvers

  `:approvers` are named by `@handle`, email address or Slack member ID, or `:anyone`.

    1. A call an agent waits on is sent to each approver in the app's Messages tab, with a link
       to its thread.
    2. The thread says who it waits on.
    3. If Slack reaches none of them, the call is asked in the thread instead.

  ## In the thread

    * While an agent works, the thread shows what it's doing as the app's status.
    * A message the agent takes gets :eyes:, then :white_check_mark: once it's answered.
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

  @doc "Returns the options it takes beyond `WardrikChannel`'s, as a `NimbleOptions` schema."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @impl Wardrik.Channel
  def request(opts, request),
    do: __MODULE__ |> WardrikChannel.channel(opts) |> WardrikSlack.HTTP.request(request)

  @impl WardrikChannel
  def children(%Channel{options: options} = channel) do
    NimbleOptions.validate!(options, @schema)

    socket =
      if Keyword.has_key?(options, :app_token), do: [{WardrikSlack.Socket, channel}], else: []

    [{Task.Supervisor, name: tasks(channel)} | socket]
  end

  @doc """
  Checks a channel's tokens with Slack.

      WardrikSlack.check(token: "xoxb-...", app_token: "xapp-...")
      #=> {:ok, "posts as @wardrik in Acme"}

      WardrikSlack.check(token: "xoxb-wrong")
      #=> {:error, "Slack refused its token: \"invalid_auth\""}

  Checks `:token` with `auth.test`, and `:app_token` by opening a Socket Mode URL. Without
  `:token`, the channel keeps a token for each workspace, and those aren't checked.
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

  @doc "Returns the name of the task supervisor that handles what Slack sends the channel."
  @spec tasks(Channel.t()) :: atom()
  def tasks(%Channel{wardrik: wardrik, name: name}),
    do: Module.concat([wardrik, "Channels", name, "Tasks"])

  @doc "Returns whether `member` is among `names`. Each name is a `@handle`, email address or member ID."
  @impl WardrikChannel
  def include?(channel, installation, names, member) do
    member.id in names or
      Enum.any?(
        names,
        &(&1 in known_as(%Workspace{channel: channel, installation: installation}, member.id))
      )
  end

  @doc "Returns the URL where someone acting for `owner` adds the app. See `WardrikSlack.Install.url/3`."
  @impl WardrikChannel
  def install_url(channel, owner, opts), do: WardrikSlack.Install.url(channel, owner, opts)

  @doc "Adds the app to a workspace once Slack sends someone back. See `WardrikSlack.Install.installed/3`."
  @impl WardrikChannel
  def installed(channel, owner, query), do: WardrikSlack.Install.installed(channel, owner, query)

  @doc """
  Uninstalls the app from `workspace` and forgets the workspace.

  The workspace is forgotten even if Slack refuses. Slack confirms with an `app_uninstalled` event.
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
