defmodule WardrikSlack.API do
  @moduledoc """
  Calls Slack's Web API.

  Each call merges in the channel's `:req_options`, so tests can point it at `Req.Test`.
  Rate-limited, 5xx and dropped requests are retried up to five times, with backoff or as long as
  Slack says to wait.
  """

  require Logger

  @api "https://slack.com/api/"
  @retried [retry: :transient, max_retries: 5]

  @doc "Calls `method` with `body` as JSON. Returns Slack's reply, or its `error`."
  @spec post(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(method, token, body, req_options \\ []),
    do: call(method, [json: body, auth: {:bearer, token}] ++ req_options)

  @doc "Calls `method` with `params` as a form, as Slack's read methods expect. Drops `nil` params."
  @spec read(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(method, token, params, req_options \\ []) do
    form = for {key, value} <- params, value != nil, do: {key, value}
    call(method, [form: form, auth: {:bearer, token}] ++ req_options)
  end

  @doc "Like `post/4`, with the bot token and `:req_options` of `workspace`."
  @spec post_in(WardrikChannel.Workspace.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def post_in(
        %WardrikChannel.Workspace{channel: channel, installation: installation},
        method,
        body
      ),
      do: post(method, installation.token, body, req_options(channel))

  @doc "Like `read/4`, with the bot token and `:req_options` of `workspace`."
  @spec read_in(WardrikChannel.Workspace.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def read_in(
        %WardrikChannel.Workspace{channel: channel, installation: installation},
        method,
        params
      ),
      do: read(method, installation.token, params, req_options(channel))

  @doc "Returns the channel's `:req_options`. `[]` unless set."
  @spec req_options(WardrikChannel.Channel.t()) :: keyword()
  def req_options(%WardrikChannel.Channel{options: options}),
    do: Keyword.get(options, :req_options, [])

  @doc """
  Calls `method` with `Req` options.

  Returns `{:ok, reply}` when Slack answers `"ok": true`, `{:error, error}` with Slack's `error`,
  `{:error, {:status, status}}` for any other status, or Req's error.
  """
  @spec call(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(method, options) do
    case Req.post(@api <> method, @retried ++ options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = reply}} -> {:ok, reply}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Posts `reply` to a button press's `response_url`.

  The reply replaces the message, or is shown only to the person who pressed. Always returns `:ok`.
  A failure is logged, since the press was already acted on.
  """
  @spec respond(String.t() | nil, map(), keyword()) :: :ok
  def respond(nil, _reply, _req_options), do: :ok

  def respond(url, reply, req_options) do
    case Req.post(url, [json: reply] ++ @retried ++ req_options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      other -> Logger.warning("Slack didn't take an answer to a button: #{inspect(other)}")
    end

    :ok
  end
end
