defmodule Wallboard.Fixtures do
  @moduledoc "Reads saved real command output from test/fixtures."

  @dir Path.expand("../fixtures", __DIR__)

  def read!(name), do: File.read!(Path.join(@dir, name))
end
