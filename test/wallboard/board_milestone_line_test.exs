defmodule Wallboard.BoardMilestoneLineTest do
  # Above the cards on the Agents tab, one line for each milestone a live
  # session's issue is in (issue #144), on the real board page. A title is
  # GitHub text: it is drawn, but never printed when the page crashes. One
  # at a time: the settings, the endpoint and the log are this whole test
  # run's.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Wallboard.{MilestoneTitles, Settings}

  @endpoint WallboardWeb.Endpoint

  setup do
    old_settings = :persistent_term.get({Settings, :settings}, nil)
    endpoint = Application.get_env(:wallboard, @endpoint, [])

    Application.put_env(
      :wallboard,
      @endpoint,
      Keyword.merge(endpoint, secret_key_base: String.duplicate("k", 64), server: false)
    )

    settings =
      Settings.merge(Settings.defaults(), %{
        archive: %{enabled: false, collect_local: false, advertise: false},
        new_relic: %{enabled: false}
      })

    :persistent_term.put({Settings, :settings}, settings)
    start_supervised!(@endpoint)

    unless Process.whereis(MilestoneTitles), do: start_supervised!(MilestoneTitles)

    on_exit(fn ->
      if old_settings,
        do: :persistent_term.put({Settings, :settings}, old_settings),
        else: :persistent_term.erase({Settings, :settings})

      Application.put_env(:wallboard, @endpoint, endpoint)
    end)

    :ok
  end

  defp open_board do
    conn =
      put_connect_params(build_conn(), %{
        "asset_version" => WallboardWeb.Layouts.asset_version()
      })

    {:ok, view, _html} = live_isolated(conn, WallboardWeb.BoardLive, session: %{})
    view
  end

  defp milestone(number, done, total, title) do
    MilestoneTitles.put("acme/shop", number, title)

    %{
      repo: "acme/shop",
      number: number,
      done: done,
      total: total,
      title_hash: :erlang.phash2(title)
    }
  end

  defp tell(view, milestones) do
    facts = %{sessions: %{}, milestones: milestones}
    send(view.pid, {:source, :session_issues, facts, %{error: nil}})
    render(view)
  end

  defp lines(html) do
    ~r{<p class="milestone-line">(.*?)</p>}s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [text] -> text |> String.split() |> Enum.join(" ") end)
  end

  test "one line for each milestone being worked, with its name and how many are done" do
    view = open_board()
    assert lines(render(view)) == []

    one = milestone(11, 3, 8, "Project tab: 1. Know what each session is working on")

    assert lines(tell(view, [one])) == [
             "Project tab: 1. Know what each session is working on · 3 of 8 done"
           ]

    two = milestone(12, 0, 6, "Project tab: 2. Wiki")

    assert lines(tell(view, [one, two])) == [
             "Project tab: 1. Know what each session is working on · 3 of 8 done",
             "Project tab: 2. Wiki · 0 of 6 done"
           ]

    # One that closes counts at once.
    assert lines(tell(view, [%{one | done: 4}])) == [
             "Project tab: 1. Know what each session is working on · 4 of 8 done"
           ]

    assert lines(tell(view, [])) == []
  end

  test "a page that crashes for another reason prints no milestone title" do
    Process.flag(:trap_exit, true)
    view = open_board()
    planted = milestone(31, 2, 5, "PLANTED milestone title")
    assert lines(tell(view, [planted])) == ["PLANTED milestone title · 2 of 5 done"]

    # The page takes any message or event, so crash it with a call nothing
    # takes, far from the line.
    log =
      capture_log(fn ->
        ref = Process.monitor(view.pid)
        catch_exit(GenServer.call(view.pid, :not_an_event_the_board_handles, 1_000))
        assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
        Process.sleep(200)
      end)

    # The crash was reported, with the page's state, and the title was not
    # in it.
    assert log =~ "not_an_event_the_board_handles"
    assert log =~ "assigns"
    refute log =~ "PLANTED"
  end
end
