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

  `approvers` are named by `@handle`, email address or Slack member ID. While an agent works, its
  thread shows what it's doing as the app's status. A message the agent takes gets :eyes:, and
  :white_check_mark: once it's answered.

  Reach for this when your people talk in Slack.
  """

  use WardrikChannel

  alias WardrikChannel.Channel
  alias WardrikChannel.Outbound
  alias WardrikChannel.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks
  alias WardrikSlack.Messages

  @impl Wardrik.Channel
  def request(opts, request),
    do: __MODULE__ |> WardrikChannel.channel(opts) |> WardrikSlack.HTTP.request(request)

  @impl WardrikChannel
  def children(%Channel{options: options} = channel) do
    socket =
      if Keyword.has_key?(options, :app_token), do: [{WardrikSlack.Socket, channel}], else: []

    [{Task.Supervisor, name: tasks(channel)} | socket]
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

  defp posted(workspace, %Outbound{body: {:waiting, calls}, approvers: approvers} = outbound),
    do: message(workspace, outbound, WardrikSlack.Waiting.message(calls, approvers))

  defp posted(workspace, %Outbound{body: {:failed, reason}} = outbound),
    do: message(workspace, outbound, %{text: ":warning: It stopped with an error: #{reason}"})

  defp posted(workspace, %Outbound{body: {:said, text}} = outbound),
    do: message(workspace, outbound, %{text: text, blocks: [Blocks.context(text)]})

  defp reply(""), do: %{text: "_It answered nothing._"}
  defp reply(text), do: %{text: Blocks.clip(text, 3_000), blocks: [Blocks.markdown(text)]}

  defp message(workspace, %Outbound{room: room, thread: thread}, message),
    do:
      API.post_in(
        workspace,
        "chat.postMessage",
        Map.merge(message, %{channel: room, thread_ts: thread})
      )
end
