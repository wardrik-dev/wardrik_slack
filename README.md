# WardrikSlack

Wardrik in Slack: agents answer in threads, and ask there, with Approve and Deny, before a call
they can't make alone.

> **maria:** @Wardrik what time is it on the server? :eyes:
> ↳ **Wardrik:** Waiting on @maria to approve `clock`.
> **Wardrik**, to maria: `clock`, from a thread in #ops. `[Approve]` `[Deny]`
> ↳ **Wardrik:** Approved by maria.
> ↳ **Wardrik:** It's 14:02 UTC.

## Make the Slack app

At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App**, then **From a
manifest**, pick your workspace, and paste one of these. Change `Wardrik` to the name your team
will see.

### For testing, over Socket Mode

Socket Mode needs no public address: your app opens a connection out to Slack.

```yaml
display_information:
  name: Wardrik
  description: Agents that answer in threads, and ask before they act.
features:
  app_home:
    home_tab_enabled: false
    messages_tab_enabled: true
    messages_tab_read_only_enabled: true
  bot_user:
    display_name: Wardrik
    always_online: true
oauth_config:
  scopes:
    bot:
      - channels:history
      - channels:read
      - chat:write
      - chat:write.public
      - groups:history
      - groups:read
      - reactions:write
      - users:read
      - users:read.email
settings:
  event_subscriptions:
    bot_events:
      - app_uninstalled
      - channel_left
      - group_left
      - member_joined_channel
      - message.channels
      - message.groups
      - tokens_revoked
  interactivity:
    is_enabled: true
  org_deploy_enabled: false
  socket_mode_enabled: true
  token_rotation_enabled: false
```

Then:

1. **Install to Workspace**, and copy the **Bot User OAuth Token** (`xoxb-...`) from **OAuth &
   Permissions**. This is `token`.
2. Under **Basic Information › App-Level Tokens**, make a token with the scope
   `connections:write` (`xapp-...`). This is `app_token`.

Give Wardrik a Slack app of its own here. Slack spreads an app's Socket Mode events across every
connection open for it.

### For production, over HTTP

Slack sends events to your app's public address. Change `agents.example.com` to it, and keep
the rest of the manifest above, with these settings:

```yaml
settings:
  event_subscriptions:
    request_url: https://agents.example.com/v1/channels/slack/events
    bot_events:
      - app_uninstalled
      - channel_left
      - group_left
      - member_joined_channel
      - message.channels
      - message.groups
      - tokens_revoked
  interactivity:
    is_enabled: true
    request_url: https://agents.example.com/v1/channels/slack/actions
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

`slack` in each URL is the channel's name in your Wardrik. Slack checks the events URL as you save,
so your app must be running at that address first. Copy the **Signing Secret** from **Basic
Information › App Credentials**. This is `signing_secret`.

## Try it locally

From this repository, with the tokens from Socket Mode above and a model key:

```sh
SLACK_BOT_TOKEN=xoxb-... SLACK_APP_TOKEN=xapp-... ANTHROPIC_API_KEY=sk-ant-... \
  mix run --no-halt examples/socket_mode.exs
```

It starts a Wardrik in memory with the agent `acme/assistant`, which may read a clock once someone
approves it. In Slack, `/invite @Wardrik` into a channel, then mention it:
`@Wardrik what time is it?`. Set `SLACK_APPROVERS=@you` to name who approves, or leave it out, and
whoever asked approves their own.

## Wire it up

```elixir
def deps do
  [
    {:wardrik_slack, "~> 0.1"}
  ]
end
```

Give your Wardrik the channel, by a name of your own:

```elixir
config :my_app, MyApp.Wardrik,
  channels: [
    slack:
      {WardrikSlack,
       token: System.fetch_env!("SLACK_BOT_TOKEN"),
       signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
       owner: "acme",
       approvers: ["@maria", "jon@example.com"]}
  ]
```

Over HTTP, serve it with [WardrikHTTP](https://hexdocs.pm/wardrik_http). If your app parses
bodies first, keep them as they came, since Slack signs the exact bytes:

```elixir
plug Plug.Parsers,
  parsers: [:json, :urlencoded],
  json_decoder: JSON,
  body_reader: {WardrikHTTP.BodyReader, :read_body, []}

forward "/", WardrikHTTP, wardrik: MyApp.Wardrik
```

Then list the channel in an agent's definition:

```elixir
Wardrik.Agent.define(scope, "acme/triage",
  model: "anthropic:claude-haiku-4-5",
  description: "Triages incidents.",
  channels: ["slack"]
)
```

Invite the app into a Slack channel. With one agent offered, it answers there from then on: mention
the app, and it answers in a thread under your message. With several, pick one. See
[WardrikChannel](https://hexdocs.pm/wardrik_channel) for rooms, threads and approvals.

## Approvers

`approvers` are named by `@handle`, email address, or Slack member ID, or `:anyone`. An email
address needs the `users:read.email` scope. Whoever asked for a turn may always decide it.

A call an agent waits on is sent to each approver in the app's **Messages** tab, with a link to
its thread, and the thread says who it waits on:

> ↳ **Wardrik:** Waiting on @maria or @jon to approve `create_bill`.

The first to answer decides. Where Slack can reach none of them, the call is asked in the thread
instead, with the same buttons.

## Notices

An agent nobody watches, such as one a trigger asks every morning, can post in a room when it
answers, fails, or waits on a person. Route it to the room as `slack:#room`:

```elixir
Wardrik.Agent.define(scope, "acme/digest",
  model: "anthropic:claude-haiku-4-5",
  notify: %{to: ["slack:#updates"], on: ["finished", "failed"]}
)
```

To ask approvers about a parked turn, name a target in your Wardrik's `notify`, and route to it:

```elixir
config :my_app, MyApp.Wardrik,
  notify: [targets: [ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops", approvers: ["@maria"]}]]

Wardrik.Agent.define(scope, "acme/triage", model: "anthropic:claude-haiku-4-5", notify: "ops")
```

The notice is posted in the room, with Approve and Deny, and sent to each approver in the
**Messages** tab with a link to it. Only the channel's own approvers may decide. The app posts in
any public channel, since the manifest asks for `chat:write.public`; invite it into a private one.
It never answers its own posts, so a room where the agent answers every message doesn't loop.
See `Wardrik.Notify` for webhooks and the rest.

## Many workspaces

One app can serve many workspaces, one for each org. Give the channel `client_id` and
`client_secret` from **Basic Information**, `installations: :stored`, and the `redirect_uri` you
set under **OAuth & Permissions**, and see `WardrikSlack.Install`. Each workspace's token is sealed
in the Wardrik's vault, so it needs `:keys`.
