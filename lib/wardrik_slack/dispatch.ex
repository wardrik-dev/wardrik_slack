defmodule WardrikSlack.Dispatch do
  @moduledoc """
  Hands what Slack sends, over Socket Mode or HTTP alike, to what acts on it, in the workspace it
  came from. A message goes to `WardrikSlack.Messages`, the bot joining or leaving a Slack channel
  to `WardrikSlack.Rooms`, and a button to `WardrikSlack.Rooms` or `WardrikSlack.Answers`. The app
  taken out of a workspace forgets its installation there.
  """

  require Logger

  alias WardrikChannel.Channel
  alias WardrikSlack.Answers
  alias WardrikSlack.Messages
  alias WardrikSlack.Rooms

  @doc "Acts on an event callback, as Slack sends one."
  @spec event(Channel.t(), map()) :: term()
  def event(channel, %{"team_id" => team, "event" => %{"type" => type}})
      when type in ["app_uninstalled", "tokens_revoked"] do
    WardrikChannel.Channel.uninstall(channel, team)
  end

  def event(channel, %{"team_id" => team, "event" => %{"type" => type} = event} = callback) do
    handler = if type == "message", do: Messages, else: Rooms
    within(channel, team, &handler.event(&1, event, bot(callback)))
  end

  def event(_channel, _callback), do: :ignored

  @doc "Acts on a button press, or a choice from a menu, as Slack sends one."
  @spec interactive(Channel.t(), map()) :: term()
  def interactive(
        channel,
        %{"team" => %{"id" => team}, "actions" => [%{"action_id" => action} | _rest]} = payload
      ) do
    handler = if String.starts_with?(action, "wardrik_room"), do: Rooms, else: Answers
    within(channel, team, &handler.answer(&1, payload))
  end

  def interactive(_channel, _payload), do: :ignored

  defp bot(%{"authorizations" => [%{"user_id" => bot} | _rest]}), do: bot
  defp bot(_callback), do: nil

  defp within(channel, team, act) do
    case WardrikChannel.workspace(channel, team) do
      {:ok, workspace} ->
        act.(workspace)

      :error ->
        Logger.warning("#{channel.name} isn't added to the Slack workspace #{team}.")
        :ignored
    end
  end
end
