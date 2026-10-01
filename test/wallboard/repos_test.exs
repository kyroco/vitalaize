defmodule Wallboard.ReposTest do
  @moduledoc "Several GitHub repositories: settings, which get a column, the status line."
  use ExUnit.Case, async: true

  alias Wallboard.{GitRemote, Settings}
  alias Wallboard.Sources.GitHub

  import Phoenix.LiveViewTest, only: [render_component: 2]

  @now ~U[2026-09-30 18:00:00Z]

  defp load(file) do
    {value, _} = Code.eval_file(Path.expand("../fixtures/settings/#{file}", __DIR__))
    {value, Settings.merge(Settings.defaults(), value)}
  end

  # What the settings page sends for these settings, as it fills its fields.
  defp page_values(settings) do
    for {_, fs} <- Settings.editable(), {path, _, type, _, _} <- fs, into: %{} do
      text =
        case Settings.current(settings, path, type) do
          nil -> ""
          list when type == :repos -> Enum.map_join(list, "\n", &Settings.repo_line/1)
          list when is_list(list) -> Enum.join(list, "\n")
          v -> to_string(v)
        end

      {Enum.join(path, "."), text}
    end
  end

  describe "settings" do
    test "an old one-repo settings file loads unchanged" do
      {file, settings} = load("one_repo.exs")

      # Everything the file set is still there, as it was.
      assert settings.github == Map.merge(Settings.defaults().github, file.github)
      assert settings.rotate_seconds == 20

      assert [gh] = Settings.github_repos(settings)
      assert gh.repo == "acme/shop"
      assert gh.branch == "trunk"
      assert gh.gate_workflow == "gate.yml"
      assert gh.dev_deploy == "dev-deploy.yml"
      assert Enum.map(gh.lanes, & &1.label) == ["Gate", "Prod"]
      assert Settings.repo_names(settings) == ["acme/shop"]
    end

    test "several repos share the GitHub settings, and a map changes them for one" do
      {_file, settings} = load("several_repos.exs")

      assert Settings.repo_names(settings) == ["acme/api", "acme/mobile", "acme/web"]
      [api, mobile, web] = Settings.github_repos(settings)

      assert api.gate_workflow == "ci.yml"
      assert web.branch == "main"
      assert mobile.gate_workflow == "build.yml"
      assert Enum.map(mobile.lanes, & &1.label) == ["Build"]
      # The shared workflow files and rows are the first repo's.
      assert Enum.map(api.lanes, & &1.label) == ["CI", "Staging", "Production"]
      assert api.deploy_workflows == ["deploy-staging.yml", "deploy-production.yml"]
    end

    test "the first repo's workflow files are not lent to the others" do
      {_file, settings} = load("several_repos.exs")
      [_api, mobile, web] = Settings.github_repos(settings)

      # web names none: no gate, no deploys, no rows of its own.
      assert %{gate_workflow: nil, dev_deploy: nil, prod_deploy: nil} = web
      assert web.deploy_workflows == [] and web.lanes == []
      # mobile has only what its own entry names.
      assert %{gate_workflow: "build.yml", dev_deploy: nil, deploy_workflows: []} = mobile
      # What is not a workflow file is still shared.
      assert web.gate_check == "ci" and web.poll_seconds == 30
    end

    test "a repo that names its workflows gets rows and a deploy list from them" do
      settings =
        Settings.merge(Settings.defaults(), %{
          github: %{
            repos: [
              "acme/rockets",
              %{repo: "acme/boosters", gate_workflow: "build.yml", prod_deploy: "ship.yml"}
            ]
          }
        })

      [_, boosters] = Settings.github_repos(settings)
      assert boosters.deploy_workflows == ["ship.yml"]

      assert boosters.lanes == [
               %{label: "Gate", workflows: ["build.yml"]},
               %{label: "Prod", workflows: ["ship.yml"]}
             ]
    end

    test "a repo's own workflows can be typed after its name, and save and load as settings.json does" do
      base = Settings.merge(Settings.defaults(), %{github: %{repos: ["acme/rockets"]}})

      typed =
        "acme/rockets\nacme/boosters gate=build.yml prod=ship.yml, acme/fins dev=\nacme/rockets"

      values = %{page_values(base) | "github.repos" => typed}
      assert {:ok, over} = Settings.check(values, base)

      assert over.github.repos == [
               "acme/rockets",
               %{repo: "acme/boosters", gate_workflow: "build.yml", prod_deploy: "ship.yml"},
               %{repo: "acme/fins", dev_deploy: nil}
             ]

      # Through the saved file and back.
      saved = over |> Jason.encode!() |> Jason.decode!() |> Settings.atomize()
      assert saved == over

      after_ = Settings.apply_overrides(base, saved)
      [rockets, boosters, fins] = Settings.github_repos(after_)
      assert rockets.gate_workflow == "ci.yml"
      assert boosters.gate_workflow == "build.yml" and boosters.prod_deploy == "ship.yml"
      assert Enum.map(boosters.lanes, & &1.label) == ["Gate", "Prod"]
      assert fins.gate_workflow == nil and fins.lanes == []

      # A form shows them the way they were typed.
      assert Settings.shown(after_)["github.repos"] ==
               "acme/rockets\nacme/boosters gate=build.yml prod=ship.yml\nacme/fins dev="

      # A saved key that is not one a form gives is not read.
      assert %{github: %{repos: [%{repo: "a/b", gate_workflow: "x.yml"} = entry]}} =
               Settings.atomize(%{
                 "github" => %{
                   "repos" => [%{"repo" => "a/b", "gate_workflow" => "x.yml", "lanes" => []}]
                 }
               })

      refute Map.has_key?(entry, :lanes)
    end

    test "what is typed after a repo's name is checked" do
      field =
        Enum.find_value(Settings.editable(), fn {_, fs} ->
          Enum.find(fs, &(elem(&1, 0) == [:github, :repos]))
        end)

      assert Settings.check_one(field, "acme/api gate=ci.yml") == :ok
      assert {:error, "gate=ci.yml: after" <> _} = Settings.check_one(field, "gate=ci.yml")
      assert {:error, "lanes=x: after" <> _} = Settings.check_one(field, "acme/api lanes=x")

      assert {:error, "../x.yml is not a workflow" <> _} =
               Settings.check_one(field, "acme/api gate=../x.yml")
    end

    test "a file entry written as a line, as the Mac app writes its list, is read the same way" do
      settings =
        Settings.merge(Settings.defaults(), %{
          github: %{repos: ["acme/rockets", "acme/boosters gate=build.yml"]}
        })

      assert [_, %{repo: "acme/boosters", gate_workflow: "build.yml"}] =
               Settings.github_repos(settings)

      assert Settings.skipped_repos(settings) == []
    end

    test "a repo the file describes keeps its rows when a form saves workflows for it" do
      {file, _} = load("several_repos.exs")
      over = %{github: %{repos: ["acme/api", %{repo: "acme/mobile", gate_workflow: "ios.yml"}]}}
      after_ = Settings.apply_overrides(Settings.merge(Settings.defaults(), file), over)

      assert [_, %{repo: "acme/mobile", gate_workflow: "ios.yml", lanes: [%{label: "Build"}]}] =
               Settings.github_repos(after_)
    end

    test "the setup app's answers laid over an earlier file keep a repo's own settings" do
      # What a file written by the Mac app evaluates: the earlier file, then
      # the answers, with one repository added.
      {base, _} = load("several_repos.exs")
      answers = %{github: %{repos: ["acme/api", "acme/mobile", "acme/web", "acme/docs"]}}

      merged = Settings.merge(Settings.defaults(), Settings.apply_overrides(base, answers))

      assert [_, %{repo: "acme/mobile", gate_workflow: "build.yml"}, _, %{repo: "acme/docs"}] =
               Settings.github_repos(merged)
    end

    test "the setup app's answers keep a repo's own settings when one repo is left" do
      {base, _} = load("several_repos.exs")
      answers = %{github: %{repo: "acme/mobile", repos: ["acme/mobile"]}}
      merged = Settings.merge(Settings.defaults(), Settings.apply_overrides(base, answers))
      assert [%{repo: "acme/mobile", gate_workflow: "build.yml"}] = Settings.github_repos(merged)
    end

    test "a file entry with spaces in its name keeps its settings when the page saves the list" do
      file =
        Settings.merge(Settings.defaults(), %{
          github: %{repos: ["acme/api", %{repo: "acme/mobile ", gate_workflow: "build.yml"}]}
        })

      after_ = Settings.apply_overrides(file, %{github: %{repos: ["acme/mobile", "acme/api"]}})

      assert [%{repo: "acme/mobile", gate_workflow: "build.yml"}, _] =
               Settings.github_repos(after_)
    end

    test "names are trimmed, and only names the board leaves out are listed as skipped" do
      spaced = Settings.merge(Settings.defaults(), %{github: %{repos: [" a/b", "x/y "]}})
      assert Settings.repo_names(spaced) == ["a/b", "x/y"]
      assert Settings.skipped_repos(spaced) == []

      # One repo, from a file before several repos, that is not owner/name.
      url = Settings.merge(Settings.defaults(), %{github: %{repo: "https://github.com/acme/api"}})
      assert Settings.repo_names(url) == []
      assert Settings.skipped_repos(url) == ["https://github.com/acme/api"]
    end

    test "the GitHub poll's time limit follows the repos in the settings of each poll" do
      one = Settings.merge(Settings.defaults(), %{github: %{repo: "a/b"}})
      nine = Settings.merge(Settings.defaults(), %{github: %{repos: Enum.map(1..9, &"a/r#{&1}")}})
      assert GitHub.timeout_ms(one) == 180_000
      assert GitHub.timeout_ms(nine) == 420_000
    end

    test "a bad or repeated entry is left out, and the Git tab can name it" do
      settings =
        Settings.merge(Settings.defaults(), %{
          github: %{repos: ["acme/api", "not a repo", "acme/api", %{branch: "x"}]}
        })

      assert Settings.repo_names(settings) == ["acme/api"]
      assert Settings.skipped_repos(settings) == ["not a repo", "%{branch: \"x\"}"]
    end

    test "the settings page shows the repos one per line, and a list saved there keeps a repo's own settings" do
      {file, settings} = load("several_repos.exs")

      assert Settings.shown(settings)["github.repos"] ==
               "acme/api\nacme/mobile gate=build.yml\nacme/web"

      # Unchanged on the page: nothing is saved for GitHub.
      assert {:ok, over} = Settings.check(page_values(settings), settings)
      refute Map.has_key?(over, :github)

      # One removed: the list is saved by name, and mobile keeps its gate.
      values = %{page_values(settings) | "github.repos" => "acme/mobile, acme/web"}

      assert {:ok, %{github: %{repos: ["acme/mobile", "acme/web"]}} = over} =
               Settings.check(values, settings)

      after_ = Settings.apply_overrides(Settings.merge(Settings.defaults(), file), over)

      assert [%{repo: "acme/mobile", gate_workflow: "build.yml"}, %{repo: "acme/web"}] =
               Settings.github_repos(after_)
    end

    test "a repo the page saved before several repos is still followed, until a file lists repos" do
      saved = Settings.atomize(%{"github" => %{"repo" => "acme/shop"}})
      assert saved == %{github: %{repo: "acme/shop"}}

      # An old one-repo file: the page's repo wins, as it always did.
      {_, old_file} = load("one_repo.exs")

      after_ =
        Settings.apply_overrides(
          %{old_file | github: %{old_file.github | repo: "acme/other"}},
          saved
        )

      assert Settings.repo_names(after_) == ["acme/shop"]

      # A file that now lists several repos (a Reconfigure, say) wins over it.
      {_, several} = load("several_repos.exs")
      after_ = Settings.apply_overrides(several, saved)
      assert Settings.repo_names(after_) == ["acme/api", "acme/mobile", "acme/web"]

      # A list saved on the page since then is read as is.
      assert Settings.atomize(%{"github" => %{"repo" => "acme/shop", "repos" => ["a/b", "c/d"]}}) ==
               %{github: %{repo: "acme/shop", repos: ["a/b", "c/d"]}}
    end
  end

  # ---------------------------------------------------------------------------
  # Which repositories get a column

  defp run(id, workflow, opts) do
    ended = DateTime.add(@now, -Keyword.get(opts, :ago_min, 60) * 60)
    status = Keyword.get(opts, :status, :completed)

    %{
      id: id,
      name: Keyword.get(opts, :name, workflow),
      workflow: workflow,
      title: "change #{id}",
      event: Keyword.get(opts, :event, "push"),
      branch: Keyword.get(opts, :branch, "main"),
      sha: Keyword.get(opts, :sha, "abc#{id}"),
      status: status,
      conclusion: if(status == :completed, do: Keyword.get(opts, :conclusion, "success")),
      started_at: DateTime.add(ended, -120),
      updated_at: ended,
      pr: nil,
      url: nil
    }
  end

  defp facts(runs),
    do: %{runs: runs, deploys: [], deploys_checked_at: @now, queue: [], prs: [], jobs: %{}}

  defp six_repos(overrides) do
    base = %{
      "acme/a" => [run(1, "ci.yml", ago_min: 300)],
      "acme/b" => [run(2, "ci.yml", status: :in_progress, ago_min: 0)],
      "acme/c" => [run(3, "ci.yml", conclusion: "failure", ago_min: 600)],
      "acme/d" => [run(4, "ci.yml", ago_min: 60)],
      "acme/e" => [run(5, "ci.yml", ago_min: 180)],
      "acme/f" => [run(6, "ci.yml", ago_min: 1200)]
    }

    runs = Map.merge(base, overrides)
    names = Enum.map(~w(a b c d e f), &"acme/#{&1}")
    settings = Settings.merge(Settings.defaults(), %{github: %{repos: names}})
    facts = %{repos: Enum.map(names, &%{repo: &1, facts: facts(runs[&1]), error: nil})}
    GitHub.repos(facts, settings, @now)
  end

  defp names(repos), do: Enum.map(repos, & &1.name)

  describe "arrange/2 with six repos" do
    test "the busiest four get columns: running and red first, then the most recent run" do
      {columns, quiet} = GitHub.arrange(six_repos(%{}))

      # b is running and c is red; d (1 hour ago) and e (3 hours) ran last.
      assert names(columns) == ~w(b c d e)
      assert names(quiet) == ~w(a f)
    end

    test "a quiet repo moves into the columns as soon as it runs" do
      repos = six_repos(%{"acme/f" => [run(7, "ci.yml", status: :in_progress, ago_min: 0)]})
      {columns, quiet} = GitHub.arrange(repos)

      assert names(columns) == ~w(b c d f)
      assert names(quiet) == ~w(a e)
    end

    test "a quiet repo moves into the columns when a build fails, and a failure 7 hours old does not count" do
      repos =
        six_repos(%{"acme/a" => [run(8, "deploy.yml", conclusion: "failure", ago_min: 120)]})

      assert {columns, _} = GitHub.arrange(repos)
      assert "a" in names(columns)
      refute "e" in names(columns)

      old = six_repos(%{"acme/a" => [run(9, "deploy.yml", conclusion: "failure", ago_min: 420)]})
      assert {_, quiet} = GitHub.arrange(old)
      assert "a" in names(quiet)
    end

    test "four or fewer repos all get columns, in settings order" do
      repos = six_repos(%{}) |> Enum.take(3)
      assert {^repos, []} = GitHub.arrange(repos)
    end

    test "a repo not read yet is quiet, not an error" do
      settings = Settings.merge(Settings.defaults(), %{github: %{repos: ["acme/a", "acme/b"]}})
      [a, b] = GitHub.repos(nil, settings, @now)
      assert a.s == nil and a.hot? == false and b.name == "b"
    end

    test "two repos with the same short name are shown by their full names" do
      settings =
        Settings.merge(Settings.defaults(), %{
          github: %{repos: ["acme/web", "beta/web", "acme/api"]}
        })

      assert GitHub.repos(nil, settings, @now) |> names() == ["acme/web", "beta/web", "api"]
    end
  end

  test "the status line adds up every repo" do
    t =
      GitHub.totals(
        six_repos(%{"acme/d" => [run(10, "ci.yml", conclusion: "failure", ago_min: 30)]})
      )

    assert t.count == 6
    # The gate (ci.yml) on main: a, e and f green; c and d red; b still running.
    assert names(t.green) == ~w(a e f)
    assert names(t.red) == ~w(c d)
    assert names(t.running) == ~w(b)
    assert [%{repo_name: "d"}, %{repo_name: "c"}] = t.failures
  end

  # ---------------------------------------------------------------------------
  # Two repositories whose workflow files differ

  # rockets has a gate and deploys; boosters has ci.yml and CodeQL and
  # names nothing. `more` is laid over the GitHub settings.
  defp two_repos(runs, more \\ %{}) do
    github =
      Map.merge(
        %{
          repos: ["acme/rockets", "acme/boosters"],
          gate_workflow: "gate.yml",
          dev_deploy: "dev-deploy.yml",
          prod_deploy: "prod-deploy.yml",
          deploy_workflows: ["dev-deploy.yml", "prod-deploy.yml"],
          lanes: [
            %{label: "Gate", workflows: ["gate.yml"]},
            %{label: "Dev deploy", workflows: ["dev-deploy.yml"]},
            %{label: "Prod", workflows: ["prod-deploy.yml"]}
          ]
        },
        more
      )

    settings = Settings.merge(Settings.defaults(), %{github: github})

    facts = %{
      repos:
        for {repo, rs} <- runs do
          {listed, rs} = Enum.split_with(rs, &match?({:workflows, _}, &1))
          %{repo: repo, facts: Map.put(facts(rs), :workflows, listed[:workflows]), error: nil}
        end
    }

    GitHub.repos(facts, settings, @now)
  end

  defp labels(repo), do: Enum.map(repo.s.lanes, & &1.label)

  describe "two repos whose workflow files differ" do
    test "each column's chart shows that repo's own runs in the window" do
      [rockets, boosters] =
        two_repos([
          {"acme/rockets",
           [
             run(1, "gate.yml", ago_min: 200),
             run(2, "prod-deploy.yml", ago_min: 90),
             run(3, "pricing.yml", name: "Pricing snapshot", ago_min: 30)
           ]},
          {"acme/boosters",
           [
             run(4, "codeql.yml", name: "CodeQL", ago_min: 100),
             run(5, "ci.yml", name: "CI", ago_min: 20, conclusion: "failure"),
             run(6, "ci.yml", name: "CI", status: :in_progress, ago_min: 0)
           ]}
        ])

      # Its own rows first, under their short labels, then what else ran.
      assert labels(rockets) == ["Gate", "Prod", "Pricing snapshot"]
      # No rows of its own: what ran, the latest first.
      assert labels(boosters) == ["CI", "CodeQL"]

      assert [%{bars: [%{kind: :fail}, %{kind: :run}]}, %{bars: [%{kind: :pass}]}] =
               boosters.s.lanes

      assert rockets.s.lanes_more == 0
    end

    test "a repo with runs never shows an empty chart, whatever its rows are" do
      # Only workflows that have no row ran, as on the day this was found.
      [rockets, boosters] =
        two_repos([
          {"acme/rockets",
           [
             run(1, "pricing.yml", name: "Pricing snapshot", ago_min: 40),
             run(2, "overnight.yml", name: "Overnight", ago_min: 300)
           ]},
          {"acme/boosters", [run(3, "ci.yml", name: "CI", ago_min: 10)]}
        ])

      assert labels(rockets) == ["Pricing snapshot", "Overnight"]
      assert labels(boosters) == ["CI"]
    end

    test "a repo with no runs in the window has no rows, and the chart says so in words" do
      [rockets, boosters] =
        two_repos([
          {"acme/rockets", [run(1, "gate.yml", ago_min: 7 * 60)]},
          {"acme/boosters", []}
        ])

      assert rockets.s.lanes == [] and boosters.s.lanes == []

      html =
        render_component(&WallboardWeb.BoardLive.timeline/1,
          lanes: rockets.s.lanes,
          more: rockets.s.lanes_more,
          now: @now
        )

      assert html =~ "No runs in the last 6 hours"
      refute html =~ "lane-track"

      # With runs: a row each, and no such words.
      [busy, _] = two_repos([{"acme/rockets", [run(2, "gate.yml", [])]}, {"acme/boosters", []}])

      html =
        render_component(&WallboardWeb.BoardLive.timeline/1,
          lanes: busy.s.lanes,
          more: busy.s.lanes_more,
          now: @now
        )

      assert html =~ "Gate" and html =~ "lane-track"
      refute html =~ "No runs in the last 6 hours"
    end

    test "the chart shows six rows at most and says how many more ran" do
      runs = for n <- 1..8, do: run(n, "w#{n}.yml", name: "Flow #{n}", ago_min: n * 10)
      [_, boosters] = two_repos([{"acme/rockets", []}, {"acme/boosters", runs}])

      assert labels(boosters) == for(n <- 1..6, do: "Flow #{n}")
      assert boosters.s.lanes_more == 2

      html =
        render_component(&WallboardWeb.BoardLive.timeline/1,
          lanes: boosters.s.lanes,
          more: boosters.s.lanes_more,
          now: @now
        )

      assert html =~ "+2 more workflows ran"
    end

    test "a repo with no gate workflow shows main green or red from its latest runs on main" do
      main = fn runs ->
        [_, boosters] = two_repos([{"acme/rockets", []}, {"acme/boosters", runs}])
        {boosters.s.main && boosters.s.main.conclusion, boosters.s.main_from}
      end

      # Every workflow on the newest commit passed.
      assert main.([
               run(1, "ci.yml", sha: "new", ago_min: 20),
               run(2, "codeql.yml", sha: "new", ago_min: 25),
               run(3, "ci.yml", sha: "old", ago_min: 300, conclusion: "failure")
             ]) == {"success", :runs}

      # One of them failed.
      assert main.([
               run(1, "ci.yml", sha: "new", ago_min: 20),
               run(2, "codeql.yml", sha: "new", ago_min: 25, conclusion: "failure")
             ]) == {"failure", :runs}

      # A failed run that was run again and passed: the newest run counts.
      assert main.([
               run(1, "ci.yml", sha: "new", ago_min: 10),
               run(2, "ci.yml", sha: "new", ago_min: 40, conclusion: "failure")
             ]) == {"success", :runs}

      # A pull request's run, or one on another branch, is not a run on main.
      assert main.([
               run(1, "ci.yml", sha: "new", ago_min: 30),
               run(2, "ci.yml",
                 sha: "pr",
                 ago_min: 5,
                 conclusion: "failure",
                 event: "pull_request"
               ),
               run(3, "ci.yml", sha: "br", ago_min: 5, conclusion: "failure", branch: "fix")
             ]) == {"success", :runs}

      # A run still going, or a cancelled one, decides nothing.
      assert main.([
               run(1, "ci.yml", sha: "newer", status: :in_progress, ago_min: 0),
               run(2, "ci.yml", sha: "newer", ago_min: 2, conclusion: "cancelled"),
               run(3, "ci.yml", sha: "new", ago_min: 30)
             ]) == {"success", :runs}

      assert main.([]) == {nil, :runs}
    end

    test "the first repo keeps its gate: other green runs on main do not stand in for it" do
      [rockets, _] =
        two_repos([
          {"acme/rockets",
           [
             run(1, "pricing.yml", ago_min: 10),
             run(2, "gate.yml", ago_min: 60, conclusion: "failure")
           ]},
          {"acme/boosters", []}
        ])

      assert rockets.s.main.conclusion == "failure" and rockets.s.main_from == :gate
    end

    test "a gate file the repo does not have is no gate, and one not checked yet still is" do
      runs = [run(1, "ci.yml", ago_min: 10)]
      one = fn workflows -> [{"acme/rockets", [{:workflows, workflows} | runs]}] end

      # GitHub lists the repo's workflow files, and gate.yml is not one.
      [r] = two_repos(one.(["ci.yml"]), %{repos: ["acme/rockets"]})
      assert r.s.main.conclusion == "success" and r.s.main_from == :runs

      # It is one: main waits for a gate run.
      [r] = two_repos(one.(["ci.yml", "gate.yml"]), %{repos: ["acme/rockets"]})
      assert r.s.main == nil and r.s.main_from == :gate

      # The list has not been read: the setting is taken at its word.
      [r] = two_repos(one.(nil), %{repos: ["acme/rockets"]})
      assert r.s.main == nil and r.s.main_from == :gate
    end

    test "the status line counts a repo with no gate, and none is left unknown" do
      repos =
        two_repos([
          {"acme/rockets", [run(1, "gate.yml", ago_min: 30)]},
          {"acme/boosters", [run(2, "ci.yml", ago_min: 20)]}
        ])

      t = GitHub.totals(repos)
      assert names(t.green) == ~w(rockets boosters)
      assert t.unknown == [] and t.red == []

      red =
        two_repos([
          {"acme/rockets", [run(1, "gate.yml", ago_min: 30)]},
          {"acme/boosters", [run(2, "ci.yml", ago_min: 20, conclusion: "failure")]}
        ])

      assert names(GitHub.totals(red).red) == ~w(boosters)
    end

    test "an old settings file with one lanes list loads, and the first repo's chart is as it was" do
      {_file, settings} = load("one_repo.exs")

      runs = [
        run(1, "gate.yml", ago_min: 200, branch: "trunk"),
        run(2, "prod-deploy.yml", ago_min: 90, branch: "trunk", conclusion: "failure")
      ]

      [shop] =
        GitHub.repos(
          %{repos: [%{repo: "acme/shop", facts: facts(runs), error: nil}]},
          settings,
          @now
        )

      # The rows, their labels and their order are the file's.
      assert [
               %{label: "Gate", bars: [%{id: 1, kind: :pass, length: 120}]},
               %{label: "Prod", bars: [%{id: 2, kind: :fail, length: 120}]}
             ] = shop.s.lanes

      assert shop.s.main.id == 1 and shop.s.main_from == :gate

      # The same file with a second repo added on the settings page: the
      # first repo's chart does not change, and the second borrows nothing.
      two =
        Settings.apply_overrides(settings, %{github: %{repos: ["acme/shop", "acme/boosters"]}})

      facts = %{
        repos: [
          %{repo: "acme/shop", facts: facts(runs), error: nil},
          %{
            repo: "acme/boosters",
            facts: facts([run(3, "ci.yml", name: "CI", branch: "trunk")]),
            error: nil
          }
        ]
      }

      assert [again, boosters] = GitHub.repos(facts, two, @now)
      assert again.s.lanes == shop.s.lanes
      assert labels(boosters) == ["CI"]
      assert boosters.s.main.conclusion == "success"
    end
  end

  test "parse_workflows/1 reads a repo's workflow files by name" do
    json = Wallboard.Fixtures.read!("github/workflows.json")
    assert GitHub.parse_workflows(json) == {:ok, ["ci.yml", "codeql.yml", "dependabot-updates"]}
    assert {:error, _} = GitHub.parse_workflows(~s({"message": "Not Found"}))
  end

  describe "GitRemote" do
    test "reads owner/name from the usual remote forms" do
      assert GitRemote.parse("git@github.com:acme/shop.git") == "acme/shop"
      assert GitRemote.parse("https://github.com/acme/shop") == "acme/shop"
      assert GitRemote.parse("https://github.com/acme/shop.git/\n") == "acme/shop"
      assert GitRemote.parse("https://gitlab.com/acme/shop") == nil
    end

    # Outside this project, whose own checkout would answer for any folder
    # without a .git of its own.
    test "finds a folder's repo from its checkout, and a worktree's from its main checkout" do
      dir = Wallboard.Fixtures.tmp_path("wallboard-repos")
      on_exit(fn -> File.rm_rf!(dir) end)
      main = Path.join(dir, "shop")
      File.mkdir_p!(Path.join([main, ".git", "worktrees", "fix"]))
      File.mkdir_p!(Path.join(main, "lib/deep"))

      File.write!(Path.join([main, ".git", "config"]), """
      [core]
      \tbare = false
      [remote "upstream"]
      \turl = git@github.com:someone/else.git
      [remote "origin"]
      \turl = git@github.com:acme/shop.git
      \tfetch = +refs/heads/*:refs/remotes/origin/*
      """)

      assert GitRemote.github_repo(main) == "acme/shop"
      assert GitRemote.github_repo(Path.join(main, "lib/deep")) == "acme/shop"

      tree = Path.join(dir, "fix")
      File.mkdir_p!(tree)
      File.write!(Path.join(tree, ".git"), "gitdir: #{main}/.git/worktrees/fix\n")
      File.write!(Path.join([main, ".git", "worktrees", "fix", "commondir"]), "../..\n")
      assert GitRemote.github_repo(tree) == "acme/shop"

      assert GitRemote.github_repo(Path.join(dir, "nowhere")) == nil
      assert GitRemote.github_repo(nil) == nil
    end
  end
end
