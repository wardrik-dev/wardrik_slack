defmodule WardrikSlack.API do
  @moduledoc """
  Calls Slack's Web API with a token. Each call takes the channel's `:req_options`, merged into
  the request, so tests can point it at `Req.Test`.
  """

  require Logger

  @api "https://slack.com/api/"

  @doc "Calls `method` with `body` as JSON, and returns Slack's reply."
  @spec post(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(method, token, body, req_options \\ []),
    do: call(method, [json: body, auth: {:bearer, token}] ++ req_options)

  @doc "Calls `method` with `params` as a form, as Slack's methods that only read take them."
  @spec read(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(method, token, params, req_options \\ []) do
    form = for {key, value} <- params, value != nil, do: {key, value}
    call(method, [form: form, auth: {:bearer, token}] ++ req_options)
  end

  @doc "Calls `method` with `body` as JSON, as the bot of `workspace`."
  @spec post_in(WardrikChannel.Workspace.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def post_in(
        %WardrikChannel.Workspace{channel: channel, installation: installation},
        method,
        body
      ),
      do: post(method, installation.token, body, req_options(channel))

  @doc "Calls `method` with `params` as a form, as the bot of `workspace`."
  @spec read_in(WardrikChannel.Workspace.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def read_in(
        %WardrikChannel.Workspace{channel: channel, installation: installation},
        method,
        params
      ),
      do: read(method, installation.token, params, req_options(channel))

  @doc "Returns the channel's `:req_options`, merged into every request it makes."
  @spec req_options(WardrikChannel.Channel.t()) :: keyword()
  def req_options(%WardrikChannel.Channel{options: options}),
    do: Keyword.get(options, :req_options, [])

  @doc "Calls `method` with `options` as Req takes them, and returns Slack's reply."
  @spec call(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(method, options) do
    case Req.post(@api <> method, options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = reply}} -> {:ok, reply}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Answers a button press at its `response_url` with `reply`, which replaces the message or is seen
  by the person who pressed alone. A failure is logged, since the press was acted on either way.
  """
  @spec respond(String.t() | nil, map(), keyword()) :: :ok
  def respond(nil, _reply, _req_options), do: :ok

  def respond(url, reply, req_options) do
    case Req.post(url, [json: reply] ++ req_options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      other -> Logger.warning("Slack didn't take an answer to a button: #{inspect(other)}")
    end

    :ok
  end
end
