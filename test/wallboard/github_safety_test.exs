defmodule Wallboard.GitHubSafetyTest do
  # What GitHub sends never reaches the log through a crash, and the owner
  # and name reach gh as text (issue #143). A stand-in gh on the PATH
  # answers like GitHub. One at a time: the PATH is this whole test run's.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wallboard.{Fixtures, Settings}
  alias Wallboard.Sources.GitHub

  @now ~U[2026-10-20 15:00:00Z]

  setup do
    dir = Fixtures.tmp_path("wallboard-gh-safety")
    File.mkdir_p!(dir)

    # gh -F turns a value of digits, true, false or null into a number or a
    # boolean; an owner or name sent that way is written down.
    File.write!(Path.join(dir, "gh"), """
    #!/bin/sh
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-F" ]; then
        case "$a" in owner=*|name=*) echo "$a" >> "$WALLBOARD_TEST_GH/typed" ;; esac
      fi
      prev="$a"
    done
    if [ "$2" = "graphql" ]; then
      echo '{"data": {"repository": {"mergeQueue": null, "pullRequests": {"nodes": []}}}}'
      exit 0
    fi
    case "$2" in
      *"/actions/runs?"*)
        # An answer in a shape the board does not expect: a run that is a
        # bare string, holding text from the repository.
        if [ -f "$WALLBOARD_TEST_GH/odd_runs" ]; then
          echo '{"total_count": 1, "workflow_runs": ["PLANTED repository text"]}'
        else
          echo '{"total_count": 0, "workflow_runs": []}'
        fi ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    """)

    File.chmod!(Path.join(dir, "gh"), 0o755)

    old = {System.get_env("PATH"), System.get_env("WALLBOARD_TEST_GH")}
    System.put_env("PATH", dir <> ":" <> elem(old, 0))
    System.put_env("WALLBOARD_TEST_GH", dir)

    on_exit(fn ->
      System.put_env("PATH", elem(old, 0))

      if elem(old, 1),
        do: System.put_env("WALLBOARD_TEST_GH", elem(old, 1)),
        else: System.delete_env("WALLBOARD_TEST_GH")

      File.rm_rf!(dir)
    end)

    settings =
      Settings.merge(Settings.defaults(), %{
        github: %{
          repo: "acme/shop",
          gate_workflow: nil,
          deploy_workflows: [],
          dev_deploy: nil,
          prod_deploy: nil
        }
      })

    %{dir: dir, settings: settings}
  end

  test "a raise while reading one repository fails that repository alone, and logs no fact text",
       c do
    File.write!(Path.join(c.dir, "odd_runs"), "")

    log =
      capture_log(fn ->
        assert {:error, reason, _} = GitHub.poll(c.settings, nil, %{}, @now)
        assert reason == "the read hit an error"
      end)

    refute log =~ "PLANTED"
    refute log =~ "terminating"
  end

  test "the owner and name reach gh as text, so a name of digits stays a name", c do
    settings = Settings.merge(c.settings, %{github: %{repo: "acme/2026"}})
    assert {:ok, _, _} = GitHub.poll(settings, nil, %{}, @now)

    typed = Path.join(c.dir, "typed")
    if File.exists?(typed), do: flunk("sent with -F: " <> File.read!(typed))
  end
end
