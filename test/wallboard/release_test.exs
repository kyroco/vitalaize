defmodule Wallboard.ReleaseTest do
  use ExUnit.Case, async: true

  alias Wallboard.Settings
  alias Wallboard.Sources.Release

  defp body(tag, url \\ "https://github.com/kyroco/vitalaize/releases/tag/v0.3.0"),
    do: Jason.encode!(%{"tag_name" => tag, "html_url" => url})

  describe "newer/2" do
    test "a newer release gives its version and page" do
      assert Release.newer(body("v0.3.0"), "0.2.0") == %{
               version: "0.3.0",
               url: "https://github.com/kyroco/vitalaize/releases/tag/v0.3.0"
             }
    end

    test "the same or an older release gives nothing" do
      assert Release.newer(body("v0.2.0"), "0.2.0") == nil
      assert Release.newer(body("v0.1.0"), "0.2.0") == nil
    end

    test "compares versions as numbers, not text" do
      assert %{version: "0.10.0"} = Release.newer(body("v0.10.0"), "0.9.0")
    end

    test "a tag that is not a version, or a page off GitHub, gives nothing" do
      assert Release.newer(body("nightly"), "0.2.0") == nil
      assert Release.newer(body("v0.3.0", "https://example.com/x"), "0.2.0") == nil
      assert Release.newer(body("v0.3.0", "javascript:alert(1)"), "0.2.0") == nil
      assert Release.newer("not json", "0.2.0") == nil
      assert Release.newer(Jason.encode!(%{"message" => "Not Found"}), "0.2.0") == nil
    end
  end

  describe "poll/4" do
    @now ~U[2026-09-30 12:00:00Z]

    test "turned off, it asks nothing and shows nothing" do
      settings = Settings.merge(Settings.defaults(), %{updates: %{check: false}})
      memory = %{checked_at: @now, facts: %{version: "9.9.9", url: "x"}}
      assert Release.poll(settings, nil, memory, @now) == {:ok, nil, nil}
    end

    test "within a day of the last check, it reuses the answer without asking GitHub" do
      facts = %{version: "0.3.0", url: "https://github.com/kyroco/vitalaize/releases"}
      memory = %{checked_at: DateTime.add(@now, -23 * 3600), facts: facts}

      assert Release.poll(Settings.defaults(), nil, memory, @now) == {:ok, facts, memory}
    end
  end

  test "the check is on by default and on the settings page" do
    assert Settings.defaults().updates.check == true

    assert Enum.any?(Settings.editable(), fn {_, fields} ->
             Enum.any?(fields, &match?({[:updates, :check], _, :boolean, false, _}, &1))
           end)
  end

  test "the board's own version reads as a version" do
    assert {:ok, _} = Version.parse(Release.current())
  end
end
