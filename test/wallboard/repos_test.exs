defmodule Wallboard.ReposTest do
  @moduledoc "Several GitHub repositories: settings, which get a column, the status line."
  use ExUnit.Case, async: true

  alias Wallboard.{GitRemote, Settings}
  alias Wallboard.Sources.GitHub

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
      # The shared lanes stay for the others.
      assert Enum.map(api.lanes, & &1.label) == ["CI", "Staging", "Production"]
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

      assert Settings.current(settings, [:github, :repos], :repos) ==
               Settings.repo_names(settings)

      # Unchanged on the page: nothing is saved for GitHub.
      values = %{page_values(settings) | "github.repos" => "acme/api\nacme/mobile\nacme/web\n"}
      assert {:ok, over} = Settings.check(values, settings)
      refute Map.has_key?(over, :github)

      # One removed: the list is saved by name, and mobile keeps its gate.
      values = %{values | "github.repos" => "acme/mobile, acme/web"}

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
      name: workflow,
      workflow: workflow,
      title: "change #{id}",
      event: Keyword.get(opts, :event, "push"),
      branch: "main",
      sha: "abc#{id}",
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
