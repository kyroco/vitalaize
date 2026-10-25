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
end
