defmodule Wallboard.DesktopSessions do
  @moduledoc """
  The address that opens a session in the Claude desktop app, for the Floor
  tab's "Open session" button.

  The app knows a session by an id of its own, `local_…`, which is not the
  id `claude agents` reports. It keeps one file for each session it
  started, named after its own id, under
  `~/Library/Application Support/Claude/claude-code-sessions`, and that
  file holds the other id as `cliSessionId` (seen on Claude 2.1.322,
  November 13, 2026). The files are undocumented, so every step is
  optional: no folder, no file or a changed shape means no address, and
  the button is left out. A session started in a terminal has no file
  there, so it has no button either.
  """

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @local ~r/\Alocal_[0-9a-f-]{8,64}\z/

  @doc "Where the app keeps its session files on this Mac."
  def default_dir,
    do: Path.expand("~/Library/Application Support/Claude/claude-code-sessions")

  @doc """
  `claude://code/continue?session=local_…` for the session `claude agents`
  calls `session_id`, or nil when the app has no session by that id.
  """
  def link(session_id, dir \\ default_dir())

  def link(session_id, dir) when is_binary(session_id) do
    if Regex.match?(@uuid, session_id) do
      dir
      |> files_newest_first()
      |> Enum.find_value(&local_id(&1, session_id))
      |> case do
        nil -> nil
        local -> "claude://code/continue?session=" <> local
      end
    end
  end

  def link(_session_id, _dir), do: nil

  # A live session's file was written lately, so the newest are read first
  # and the search stops at the first match.
  defp files_newest_first(dir) do
    [dir, "*", "*", "local_*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> {mtime, path}
        _ -> {0, path}
      end
    end)
    |> Enum.sort(:desc)
    |> Enum.map(&elem(&1, 1))
  end

  # The app's own id for the session in this file, when the file is that
  # session's. The id goes into an address, so only the app's own shape of
  # id is taken from the file.
  defp local_id(path, session_id) do
    with {:ok, text} <- File.read(path),
         true <- String.contains?(text, session_id),
         {:ok, %{"cliSessionId" => ^session_id, "sessionId" => local}} <- Jason.decode(text),
         true <- is_binary(local) and Regex.match?(@local, local) do
      local
    else
      _ -> nil
    end
  end
end
