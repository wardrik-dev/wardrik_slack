defmodule WardrikSlack.Notices do
  @moduledoc """
  Lays out a `Wardrik.Notice` as one Slack message.

  | Notice      | Message                                                        |
  | ----------- | -------------------------------------------------------------- |
  | `:parked`   | the waiting calls, with Approve and Deny, naming the approvers |
  | `:failed`   | why it failed                                                  |
  | `:finished` | the answer, under the agent's name                             |

  The agent is named without its owner, as `triage`. See `WardrikSlack.Rooms.shown/2`.
  """

  alias WardrikChannel.Waiting
  alias WardrikSlack.Blocks

  @doc "Returns the message for `notice`. `agent` is the name to show; `approvers` are asked about a parked turn."
  @spec message(Wardrik.Notice.t(), [String.t()], String.t()) ::
          %{text: String.t(), blocks: [map()]}
  def message(%Wardrik.Notice{kind: :parked} = notice, approvers, agent) do
    calls = Waiting.from_notice(notice)
    text = "`#{agent}` waits on #{who(approvers)} to #{WardrikSlack.Waiting.asked(calls)}."
    %{text: text, blocks: [Blocks.section(text) | WardrikSlack.Waiting.calls_blocks(calls)]}
  end

  def message(%Wardrik.Notice{kind: :failed} = notice, _approvers, agent) do
    text = ":warning: `#{agent}` stopped with an error: #{notice.reason}"
    %{text: text, blocks: [Blocks.section(text)]}
  end

  def message(%Wardrik.Notice{kind: :finished, text: text}, _approvers, agent) do
    %{
      text: Blocks.clip("#{agent}: #{text}", 3_000),
      blocks: [Blocks.context("From `#{agent}`"), Blocks.markdown(text || "")]
    }
  end

  defp who([]), do: "an approver"
  defp who(approvers), do: WardrikSlack.Waiting.named(approvers)
end
