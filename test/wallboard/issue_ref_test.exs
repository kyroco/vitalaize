defmodule Wallboard.IssueRefTest do
  # The issue a prompt names, the way people write one (issue #143).
  use ExUnit.Case, async: true

  alias Wallboard.IssueRef

  test "a number after #, or after the word issue, names an issue in the session's repository" do
    assert IssueRef.find("work on #1418 please") == %{repo: nil, number: 1418}
    assert IssueRef.find("hey work on issue 1418 in github") == %{repo: nil, number: 1418}
    assert IssueRef.find("Issue #1418") == %{repo: nil, number: 1418}
    assert IssueRef.find("#1418") == %{repo: nil, number: 1418}
  end

  test "a link to an issue names its repository" do
    assert IssueRef.find("see https://github.com/acme/shop/issues/1418 for it") ==
             %{repo: "acme/shop", number: 1418}

    assert IssueRef.find("https://github.com/acme/shop/issues/1418#issuecomment-99") ==
             %{repo: "acme/shop", number: 1418}
  end

  test "a project-board link that opens an issue names its repository" do
    link = "https://github.com/orgs/acme/projects/2?pane=issue&itemId=5&issue=acme%7Cshop%7C1441"
    assert IssueRef.find("look at " <> link) == %{repo: "acme/shop", number: 1441}

    assert IssueRef.find("https://github.com/orgs/acme/projects/2?pane=issue&issue=acme|shop|7") ==
             %{repo: "acme/shop", number: 7}
  end

  test "when a prompt names two, the first one in it wins" do
    assert IssueRef.find("issue 12, then #13") == %{repo: nil, number: 12}

    assert IssueRef.find("#5 is done, now https://github.com/acme/shop/issues/9") ==
             %{repo: nil, number: 5}

    assert IssueRef.find("https://github.com/acme/shop/issues/9 replaces #5") ==
             %{repo: "acme/shop", number: 9}
  end

  test "every reference in a prompt, in order, and never number 0" do
    assert IssueRef.find_all("color #333333, then work on #1418 and issue 1419") == [
             %{repo: nil, number: 333_333},
             %{repo: nil, number: 1418},
             %{repo: nil, number: 1419}
           ]

    assert IssueRef.find_all("#000 and issue 0") == []
    assert IssueRef.find("#000 then #12") == %{repo: nil, number: 12}
    assert IssueRef.find_all(nil) == []
  end

  test "a number that is not written as an issue names none" do
    for text <- [
          "fix the 3 failing tests",
          "robert/1418-short-title",
          "issues 12",
          "tissue 12",
          "abc#12",
          "#12abc",
          "https://github.com/acme/shop/pull/12",
          "color #fff and step #2b",
          "",
          nil
        ] do
      assert IssueRef.find(text) == nil, inspect(text)
    end
  end

  test "a Linear issue is named by its own id, or a link to it" do
    assert IssueRef.find("work on VIT-41 please") == %{team: "VIT", number: 41}
    assert IssueRef.find("(MAST-9)") == %{team: "MAST", number: 9}

    assert IssueRef.find("see https://linear.app/acme/issue/VIT-41/add-linear-support") ==
             %{team: "VIT", number: 41}

    assert IssueRef.find_all("https://linear.app/acme/issue/VIT-41 then #12 and VIT-42") == [
             %{team: "VIT", number: 41},
             %{repo: nil, number: 12},
             %{team: "VIT", number: 42}
           ]

    assert IssueRef.linear?(%{team: "VIT", number: 41})
    refute IssueRef.linear?(%{repo: nil, number: 41})
  end

  test "what is not written as a Linear id names none" do
    for text <- [
          "robert/vit-41-short-title",
          "vit-41",
          "feature/VIT-41-title",
          "VIT-41-more",
          "xVIT-41",
          "VIT-0",
          "https://example.com/VIT-41",
          "v1.VIT-41"
        ] do
      assert IssueRef.find(text) == nil, inspect(text)
    end
  end

  test "a session keeps the first three of each kind, in the order written" do
    kept =
      []
      |> IssueRef.keep("UTF-8 and #1, #2, #3, #4")
      |> IssueRef.keep("SHA-256, ISO-8601, VIT-41, then issue 5")

    assert kept == [
             %{team: "UTF", number: 8},
             %{repo: nil, number: 1},
             %{repo: nil, number: 2},
             %{repo: nil, number: 3},
             %{team: "SHA", number: 256},
             %{team: "ISO", number: 8601}
           ]

    assert IssueRef.full?(kept)
    refute IssueRef.full?(Enum.take(kept, 4))
    assert IssueRef.keep(kept, "VIT-42 and #9") == kept
  end
end
