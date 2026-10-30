defmodule WardrikSlack.Approvers do
  @moduledoc """
  Finds approvers' Slack member IDs, to message each directly.

  | Approver      | Looked up with          | Scope              |
  | ------------- | ----------------------- | ------------------ |
  | `U024BE7LH`   | used as is              |                    |
  | `maria@...`   | `users.lookupByEmail`   | `users:read.email` |
  | `@maria`      | `users.list`            | `users:read`       |

  Deleted members are skipped. Approvers are looked up each time a call waits. Nothing is cached.
  """

  alias WardrikChannel.Workspace
  alias WardrikSlack.API

  @doc """
  Returns each approver with its member ID, or `:error` if Slack has none.

      WardrikSlack.Approvers.members(workspace, ["@maria", "nobody@example.com"])
      #=> [{"@maria", {:ok, "U024BE7LH"}}, {"nobody@example.com", :error}]
  """
  @spec members(Workspace.t(), [String.t()]) :: [{String.t(), {:ok, String.t()} | :error}]
  def members(workspace, approvers) do
    handles = handles(workspace, approvers)
    for approver <- approvers, do: {approver, member(workspace, approver, handles)}
  end

  @doc "Returns whether `approver` is a Slack member ID, such as `U024BE7LH`."
  @spec id?(String.t()) :: boolean()
  def id?(approver), do: Regex.match?(~r/\A[UW][A-Z0-9]+\z/, approver)

  defp member(_workspace, "@" <> handle, handles), do: Map.fetch(handles, handle)

  defp member(workspace, approver, _handles) do
    if id?(approver), do: {:ok, approver}, else: by_email(workspace, approver)
  end

  defp by_email(workspace, email) do
    case API.read_in(workspace, "users.lookupByEmail", %{email: email}) do
      {:ok, %{"user" => %{"id" => id}}} -> {:ok, id}
      _unknown -> :error
    end
  end

  defp handles(workspace, approvers) do
    if Enum.any?(approvers, &String.starts_with?(&1, "@")),
      do: listed(workspace, nil, %{}),
      else: %{}
  end

  defp listed(workspace, cursor, found) do
    case API.read_in(workspace, "users.list", %{limit: 200, cursor: cursor}) do
      {:ok, %{"members" => members} = page} ->
        found = Map.merge(found, active(members))
        next(workspace, get_in(page, ["response_metadata", "next_cursor"]), found)

      _unlisted ->
        found
    end
  end

  defp next(_workspace, cursor, found) when cursor in [nil, ""], do: found
  defp next(workspace, cursor, found), do: listed(workspace, cursor, found)

  defp active(members) do
    members
    |> Enum.reject(fn member -> member["deleted"] == true end)
    |> Map.new(fn member -> {member["name"], member["id"]} end)
  end
end
