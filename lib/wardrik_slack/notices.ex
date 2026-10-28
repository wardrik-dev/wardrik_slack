defmodule WardrikSlack.Notices do
  @moduledoc """
  Lays out a notice as one Slack message in a room. A parked turn's calls show as a thread's do,
  with Approve and Deny, naming the approvers it asks; a failed turn says why; a finished turn
  shows what it answered, under the agent's name. The agent is named as the workspace shows it,
  without its owner, whose workspace it is.
  """

  alias WardrikChannel.Waiting
  alias WardrikSlack.Blocks

  @doc "Returns the message that tells of `notice`, asking `approvers`, naming its agent `agent`."
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
