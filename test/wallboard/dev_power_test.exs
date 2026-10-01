defmodule Wallboard.DevPowerTest do
  use ExUnit.Case, async: true

  alias Wallboard.Sources.DevPower
  alias WallboardWeb.BoardLive

  @fixtures Path.expand("../fixtures/aws", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # Real replies captured at 10:29 PM on 2026-09-28, with dev asleep.
  defp asleep do
    {:ok, facts} = DevPower.parse(fixture("db_stopped.json"), fixture("services_asleep.json"))
    facts
  end

  # Dev was asleep when the fixtures were captured, so the other states take
  # the real reply and set the counts a wake sets (extraction stays at 0).
  defp with_services(facts, db, fun) do
    services =
      Enum.map(facts.services, fn s ->
        if s.name == "shop-dev-extraction", do: s, else: fun.(s)
      end)

    %{facts | database: db, services: services}
  end

  # The Mac app's setup asks only for the profile.
  test "a profile with no database or cluster says what is missing, and asks AWS nothing" do
    settings = %{
      dev_power: %{aws_profile: "acme-dev-read", region: nil, database: nil, cluster: nil}
    }

    assert {:error, reason, :memory} = DevPower.poll(settings, nil, :memory, nil)
    assert reason =~ "database and cluster"
  end

  test "reads the database status and every service's task counts" do
    facts = asleep()
    assert facts.database == "stopped"
    assert length(facts.services) == 7
    assert Enum.all?(facts.services, &(&1.desired == 0 and &1.running == 0))
  end

  test "stopped database and no tasks is asleep" do
    assert DevPower.state(asleep()) == :asleep
    assert %{value: "Asleep"} = BoardLive.dev_power_tile(asleep(), %{error: nil})
  end

  test "available database and every service running what it wants is awake" do
    facts = with_services(asleep(), "available", &%{&1 | desired: 1, running: 1})
    assert DevPower.state(facts) == :awake

    assert %{value: "Awake", sub: "6 services up"} =
             BoardLive.dev_power_tile(facts, %{error: nil})
  end

  test "a wake in progress: database starting, then services coming up" do
    starting = with_services(asleep(), "starting", & &1)
    assert DevPower.state(starting) == :waking

    coming_up =
      with_services(asleep(), "available", fn s ->
        %{s | desired: 1, running: if(s.name == "shop-dev-app", do: 0, else: 1)}
      end)

    assert DevPower.state(coming_up) == :waking

    assert %{value: "Waking", sub: "5 of 6 services up"} =
             BoardLive.dev_power_tile(coming_up, %{error: nil})
  end

  test "right after 8pm: services at 0 while the database is still up" do
    assert DevPower.state(%{asleep() | database: "available"}) == :falling_asleep
    assert DevPower.state(%{asleep() | database: "stopping"}) == :falling_asleep
  end

  test "a stopped database with services wanting tasks is called out" do
    facts = with_services(asleep(), "stopped", &%{&1 | desired: 1})
    assert DevPower.state(facts) == :mixed
    assert %{value: "Half awake", loud: true} = BoardLive.dev_power_tile(facts, %{error: nil})
  end

  test "a failed read keeps the last state and says why" do
    assert %{value: "Asleep", sub: "stale: AWS sign-in expired: run aws sso login"} =
             BoardLive.dev_power_tile(asleep(), %{error: "AWS sign-in expired: run aws sso login"})
  end

  test "off until settings name an AWS profile" do
    refute DevPower.enabled?(Wallboard.Settings.defaults())
    assert DevPower.enabled?(%{dev_power: %{aws_profile: "dev-readonly"}})
  end
end
