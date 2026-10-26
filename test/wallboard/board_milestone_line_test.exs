defmodule Wallboard.BoardMilestoneLineTest do
  # Above the cards on the Agents tab, one box for each milestone a live
  # session's issue is in (issues #144 and #168), on the real board page. A
  # title is GitHub text: it is drawn, but never printed when the page
  # crashes. One at a time: the settings, the endpoint and the log are this
  # whole test run's.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Wallboard.{MilestoneTitles, Settings}

  @endpoint WallboardWeb.Endpoint

  setup context do
    old_settings = :persistent_term.get({Settings, :settings}, nil)
    endpoint = Application.get_env(:wallboard, @endpoint, [])

    Application.put_env(
      :wallboard,
      @endpoint,
      Keyword.merge(endpoint, secret_key_base: String.duplicate("k", 64), server: false)
    )

    settings =
      Settings.merge(Settings.defaults(), %{
        archive: %{enabled: !!context[:archive], collect_local: false, advertise: false},
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

  @now ~U[2026-10-20 15:00:00Z]

  # A live card from a collector, as Wallboard.Link.Sessions gives it.
  defp card(id) do
    %{
      key: "main:" <> id,
      session_id: id,
      name: id,
      short_id: id,
      account: nil,
      folder: "/nowhere/" <> id,
      cwd: nil,
      repo: "shop",
      gh_repo: "acme/shop",
      status: :working,
      task: "working on it",
      why: nil,
      since: @now,
      updated_at: @now,
      tool: :claude
    }
  end

  defp milestone(repo \\ "acme/shop", number, done, total, title, sessions \\ ["main:a"]) do
    %{
      repo: repo,
      number: number,
      done: done,
      total: total,
      rev: MilestoneTitles.put(repo, number, title),
      sessions: sessions
    }
  end

  defp tell(view, milestones, cards \\ [card("a")]) do
    send(view.pid, {:stream, cards})
    facts = %{sessions: %{}, milestones: milestones}
    send(view.pid, {:source, :session_issues, facts, %{error: nil}})
    render(view)
  end

  defp tell_issues(view, milestones, cards, issues) do
    send(view.pid, {:stream, cards})
    facts = %{sessions: issues, milestones: milestones}
    send(view.pid, {:source, :session_issues, facts, %{error: nil}})
    render(view)
  end

  # Each milestone box, read back as a person sees it.
  defp boxes(html) do
    html
    |> String.split(~s(<article class="milestone-box ))
    |> tl()
    |> Enum.map(fn box ->
      box = box |> String.split("</article>") |> hd()
      [tone] = Regex.run(~r{^(ms-\d)}, box, capture: :all_but_first)

      [width] =
        Regex.run(~r{class="ms-fill[^"]*" style="width: (\d+)%"}, box, capture: :all_but_first)

      %{
        tone: tone,
        repo: text(box, ~r{class="ms-repo">(.*?)</span>}s),
        title: text(box, ~r{class="ms-title">(.*?)</div>}s),
        left: text(box, ~r{class="ms-left">(.*?)</span>}s),
        width: width,
        done: text(box, ~r{class="ms-done">(.*?</span>.*?)</span>}s),
        agents:
          ~r{class="ms-chip">(.*?</span>)\s*</span>|class="ms-chip ms-more">(.*?)</span>}s
          |> Regex.scan(box, capture: :all_but_first)
          |> Enum.map(&(&1 |> Enum.join() |> squish()))
      }
    end)
  end

  defp titles(html), do: html |> boxes() |> Enum.map(& &1.title)

  defp text(html, re) do
    [found] = Regex.run(re, html, capture: :all_but_first)
    squish(found)
  end

  defp squish(html),
    do: html |> String.replace(~r{<[^>]*>}, " ") |> String.split() |> Enum.join(" ")

  # The class on each card's issue number, by card name.
  defp issue_classes(html) do
    ~r{<span class="sc-name">([^<]*)</span>.*?class="(sc-issue[^"]*)"}s
    |> Regex.scan(html, capture: :all_but_first)
    |> Map.new(fn [name, class] -> {name, class} end)
  end

  test "one box for each milestone being worked: repository, name, bar, counts and agents" do
    view = open_board()
    refute render(view) =~ "Milestones being worked"

    one = milestone("acme/shop", 11, 3, 8, "Checkout v2", ["main:a"])
    two = milestone("acme/shop", 12, 0, 6, "Search", ["main:b"])
    issues = %{"main:a" => %{number: 101, repo: "acme/shop"}, "main:b" => %{number: 102}}
    html = tell_issues(view, [one, two], [card("a"), card("b")], issues)

    assert html =~ "Milestones being worked"

    assert boxes(html) == [
             %{
               tone: "ms-1",
               repo: "acme/shop",
               title: "Checkout v2",
               left: "5 left · 37%",
               width: "37",
               done: "3 of 8 done",
               agents: ["#101 a"]
             },
             %{
               tone: "ms-2",
               repo: "acme/shop",
               title: "Search",
               left: "6 left · 0%",
               width: "0",
               done: "0 of 6 done",
               agents: ["#102 b"]
             }
           ]

    # The bar says the same in words, for a screen reader.
    assert html =~ ~s(aria-label="3 of 8 issues done")

    # One that closes counts at once.
    [box] = boxes(tell_issues(view, [%{one | done: 4}], [card("a")], issues))
    assert {box.left, box.width, box.done} == {"4 left · 50%", "50", "4 of 8 done"}

    # Two agents on one milestone share its box.
    both = milestone("acme/shop", 11, 8, 8, "Checkout v2", ["main:a", "main:b"])
    [box] = boxes(tell_issues(view, [both], [card("a"), card("b")], issues))
    assert {box.left, box.width, box.agents} == {"0 left · 100%", "100", ["#101 a", "#102 b"]}

    html = tell(view, [])
    assert boxes(html) == []
    refute html =~ "Milestones being worked"
  end

  test "each box names its repository as it was written" do
    view = open_board()
    one = milestone("Acme/Shop", 1, 3, 8, "v1.0")
    two = milestone("acme/api", 1, 1, 2, "v1.0")

    assert Enum.map(boxes(tell(view, [one, two])), &{&1.repo, &1.title}) == [
             {"Acme/Shop", "v1.0"},
             {"acme/api", "v1.0"}
           ]
  end

  test "a milestone's color is on its box and its cards' issue numbers; other cards' are plain" do
    view = open_board()
    one = milestone("acme/shop", 11, 3, 8, "Checkout v2", ["main:a"])
    two = milestone("acme/shop", 12, 0, 6, "Search", ["main:b"])

    issues = %{
      "main:a" => %{number: 101},
      "main:b" => %{number: 102},
      "main:c" => %{number: 103}
    }

    html = tell_issues(view, [one, two], [card("a"), card("b"), card("c"), card("d")], issues)

    assert Enum.map(boxes(html), & &1.tone) == ["ms-1", "ms-2"]

    # Card d is on no issue, so it has no number at all.
    assert issue_classes(html) == %{
             "a" => "sc-issue ms-1",
             "b" => "sc-issue ms-2",
             "c" => "sc-issue"
           }

    # Four colors; a fifth milestone takes the first again.
    five = for n <- 1..5, do: milestone("acme/shop", n, 0, 1, "M#{n}", ["main:a"])
    assert Enum.map(boxes(tell(view, five)), & &1.tone) == ~w(ms-1 ms-2 ms-3 ms-4 ms-1)
  end

  test "a milestone box goes as soon as the last card on it does" do
    view = open_board()
    one = milestone("acme/shop", 11, 3, 8, "Project tab: 1", ["main:a", "main:b"])
    assert titles(tell(view, [one], [card("a"), card("b")])) == ["Project tab: 1"]
    assert titles(tell(view, [one], [card("b")])) == ["Project tab: 1"]

    # The issue finder has not checked again yet, but no card is on it.
    send(view.pid, {:stream, []})
    assert titles(render(view)) == []
  end

  @tag archive: true
  test "with the archive on, Live, Archive and Trends are tabs, with the live counts as chips" do
    view = open_board()
    waiting = %{card("a") | status: :needs, why: "May I push?"}
    html = tell(view, [], [waiting, card("b")])

    tabs =
      ~r{<button class="view-tab([^"]*)" role="tab" aria-selected="(\w+)".*?>(.*?)</button>}s
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [on, selected, label] -> {String.trim(on), selected, squish(label)} end)

    assert [{"on", "true", "Live 2"}, {"", "false", "Archive" <> _}, {"", "false", "Trends"}] =
             tabs

    assert html =~ ~s(role="tablist" aria-label="Agents views")

    chips =
      ~r{<span class="live-chip[^"]*">(.*?)</span>(?=\s*</?(?:span|div))}s
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [chip] -> squish(chip) end)

    assert chips == ["1 need you", "1 working", "0 idle"]
  end

  test "a page that crashes for another reason prints no milestone title" do
    Process.flag(:trap_exit, true)
    view = open_board()
    planted = milestone(31, 2, 5, "PLANTED milestone title")
    assert titles(tell(view, [planted])) == ["PLANTED milestone title"]

    # The page takes any message or event, so crash it with a call nothing
    # takes, far from the box.
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

  test "the percent rounds down, so a box reads 100% only when every issue is done" do
    view = open_board()

    read = fn done, total ->
      [box] = boxes(tell(view, [milestone("acme/shop", 11, done, total, "Big", ["main:a"])]))
      {box.left, box.width}
    end

    assert read.(199, 200) == {"1 left · 99%", "99"}
    assert read.(3, 8) == {"5 left · 37%", "37"}
    assert read.(8, 8) == {"0 left · 100%", "100"}
    # A milestone with no issues yet, and counts read out of step.
    assert read.(0, 0) == {"0 left · 0%", "0"}
    assert read.(9, 8) == {"0 left · 100%", "100"}
  end

  test "each agent's name is its own part of the chip, so a long one ends in an ellipsis" do
    view = open_board()
    name = "robert/1400-checkout-flow-and-cart"
    one = milestone("acme/shop", 11, 1, 2, "Checkout", ["main:a"])
    html = tell(view, [one], [%{card("a") | name: name}])

    assert html =~ ~s(<span class="ms-chip-name" title="#{name}">#{name}</span>)
  end

  test "more milestones sit more to a row, up to four, so the cards keep their room" do
    view = open_board()

    cols = fn n ->
      ms = for i <- 1..n, do: milestone("acme/shop", i, 0, 1, "M#{i}", ["main:a"])

      [cols] =
        Regex.run(~r{class="milestone-grid[^"]*" style="--ms-cols: (\d)"}, tell(view, ms),
          capture: :all_but_first
        )

      cols
    end

    assert Enum.map([1, 2, 3, 4, 5, 8], cols) == ~w(2 2 3 4 4 4)

    # Three or more to a row are narrow: their titles keep to one line.
    narrow? = fn n ->
      ms = for i <- 1..n, do: milestone("acme/shop", i, 0, 1, "M#{i}", ["main:a"])
      tell(view, ms) =~ ~s(class="milestone-grid narrow")
    end

    assert Enum.map([2, 3, 5], narrow?) == [false, true, true]
  end

  test "with no sessions, the live counts are not shown" do
    view = open_board()
    html = tell(view, [], [])
    assert html =~ "No Claude sessions running."
    refute html =~ "live-chip"
    assert tell(view, [], [card("a")]) =~ "live-chip"
  end

  test "a box names two of its agents, or one when boxes are narrow, and counts the rest" do
    view = open_board()
    cards = for id <- ~w(a b c d), do: card(id)
    one = milestone("acme/shop", 11, 1, 2, "Checkout", ~w(main:a main:b main:c main:d))
    [box] = boxes(tell(view, [one], cards))
    assert box.agents == ["a", "b", "+2 more"]

    two = milestone("acme/shop", 11, 1, 2, "Checkout", ~w(main:a main:b))
    [box] = boxes(tell(view, [two], cards))
    assert box.agents == ["a", "b"]

    # Three or more to a row leave room for one name.
    others = for n <- 12..13, do: milestone("acme/shop", n, 0, 1, "M#{n}", ["main:d"])
    [box | _] = boxes(tell(view, [%{one | sessions: ~w(main:a main:b main:c)} | others], cards))
    assert box.agents == ["a", "+2 more"]
  end

  # What the browser tests measure: the board, the card area, the
  # needs-you cards and each milestone box, with its title, bar and chips.
  @measure """
  (() => {
    const rect = (el) => { const r = el.getBoundingClientRect(); return {top: r.top, bottom: r.bottom, right: r.right, height: r.height}; };
    const textWidth = (el) => { const r = document.createRange(); r.selectNodeContents(el); return r.getBoundingClientRect().width; };
    const grid = document.querySelector('.milestone-grid');
    const cards = document.querySelector('.card-grid');
    return {
      board: rect(document.getElementById('board')),
      cards: {...rect(cards), client: cards.clientHeight},
      card_height: Math.max(...[...cards.querySelectorAll('.session-card')].map((c) => c.getBoundingClientRect().height)),
      needs: [...document.querySelectorAll('.session-card.needs')].map(rect),
      grid: {...rect(grid), client: grid.clientHeight, scroll: grid.scrollHeight},
      boxes: [...document.querySelectorAll('.milestone-box')].map((b) => {
        const t = b.querySelector('.ms-title');
        return {
          ...rect(b),
          title: {height: t.getBoundingClientRect().height, line: parseFloat(getComputedStyle(t).lineHeight)},
          done: b.querySelector('.ms-done').textContent.trim().replace(/\\s+/g, ' '),
          fill: b.querySelector('.ms-fill').getBoundingClientRect().width,
          labels: [...b.querySelectorAll('.ms-chip b')].map((l) => ({text: l.textContent.trim(), width: l.getBoundingClientRect().width, needs: textWidth(l)})),
          names: [...b.querySelectorAll('.ms-chip-name')].map((n) => n.getBoundingClientRect().width),
          more: [...b.querySelectorAll('.ms-more')].map((m) => ({...rect(m), whole: m.scrollWidth <= m.clientWidth}))
        };
      })
    };
  })()
  """

  defp drawn(milestones, cards, issues) do
    view = open_board()
    html = tell_issues(view, milestones, cards, issues)
    [board] = Regex.run(~r{<div[^>]*id="board".*}s, html)
    Wallboard.Browser.measure(board, @measure)
  end

  defp long_title(n), do: "Milestone #{n}: checkout, carts, gift cards and the order history page"

  @tag :browser
  test "with eight milestones, the needs-you card is still wholly in view (#169)" do
    cards = [
      %{card("a") | status: :needs, why: "May I push?"}
      | for(id <- ~w(b c d e f g h), do: card(id))
    ]

    ms =
      for {id, n} <- Enum.with_index(~w(a b c d e f g h), 1),
          do: milestone("acme/shop", n, 1, 4, long_title(n), ["main:" <> id])

    m = drawn(ms, cards, %{})

    assert m["cards"]["client"] >= m["card_height"]
    [needs] = m["needs"]
    assert needs["top"] >= m["cards"]["top"]
    assert needs["bottom"] <= m["cards"]["top"] + m["cards"]["client"]
    assert needs["bottom"] <= m["board"]["bottom"]
  end

  @tag :browser
  test "six milestones fit whole: one-line titles, whole issue numbers, agent names and +N more (#170)" do
    names =
      for id <- ~w(a b c d e f g h i),
          into: %{},
          do: {id, "robert/#{id}-refactor-the-board-layout-and-the-cards"}

    cards = for {id, name} <- names, do: %{card(id) | name: name}

    issues =
      %{"main:a" => %{number: 1400, repo: "acme/payments-service"}, "main:b" => %{number: 7}}
      |> Map.merge(for id <- ~w(c d e f g h i), into: %{}, do: {"main:" <> id, %{number: 1418}})

    ms = [
      milestone("acme/shop", 1, 2, 60, long_title(1), ~w(main:a main:b main:c main:d))
      | for(
          {id, n} <- Enum.zip(~w(e f g h i), 2..6),
          do: milestone("acme/shop", n, 3, 8, long_title(n), ["main:" <> id])
        )
    ]

    m = drawn(ms, cards, issues)
    assert length(m["boxes"]) == 6
    # Both rows of boxes are whole, above the cards.
    assert m["grid"]["scroll"] <= m["grid"]["client"]

    for box <- m["boxes"] do
      assert box["bottom"] <= m["grid"]["bottom"] + 0.5
      assert box["title"]["height"] <= box["title"]["line"] * 1.5

      for label <- box["labels"],
          not String.contains?(label["text"], "/"),
          do: assert(label["needs"] <= label["width"] + 0.01, "#{label["text"]} is cut")

      for name <- box["names"], do: assert(name >= 30, "an agent name is #{name}px wide")

      for more <- box["more"] do
        assert more["whole"]
        assert more["right"] <= box["right"]
      end
    end
  end

  @tag :browser
  test "a bar fills only when something is done, however little (#170)" do
    ms = [
      milestone("acme/shop", 1, 0, 5, "None yet", ["main:a"]),
      milestone("acme/shop", 2, 1, 200, "Barely", ["main:b"])
    ]

    m = drawn(ms, [card("a"), card("b")], %{})

    assert [{"0 of 5 done", 0}, {"1 of 200 done", some}] =
             Enum.map(m["boxes"], &{&1["done"], &1["fill"]})

    assert some > 0
  end

  test "no milestone color is the needs-you orange, in either look" do
    css = File.read!(Application.app_dir(:wallboard, "priv/static/css/app.css"))
    theme = Wallboard.Settings.defaults().theme

    for {look, block, colors} <- [
          {:light, ~r/^:root \{ (--milestone-[^}]*)\}/m, theme},
          {:dark, ~r/^:root\[data-theme=dark\] \{ (--milestone-[^}]*)\}/m, theme.dark}
        ] do
      [vars] = Regex.run(block, css, capture: :all_but_first)
      values = Regex.scan(~r/--milestone-\d: (#[0-9a-f]{6})/i, vars, capture: :all_but_first)
      assert length(values) == 3

      orange = Enum.map([colors.warn, colors.warn_deep], &String.downcase/1)

      for [value] <- values,
          do: refute(String.downcase(value) in orange, "#{look} milestone color #{value}")

      # The first milestone takes the theme's info color.
      assert css =~ ".ms-1 { --ms: var(--info); }"
      refute String.downcase(colors.info) in orange
    end
  end
end
