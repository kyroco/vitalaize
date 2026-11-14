defmodule Wallboard.FloorScriptTest do
  @moduledoc """
  What the people on the Floor tab do in the browser.

  The Floor's rules about who someone is live in `Wallboard.Floor` and have
  their own tests. How its people move is the browser's job, in
  `priv/static/js/floor.js`. These tests run that script under Node, with a
  made-up page and a canvas that draws nothing, and check where everyone
  stands, how the games go and what a session says when it leaves. The
  checks themselves are in `test/js/floor_checks.js`; each one here is one
  of those, by name.

  They need `node` on the PATH, as GitHub's runners and a Mac with Claude
  Code have. What they cannot see is the drawing itself.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../js/floor_checks.js", __DIR__)

  @checks [
    {"nobody_inside_the_furniture", "nobody stands or walks inside the furniture, in five rooms"},
    {"nobody_inside_the_furniture_as_sessions_come_and_go",
     "nobody is inside the furniture while sessions come and go and the board changes size"},
    {"desks_move_and_land_on_nobody",
     "a desk that moves when a session joins or leaves lands on nobody"},
    {"ping_pong_players_move",
     "ping pong players step in for a short ball and back for a deep one"},
    {"arguments_end_and_play_goes_on",
     "an argument ends in a replay or the point standing, and play goes on"},
    {"foosball_is_first_to_five",
     "foosball is one a side for the idle, first to five, where there is room"},
    {"called_away_from_a_game",
     "one called away leaves the game at once and the game does not get stuck"},
    {"goodbye_then_out_of_the_door",
     "a session that ends says goodbye, waves and walks out of the door"},
    {"long_wait_gets_up_to_say_goodbye",
     "one that waited half an hour gets up off the floor to say goodbye"},
    {"back_before_it_left", "a session that comes back before it has left stays on the floor"},
    {"no_you_are_here_sign", "the YOU ARE HERE sign is not drawn"}
  ]

  for {check, title} <- @checks do
    @tag timeout: 120_000
    test title do
      node =
        System.find_executable("node") ||
          flunk("This test runs the Floor's browser script and needs node on the PATH.")

      {out, status} = System.cmd(node, [@script, unquote(check)], stderr_to_stdout: true)
      assert status == 0, out
    end
  end
end
