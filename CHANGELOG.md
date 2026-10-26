# Changelog

## 0.1.0 (unreleased)

- A `WardrikChannel` adapter for a Slack app: agents answer mentions in threads, and replies in
  them, as the person who wrote.
- Events and buttons over HTTP, signed with the app's signing secret, or over Socket Mode with an
  app-level token, for testing with no public address.
- Rooms bound as the app is invited, with buttons to answer every message, switch agents, or stop.
- Waiting calls posted with their arguments, a note box, and Approve and Deny, or Show link for a
  sign-in. Approvers named by handle, email or member ID are each asked in the app's Messages tab,
  with a link to the thread, which says who it waits on. Where none can be reached, the thread asks.
- :eyes: on what an agent takes, :white_check_mark: once it's answered, and the agent's status in
  its thread while it works.
- One app in many workspaces, added through Slack's OAuth with `WardrikSlack.Install`.
