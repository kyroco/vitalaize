defmodule Wallboard.CodexCopyTest do
  @moduledoc """
  Chats the Codex app copied in (VIT-59): files written in one go, every
  line stamped with the moment of the copy. See
  `Wallboard.Fixtures.codex_copy/3` for their shape.
  """
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{CodexTranscript, Collector}
  alias Wallboard.Fixtures
  alias Wallboard.Settings
  alias Wallboard.Sources.Codex
  alias Wallboard.Store

  # Ids made in the same second, as Codex made them: the same first 8.
  @one "01a0f8bc-44e8-7b10-80e4-85e969625028"
  @two "01a0f8bc-44eb-7701-8532-3cb6069ec94f"
  @real "01a0f8bc-9f00-7c31-b926-722e0d0ebfbb"

  # The conversation happened two days before it was copied.
  @copied ~U[2026-10-01 18:31:23.150Z]
  @began DateTime.to_unix(~U[2026-09-29 12:54:31Z])
  @turns [{@began, @began + 42}, {@began + 600, @began + 660}]

  setup do
    home = Fixtures.tmp_path("codex-copy")
    codex = Path.join(home, ".codex")
    File.mkdir_p!(Path.join(codex, "sessions/2026/10/01"))
    File.mkdir_p!(Path.join(home, ".claude/projects/-Users-r-projects-shop"))
    on_exit(fn -> File.rm_rf!(home) end)

    settings =
      Settings.defaults()
      |> Settings.merge(%{
        claude: %{config_dirs: [Path.join(home, ".claude")]},
        codex: %{enabled: true, dirs: [codex]},
        archive: %{machine: "papa"}
      })
      |> Settings.normalize()

    %{home: home, codex: codex, settings: settings}
  end

  defp path(c, id),
    do: Path.join(c.codex, "sessions/2026/10/01/rollout-2026-10-01T14-31-23-#{id}.jsonl")

  # Writes a file as it was at `at`: its change time is the copy's moment.
  defp write(c, id, lines, at \\ @copied) do
    File.write!(path(c, id), Enum.map_join(lines, &(&1 <> "\n")))
    File.touch!(path(c, id), DateTime.to_unix(at))
  end

  defp copy(id), do: Fixtures.codex_copy(id, @copied, @turns)

  # A session someone is running: each line stamped as it is written, and
  # each turn's own clock the same as its line's.
  defp running(id, started) do
    stamp = fn s -> started |> DateTime.add(s) |> DateTime.to_iso8601() end

    [
      %{
        timestamp: stamp.(0),
        type: "session_meta",
        payload: %{id: id, cwd: "/Users/r/projects/shop", originator: "Codex Desktop"}
      },
      %{
        timestamp: stamp.(0),
        type: "event_msg",
        payload: %{type: "task_started", started_at: DateTime.to_unix(started)}
      },
      %{
        timestamp: stamp.(1),
        type: "event_msg",
        payload: %{
          type: "item_completed",
          item: %{type: "UserMessage", content: [%{type: "text", text: "Acme: fix the cart"}]}
        }
      }
    ]
    |> Enum.map(&Jason.encode!/1)
  end

  # The lines someone adds by carrying a copied chat on in Codex, later.
  defp carried_on(at) do
    [
      %{
        timestamp: DateTime.to_iso8601(at),
        type: "event_msg",
        payload: %{type: "task_started", started_at: DateTime.to_unix(at)}
      },
      %{
        timestamp: DateTime.to_iso8601(at),
        type: "event_msg",
        payload: %{type: "user_message", message: "Acme: and the coupon?"}
      }
    ]
    |> Enum.map(&Jason.encode!/1)
  end

  defp live(c, now) do
    {:ok, %{sessions: sessions}, _} = Codex.poll(c.settings, nil, nil, now)
    sessions
  end

  test "the reader knows a copy, and gives it the conversation's own times" do
    t = CodexTranscript.read_lines(Enum.join(copy(@one), "\n"))

    assert CodexTranscript.copy?(t)
    assert DateTime.to_unix(t.first_at) == @began
    assert DateTime.to_unix(t.last_at) == @began + 660
    assert {t.prompts, t.turns, t.turn_ms, t.running} == {2, 2, 102_000, false}
    assert {t.first_prompt, t.last_prompt} == {"Acme cart question 1", "Acme cart question 2"}

    # No reply records in this shape, only the chat's total.
    assert t.requests == %{}
    assert t.total_tokens == 33_345

    refute CodexTranscript.copy?(CodexTranscript.empty())
  end

  test "a session at work is not a copy, however little it has written" do
    now = ~U[2026-10-01 18:40:00Z]
    t = CodexTranscript.read_lines(Enum.join(running(@real, now), "\n"))
    refute CodexTranscript.copy?(t)
    assert t.first_at == now
  end

  # The first look after a start is what a board installed over a running
  # one does: copies it showed are gone at once, not after the idle time.
  test "copies written just now are not on Live; a session that keeps writing is", c do
    now = DateTime.add(@copied, 5)
    write(c, @one, copy(@one))
    write(c, @two, copy(@two))
    assert live(c, now) == []

    write(c, @real, running(@real, DateTime.add(now, -3)), now)
    assert [%{session_id: @real, status: :working}] = live(c, now)

    # Ten minutes on, still nothing from the copies.
    later = DateTime.add(now, 600)
    File.touch!(path(c, @real), DateTime.to_unix(later))
    assert [%{session_id: @real}] = live(c, later)
  end

  test "a copy someone carries on in Codex is a session from then on", c do
    later = DateTime.add(@copied, 900) |> DateTime.truncate(:second)
    write(c, @one, copy(@one) ++ carried_on(later), later)

    assert [card] = live(c, later)
    assert {card.session_id, card.status} == {@one, :working}
    # The file has no reply records, so the chat's total stands in.
    assert card.detail.tokens == 33_345
  end

  test "sessions started close together show different short ids", c do
    now = ~U[2026-10-01 18:40:00Z]
    write(c, @one, running(@one, now), now)
    write(c, @two, running(@two, now), now)

    assert String.slice(@one, 0, 8) == String.slice(@two, 0, 8)
    assert [a, b] = live(c, now) |> Enum.map(& &1.short_id) |> Enum.sort()
    assert a != b
    assert {a, b} == {"069ec94f", "69625028"}
  end

  describe "the Archive" do
    setup do
      start_supervised!({Store, path: ":memory:"})
      :ok
    end

    # What Codex notes about a chat it copied from a Claude session.
    defp imported(c, ids) do
      records =
        for id <- ids do
          %{
            source_path:
              Path.join(c.home, ".claude/projects/-Users-r-projects-shop/#{id}-source.jsonl"),
            imported_thread_id: id,
            imported_at: DateTime.to_unix(@copied)
          }
        end

      File.write!(
        Path.join(c.codex, "external_agent_session_imports.json"),
        Jason.encode!(%{records: records})
      )
    end

    test "a copied-in chat is saved once, on the days it happened", c do
      write(c, @one, copy(@one))
      now = DateTime.add(@copied, 600)

      assert {:ok, 1} = Collector.round(c.settings, now, false)
      assert {:ok, 0} = Collector.round(c.settings, DateTime.add(now, 60), false)

      assert [row] = Store.list_sessions()
      assert {row.tool, row.session_id, row.prompts} == {"codex", @one, 2}
      assert {row.started_at, row.ended_at} == {@began, @began + 660}

      # Trends puts a session on the hour it ended, so none lands at the copy.
      assert [%{n: 0}] =
               Store.query("SELECT count(*) AS n FROM sessions WHERE ended_at >= ?1", [
                 DateTime.to_unix(@copied) - 3600
               ])

      assert live(c, DateTime.add(@copied, 5)) == []
    end

    test "a copy of a Claude session read here is not saved a second time", c do
      write(c, @one, copy(@one))
      write(c, @two, copy(@two))
      imported(c, [@one])
      now = DateTime.add(@copied, 600)

      assert {:ok, 1} = Collector.round(c.settings, now, false)
      assert [%{session_id: @two}] = Store.list_sessions()

      # Carried on in Codex, it is a Codex session and is saved.
      later = DateTime.add(@copied, 900) |> DateTime.truncate(:second)
      write(c, @one, copy(@one) ++ carried_on(later), later)
      assert {:ok, 1} = Collector.round(c.settings, DateTime.add(later, 600), false)

      assert Store.list_sessions() |> Enum.map(& &1.session_id) |> Enum.sort() ==
               Enum.sort([@one, @two])
    end

    test "a copy from a folder that is not read here is saved", c do
      write(c, @one, copy(@one))
      imported(c, [@one])
      other = [Path.join(c.home, ".claude-other")]
      settings = put_in(c.settings, [:claude, :config_dirs], other)

      assert {:ok, 1} = Collector.round(settings, DateTime.add(@copied, 600), false)
    end
  end
end
