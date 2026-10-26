defmodule WardrikSlack.Waiting do
  @moduledoc """
  Lays out the calls an agent waits on as one Slack message. Each call shows its tool, the
  policy's question and its arguments, with a box for a note and Approve and Deny buttons. A call
  waiting on a sign-in has Show link in place of Approve, which tells whoever presses it alone
  where to sign in.

  Each button carries the conversation, the call and who asked, which `WardrikSlack.Answers` reads
  back. Slack hands a button back as the bot posted it, and nobody else can change a bot's message.
  """

  alias WardrikChannel.Waiting
  alias WardrikSlack.Blocks

  @note "wardrik-note:"
  @max_arguments 1_500

  @doc "Returns the message that asks `approvers` about `calls`."
  @spec message([Waiting.t()], [String.t()] | :anyone) :: %{text: String.t(), blocks: [map()]}
  def message(calls, approvers) do
    text = "#{who(approvers)} #{asked(calls)}."
    %{text: text, blocks: [Blocks.section(text) | Enum.flat_map(calls, &blocks/1)]}
  end

  @doc "Returns the id of the box a note on the call `id` is written in."
  @spec note_block(String.t()) :: String.t()
  def note_block(id), do: @note <> id

  @doc "Returns the id of the buttons of the call `id`."
  @spec buttons_block(String.t()) :: String.t()
  def buttons_block(id), do: "wardrik:" <> id

  defp who(:anyone), do: "Anyone here may"
  defp who([]), do: "Waiting on whoever asked to"
  defp who(approvers), do: "Waiting on #{named(approvers)} to"

  @doc "Returns `approvers` as a sentence names them, as `@maria or @jon`."
  @spec named([String.t()]) :: String.t()
  def named([only]), do: mention(only)

  def named(approvers) do
    {most, [last]} = Enum.split(approvers, -1)
    Enum.map_join(most, ", ", &mention/1) <> " or " <> mention(last)
  end

  defp mention(approver) do
    if Regex.match?(~r/\A[UW][A-Z0-9]+\z/, approver), do: "<@#{approver}>", else: approver
  end

  defp asked(calls), do: Enum.map_join(calls, " and ", &ask/1)

  defp ask(%Waiting{interrupt: %{reason: :authorization, name: name}}),
    do: "sign in for `#{name}`"

  defp ask(%Waiting{interrupt: %{name: name}}), do: "approve `#{name || "the model"}`"

  defp blocks(%Waiting{interrupt: interrupt} = waiting) do
    value =
      JSON.encode!(%{
        c: waiting.conversation,
        i: interrupt.id,
        a: waiting.asked_by,
        n: interrupt.name || "the model"
      })

    [question(waiting)] ++
      note_box(interrupt) ++
      [Blocks.actions(buttons_block(interrupt.id), buttons(interrupt, value))]
  end

  defp question(%Waiting{interrupt: interrupt, arguments: arguments}) do
    lines = [
      "`#{interrupt.name || "the model"}`  #{interrupt.message}",
      read(interrupt.labels),
      shown(arguments)
    ]

    lines |> Enum.reject(&(&1 == "")) |> Enum.join("\n") |> Blocks.section()
  end

  defp read(labels) when is_list(labels) do
    if "outside" in labels,
      do: "_It has read content from outside, which may be what asked for this._",
      else: ""
  end

  defp read(_labels), do: ""

  defp shown(nil), do: ""
  defp shown(arguments), do: "```#{Blocks.clip(JSON.encode!(arguments), @max_arguments)}```"

  defp note_box(%{reason: :authorization}), do: []

  defp note_box(interrupt) do
    [
      %{
        type: "input",
        block_id: note_block(interrupt.id),
        optional: true,
        label: Blocks.plain("A note for the agent, sent with either button"),
        element: %{type: "plain_text_input", action_id: "note", multiline: true}
      }
    ]
  end

  defp buttons(%{reason: :authorization}, value),
    do: [
      Blocks.button("Show link", "wardrik_link", value, "primary"),
      Blocks.button("Deny", "wardrik_deny", value, "danger")
    ]

  defp buttons(_interrupt, value),
    do: [
      Blocks.button("Approve", "wardrik_approve", value, "primary"),
      Blocks.button("Deny", "wardrik_deny", value, "danger")
    ]
end
