defmodule Wallboard.FloorTest do
  # The Floor tab's rules: who is a foreman, what each session is doing on
  # the floor, and how loud one that needs you has become.
  use ExUnit.Case, async: true

  alias Wallboard.Floor

  @now ~U[2026-11-13 18:00:00Z]

  defp ago(secs), do: DateTime.add(@now, -secs, :second)
  defp days(n), do: n * 86_400

  defp session(more) do
    Map.merge(
      %{
        key: ":abc",
        session_id: "abc",
        name: "KOR-629 Dev seed",
        folder: "eager-shirley-85350e",
        cwd: "/Users/someone/projects/kyroco-main/.claude/worktrees/eager-shirley-85350e",
        status: :idle,
        task: "worktrees/eager-shirley-85350e",
        why: nil,
        since: ago(60),
        updated_at: ago(60),
        started_at: ago(3600)
      },
      Map.new(more)
    )
  end

  describe "role/1" do
    test "a session named foreman is the foreman" do
      assert Floor.role(session(name: "Foreman billing and operations extraction")) == :foreman
      assert Floor.role(session(name: "flyer m4 FOREMAN")) == :foreman
    end

    test "a session in a foreman folder is the foreman, whatever its name" do
      assert Floor.role(session(name: "Billing", folder: "foreman-billing-operations-b9914b")) ==
               :foreman
    end

    test "everyone else is a worker" do
      assert Floor.role(session(name: "KOR-629 Dev seed in its own dev-only image")) == :worker
      assert Floor.role(session(name: nil, folder: nil)) == :worker
    end

    test "foreman inside a longer word does not count" do
      assert Floor.role(session(name: "Update the foremanual", folder: "foremanual-1")) == :worker
    end
  end

  describe "mood/2" do
    test "a session waiting on you needs you, however long it has been quiet" do
      assert Floor.mood(session(status: :needs, updated_at: ago(days(30))), @now) == :needs
    end

    test "a busy session is working, however long it has been quiet" do
      assert Floor.mood(session(status: :working, updated_at: ago(days(30))), @now) == :working
    end

    test "idle for less than a day wanders" do
      assert Floor.mood(session(updated_at: ago(60)), @now) == :wandering
      assert Floor.mood(session(updated_at: ago(days(1) - 1)), @now) == :wandering
    end

    test "idle for one to seven days is asleep" do
      assert Floor.mood(session(updated_at: ago(days(1))), @now) == :asleep
      assert Floor.mood(session(updated_at: ago(days(7) - 1)), @now) == :asleep
    end

    test "idle for seven days or more has packed its bag" do
      assert Floor.mood(session(updated_at: ago(days(7))), @now) == :packed
      assert Floor.mood(session(updated_at: ago(days(40))), @now) == :packed
    end

    test "an idle session with no times at all wanders" do
      assert Floor.mood(session(updated_at: nil, since: nil, started_at: nil), @now) == :wandering
    end

    test "with no last word, when it went idle stands in" do
      assert Floor.mood(session(updated_at: nil, since: ago(days(2))), @now) == :asleep
    end

    test "a time ahead of the clock counts as just now" do
      assert Floor.mood(session(updated_at: DateTime.add(@now, 500, :second)), @now) == :wandering
    end
  end

  describe "urgency/2" do
    test "a session that does not need you makes no noise" do
      assert Floor.urgency(session(status: :working), @now) == 0
      assert Floor.urgency(session(status: :idle), @now) == 0
    end

    test "it gets louder at 2, 10 and 30 minutes of waiting" do
      waiting = fn secs -> Floor.urgency(session(status: :needs, since: ago(secs)), @now) end

      assert waiting.(0) == 1
      assert waiting.(119) == 1
      assert waiting.(120) == 2
      assert waiting.(599) == 2
      assert waiting.(600) == 3
      assert waiting.(1799) == 3
      assert waiting.(1800) == 4
      assert waiting.(days(3)) == 4
    end

    test "with no time to go on, it starts at the quietest step" do
      assert Floor.urgency(session(status: :needs, since: nil, waiting_since: nil), @now) == 1
    end

    test "the files' own waiting time counts when the board has none yet" do
      assert Floor.urgency(session(status: :needs, since: nil, waiting_since: ago(700)), @now) ==
               3
    end
  end

  describe "crew/1" do
    test "the repository's name when the board knows it" do
      assert Floor.crew(session(repo: "vitalaize")) == "vitalaize"
    end

    test "else the project folder, so a worktree joins its project" do
      assert Floor.crew(session(repo: nil)) == "kyroco-main"
      assert Floor.crew(session(repo: nil, cwd: "/Users/someone/projects/korium")) == "korium"
    end

    test "else its folder, else somewhere" do
      assert Floor.crew(session(repo: nil, cwd: nil, folder: "notes")) == "notes"
      assert Floor.crew(session(repo: nil, cwd: nil, folder: nil)) == "somewhere"
    end
  end

  describe "says/1 and tag/1" do
    test "one that needs you says its question" do
      assert Floor.says(session(status: :needs, why: "May I delete the old seed files?")) ==
               "May I delete the old seed files?"
    end

    test "one that needs you with no question still says so" do
      assert Floor.says(session(status: :needs, why: nil)) == "Waiting on you"
    end

    test "one that works says what it is on, and an idle one says nothing" do
      assert Floor.says(session(status: :working, task: "Running the tests")) ==
               "Running the tests"

      assert Floor.says(session(status: :idle, task: "Running the tests")) == nil
    end

    test "one that works with only its folder to show says nothing" do
      assert Floor.says(session(status: :working)) == nil
      assert Floor.says(session(status: :working, task: "eager-shirley-85350e")) == nil
      assert Floor.says(session(status: :working, task: nil)) == nil
    end

    test "a long question is cut to fit a bubble, on one line" do
      said = Floor.says(session(status: :needs, why: String.duplicate("word\n", 60)))

      assert String.length(said) <= 90
      assert String.ends_with?(said, "…")
      refute said =~ "\n"
    end

    test "the tag is the issue when there is one, else a short name" do
      assert Floor.tag(session(issue: "KOR-629")) == "KOR-629"
      assert Floor.tag(session(issue: 1418)) == "#1418"
      assert Floor.tag(session(name: "Short name")) == "Short name"
      assert Floor.tag(session(name: "KOR-629 Dev seed in its own dev-only image")) == "KOR-629"
      assert Floor.tag(session(name: "#1418 fix the sign-in page")) == "#1418"
      assert Floor.tag(session(name: "UTF-8 everywhere", issue: "VIT-41")) == "VIT-41"
      assert Floor.tag(session(name: "Fix KOR-629 seed")) == "Fix KOR-629 seed"
      assert String.length(Floor.tag(session(name: String.duplicate("long ", 20)))) <= 20
    end
  end

  describe "cast/3" do
    test "each member carries what the browser draws" do
      [m] =
        Floor.cast(
          [session(status: :working, repo: "kyroco-main", tool: :codex, long?: true)],
          @now
        )

      assert %{
               key: ":abc",
               role: "worker",
               mood: "working",
               urgency: 0,
               crew: "kyroco-main",
               tool: "codex",
               long: true,
               ghost: false,
               days: 0,
               helpers: 0
             } = m
    end

    test "the loudest come first, then each crew with its foreman ahead" do
      cast =
        Floor.cast(
          [
            session(key: "w", name: "Worker", repo: "b"),
            session(key: "f", name: "Foreman of b", repo: "b"),
            session(key: "a", name: "Other", repo: "a"),
            session(key: "n1", name: "Quiet ask", repo: "b", status: :needs, since: ago(10)),
            session(key: "n2", name: "Loud ask", repo: "b", status: :needs, since: ago(2000))
          ],
          @now
        )

      assert Enum.map(cast, & &1.key) == ["n2", "n1", "a", "f", "w"]
    end

    test "a sleeper carries its days, and a wanderer none" do
      [sleeper] = Floor.cast([session(updated_at: ago(days(3) + 50))], @now)
      [walker] = Floor.cast([session(updated_at: ago(500))], @now)

      assert sleeper.mood == "asleep" and sleeper.days == 3
      assert walker.mood == "wandering" and walker.days == 0
    end

    test "a session whose machine went quiet is a ghost" do
      [m] = Floor.cast([session(stale: true)], @now)
      assert m.ghost
    end

    test "helpers are the ones running now, from the card or the usage reader, three at most" do
      on = %{running: true}
      own = session(detail: %{subagents: [on, on, %{running: false}]})
      read = session(session_id: "xyz")
      many = session(detail: %{subagents: List.duplicate(on, 9)})

      assert [%{helpers: 2}] = Floor.cast([own], @now)
      assert [%{helpers: 1}] = Floor.cast([read], @now, %{"xyz" => %{subagents: [on]}})
      assert [%{helpers: 3}] = Floor.cast([many], @now)
      assert [%{helpers: 0}] = Floor.cast([session(detail: %{subagents: [%{}]})], @now)
    end

    test "a working session with no step of its own says what its helper is on" do
      helper = %{running: true, description: "Collect unproven items"}
      busy = session(status: :working, detail: %{subagents: [helper]})

      assert [%{says: "Helper: Collect unproven items"}] = Floor.cast([busy], @now)

      assert [%{says: "Running the tests"}] =
               Floor.cast([Map.put(busy, :task, "Running the tests")], @now)

      assert [%{says: nil}] = Floor.cast([%{busy | status: :idle}], @now)
    end

    test "the cast turns into JSON for the page" do
      assert {:ok, _} = Jason.encode(Floor.cast(Floor.demo(@now), @now))
    end
  end

  describe "status_line/2" do
    test "says what it is doing and for how long" do
      line = fn more -> Floor.status_line(session(more), @now) end

      assert line.(status: :needs, since: ago(400)) == "Needs you. Waiting 6m."
      assert line.(status: :working, since: ago(4000)) == "Working for 1h 6m."
      assert line.(updated_at: ago(30)) == "Idle. Last heard from 30s ago."
      assert line.(updated_at: ago(days(1))) == "Asleep. Nothing for 1 day. Did you forget it?"

      assert line.(updated_at: ago(days(9))) ==
               "Packed and ready to archive. Nothing for 9 days."
    end
  end

  describe "demo/1" do
    test "shows every behavior at least once" do
      cast = Floor.cast(Floor.demo(@now), @now)

      assert cast |> Enum.map(& &1.mood) |> Enum.uniq() |> Enum.sort() ==
               ~w(asleep needs packed wandering working)

      assert cast |> Enum.map(& &1.urgency) |> Enum.uniq() |> Enum.sort() == [0, 1, 2, 4]
      assert Enum.any?(cast, &(&1.role == "foreman" and &1.mood == "needs"))
      assert Enum.any?(cast, &(&1.role == "foreman" and &1.mood == "working"))
      assert Enum.any?(cast, & &1.ghost)
      assert Enum.any?(cast, & &1.long)
      assert Enum.any?(cast, &(&1.tool == "codex"))
      assert Enum.any?(cast, &(&1.helpers > 0))
    end
  end
end
