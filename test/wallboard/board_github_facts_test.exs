defmodule Wallboard.BoardGitHubFactsTest do
  # The board page must not crash while it works out what to show from the
  # GitHub facts: a LiveView's crash report prints its whole state and the
  # message it was handling, and the GitHub facts hold issue text from
  # private repositories (issue #143).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wallboard.Settings
  alias WallboardWeb.BoardLive

  setup do
    before = Settings.get()
    Settings.put(Settings.merge(before, %{github: %{repos: ["acme/shop"]}}))
    on_exit(fn -> Settings.put(before) end)
    :ok
  end

  test "facts the board cannot read are logged by the error's kind alone, and the last good ones stay" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, github: nil, runners: %{}, open_run: nil, run_view: nil}
    }

    # A repository's facts without its runs: working out its summary raises
    # a KeyError, whose text holds the whole map.
    facts = %{repos: [%{repo: "acme/shop", facts: %{body: "PLANTED issue body"}, error: nil}]}

    log =
      capture_log(fn ->
        assert {:noreply, after_facts} =
                 BoardLive.handle_info({:source, :github, facts, %{error: nil}}, socket)

        assert after_facts.assigns.github == nil
      end)

    assert log =~ "KeyError"
    refute log =~ "PLANTED"
  end

  # Facts with issue text, for a repository the board does not draw, so
  # only what the page keeps of them is tested.
  @with_text %{
    repos: [
      %{
        repo: "acme/other",
        error: nil,
        facts: %{
          issues: [
            %{
              number: 1,
              title: "Tax rules",
              body: "PLANTED body",
              parked_reason: "PLANTED reason"
            }
          ],
          milestones: [
            %{
              number: 2,
              title: "Taxes",
              issues: [%{number: 1, title: "Tax rules", body: "PLANTED body"}]
            }
          ]
        }
      }
    ]
  }

  defmodule FakeGitHub do
    use GenServer

    def start_link(facts), do: GenServer.start_link(__MODULE__, facts, name: :github)

    @impl true
    def init(facts), do: {:ok, facts}

    @impl true
    def handle_call(:snapshot, _from, facts),
      do: {:reply, %{facts: facts, meta: %{fetched_at: nil, error: nil, interval: 30_000}}, facts}
  end

  test "the board keeps no issue bodies or comment lines from the facts it is sent" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, github: nil, runners: %{}, open_run: nil, run_view: nil}
    }

    {:noreply, socket} = BoardLive.handle_info({:source, :github, @with_text, %{}}, socket)

    refute inspect(socket.assigns) =~ "PLANTED"
    [%{facts: kept}] = socket.assigns.github.repos
    assert [%{number: 1, title: "Tax rules"}] = kept.issues
    assert [%{title: "Taxes", issues: [%{title: "Tax rules"}]}] = kept.milestones
  end

  test "a board opened afresh keeps no issue bodies or comment lines either" do
    start_supervised!({FakeGitHub, @with_text})

    {:ok, socket} =
      BoardLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    refute inspect(socket.assigns) =~ "PLANTED"
    assert [%{facts: %{issues: [%{title: "Tax rules"}]}}] = socket.assigns.github.repos
  end

  test "every path that works out the GitHub view logs no fact text, and falls back to the last good facts" do
    good = %{repos: []}
    bad = %{repos: [%{repo: "acme/shop", facts: %{body: "PLANTED issue body"}, error: nil}]}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        github: good,
        now: DateTime.utc_now(),
        runners: %{},
        open_run: nil,
        run_view: nil
      }
    }

    # Good facts taken in first, so the board has something to fall back to.
    {:noreply, socket} = BoardLive.handle_info({:runners, %{}}, socket)

    # Bad facts in the socket, as a later message or a tick would find them.
    socket = Phoenix.Component.assign(socket, github: bad)

    log =
      capture_log(fn ->
        assert {:noreply, after_runners} =
                 BoardLive.handle_info({:runners, %{"air-1" => :online}}, socket)

        assert after_runners.assigns.github == good
      end)

    assert log =~ "KeyError"
    refute log =~ "PLANTED"
  end

  test "an open run that cannot be shown closes its panel, and the log names only the error's kind" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        github: nil,
        runners: %{},
        open_run: %{repo: "acme/other", id: 1},
        run_view: nil
      }
    }

    # A run with no id: looking for the open run among them raises a
    # KeyError, whose text holds the run.
    facts = %{
      repos: [%{repo: "acme/other", facts: %{runs: [%{title: "PLANTED run title"}]}, error: nil}]
    }

    log =
      capture_log(fn ->
        assert {:noreply, socket} = BoardLive.handle_info({:source, :github, facts, %{}}, socket)
        assert socket.assigns.open_run == nil
        assert socket.assigns.run_view == nil
      end)

    assert log =~ "could not show a run: KeyError"
    refute log =~ "PLANTED"
  end
end
