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
end
