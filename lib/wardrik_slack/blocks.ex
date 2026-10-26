defmodule WardrikSlack.Blocks do
  @moduledoc "Builds the Block Kit blocks Wardrik's messages are made of."

  @max_markdown 12_000

  @doc "Returns a section of `mrkdwn` text."
  @spec section(String.t()) :: map()
  def section(text), do: %{type: "section", text: %{type: "mrkdwn", text: text}}

  @doc "Returns a line of small `mrkdwn` text."
  @spec context(String.t()) :: map()
  def context(text), do: %{type: "context", elements: [%{type: "mrkdwn", text: text}]}

  @doc "Returns a block of Markdown, as a model writes it, clipped to Slack's limit."
  @spec markdown(String.t()) :: map()
  def markdown(text), do: %{type: "markdown", text: clip(text, @max_markdown)}

  @doc "Returns a row of buttons, or other elements, under `block_id`."
  @spec actions(String.t(), [map()]) :: map()
  def actions(block_id, elements), do: %{type: "actions", block_id: block_id, elements: elements}

  @doc "Returns a button that sends `value` under `action_id`, styled `primary` or `danger` if given."
  @spec button(String.t(), String.t(), String.t(), String.t() | nil) :: map()
  def button(label, action_id, value, style \\ nil) do
    button = %{type: "button", text: plain(label), action_id: action_id, value: value}
    if style, do: Map.put(button, :style, style), else: button
  end

  @doc "Returns plain text, as buttons and options take it."
  @spec plain(String.t()) :: map()
  def plain(text), do: %{type: "plain_text", text: text}

  @doc "Returns a reply to a button that the person who pressed it sees alone."
  @spec ephemeral(String.t()) :: map()
  def ephemeral(text), do: %{response_type: "ephemeral", replace_original: false, text: text}

  @doc "Returns `text` cut to `max` characters, ending in `…` where it was cut."
  @spec clip(String.t(), pos_integer()) :: String.t()
  def clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
