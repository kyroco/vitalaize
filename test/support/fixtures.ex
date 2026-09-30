defmodule Wallboard.Fixtures do
  @moduledoc "Reads saved real command output from test/fixtures, and names temp folders."

  @dir Path.expand("../fixtures", __DIR__)

  def read!(name), do: File.read!(Path.join(@dir, name))

  @doc """
  A temp path starting with `prefix` that no other test, and no other test
  run on the same machine, uses. `unique_integer` starts over in every run,
  so the OS process id keeps two runs at once apart.
  """
  def tmp_path(prefix),
    do:
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )
end
