defmodule Wallboard.CollectorOutboxTest do
  use ExUnit.Case, async: true

  alias Wallboard.Collector.{Outbox, Proto}
  alias Wallboard.Fixtures

  setup do
    dir = Fixtures.tmp_path("outbox")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Temporary, so the test's supervisor does not start it again when a test
  # stops it. Started again, a second outbox works in the same folder as
  # the one the test starts next, and writes its saved point there while
  # the test is changing those files.
  defp start(dir, opts \\ []) do
    start_supervised!({Outbox, [dir: dir, name: nil] ++ opts},
      id: make_ref(),
      restart: :temporary
    )
  end

  defp event(n, pad \\ 0) do
    %Proto.Event{
      session_id: "s#{n}",
      file: String.duplicate("f", pad) <> ".jsonl",
      position: n,
      items: [%Proto.Item{body: {:ended, %Proto.SessionEnded{}}}]
    }
  end

  defp files(dir), do: dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "events-"))

  test "events come back in the order they went in, numbered from 1", %{dir: dir} do
    box = start(dir)
    assert Outbox.checkpoint(box) == nil
    assert Outbox.append(box, [event(1), event(2)], "a") == 2
    assert Outbox.append(box, [event(3)], "b") == 3

    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}, {3, event(3)}]
    assert Outbox.read(box, 2) == [{3, event(3)}]
    assert Outbox.read(box, 0, 2) == [{1, event(1)}, {2, event(2)}]
    assert Outbox.checkpoint(box) == "b"
    assert %{seq: 3, acked: 0} = Outbox.stats(box)
  end

  test "a restart keeps the events, their numbers and the saved point", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1), event(2)], "a")
    GenServer.stop(box)

    box = start(dir)
    assert Outbox.checkpoint(box) == "a"
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}]
    assert Outbox.append(box, [event(3)], "b") == 3
    assert Outbox.read(box, 2) == [{3, event(3)}]
  end

  test "events written after the last saved point are dropped on the next start", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1)], "a")
    GenServer.stop(box)

    # The collector stopped after writing two events and half of a third,
    # before their point was saved.
    [name] = files(dir)
    body = Proto.Event.encode(event(2))

    extra =
      <<byte_size(body)::32, body::binary, byte_size(body)::32, body::binary, 9::32, "half">>

    File.write!(Path.join(dir, name), extra, [:append])

    box = start(dir)
    assert Outbox.checkpoint(box) == "a"
    assert Outbox.read(box, 0) == [{1, event(1)}]
    assert Outbox.append(box, [event(2)], "b") == 2
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}]
  end

  test "a file of nothing but unsaved events is emptied", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [], "a")
    GenServer.stop(box)

    body = Proto.Event.encode(event(1))
    stray = Path.join(dir, "events-00000000000000000001.log")
    File.write!(stray, <<byte_size(body)::32, body::binary>>)

    box = start(dir)
    assert Outbox.read(box, 0) == []
    assert File.stat!(stray).size == 0
    assert Outbox.append(box, [event(1)], "b") == 1
    assert Outbox.read(box, 0) == [{1, event(1)}]

    # One named for a later number than the next goes altogether.
    GenServer.stop(box)
    later = Path.join(dir, "events-00000000000000000009.log")
    File.write!(later, <<byte_size(body)::32, body::binary>>)
    box = start(dir)
    assert Outbox.read(box, 0) == [{1, event(1)}]
    refute File.exists?(later)
  end

  test "sent events go, a file at a time, and the numbers carry on", %{dir: dir} do
    box = start(dir)
    # Each batch is over a megabyte, so each starts a file of its own.
    for n <- 1..3, do: Outbox.append(box, [event(n, 600_000), event(n + 10, 600_000)], "c#{n}")
    assert length(files(dir)) == 3
    before = Outbox.stats(box).bytes

    assert Outbox.ack(box, 3) == :ok
    assert length(files(dir)) == 2
    assert Outbox.stats(box).bytes < before
    assert [{3, _}, {4, _}, {5, _}, {6, _}] = Outbox.read(box, 2)

    # More than there is acks only what there is.
    Outbox.ack(box, 99)
    # Only an empty file named for the next number is left.
    assert files(dir) == ["events-00000000000000000007.log"]
    assert %{seq: 6, acked: 6, bytes: 0} = Outbox.stats(box)
    assert Outbox.append(box, [event(7)], "d") == 7
    GenServer.stop(box)

    box = start(dir)
    assert Outbox.read(box, 0) == [{7, event(7)}]
    assert %{seq: 7, acked: 6} = Outbox.stats(box)
  end

  test "it says when it is full, and has room again once events are sent", %{dir: dir} do
    box = start(dir, max_bytes: 1_000)
    assert Outbox.room?(box)
    Outbox.append(box, [event(1, 2_000)], "a")
    refute Outbox.room?(box)
    Outbox.ack(box, 1)
    assert Outbox.room?(box)
  end

  test "only the person the collector runs as can read it", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1)], "a")
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700

    for name <- File.ls!(dir) do
      assert Bitwise.band(File.stat!(Path.join(dir, name)).mode, 0o777) == 0o600
    end
  end

  @tag :capture_log
  test "a saved point that cannot be read is rebuilt from the events, which are kept", %{
    dir: dir
  } do
    box = start(dir)
    Outbox.append(box, [event(1), event(2)], "a")
    GenServer.stop(box)
    File.write!(Path.join(dir, "state"), "not json")

    box = start(dir)
    # The caller's place is gone, so it starts over; the events stay and
    # the numbers carry on.
    assert Outbox.checkpoint(box) == nil
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}]
    assert Outbox.append(box, [event(3)], "b") == 3
  end

  test "an append the disk refuses is an answer, not a crash, and leaves nothing behind", %{
    dir: dir
  } do
    box = start(dir)
    Outbox.append(box, [event(1)], "a")

    File.chmod!(dir, 0o500)
    assert {:error, _} = Outbox.append(box, [event(2)], "b")
    File.chmod!(dir, 0o700)

    assert Outbox.checkpoint(box) == "a"
    assert Outbox.read(box, 0) == [{1, event(1)}]
    assert Outbox.append(box, [event(2)], "b") == 2
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}]
  end

  @tag :capture_log
  test "with every event sent and the saved point lost, the numbers still carry on", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1), event(2), event(3)], "a")
    Outbox.ack(box, 3)
    GenServer.stop(box)
    File.write!(Path.join(dir, "state"), "not json")

    box = start(dir)
    assert %{seq: 3, acked: 3, bytes: 0} = Outbox.stats(box)
    assert Outbox.append(box, [event(4)], "b") == 4
    assert Outbox.read(box, 0) == [{4, event(4)}]
  end

  @tag :capture_log
  test "an event file that cannot be read stops appends, not the outbox", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1)], "a")
    [name] = files(dir)
    file = Path.join(dir, name)

    # The folder refuses the append, and the file cannot be read to put
    # things back as they were.
    File.chmod!(file, 0o000)
    File.chmod!(dir, 0o500)
    assert {:error, _} = Outbox.append(box, [event(2)], "b")
    assert {:error, _} = Outbox.append(box, [event(2)], "b")
    assert Process.alive?(box)

    File.chmod!(dir, 0o700)
    File.chmod!(file, 0o600)
    assert Outbox.append(box, [event(2)], "b") == 2
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}]
    GenServer.stop(box)

    # The same at a start.
    File.chmod!(file, 0o000)
    box = start(dir)
    assert {:error, :outbox_unreadable} = Outbox.append(box, [event(3)], "c")
    File.chmod!(file, 0o600)
    assert Outbox.append(box, [event(3)], "c") == 3
  end

  @tag :capture_log
  test "while its files cannot be read it gives nothing out and loses nothing", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1), event(2), event(3)], "place-a")
    GenServer.stop(box)
    [name] = files(dir)
    file = Path.join(dir, name)
    saved = File.read!(Path.join(dir, "state"))

    File.chmod!(file, 0o000)
    box = start(dir)
    # No saved point is not the same as an empty one.
    assert Outbox.checkpoint(box) == {:error, :outbox_unreadable}
    assert Outbox.read(box, 0) == []
    refute Outbox.room?(box)
    assert Outbox.stats(box) == %{broken?: true}
    assert Outbox.ack(box, 2) == :ok
    assert {:error, :outbox_unreadable} = Outbox.append(box, [event(4)], "place-b")
    assert File.read!(Path.join(dir, "state")) == saved

    File.chmod!(file, 0o600)
    assert Outbox.checkpoint(box) == "place-a"
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}, {3, event(3)}]
    assert %{seq: 3, acked: 0, broken?: false} = Outbox.stats(box)
  end

  @tag :capture_log
  test "an append that failed is never handed out or kept, whatever else is wrong", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1), event(2)], "a")
    [name] = files(dir)
    file = Path.join(dir, name)

    # The events can be written but their point cannot be saved, and the
    # file cannot be read to take them out again.
    File.chmod!(file, 0o200)
    File.chmod!(dir, 0o500)
    assert {:error, _} = Outbox.append(box, [event(3)], "b")
    assert Outbox.read(box, 0) == []

    File.chmod!(dir, 0o700)
    File.chmod!(file, 0o600)
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}]
    assert Outbox.append(box, [event(7)], "c") == 3
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}, {3, event(7)}]
    GenServer.stop(box)

    # The saved point unreadable too: the failed appends still do not stay.
    File.write!(Path.join(dir, "state"), "not json")
    File.mkdir_p!(Path.join(dir, "state.tmp"))
    box = start(dir)
    for _ <- 1..3, do: assert({:error, _} = Outbox.append(box, [event(8)], "d"))
    assert %{seq: 3} = Outbox.stats(box)
    assert Enum.map(Outbox.read(box, 0), &elem(&1, 0)) == [1, 2, 3]
  end

  @tag :capture_log
  @tag :capture_log
  test "an event file that cannot be read is never stepped over", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1, 600_000), event(2, 600_000)], "a")
    Outbox.append(box, [event(3), event(4)], "b")
    [first, _second] = Enum.sort(files(dir))
    File.chmod!(Path.join(dir, first), 0o000)

    # Events 3 and 4 alone would let an ack of 4 remove 1 and 2 unsent.
    assert Outbox.read(box, 0) == []
    assert Outbox.ack(box, 4) == :ok
    assert length(files(dir)) == 2

    File.chmod!(Path.join(dir, first), 0o600)
    assert Enum.map(Outbox.read(box, 0), &elem(&1, 0)) == [1, 2, 3, 4]
    assert %{acked: 0} = Outbox.stats(box)
  end

  @tag :capture_log
  test "a saved point that cannot be read is left alone, and the outbox waits for it", %{dir: dir} do
    box = start(dir)
    Outbox.append(box, [event(1), event(2)], "place-a")
    Outbox.ack(box, 1)
    GenServer.stop(box)
    state = Path.join(dir, "state")
    saved = File.read!(state)

    File.chmod!(state, 0o000)
    box = start(dir)
    assert Outbox.checkpoint(box) == {:error, :outbox_unreadable}
    assert Outbox.read(box, 0) == []
    File.chmod!(state, 0o600)
    assert File.read!(state) == saved

    assert Outbox.checkpoint(box) == "place-a"
    assert Outbox.read(box, 0) == [{1, event(1)}, {2, event(2)}]
    assert %{seq: 2, acked: 1} = Outbox.stats(box)
  end

  test "a stop during the very first append leaves none of its events behind", %{dir: dir} do
    # The events were written and the collector stopped before their point
    # was saved for the first time.
    File.mkdir_p!(dir)
    body = Proto.Event.encode(event(1))

    File.write!(
      Path.join(dir, "events-00000000000000000001.log"),
      <<byte_size(body)::32, body::binary>>
    )

    box = start(dir)
    assert Outbox.checkpoint(box) == nil
    assert Outbox.read(box, 0) == []
    assert Outbox.append(box, [event(1)], "a") == 1
    assert Outbox.read(box, 0) == [{1, event(1)}]
  end

  @tag :capture_log
  test "a saved point that is gone, with events still there, does not start the numbers over", %{
    dir: dir
  } do
    box = start(dir)
    Outbox.append(box, [event(1), event(2), event(3)], "a")
    Outbox.ack(box, 3)
    GenServer.stop(box)
    File.rm!(Path.join(dir, "state"))

    box = start(dir)
    assert Outbox.append(box, [event(4)], "b") == 4
  end
end
