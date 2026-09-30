defmodule Wallboard.HubTest do
  use ExUnit.Case, async: false

  alias Wallboard.Archive.Ingest
  alias Wallboard.{Settings, Store}

  @sid "9f8651f6-634b-47b7-a4db-b27994e624eb"

  test "an upload holds one session and its own subagent files, nothing else" do
    main = {@sid <> ".jsonl", "{}"}
    sub = {@sid <> "/subagents/agent-a1.jsonl", "{}"}
    meta = {@sid <> "/subagents/agent-a1.meta.json", "{}"}

    assert {:ok, @sid, "{}", [{"agent-a1.jsonl", _}, {"agent-a1.meta.json", _}]} =
             Ingest.sort_files([main, sub, meta])

    assert {:error, _} = Ingest.sort_files([main, {"../../etc/evil.jsonl", "x"}])
    assert {:error, _} = Ingest.sort_files([main, {@sid <> "/subagents/../../x.jsonl", "x"}])
    assert {:error, _} = Ingest.sort_files([main, {"/tmp/" <> @sid <> ".jsonl", "x"}])
    assert {:error, _} = Ingest.sort_files([sub])

    other = "00000000-0000-0000-0000-000000000000"
    assert {:error, _} = Ingest.sort_files([main, {other <> "/subagents/a.jsonl", "{}"}])
  end

  test "macOS attribute files in an upload are left out, and the session is saved" do
    start_supervised!({Store, path: ":memory:"})
    dir = Path.join(System.tmp_dir!(), "wallboard-hub-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    line =
      ~s({"type":"user","timestamp":"2026-09-29T13:00:00Z","message":{"role":"user","content":"hello"}})

    tar =
      Path.join(dir, "up.tgz")
      |> tap(fn path ->
        :ok =
          :erl_tar.create(
            String.to_charlist(path),
            [{~c"._#{@sid}.jsonl", "attrs"}, {~c"#{@sid}.jsonl", line <> "\n"}],
            [:compressed]
          )
      end)
      |> File.read!()

    settings = %{
      archive: %{path: Path.join(dir, "wallboard.db")},
      usage: %{prices: %{}}
    }

    assert {:ok, @sid} = Ingest.receive(tar, "probe-mac", ".claude", settings)
    [row] = Store.list_sessions()
    assert {row.machine, row.account, row.prompts} == {"probe-mac", "main", 1}
    File.rm_rf!(dir)
  end

  test "the settings page knows this Mac by localhost and by its own network addresses" do
    alias WallboardWeb.SettingsLive
    assert SettingsLive.this_mac?({127, 0, 0, 1})
    assert SettingsLive.this_mac?({0, 0, 0, 0, 0, 0, 0, 1})

    {:ok, ifs} = :inet.getifaddrs()
    own = for {_, opts} <- ifs, {:addr, {_, _, _, _} = a} <- opts, a != {127, 0, 0, 1}, do: a

    for {a, b, c, d} <- own do
      assert SettingsLive.this_mac?({a, b, c, d})
      assert SettingsLive.this_mac?({0, 0, 0, 0, 0, 65535, a * 256 + b, c * 256 + d})
    end

    refute SettingsLive.this_mac?({192, 0, 2, 77})
  end

  test "the page carries a light and a dark color set" do
    css = WallboardWeb.Layouts.theme_css(Settings.defaults().theme)
    assert css =~ ":root{color-scheme:light;--page:#f1efed;"
    assert css =~ ":root[data-theme=dark]{color-scheme:dark;--page:#161413;"
    assert css =~ "@media (prefers-color-scheme: dark){:root:not([data-theme=light])"
  end

  test "machine and account names must be safe folder names" do
    assert Ingest.valid_name?("Papa-2")
    refute Ingest.valid_name?("../papa")
    refute Ingest.valid_name?("")
    refute Ingest.valid_name?(nil)
  end

  test "the ingest key is made once and checked exactly" do
    start_supervised!({Store, path: ":memory:"})
    key = Ingest.token()
    assert key == Ingest.token()
    assert Ingest.valid_token?(key)
    refute Ingest.valid_token?(key <> "x")
    refute Ingest.valid_token?(nil)
  end

  test "the database goes where the setting says, or in this system's usual place" do
    assert Settings.db_path("/tmp/x/board.db") == "/tmp/x/board.db"

    default = Settings.db_path(nil)
    assert String.ends_with?(default, "wallboard.db")

    case :os.type() do
      {:unix, :darwin} -> assert default =~ "Library/Application Support/Wallboard"
      _ -> assert default =~ "vitalaize"
    end
  end

  test "the connect script's Linux part is valid Python" do
    script = Ingest.install_script("http://192.168.1.20:4747", "abc")
    [_, rest] = String.split(script, "<<'WALLBOARD_PY'\n", parts: 2)
    [python, _] = String.split(rest, "\nWALLBOARD_PY", parts: 2)
    path = Path.join(System.tmp_dir!(), "wallboard-connect-test.py")
    File.write!(path, python)

    if System.find_executable("python3") do
      assert {_, 0} = System.cmd("python3", ["-m", "py_compile", path], stderr_to_stdout: true)
    end

    File.rm(path)
  end

  test "the upload script is valid shell" do
    script = Ingest.install_script("http://192.168.1.20:4747", "abc")
    path = Path.join(System.tmp_dir!(), "wallboard-install-test.sh")
    File.write!(path, script)
    assert {_, 0} = System.cmd("sh", ["-n", path])
    File.rm(path)
  end

  test "the settings page keeps only values that differ from the file, and checks them" do
    base = %{
      rotate_seconds: 30,
      alerts: %{phone: "+1555", via: "iMessage"},
      github: %{repo: "acme/shop"},
      claude: %{config_dirs: ["/Users/r/.claude"]}
    }

    values = %{
      "rotate_seconds" => "30",
      "alerts.phone" => "",
      "alerts.via" => "SMS",
      "github.repos" => "acme/shop",
      "claude.config_dirs" => "/Users/r/.claude\n",
      "claude.long_running_minutes" => "45",
      "archive.backfill_days" => "14",
      "archive.settle_seconds" => "120",
      "codex.idle_minutes" => "120"
    }

    assert {:ok, over} = Settings.check(values, base)
    assert over.alerts == %{phone: nil, via: "SMS"}
    refute Map.has_key?(over, :rotate_seconds)
    refute Map.has_key?(over, :github)

    assert {:error, errors} =
             Settings.check(%{values | "github.repos" => "acme/shop\nnot-a-repo"}, base)

    assert errors["github.repos"] =~ "not-a-repo is not owner/name"

    assert {:error, errors} = Settings.check(%{values | "rotate_seconds" => "soon"}, base)
    assert errors["rotate_seconds"] =~ "whole number"
  end
end
