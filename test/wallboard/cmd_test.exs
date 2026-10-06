defmodule Wallboard.CmdTest do
  use ExUnit.Case, async: true

  alias Wallboard.{Cmd, Fixtures}

  # A stand-in program writes the process ids it wants checked to a file,
  # then never ends. The test fires the time limit by hand once the file is
  # there, so no test waits for a real limit to pass.
  setup do
    dir = Fixtures.tmp_path("wallboard-cmd")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, pids: Path.join(dir, "pids")}
  end

  defp stand_in(dir, body) do
    path = Path.join(dir, "stuck")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # The process ids the stand-in wrote, once it has written them.
  defp started(pids) do
    wait_until(fn -> File.exists?(pids) and String.ends_with?(File.read!(pids), "\n") end)
    pids |> File.read!() |> String.split()
  end

  defp time_up(task), do: send(task.pid, {Cmd, :time_up})

  # Gone, or ended and only waiting to be cleared away by the system.
  defp gone?(pid) do
    {out, _} = System.cmd("ps", ["-o", "stat=", "-p", pid])
    out = String.trim(out)
    out == "" or String.starts_with?(out, "Z")
  end

  defp wait_until(fun, left \\ 100) do
    cond do
      fun.() -> :ok
      left == 0 -> flunk("waited too long")
      # A pause between looks at a condition, not a wait for a timer.
      true -> Process.sleep(50) && wait_until(fun, left - 1)
    end
  end

  test "a program past its time limit is killed, not left running", %{dir: dir, pids: pids} do
    stuck = stand_in(dir, ~s(echo $$ > "$1"\nexec sleep 600\n))
    task = Task.async(fn -> Cmd.run(stuck, [pids], timeout: 600_000) end)
    [pid] = started(pids)

    time_up(task)
    assert {:error, message} = Task.await(task)
    assert message == "#{stuck} took longer than 600s"
    assert gone?(pid)
  end

  test "with a line of input, output does not hold off the limit, and what the program started dies too",
       %{dir: dir, pids: pids} do
    # It reads its line, starts a program of its own, then prints forever.
    stuck =
      stand_in(dir, """
      read line
      sleep 600 &
      echo "$$ $!" > "$1"
      while :; do echo tick; sleep 0.01; done
      """)

    task = Task.async(fn -> Cmd.run(stuck, [pids], input: "a key", timeout: 600_000) end)
    [pid, child] = started(pids)

    time_up(task)
    assert {:error, message} = Task.await(task)
    assert message == "#{stuck} took longer than 600s"
    wait_until(fn -> gone?(pid) and gone?(child) end)
  end

  test "the kill takes a program and what it started, in every shell /bin/sh may be" do
    # dash is /bin/sh on Ubuntu and Debian, bash on a Mac.
    for shell <- ["/bin/sh", "/bin/dash", "/bin/bash"], File.exists?(shell) do
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          args: ["-c", "sleep 600 & echo $!; wait"]
        ])

      assert_receive {^port, {:data, child}}, 5_000
      {:os_pid, pid} = Port.info(port, :os_pid)

      assert {_, 0} =
               System.cmd(shell, ["-c", Cmd.kill_group(), Integer.to_string(pid)],
                 stderr_to_stdout: true
               )

      assert_receive {^port, {:exit_status, _}}, 5_000, "#{shell} did not kill the group"
      wait_until(fn -> gone?(String.trim(child)) end)
    end
  end

  test "the limit is a real timer, with or without input" do
    assert {:error, "sleep took longer than 0s"} = Cmd.run("sleep", ["600"], timeout: 0)

    assert {:error, "sleep took longer than 0s"} =
             Cmd.run("sleep", ["600"], input: "x", timeout: 0)

    # A limit that ends a run is not left behind for the next one.
    refute_received {Cmd, :time_up}
  end

  test "a program that ends gives its output, or its exit status and first error line" do
    assert {:ok, "out\n"} = Cmd.run("sh", ["-c", "echo out; echo note >&2"])

    assert {:error, "sh exited with 3: oops"} =
             Cmd.run("sh", ["-c", "echo oops >&2; echo more >&2; exit 3"])

    refute_received {Cmd, :time_up}
  end
end
