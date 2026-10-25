defmodule Wallboard.BoardSessionIssuesTest do
  # A session's card on the Agents tab names the issue it is on (issue
  # #143), from what the issue finder says about each session.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Wallboard.Settings
  alias WallboardWeb.BoardLive

  @now ~U[2026-10-20 15:00:00Z]

  defp session(id, name) do
    %{
      key: "main:" <> id,
      session_id: id,
      name: name,
      short_id: String.slice(id, 0, 8),
      account: nil,
      folder: "/nowhere/" <> name,
      cwd: nil,
      repo: "shop",
      status: :working,
      task: "working on it",
      why: nil,
      since: @now,
      updated_at: @now,
      tool: :claude
    }
  end

  defp socket(sessions) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        settings: Settings.defaults(),
        now: @now,
        claude: %{sessions: sessions},
        codex: nil,
        stream: [],
        repo_of: %{}
      }
    }
  end

  test "the finder's answer puts the issue on its session, and only on that one" do
    socket = socket([session("aaaa1111", "login"), session("bbbb2222", "notes")])
    facts = %{sessions: %{"main:aaaa1111" => %{repo: "acme/shop", number: 1418}}}

    assert {:noreply, socket} =
             BoardLive.handle_info({:source, :session_issues, facts, %{error: nil}}, socket)

    issues = Map.new(socket.assigns.working, &{&1.session_id, &1[:issue]})
    assert issues == %{"aaaa1111" => 1418, "bbbb2222" => nil}
  end

  test "before the finder has answered, no session has an issue" do
    socket = socket([session("aaaa1111", "login")])
    assert {:noreply, socket} = BoardLive.handle_info({:stream, []}, socket)
    assert [%{issue: nil}] = socket.assigns.working
  end

  test "the card shows the issue beside its repository, and nothing when there is none" do
    found =
      render_component(&BoardLive.session_card/1, s: Map.put(session("a", "login"), :issue, 1418))

    assert found =~ ~r{class="sc-issue"[^>]*>\s*#1418\s*<}

    none =
      render_component(&BoardLive.session_card/1, s: Map.put(session("b", "notes"), :issue, nil))

    refute none =~ "sc-issue"
  end

  test "an issue in another repository than the session's names its repository" do
    socket = socket([session("aaaa1111", "login")])
    facts = %{sessions: %{"main:aaaa1111" => %{repo: "vendor/lib", number: 12}}}

    {:noreply, socket} =
      BoardLive.handle_info({:source, :session_issues, facts, %{error: nil}}, socket)

    [card] = socket.assigns.working
    html = render_component(&BoardLive.session_card/1, s: card)
    assert html =~ ~r{class="sc-issue"[^>]*>\s*vendor/lib#12\s*<}

    # The session's own repository, in any capitals, is left out.
    own = Map.merge(session("b", "notes"), %{issue: 7, issue_repo: "Acme/SHOP"})
    assert render_component(&BoardLive.session_card/1, s: own) =~ ~r{>\s*#7\s*<}
  end
end
