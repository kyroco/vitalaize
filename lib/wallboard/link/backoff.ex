defmodule Wallboard.Link.Backoff do
  @moduledoc """
  How long a collector waits before it tries the hub again.

  Each wait is between half of a ceiling and the whole of it. The ceiling
  starts at `base_ms` and doubles with every failed try, up to `cap_ms`, so
  waits grow and never pass the cap. The random half keeps a room full of
  collectors from all returning at the same instant after the hub restarts.

  When the hub said "back soon" before it went, the first wait is longer
  (`back_soon_ms` plus up to twice that again): the hub is restarting on
  purpose and will not be there in a second.
  """

  import Bitwise

  defstruct base_ms: 1_000, cap_ms: 60_000, back_soon_ms: 5_000, tries: 0

  @doc "A fresh state. Options: `base_ms`, `cap_ms`, `back_soon_ms`."
  def new(opts \\ []),
    do: struct!(__MODULE__, Keyword.take(opts, [:base_ms, :cap_ms, :back_soon_ms]))

  @doc """
  The next wait in milliseconds and the state after it. `random` is a
  number from 0 to 1; tests pass one, everything else leaves it out.
  """
  def next(%__MODULE__{} = b, random \\ :rand.uniform()) do
    # Doubling stops at 30 so the number never grows huge; the cap is far
    # below that.
    ceiling = min(b.cap_ms, b.base_ms <<< min(b.tries, 30))
    {round(ceiling / 2 + random * ceiling / 2), %{b | tries: b.tries + 1}}
  end

  @doc "The first wait after the hub said it will be back soon. Never more than the cap."
  def back_soon(%__MODULE__{} = b, random \\ :rand.uniform()) do
    wait = round(b.back_soon_ms + random * 2 * b.back_soon_ms)
    {min(wait, b.cap_ms), %{b | tries: b.tries + 1}}
  end

  @doc "Back to the first, short wait: the hub answered."
  def reset(%__MODULE__{} = b), do: %{b | tries: 0}
end
