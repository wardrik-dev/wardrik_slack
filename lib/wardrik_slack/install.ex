defmodule WardrikSlack.Install do
  @moduledoc """
  Adds one Slack app to many workspaces, one for each org. Give the channel `client_id` and
  `client_secret`, from **Basic Information**, and `installations: :stored`. Set the app's
  **Redirect URL**, under **OAuth & Permissions**, to a route of your app's own, and pass it as
  `redirect_uri` too.

      {:ok, channel} = WardrikChannel.fetch(MyApp.Wardrik, "slack")
      {:ok, url} = WardrikSlack.Install.url(channel, "acme", return_to: "/settings/slack")

  Send someone signed in for the org to `url`. Slack sends them back to your route, which hands
  what Slack sent to `installed/3`, for the org they act for:

      case WardrikSlack.Install.installed(channel, "acme", conn.query_params) do
        {:ok, _installation, return_to} -> redirect(conn, external: return_to || "/")
        {:error, message} -> send_resp(conn, 400, message)
      end

  The link lasts ten minutes, and carries the owner it was made for, signed with the client
  secret, so someone else's link can't add a workspace for you. A new workspace takes the
  channel's `approvers`.
  """

  alias Wardrik.Channel.Installation
  alias WardrikChannel.Channel
  alias WardrikSlack.API

  @authorize "https://slack.com/oauth/v2/authorize"
  @scopes ~w(channels:history channels:read chat:write chat:write.public groups:history
             groups:read reactions:write users:read users:read.email)
  @expires 600

  @doc "Returns the bot scopes the app asks for."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "Returns where to send someone adding the app for `owner`. Takes `:return_to`."
  @spec url(Channel.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def url(channel, owner, opts \\ []) do
    with {:ok, id, secret} <- client(channel) do
      state =
        sign(
          %{"o" => owner, "r" => opts[:return_to], "e" => System.os_time(:second) + @expires},
          secret
        )

      query =
        [
          client_id: id,
          scope: Enum.join(@scopes, ","),
          state: state,
          redirect_uri: channel.options[:redirect_uri]
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> URI.encode_query()

      {:ok, @authorize <> "?" <> query}
    end
  end

  @doc """
  Adds the app to the workspace Slack sent someone back from, for `owner`, given the query Slack
  sent. Returns the installation and where to send them, or why it couldn't.
  """
  @spec installed(Channel.t(), String.t(), map()) ::
          {:ok, Installation.t(), String.t() | nil} | {:error, String.t()}
  def installed(channel, owner, query) do
    with {:ok, id, secret} <- client(channel),
         {:ok, state} <- verified(query["state"], secret, owner),
         {:ok, code} <- code(query),
         {:ok, installation} <- exchange(channel, code, {id, secret}, owner),
         :ok <- Channel.install(channel, installation) do
      {:ok, installation, state["r"]}
    end
  end

  defp client(%Channel{name: name, options: options}) do
    case {options[:client_id], options[:client_secret]} do
      {id, secret} when is_binary(id) and is_binary(secret) ->
        {:ok, id, secret}

      _unnamed ->
        {:error,
         "#{name} is added with its token alone. Give it client_id and client_secret to add it to more workspaces."}
    end
  end

  defp code(%{"code" => code}) when is_binary(code), do: {:ok, code}

  defp code(%{"error" => error}),
    do: {:error, "Slack didn't add the app: #{error}. Start again to add it."}

  defp code(_query), do: {:error, "Slack sent no code back. Start again to add the app."}

  defp exchange(channel, code, {id, secret}, owner) do
    form =
      Enum.reject(
        [
          client_id: id,
          client_secret: secret,
          code: code,
          redirect_uri: channel.options[:redirect_uri]
        ],
        fn {_key, value} -> is_nil(value) end
      )

    case API.call("oauth.v2.access", [form: form] ++ API.req_options(channel)) do
      {:ok, %{"access_token" => token, "team" => %{"id" => team} = workspace}} ->
        {:ok,
         %Installation{
           channel: channel.name,
           workspace: team,
           name: workspace["name"],
           owner: owner,
           token: token,
           approvers: channel.approvers
         }}

      {:error, reason} ->
        {:error,
         "Slack didn't give the app its token (#{inspect(reason)}). Start again to add it."}
    end
  end

  defp sign(state, secret) do
    payload = state |> JSON.encode!() |> Base.url_encode64(padding: false)
    payload <> "." <> mac(payload, secret)
  end

  defp verified(text, secret, owner) when is_binary(text) do
    with [payload, mac] <- String.split(text, ".", parts: 2),
         true <- same?(mac, mac(payload, secret)),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"o" => ^owner, "e" => expires} = state} <- JSON.decode(json),
         true <- System.os_time(:second) <= expires do
      {:ok, state}
    else
      _unverified -> refused()
    end
  end

  defp verified(_none, _secret, _owner), do: refused()

  defp refused,
    do:
      {:error,
       "This was started by someone else, for another org, or too long ago. Start again to add the app."}

  defp same?(given, expected),
    do: byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)

  defp mac(payload, secret),
    do: :hmac |> :crypto.mac(:sha256, secret, payload) |> Base.url_encode64(padding: false)
end
