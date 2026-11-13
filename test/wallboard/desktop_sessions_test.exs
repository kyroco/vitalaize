defmodule Wallboard.DesktopSessionsTest do
  # The address behind the Floor tab's "Open session" button: the Claude
  # app's own id for a session, read from the files the app keeps.
  use ExUnit.Case, async: true

  alias Wallboard.DesktopSessions

  @cli "c48bc021-bf38-4440-8ac2-2312348daf29"
  @local "local_a22acfae-8909-42d6-bd22-17b749816aea"

  setup do
    dir = Wallboard.Fixtures.tmp_path("desktop-sessions")
    File.mkdir_p!(Path.join([dir, "account", "org"]))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp put(dir, name, body) do
    path = Path.join([dir, "account", "org", name])
    File.write!(path, if(is_binary(body), do: body, else: Jason.encode!(body)))
    path
  end

  test "gives the address for the app's own id", %{dir: dir} do
    put(dir, @local <> ".json", %{"sessionId" => @local, "cliSessionId" => @cli})

    put(dir, "local_other.json", %{
      "sessionId" => "local_0000aaaa-0000-0000-0000-000000000000",
      "cliSessionId" => "11111111-2222-3333-4444-555555555555"
    })

    assert DesktopSessions.link(@cli, dir) == "claude://code/continue?session=" <> @local
  end

  test "a session the app did not start has no address", %{dir: dir} do
    put(dir, @local <> ".json", %{"sessionId" => @local, "cliSessionId" => @cli})

    assert DesktopSessions.link("99999999-2222-3333-4444-555555555555", dir) == nil
  end

  test "a file that only mentions the id somewhere else is not that session's", %{dir: dir} do
    put(dir, @local <> ".json", %{
      "sessionId" => @local,
      "cliSessionId" => "11111111-2222-3333-4444-555555555555",
      "lastAssistantCliSessionId" => @cli
    })

    assert DesktopSessions.link(@cli, dir) == nil
  end

  test "an id of another shape in the file is never put in an address", %{dir: dir} do
    put(dir, "local_bad.json", %{
      "sessionId" => "local_x\"><script>",
      "cliSessionId" => @cli
    })

    assert DesktopSessions.link(@cli, dir) == nil
  end

  test "a broken file, a missing folder or no id gives nothing", %{dir: dir} do
    put(dir, "local_broken.json", "{not json " <> @cli)

    assert DesktopSessions.link(@cli, dir) == nil
    assert DesktopSessions.link(@cli, Path.join(dir, "nowhere")) == nil
    assert DesktopSessions.link(nil, dir) == nil
    assert DesktopSessions.link("not-an-id", dir) == nil
  end
end
