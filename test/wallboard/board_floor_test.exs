defmodule Wallboard.BoardFloorTest do
  # The Floor tab on the real board page: the cast the browser draws, and
  # the talk box that opens when someone on the floor is tapped. One at a
  # time: the settings and the endpoint are this whole test run's.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Wallboard.Settings

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
        new_relic: %{enabled: false},
        # A loaded settings file always says yes or no here.
        approve_devices: false
      })

    :persistent_term.put({Settings, :settings}, settings)
    start_supervised!(@endpoint)

    on_exit(fn ->
      if old_settings,
        do: :persistent_term.put({Settings, :settings}, old_settings),
        else: :persistent_term.erase({Settings, :settings})

      Application.put_env(:wallboard, @endpoint, endpoint)
    end)

    :ok
  end

  defp conn do
    put_connect_params(build_conn(), %{"asset_version" => WallboardWeb.Layouts.asset_version()})
  end

  defp open_board do
    {:ok, view, _html} = live_isolated(conn(), WallboardWeb.BoardLive, session: %{})
    view
  end

  defp card(id, more) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Map.merge(
      %{
        key: "main:" <> id,
        session_id: id,
        name: id,
        short_id: id,
        account: nil,
        folder: id,
        cwd: nil,
        repo: "shop",
        gh_repo: "acme/shop",
        status: :working,
        task: "Running the tests",
        why: nil,
        since: now,
        updated_at: now,
        tool: :claude
      },
      Map.new(more)
    )
  end

  defp tell(view, cards) do
    send(view.pid, {:stream, cards})
    render(view)
  end

  # The cast as the browser reads it from the page.
  defp cast(html) do
    [json] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#floor-room")
      |> LazyHTML.attribute("data-cast")

    Jason.decode!(json)
  end

  test "Floor is a tab between Agents and Git" do
    html = render(open_board())

    assert Regex.scan(~r/class="board-tab"[^>]*data-tab="(\w+)"/, html, capture: :all_but_first) ==
             [["agents"], ["floor"], ["git"]]

    assert html =~ ~s(aria-label="Floor")
    assert cast(html) == []
  end

  test "the cast holds every live session: who they are and what they are doing" do
    waited = DateTime.add(DateTime.utc_now(), -700, :second)

    html =
      tell(open_board(), [
        card("Foreman of the shop", status: :needs, why: "Who goes first?", since: waited),
        card("KOR-12 cart", []),
        card("old one",
          status: :idle,
          updated_at: DateTime.add(DateTime.utc_now(), -3 * 86_400 - 60)
        )
      ])

    assert [
             %{"name" => "Foreman of the shop", "role" => "foreman", "mood" => "needs"} = boss,
             %{"tag" => "KOR-12", "role" => "worker", "mood" => "working"} = worker,
             %{"name" => "old one", "mood" => "asleep", "days" => 3}
           ] = cast(html)

    assert boss["urgency"] == 3 and boss["says"] == "Who goes first?"
    assert worker["says"] == "Running the tests" and worker["crew"] == "shop"
    assert html =~ "1 need you" and html =~ "1 asleep"
  end

  test "tapping someone opens their talk box, and it closes again" do
    view = open_board()
    tell(view, [card("KOR-12 cart", status: :needs, why: "May I delete <b>the</b> seed?")])

    html = render_hook(view, "floor_talk", %{"key" => "main:KOR-12 cart"})

    [box] =
      Regex.run(~r{<div class="detail detail-small floor-talk".*?</div>\s*</div>\s*</div>}s, html)

    assert box =~ "KOR-12 cart"
    assert box =~ "Worker"
    assert box =~ "Needs you. Waiting"
    # A session's words are text, never markup.
    assert box =~ "May I delete &lt;b&gt;the&lt;/b&gt; seed?"
    refute box =~ "<b>the</b>"
    # The Claude app opens a session only for the person at the board's own machine.
    refute box =~ "Open session"

    refute render_click(view, "floor_close") =~ "floor-talk"
  end

  test "a tap on someone who has left opens nothing" do
    view = open_board()
    tell(view, [card("a", [])])

    refute render_hook(view, "floor_talk", %{"key" => "main:gone"}) =~ "floor-talk\""
  end

  test "the talk box goes when its session does" do
    view = open_board()
    tell(view, [card("a", [])])
    assert render_hook(view, "floor_talk", %{"key" => "main:a"}) =~ ~s(floor-talk")

    refute tell(view, []) =~ ~s(floor-talk")
  end

  test "/?floor=demo shows a made-up cast, and says so" do
    {:ok, view, html} = live(conn(), "/?floor=demo")

    assert html =~ "Made-up cast"
    assert length(cast(render(view))) == length(Wallboard.Floor.demo(DateTime.utc_now()))
    # The Agents tab still counts the real sessions: none here.
    assert render(view) =~ "No Claude sessions running."
  end
end
