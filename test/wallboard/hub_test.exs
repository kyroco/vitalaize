defmodule Wallboard.HubTest do
  use ExUnit.Case, async: false

  alias Wallboard.Settings

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

  test "the database goes where the setting says, or in this system's usual place" do
    assert Settings.db_path("/tmp/x/board.db") == "/tmp/x/board.db"

    default = Settings.db_path(nil)
    assert String.ends_with?(default, "wallboard.db")

    case :os.type() do
      {:unix, :darwin} -> assert default =~ "Library/Application Support/Wallboard"
      _ -> assert default =~ "vitalaize"
    end
  end

  test "the settings page keeps only values that differ from the file, and checks them" do
    base = %{
      rotate_seconds: 30,
      alerts: %{phone: "+1555", via: "iMessage"},
      github: %{repo: "acme/shop"},
      claude: %{config_dirs: ["/Users/r/.claude"]}
    }

    values = %{
      "role" => "both",
      "port" => "4747",
      "link.port" => "4748",
      "new_relic.region" => "us",
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
