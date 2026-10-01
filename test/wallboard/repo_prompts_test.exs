defmodule Wallboard.RepoPromptsTest do
  # One hub at a time: it has one database and one settings file. Nothing
  # here asks GitHub: a stand-in answers for it.
  use ExUnit.Case, async: false

  alias Wallboard.Collector.Proto
  alias Wallboard.{Fixtures, Mailbox, Poller, RepoPrompts, Settings, Store}
  alias WallboardWeb.{MailboxPanel, SettingsLive}

  @moduletag :capture_log

  setup do
    dir = Fixtures.tmp_path("wallboard-repos")
    File.mkdir_p!(dir)

    # A throwaway settings file, so Track saves to and reads back from this
    # test's own database and never this machine's.
    file = Path.join(dir, "settings.exs")

    File.write!(file, """
    %{
      archive: %{path: #{inspect(Path.join(dir, "wallboard.db"))}, machine: "the-hub"},
      github: %{repos: ["acme/shop"]}
    }
    """)

    old_env = System.get_env("WALLBOARD_SETTINGS")
    old = :persistent_term.get({Settings, :settings}, nil)
    System.put_env("WALLBOARD_SETTINGS", file)
    Settings.load!()

    on_exit(fn ->
      if old_env,
        do: System.put_env("WALLBOARD_SETTINGS", old_env),
        else: System.delete_env("WALLBOARD_SETTINGS")

      if old,
        do: :persistent_term.put({Settings, :settings}, old),
        else: :persistent_term.erase({Settings, :settings})

      File.rm_rf!(dir)
    end)

    # What GitHub would say about each repository, and what it was asked.
    {:ok, github} = Agent.start_link(fn -> %{answers: %{}, asked: []} end)
    Phoenix.PubSub.subscribe(Wallboard.PubSub, Mailbox.topic())
    %{dir: dir, github: github}
  end

  # ---------------------------------------------------------------------------
  # Helpers

  # The saved settings (settings.json), beside this test's settings file.
  defp saved(c), do: Path.join(c.dir, "settings.json")
  defp saved_json(c), do: c |> saved() |> File.read!() |> Jason.decode!()

  defp start_hub(c, opts \\ []) do
    start_supervised!({Store, path: Path.join(c.dir, "wallboard.db")})
    start_prompts(c, opts)
  end

  defp start_prompts(c, opts) do
    github = c.github

    look = fn repo ->
      Agent.get_and_update(github, fn s ->
        {Map.get(s.answers, repo, {:visible, repo}), %{s | asked: s.asked ++ [repo]}}
      end)
    end

    start_supervised!(
      {RepoPrompts, Keyword.merge([look: look, local: fn -> [] end, tick_ms: 3_600_000], opts)}
    )
  end

  defp stop_hub do
    :ok = stop_supervised(RepoPrompts)
    :ok = stop_supervised(Store)
  end

  defp answer(c, repo, what),
    do: Agent.update(c.github, &put_in(&1.answers[repo], what))

  defp asked(c), do: Agent.get(c.github, & &1.asked)

  # What a collector's stream tells the hub about a session: its summary.
  defp streamed(machine, session, repo, at \\ System.os_time(:second)) do
    event = %Proto.Event{
      session_id: session,
      file: session <> ".jsonl",
      position: 100,
      at: at,
      items: [
        %Proto.Item{body: {:summary, %Proto.Summary{folder: "/Users/r/work", repo: repo}}}
      ]
    }

    row = %{
      session_id: session,
      file: event.file,
      position: 100,
      at: at,
      kind: "file",
      event: Proto.Event.encode(event)
    }

    Phoenix.PubSub.broadcast(Wallboard.PubSub, "link", {:link, :events, machine, [row]})
  end

  # Everything sent so far has been taken in, and GitHub has answered.
  defp settled do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      state = :sys.get_state(RepoPrompts)

      if state.checks == %{} do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end)
  end

  defp html(rendered), do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  defp panel do
    html(
      MailboxPanel.panel(%{
        items: Mailbox.items(),
        note: nil,
        may_decide?: true,
        cannot: "Decide on the hub's own machine.",
        __changed__: nil
      })
    )
  end

  # A folder that is a git checkout with this origin, or with none.
  defp checkout(c, name, origin) do
    folder = Path.join(c.dir, name)
    File.mkdir_p!(Path.join(folder, ".git"))

    remote = if origin, do: ~s([remote "origin"]\n\turl = #{origin}\n), else: ""
    File.write!(Path.join(folder, ".git/config"), "[core]\n\tbare = false\n" <> remote)
    folder
  end

  # ---------------------------------------------------------------------------

  describe "work in a repo the Git tab does not follow" do
    test "raises exactly one item, however many sessions and machines work in it", c do
      start_hub(c)
      assert Mailbox.items() == []

      streamed("Robert's MacBook Air", "s1", "acme/billing-api")
      streamed("Robert's MacBook Air", "s2", "acme/billing-api")
      streamed("studio", "s3", "Acme/Billing-API")
      RepoPrompts.seen("acme/billing-api", "the-hub")
      settled()

      assert [item] = Mailbox.items()
      assert item.id == "repo:acme/billing-api"
      assert item.title == "Track a new repo?"
      assert item.actions == [{"track", "Track"}, {"ignore", "Ignore"}]
      assert_receive {:mailbox, :changed}

      # GitHub was asked once, not once a session.
      assert asked(c) == ["acme/billing-api"]

      # As mockup 6 draws it.
      page = panel()
      assert page =~ "1 thing to decide"
      assert page =~ ~s(<div class="mailbox-title">Track a new repo?</div>)
      assert page =~ "Someone is working in <b>acme/billing-api</b> on Robert&#39;s MacBook Air"
      assert page =~ "and 2 other machines."
      assert page =~ "The Git tab doesn&#39;t track it yet."
      assert page =~ ~r/class="mailbox-act primary"[^>]*phx-value-action="track"/s
      assert page =~ ~r/class="mailbox-act ?"[^>]*phx-value-action="ignore"/s

      # The same sessions saying more change nothing.
      streamed("Robert's MacBook Air", "s1", "acme/billing-api")
      settled()
      assert [_] = Mailbox.items()
      assert asked(c) == ["acme/billing-api"]
    end

    test "names its one machine, and a second repo is a second item", c do
      start_hub(c)
      streamed("air", "s1", "acme/billing-api")
      settled()
      streamed("air", "s2", "acme/docs")
      settled()

      assert [first, second] = Mailbox.items()
      assert first.id == "repo:acme/billing-api"
      assert second.id == "repo:acme/docs"
      assert panel() =~ "Someone is working in <b>acme/billing-api</b> on air. The Git tab"
    end

    test "a repo the board follows already raises nothing, whatever its case", c do
      start_hub(c)
      streamed("air", "s1", "acme/shop")
      streamed("air", "s2", "ACME/Shop")
      settled()

      assert Mailbox.items() == []
      assert asked(c) == []
    end

    test "old history a collector sends raises nothing", c do
      start_hub(c)
      streamed("air", "s1", "acme/old-work", System.os_time(:second) - 13 * 3600)
      settled()

      assert Mailbox.items() == []
      assert asked(c) == []
    end

    test "a name that is not owner/name raises nothing and is never put to GitHub", c do
      start_hub(c)

      for bad <- ["acme", "acme/..", "../user", "acme/a b", "acme/shop/x", "-x/y", "a/b?c=d"] do
        RepoPrompts.seen(bad, "air")
      end

      settled()
      assert Mailbox.items() == []
      assert asked(c) == []
      assert RepoPrompts.name?("acme/billing-api")
      assert RepoPrompts.name?("kyroco/.github")
      assert RepoPrompts.name?("mona_octo/repo")

      # A name with a line end after it is not the name before it.
      streamed("air", "s1", "acme/shop\n")
      streamed("air", "s2", "acme/..\n")
      settled()
      assert Mailbox.items() == []
      assert asked(c) == []
      refute RepoPrompts.name?("acme/shop\n")
      refute Settings.repo_name?("acme/shop\n")
      assert {:error, :not_a_repo} = Settings.track_repo("acme/..")
    end

    test "a repo that found no room asks once there is room, without its session saying more",
         c do
      start_hub(c)
      for n <- 1..5, do: streamed("air", "s#{n}", "acme/r#{n}")
      settled()
      streamed("air", "s6", "acme/r6")
      settled()
      assert length(Mailbox.items()) == 5
      refute "acme/r6" in asked(c)

      assert :ok = Mailbox.act("repo:acme/r1", "ignore")
      settled()
      assert "repo:acme/r6" in Enum.map(Mailbox.items(), & &1.id)
      assert length(Mailbox.items()) == 5
    end

    test "a renamed repo seen under both names has one item and one question each", c do
      start_hub(c)
      answer(c, "acme/old", {:visible, "acme/new"})

      # The new name first, then the old one, twice.
      streamed("air", "s1", "acme/new")
      settled()
      streamed("box", "s2", "acme/old")
      settled()
      streamed("box", "s3", "acme/old")
      settled()
      assert [%{id: "repo:acme/new"}] = Mailbox.items()
      assert asked(c) == ["acme/new", "acme/old"]
      assert panel() =~ "on air and box."

      # The old name first, then the new one.
      answer(c, "acme/was", {:visible, "acme/is"})
      streamed("air", "s4", "acme/was")
      settled()
      streamed("air", "s5", "acme/is")
      settled()

      assert Mailbox.items() |> Enum.map(& &1.id) |> Enum.sort() ==
               ["repo:acme/is", "repo:acme/new"]

      assert asked(c) == ["acme/new", "acme/old", "acme/was"]

      # Ignored once, it stays ignored under either name, and one Ask again undoes it.
      assert :ok = Mailbox.act("repo:acme/is", "ignore")
      streamed("air", "s6", "acme/was")
      settled()
      assert [%{id: "repo:acme/new"}] = Mailbox.items()
      assert RepoPrompts.ignored() == ["acme/is"]
      assert :ok = RepoPrompts.ask_again("acme/is")
      settled()

      assert Enum.map(Mailbox.items(), & &1.id) |> Enum.sort() == [
               "repo:acme/is",
               "repo:acme/new"
             ]
    end

    test "a renamed repo the board follows under its new name raises nothing", c do
      start_hub(c)
      answer(c, "acme/shop-old", {:visible, "acme/shop"})
      streamed("air", "s1", "acme/shop-old")
      settled()
      assert Mailbox.items() == []

      # And is not put to GitHub again each time it is seen.
      streamed("air", "s2", "acme/shop-old")
      settled()
      assert asked(c) == ["acme/shop-old"]

      # One the board does not follow is asked about, and tracked, by its name now.
      answer(c, "acme/api-old", {:visible, "acme/api"})
      streamed("air", "s3", "acme/api-old")
      settled()
      assert [%{id: id}] = Mailbox.items()
      assert panel() =~ "<b>acme/api</b>"
      assert :ok = Mailbox.act(id, "track")
      assert Settings.repo_names(Settings.get()) == ["acme/shop", "acme/api"]
      streamed("air", "s4", "acme/api-old")
      settled()
      assert Mailbox.items() == []
    end

    test "one machine cannot fill the mailbox", c do
      start_hub(c)
      for n <- 1..8, do: RepoPrompts.seen("acme/r#{n}", "air")
      settled()
      assert length(Mailbox.items()) == 5

      for n <- 1..8, do: RepoPrompts.seen("other/r#{n}", "box")
      for n <- 1..8, do: RepoPrompts.seen("third/r#{n}", "cube")
      settled()
      assert length(Mailbox.items()) == 10
      assert length(asked(c)) == 10
    end
  end

  describe "Track" do
    test "adds the repo to the board's list and the item goes", c do
      start_hub(c)
      streamed("air", "s1", "acme/billing-api")
      settled()
      assert [%{id: id}] = Mailbox.items()
      assert_receive {:mailbox, :changed}

      assert :ok = Mailbox.act(id, "track")
      assert Mailbox.items() == []
      assert_receive {:mailbox, :changed}

      # The Git tab reads this list on every check.
      assert Settings.repo_names(Settings.get()) == ["acme/shop", "acme/billing-api"]
      assert {:error, :gone} = Mailbox.act(id, "track")

      # Work there no longer asks, and the list is still there after a restart.
      streamed("air", "s1", "acme/billing-api")
      settled()
      assert Mailbox.items() == []

      stop_hub()
      :persistent_term.erase({Settings, :settings})
      start_hub(c)
      assert Settings.repo_names(Settings.get()) == ["acme/shop", "acme/billing-api"]
      assert Mailbox.items() == []
    end

    test "takes GitHub's spelling of the name", c do
      start_hub(c)
      answer(c, "acme/Billing-API", {:visible, "Acme/billing-api"})
      streamed("air", "s1", "acme/Billing-API")
      settled()

      assert [%{id: id}] = Mailbox.items()
      assert :ok = Mailbox.act(id, "track")
      assert Settings.repo_names(Settings.get()) == ["acme/shop", "Acme/billing-api"]
    end

    test "keeps what an older settings page saved, and what the app saved", c do
      start_hub(c)
      # An older board's page kept its values in the database; the app and
      # `vitalaize setup` save in settings.json, and so does Track.
      Store.put_meta("settings_overrides", Jason.encode!(%{github: %{branch: "trunk"}}))
      File.write!(saved(c), Jason.encode!(%{alerts: %{phone: "+15550100"}}))
      Settings.load!()

      assert :ok = Settings.track_repo("acme/billing-api")
      assert :ok = Settings.track_repo("ACME/Billing-API")

      settings = Settings.get()
      assert Settings.repo_names(settings) == ["acme/shop", "acme/billing-api"]
      assert settings.github.branch == "trunk"
      assert settings.alerts.phone == "+15550100"

      assert saved_json(c) == %{
               "alerts" => %{"phone" => "+15550100"},
               "github" => %{"repos" => ["acme/shop", "acme/billing-api"]}
             }

      assert {:error, :not_a_repo} = Settings.track_repo("not a repo")
    end

    test "adds to a list the app saved, and is still there after a restart", c do
      start_hub(c)
      File.write!(saved(c), Jason.encode!(%{github: %{repos: ["acme/web", "acme/shop"]}}))
      Settings.load!()

      assert :ok = Settings.track_repo("acme/billing-api")
      names = ["acme/web", "acme/shop", "acme/billing-api"]
      assert Settings.repo_names(Settings.get()) == names
      assert saved_json(c) == %{"github" => %{"repos" => names}}

      # A start reads it back from the files.
      assert Settings.repo_names(Settings.load!()) == names
    end

    test "does not load an open board again: the mailbox stays open under the owner's hand", c do
      start_hub(c)
      shown = Settings.get()
      assert :ok = Settings.track_repo("acme/billing-api")
      tracked = Settings.get()
      assert tracked != shown
      refute WallboardWeb.BoardLive.reload_for?(shown, tracked)

      # Any other setting saved since still loads an open board again.
      saved_now = Map.put(saved_json(c), "rotate_seconds", 7)
      File.write!(saved(c), Jason.encode!(saved_now))
      later = Settings.load!()
      assert WallboardWeb.BoardLive.reload_for?(shown, later)
      assert WallboardWeb.BoardLive.reload_for?(tracked, later)
      refute WallboardWeb.BoardLive.reload_for?(later, later)
    end

    test "takes up nothing that waits for a restart", c do
      start_hub(c)
      assert Settings.get().token == nil

      # A board password saved from another program, with no restart yet.
      File.write!(saved(c), Jason.encode!(%{token: "hunter2"}))
      assert :ok = Settings.track_repo("acme/billing-api")

      assert Settings.repo_names(Settings.get()) == ["acme/shop", "acme/billing-api"]
      assert Settings.get().token == nil
      # Both are in the file for the next start.
      assert %{"token" => "hunter2", "github" => %{"repos" => [_, _]}} = saved_json(c)
    end

    test "a repo added in settings by hand drops its item, and open boards hear of it", c do
      start_hub(c)
      streamed("air", "s1", "acme/billing-api")
      settled()
      assert [_] = Mailbox.items()
      assert_receive {:mailbox, :changed}

      assert :ok = Settings.track_repo("acme/billing-api")
      assert Mailbox.items() == []
      RepoPrompts.refresh()
      assert_receive {:mailbox, :changed}
    end

    test "a repo added in the app or with vitalaize setup drops its item, and open boards hear of it",
         c do
      start_hub(c)
      streamed("air", "s1", "acme/billing-api")
      settled()
      assert [_] = Mailbox.items()
      assert_receive {:mailbox, :changed}
      refute_received {:mailbox, :changed}

      start_supervised!(
        {Wallboard.Settings.Watch, name: :watch_repos, every_ms: 20, listener: self()}
      )

      # Another program saves the list, and the running board takes it up.
      names = ["acme/shop", "acme/billing-api"]
      File.write!(saved(c), Jason.encode!(%{github: %{repos: names}}))
      assert_receive {:settings, :reloaded}, 2_000
      assert Settings.repo_names(Settings.get()) == names
      assert Mailbox.items() == []
      # Told at once, not at the next round five minutes on.
      assert_receive {:mailbox, :changed}, 2_000
    end

    test "a settings page drawn before the Track cannot undo it: the page saves nothing", c do
      start_hub(c)
      shown = Settings.get()
      assert :ok = Settings.track_repo("acme/billing-api")

      page = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          allowed?: true,
          who: %{local?: true},
          settings: shown,
          values: SettingsLive.values(shown),
          ignored_repos: [],
          notice: nil
        }
      }

      # The Save an older page sent, with its Repositories box as it was drawn.
      sent = %{"s" => %{"github.repos" => "acme/shop", "github.branch" => "main"}}
      assert {:noreply, _} = SettingsLive.handle_event("save", sent, page)

      names = ["acme/shop", "acme/billing-api"]
      assert Settings.repo_names(Settings.get()) == names
      assert saved_json(c) == %{"github" => %{"repos" => names}}

      # The open page hears the mailbox changed and shows the new list.
      assert {:noreply, page} = SettingsLive.handle_info({:mailbox, :changed}, page)
      assert Settings.repo_names(page.assigns.settings) == names
      assert page.assigns.values["github.repos"] == Enum.join(names, "\n")
    end

    test "saved settings that cannot be read are left alone", c do
      start_hub(c)
      File.write!(saved(c), "{ not json")
      assert {:error, :unreadable} = Settings.track_repo("acme/billing-api")
      assert File.read!(saved(c)) == "{ not json"
    end

    test "on a board with no repos set, the example name is not kept", c do
      File.write!(
        System.get_env("WALLBOARD_SETTINGS"),
        "%{archive: %{path: #{inspect(Path.join(c.dir, "wallboard.db"))}}}"
      )

      Settings.load!()
      start_hub(c)
      assert :ok = Settings.track_repo("acme/billing-api")
      assert Settings.repo_names(Settings.get()) == ["acme/billing-api"]
      assert saved_json(c) == %{"github" => %{"repos" => ["acme/billing-api"]}}
    end
  end

  describe "Ignore" do
    test "is remembered across a restart, and can be undone on the settings page", c do
      start_hub(c)
      streamed("air", "s1", "acme/billing-api")
      streamed("air", "s2", "acme/docs")
      settled()
      assert [%{id: id}, %{id: "repo:acme/docs"}] = Mailbox.items()

      assert :ok = Mailbox.act(id, "ignore")
      assert [%{id: "repo:acme/docs"}] = Mailbox.items()
      assert RepoPrompts.ignored() == ["acme/billing-api"]
      assert {:error, :gone} = Mailbox.act(id, "ignore")
      # Ignoring adds nothing to the board's list.
      assert Settings.repo_names(Settings.get()) == ["acme/shop"]

      stop_hub()
      start_hub(c)

      # The ignored list is back, and so is the item nobody answered.
      assert RepoPrompts.ignored() == ["acme/billing-api"]
      assert [%{id: "repo:acme/docs"}] = Mailbox.items()

      streamed("air", "s1", "acme/billing-api")
      streamed("box", "s9", "ACME/Billing-Api")
      settled()
      assert [%{id: "repo:acme/docs"}] = Mailbox.items()
      assert asked(c) == ["acme/billing-api", "acme/docs"]

      # Where the repos are configured, the ignored one shows with its way back.
      page =
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            allowed?: true,
            who: %{local?: true},
            ignored_repos: RepoPrompts.ignored(),
            notice: nil
          }
        }

      assert {:noreply, page} =
               SettingsLive.handle_event("ask_again", %{"repo" => "acme/billing-api"}, page)

      assert page.assigns.ignored_repos == []
      assert page.assigns.notice =~ "acme/billing-api"
      assert RepoPrompts.ignored() == []

      streamed("air", "s1", "acme/billing-api")
      settled()

      assert Mailbox.items() |> Enum.map(& &1.id) |> Enum.sort() ==
               ["repo:acme/billing-api", "repo:acme/docs"]
    end

    test "the settings page lists ignored repos under GitHub", c do
      start_hub(c)
      streamed("air", "s1", "acme/billing-api")
      settled()
      assert :ok = Mailbox.act("repo:acme/billing-api", "ignore")

      settings = Settings.get()

      page =
        html(
          SettingsLive.render(%{
            __changed__: nil,
            connected?: true,
            allowed?: true,
            notice: nil,
            restart?: false,
            linked: nil,
            linked_readable?: true,
            settings: settings,
            values: SettingsLive.values(settings),
            errors: %{},
            machines: [],
            ignored_repos: RepoPrompts.ignored()
          })
        )

      assert page =~ "Ignored repositories"
      assert page =~ ~r/phx-click="ask_again"[^>]*phx-value-repo="acme\/billing-api"/s
    end
  end

  describe "a repo the hub's GitHub login cannot see" do
    test "says so and offers only Ignore", c do
      start_hub(c)
      answer(c, "acme/secret", :hidden)
      streamed("air", "s1", "acme/secret")
      settled()

      assert [item] = Mailbox.items()
      assert item.actions == [{"ignore", "Ignore"}]

      page = panel()
      assert page =~ "Someone is working in <b>acme/secret</b> on air."
      assert page =~ "This hub&#39;s GitHub login can&#39;t see that repo"
      refute page =~ ~s(phx-value-action="track")

      # Track asked for anyway does nothing.
      assert {:error, :gone} = Mailbox.act(item.id, "track")
      assert Settings.repo_names(Settings.get()) == ["acme/shop"]

      assert :ok = Mailbox.act(item.id, "ignore")
      assert Mailbox.items() == []
      assert RepoPrompts.ignored() == ["acme/secret"]
    end

    test "tells GitHub's no from GitHub not being reachable" do
      assert RepoPrompts.sight({:ok, "acme/billing-api\n"}) == {:visible, "acme/billing-api"}

      assert RepoPrompts.sight({:error, "gh exited with 1: gh: Not Found (HTTP 404)"}) ==
               :hidden

      assert RepoPrompts.sight(
               {:error,
                "gh exited with 1: gh: Resource protected by organization SAML enforcement (HTTP 403)"}
             ) == :hidden

      # A login GitHub no longer takes says nothing about the repo.
      for reason <- [
            "gh exited with 1: gh: Bad credentials (HTTP 401)",
            "gh is not installed or not on the PATH",
            "gh took longer than 30s",
            "gh exited with 1: gh: API rate limit exceeded (HTTP 403)",
            "gh exited with 1: error connecting to api.github.com"
          ] do
        assert RepoPrompts.sight({:error, reason}) == :unknown
      end
    end

    test "nothing shows while GitHub cannot be asked, and it is asked again later", c do
      answer(c, "acme/billing-api", :unknown)
      start_hub(c, tick_ms: 30)
      streamed("air", "s1", "acme/billing-api")
      settled()
      assert Mailbox.items() == []

      answer(c, "acme/billing-api", {:visible, "acme/billing-api"})
      Process.sleep(150)
      settled()
      assert [%{id: "repo:acme/billing-api", actions: [{"track", _}, _]}] = Mailbox.items()
    end
  end

  describe "the hub's own sessions" do
    test "ask like any machine's, and a folder with no GitHub remote raises nothing", c do
      on_github = checkout(c, "billing", "git@github.com:acme/billing-api.git")
      no_remote = checkout(c, "scratch", nil)
      elsewhere = checkout(c, "mirror", "https://gitlab.com/acme/mirror.git")
      not_git = Path.join(c.dir, "notes")
      File.mkdir_p!(not_git)

      start_hub(c, hub: fn -> "the-hub" end)

      facts = %{
        sessions: [%{cwd: no_remote}, %{cwd: elsewhere}, %{cwd: not_git}, %{cwd: nil}]
      }

      Phoenix.PubSub.broadcast(Wallboard.PubSub, Poller.topic(), {:source, :claude, facts, %{}})
      # A stream's session in a folder with no GitHub remote names no repo.
      streamed("air", "s1", "")
      settled()
      assert Mailbox.items() == []
      assert asked(c) == []

      facts = %{sessions: [%{cwd: on_github}, %{cwd: no_remote}]}
      Phoenix.PubSub.broadcast(Wallboard.PubSub, Poller.topic(), {:source, :codex, facts, %{}})
      settled()

      assert [%{id: "repo:acme/billing-api"}] = Mailbox.items()
      assert panel() =~ "Someone is working in <b>acme/billing-api</b> on the-hub."
    end

    test "are looked at again on every round", c do
      on_github = checkout(c, "billing", "https://github.com/acme/billing-api")
      start_hub(c, hub: fn -> "the-hub" end, local: fn -> [on_github] end, tick_ms: 30)
      Process.sleep(100)
      settled()
      assert [%{id: "repo:acme/billing-api"}] = Mailbox.items()
      assert asked(c) == ["acme/billing-api"]
    end
  end

  test "a collector's session over the real link raises the item", c do
    start_hub(c)
    link = Path.join(c.dir, "link")
    start_supervised!({Wallboard.Link.Hub, dir: link, port: 0})
    {:ok, files} = Wallboard.Link.Authority.issue(link, "air")

    start_supervised!(
      {Wallboard.Link.Client,
       name: :air,
       host: "127.0.0.1",
       port: Wallboard.Link.Hub.port(),
       tls: Map.take(files, [:cert_pem, :key_pem, :ca_pem]),
       hello:
         Wallboard.Collector.Filter.hello(%{
           machine: "air",
           os: "macOS 15.6",
           version: "0.3.0",
           folders: ["/Users/r/.claude"]
         }),
       buffer: Path.join(c.dir, "air.buffer"),
       listener: self(),
       backoff: [base_ms: 40, cap_ms: 400, back_soon_ms: 600]}
    )

    assert_receive {:wallboard_link, {:resume, _}}, 5_000

    :ok =
      Wallboard.Link.Client.push(:air, %Proto.Event{
        session_id: "s1",
        file: "s1.jsonl",
        position: 100,
        at: System.os_time(:second),
        items: [
          %Proto.Item{
            body: {:summary, %Proto.Summary{folder: "/Users/r/work", repo: "acme/billing-api"}}
          }
        ]
      })

    assert_receive {:wallboard_link, {:stored, _}}, 5_000
    settled()
    assert [%{id: "repo:acme/billing-api"}] = Mailbox.items()
    assert panel() =~ "Someone is working in <b>acme/billing-api</b> on air."
  end

  test "with the database gone nothing is asked or lost, and a mailbox without the watcher is empty",
       c do
    assert Mailbox.items() == []
    assert {:error, _} = Mailbox.act("repo:acme/billing-api", "track")
    assert RepoPrompts.ignored() == []

    # The watcher without its database: it waits, and saves nothing over
    # what the database holds.
    start_supervised!({Store, path: Path.join(c.dir, "wallboard.db")})
    Store.put_meta("repo_prompts", Jason.encode!(%{ignored: ["acme/kept"], asks: []}))
    :ok = stop_supervised(Store)

    start_prompts(c, tick_ms: 30)
    streamed("air", "s1", "acme/billing-api")
    Process.sleep(80)
    assert Mailbox.items() == []
    assert asked(c) == []

    start_supervised!({Store, path: Path.join(c.dir, "wallboard.db")})
    Process.sleep(100)
    assert RepoPrompts.ignored() == ["acme/kept"]
  end
end
