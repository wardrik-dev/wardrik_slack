defmodule WardrikSlack.HTTP do
  @moduledoc """
  Answers what Slack sends over HTTP: its events at `events`, the Request URL under **Event
  Subscriptions**, and its buttons at `actions`, the one under **Interactivity**.

  Each request must be signed with the channel's `signing_secret`, within five minutes. Slack's
  check of a Request URL is answered with what it asked. The rest is acted on in a task, and Slack
  is answered once it's done, or after two seconds, whichever comes first. Slack sends again what
  it isn't answered within three, and a message sent again is asked once.
  """

  alias WardrikChannel.Channel
  alias WardrikSlack.Dispatch

  @window 300
  @wait 2_000

  @doc "Answers `request`, which Slack sent the channel."
  @spec request(Channel.t(), Wardrik.Channel.request()) :: Wardrik.Channel.response()
  def request(%Channel{options: options} = channel, request) do
    case Keyword.fetch(options, :signing_secret) do
      {:ok, secret} ->
        if signed?(request, secret),
          do: route(channel, request),
          else: text(401, "Slack didn't sign this.")

      :error ->
        text(404, "This channel takes nothing from Slack over HTTP.")
    end
  end

  defp route(channel, %{path: "events", body: body}) do
    case JSON.decode(body) do
      {:ok, %{"type" => "url_verification", "challenge" => challenge}} ->
        text(200, challenge)

      {:ok, %{"type" => "event_callback"} = callback} ->
        acted(channel, fn -> Dispatch.event(channel, callback) end)

      _other ->
        text(200, "")
    end
  end

  defp route(channel, %{path: "actions", body: body}) do
    with %{"payload" => text} <- URI.decode_query(body),
         {:ok, payload} <- JSON.decode(text) do
      acted(channel, fn -> Dispatch.interactive(channel, payload) end)
    else
      _unreadable -> text(400, "That isn't a payload Slack sends.")
    end
  end

  defp route(_channel, _request), do: text(404, "Slack sends nothing here.")

  defp acted(channel, act) do
    task = Task.Supervisor.async_nolink(WardrikSlack.tasks(channel), act)
    if Task.yield(task, @wait) == nil, do: Task.ignore(task)
    text(200, "")
  end

  defp signed?(%{headers: headers, body: body}, secret) do
    with at when is_binary(at) <- headers["x-slack-request-timestamp"],
         "v0=" <> _hex = given <- headers["x-slack-signature"],
         {at, ""} <- Integer.parse(at),
         true <- abs(System.os_time(:second) - at) <= @window do
      expected = signature(secret, at, body)
      byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)
    else
      _unsigned -> false
    end
  end

  @doc "Returns the signature Slack sends with `body`, signed with `secret` at `at`."
  @spec signature(String.t(), integer(), String.t()) :: String.t()
  def signature(secret, at, body),
    do:
      "v0=" <>
        Base.encode16(:crypto.mac(:hmac, :sha256, secret, "v0:#{at}:#{body}"), case: :lower)

  defp text(status, body),
    do: %{status: status, headers: %{"content-type" => "text/plain; charset=utf-8"}, body: body}
end
