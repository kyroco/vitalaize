defmodule Wallboard.BuildsTest do
  use ExUnit.Case, async: true

  alias Wallboard.Sources.Builds

  @fixtures Path.expand("../fixtures/aws", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # Real replies captured at 9:30 AM on 2026-09-29, trimmed to names and
  # images. Prod had just deployed 511c86bab, whose deploy picked the image
  # dev built from 9847f3f92 (the commit in between changed only CI files).

  # The Mac app's setup asks only for the profiles.
  test "profiles with no repository or clusters say what is missing, and ask AWS nothing" do
    settings = %{
      dev_power: %{aws_profile: "acme-dev-read"},
      builds: %{
        prod_profile: "acme-prod-read",
        dev_profile: nil,
        region: "us-east-1",
        repository: nil,
        dev: %{cluster: nil, services: []},
        prod: %{cluster: nil, services: []}
      }
    }

    assert {:error, reason, %{}} = Wallboard.Sources.Builds.poll(settings, nil, nil, nil)
    assert reason =~ "repository and both clusters"
  end

  test "reads each service's current task definition" do
    assert {:ok, arns} = Builds.task_definitions(fixture("builds_prod_services.json"))

    assert arns == [
             "arn:aws:ecs:us-east-1:123456789012:task-definition/shop-prod-app:109",
             "arn:aws:ecs:us-east-1:123456789012:task-definition/shop-prod-web:69"
           ]
  end

  test "keeps only our own images, not the telemetry collector" do
    assert Builds.repo_images(fixture("builds_prod_app_td.json"), "shop") == [
             %{container: "app", tag: "9847f3f92fd1ed5f867df3d3d207707859761b01-api"}
           ]
  end

  test "reads the digest and the commit the image was built from" do
    assert Builds.image_detail(fixture("builds_prod_api_image.json")) == %{
             digest: "sha256:689fd9e1d12c74ca193b9e28c1102e029d2756e50e21208a7fe29ad33b0a910d",
             built_from: "9847f3f92"
           }
  end

  defp build(json_name, tag) do
    %{"app" => Map.put(Builds.image_detail(fixture(json_name)), :tag, tag)}
  end

  test "the promoted copy in prod is the same build as dev's" do
    tag = "9847f3f92fd1ed5f867df3d3d207707859761b01-api"
    dev = build("builds_dev_api_image.json", tag)
    prod = build("builds_prod_api_image.json", tag)
    assert Builds.compare(%{dev: dev, prod: prod}) == :same
  end

  test "a different digest on dev means prod is behind" do
    tag = "9847f3f92fd1ed5f867df3d3d207707859761b01-api"
    prod = build("builds_prod_api_image.json", tag)
    dev = put_in(prod, ["app", :digest], "sha256:0000")
    assert Builds.compare(%{dev: dev, prod: prod}) == :different
  end

  test "nothing to compare is unknown, never behind" do
    assert Builds.compare(%{dev: %{}, prod: %{}}) == :unknown
    assert Builds.compare(nil) == :unknown

    prod = %{"app" => %{tag: "x", digest: nil, built_from: nil}}
    assert Builds.compare(%{dev: prod, prod: prod}) == :unknown
  end
end
