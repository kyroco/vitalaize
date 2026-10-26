# Tests tagged :browser draw the board in headless Chrome (see
# Wallboard.Browser). Without Chrome they are skipped on a laptop, but CI
# has it, so there a missing Chrome fails them rather than skipping.
exclude = if Wallboard.Browser.chrome() || System.get_env("CI"), do: [], else: [:browser]
ExUnit.start(exclude: exclude)
