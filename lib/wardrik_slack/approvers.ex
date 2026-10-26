defmodule WardrikSlack.Approvers do
  @moduledoc """
  Finds a workspace's approvers as Slack knows them, to message each directly. A member ID is
  taken as it is. An email address is looked up with `users.lookupByEmail`, which needs the
  `users:read.email` scope, and a `@handle` among the workspace's members with `users.list`, which
  needs `users:read`. Each is looked up as a call waits, and nothing is kept.
  """

  alias WardrikChannel.Workspace
  alias WardrikSlack.API

  @doc "Returns each of `approvers` with the member ID it names, or `:error` where Slack found none."
  @spec members(Workspace.t(), [String.t()]) :: [{String.t(), {:ok, String.t()} | :error}]
  def members(workspace, approvers) do
    handles = handles(workspace, approvers)
    for approver <- approvers, do: {approver, member(workspace, approver, handles)}
  end

  @doc "Returns whether `approver` is a Slack member ID, as `U024BE7LH`."
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
