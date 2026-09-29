defmodule Wallboard.Network do
  @moduledoc "Finds this computer's addresses on the home network."

  @doc "IPv4 addresses on the local network, like 192.168.1.20."
  def lan_addresses do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        for {_name, opts} <- ifs,
            {:addr, {a, b, c, d}} <- opts,
            private?({a, b, c, d}),
            do: Enum.join([a, b, c, d], ".")

      _ ->
        []
    end
    |> Enum.uniq()
  end

  defp private?({10, _, _, _}), do: true
  defp private?({172, b, _, _}) when b in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?(_), do: false
end
