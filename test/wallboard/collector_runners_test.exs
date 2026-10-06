defmodule Wallboard.CollectorRunnersTest do
  @moduledoc """
  The GitHub runners a collector finds on its machine, from a made-up
  process list and runner folders under the temp folder. No real runner
  is needed, and none is touched.
  """
  use ExUnit.Case, async: true

  alias Wallboard.Collector.Runners
  alias Wallboard.Fixtures
  alias Wallboard.Link.RunnerStates

  setup do
    dir = Fixtures.tmp_path("wallboard-runners")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp folder(c, name, runner_file) do
    path = Path.join(c.dir, name)
    File.mkdir_p!(path)
    if runner_file, do: File.write!(Path.join(path, ".runner"), runner_file)
    path
  end

  defp ps(lines), do: fn -> {:ok, lines} end

  describe "the process list" do
    test "a listener is online, a worker from the same folder makes it busy" do
      lines = [
        # macOS, run by hand from a folder with a space in its name
        "/Users/r/actions runner/bin/Runner.Listener run",
        # Linux, as a service, with a job running
        "/home/runner/actions-runner/bin/Runner.Listener run --startuptype service",
        "/home/runner/actions-runner/bin/Runner.Worker spawnclient 115 118",
        # a runner that updated itself runs from bin.<version>
        "/opt/gh/bin.2.328.0/Runner.Listener run",
        # not runners: a search for one, a log, a file under another bin
        "grep Runner.Listener",
        "tail -f /home/runner/actions-runner/_diag/Runner_20261005.log",
        "/usr/local/bin/Runner.Listener.sh",
        "/home/r/bin/other/Runner.Listener",
        "/usr/sbin/sshd -D"
      ]

      assert Runners.parse(lines) == %{
               "/Users/r/actions runner" => :online,
               "/home/runner/actions-runner" => :busy,
               "/opt/gh" => :online
             }

      # A worker before its listener in the list is still busy.
      assert Runners.parse(Enum.reverse(Enum.take(lines, 3)))
             |> Map.take(["/home/runner/actions-runner"]) ==
               %{"/home/runner/actions-runner" => :busy}
    end

    test "each runner by the name in its .runner file, and the folders it could not name", c do
      # As the runner writes it: a byte order mark, then camel case.
      air = folder(c, "air", "﻿" <> Jason.encode!(%{agentId: 3, agentName: "kyroco-air-1"}))
      old = folder(c, "old", Jason.encode!(%{"AgentName" => "box.2_b"}))
      none = folder(c, "none", nil)
      broken = folder(c, "broken", "{not json")
      empty = folder(c, "empty", Jason.encode!(%{agentName: ""}))

      lines =
        for(dir <- [air, old, none, broken, empty], do: "#{dir}/bin/Runner.Listener run") ++
          ["#{old}/bin/Runner.Worker spawnclient 1 2"]

      assert {runners, unnamed} = Runners.read(ps(lines))

      assert runners == [
               %{name: "box.2_b", state: :busy},
               %{name: "kyroco-air-1", state: :online}
             ]

      assert unnamed == Enum.sort([none, broken, empty])
    end

    test "a .runner file this user may not read leaves the runner unnamed", c do
      dir = folder(c, "locked", Jason.encode!(%{agentName: "air-9"}))
      File.chmod!(Path.join(dir, ".runner"), 0o000)
      on_exit(fn -> File.chmod(Path.join(dir, ".runner"), 0o600) end)

      # Root reads any file, so the check means something only for others.
      if System.get_env("USER") != "root" do
        assert Runners.read(ps(["#{dir}/bin/Runner.Listener run"])) == {[], [dir]}
      end
    end

    test "no process list, no runners and no error" do
      assert Runners.read(fn -> :error end) == :error
      assert Runners.read(ps([])) == {[], []}
    end

    test "this machine's own process list can be read" do
      assert {:ok, [_ | _] = lines} = Runners.processes()
      assert Enum.all?(lines, &is_binary/1)
    end
  end

  describe "a .runner that is not a plain file" do
    # Any program on the machine can start a Runner.Listener from a folder
    # it made and put what it likes at that folder's .runner. Reading a
    # named pipe waits for a writer forever, so each name is asked for in a
    # task that must answer within a second.
    defp name_within_a_second(folder) do
      task = Task.async(fn -> Runners.name(folder) end)

      case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> :still_reading
      end
    end

    test "a named pipe is not read, and does not hold the collector up", c do
      path = folder(c, "pipe", nil)
      {_, 0} = System.cmd("mkfifo", [Path.join(path, ".runner")])

      assert name_within_a_second(path) == :error
    end

    test "a link is not followed, to a pipe or to a plain file", c do
      pipe = folder(c, "elsewhere", nil)
      {_, 0} = System.cmd("mkfifo", [Path.join(pipe, "fifo")])
      to_pipe = folder(c, "to-pipe", nil)
      File.ln_s!(Path.join(pipe, "fifo"), Path.join(to_pipe, ".runner"))

      plain = Path.join(c.dir, "plain.json")
      File.write!(plain, ~s({"agentName": "linked"}))
      to_plain = folder(c, "to-plain", nil)
      File.ln_s!(plain, Path.join(to_plain, ".runner"))

      assert name_within_a_second(to_pipe) == :error
      assert name_within_a_second(to_plain) == :error
    end

    test "a plain file past the size limit is not read", c do
      big = ~s({"agentName": "big", "pad": ") <> String.duplicate("x", 70_000) <> ~s("})
      assert name_within_a_second(folder(c, "big", big)) == :error

      assert name_within_a_second(folder(c, "small", ~s({"agentName": "small"}))) ==
               {:ok, "small"}
    end

    test "a .runner swapped between a plain file and a named pipe never holds the read", c do
      path = folder(c, "swapped", nil)
      plain = Path.join(c.dir, "plain.json")
      fifo = Path.join(c.dir, "fifo")
      File.write!(plain, ~s({"agentName": "swapped"}))
      {_, 0} = System.cmd("mkfifo", [fifo])
      runner = Path.join(path, ".runner")

      # Another program puts each in place in turn, as fast as it can, so
      # that a look at a plain file can be followed by an open of the pipe.
      swap = """
      while (1) {
        for my $from (@ARGV[0, 1]) {
          unlink "$ARGV[2].tmp"; link $from, "$ARGV[2].tmp"; rename "$ARGV[2].tmp", $ARGV[2];
        }
      }
      """

      swapper =
        Port.open({:spawn_executable, System.find_executable("perl")}, [
          :binary,
          args: ["-e", swap, plain, fifo, runner]
        ])

      {:os_pid, swapper_pid} = Port.info(swapper, :os_pid)

      ps = fn -> {:ok, ["#{path}/bin/Runner.Listener run"]} end

      # Each read may take a tenth of a second here, not the usual second,
      # so that the many reads that land on the pipe stay quick.
      results =
        for _ <- 1..200 do
          task = Task.async(fn -> Runners.read(ps, 100) end)

          case Task.yield(task, 3_000) do
            {:ok, result} ->
              result

            nil ->
              # A read stuck in the pipe: another program opens it to write,
              # so the read lets go and the test run can end.
              Port.open({:spawn_executable, System.find_executable("perl")},
                args: ["-e", ~s{open(my $f, ">", $ARGV[0])}, fifo]
              )

              Task.shutdown(task, 2_000)
              :still_reading
          end
        end

      System.cmd("kill", ["-9", Integer.to_string(swapper_pid)])

      # Every read answered: named, or the folder left unnamed.
      refute :still_reading in results

      assert Enum.all?(
               results,
               &(match?({[], [_]}, &1) or match?({[%{name: "swapped"}], []}, &1))
             )
    end
  end

  describe "on the hub" do
    test "the same name on two machines shows the busiest state" do
      assert RunnerStates.merge(%{
               "a" => %{"air-1" => :offline, "air-2" => :online},
               "b" => %{"air-1" => :busy, "air-3" => :offline}
             }) == %{"air-1" => :busy, "air-2" => :online, "air-3" => :offline}

      assert RunnerStates.merge(%{"a" => %{"x" => :online}, "b" => %{"x" => :offline}}) ==
               %{"x" => :online}
    end
  end
end
