defmodule Wallboard.Advertise do
  @moduledoc """
  Announces the board on the local network (Bonjour, `_wallboard._tcp`), so
  the Wallboard app on another Mac lists it without anyone typing an
  address.

  It runs macOS's own `dns-sd` for as long as the board runs. `dns-sd` does
  not notice when the board stops, so it runs under a small shell that
  waits on the board: when the board goes away its pipe closes, the shell
  stops waiting and ends `dns-sd`, and the announcement goes with it.
  """

  use GenServer
  require Logger

  @service "_wallboard._tcp"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case System.find_executable("dns-sd") || existing("/usr/bin/dns-sd") do
      nil ->
        :ignore

      dns_sd ->
        {:ok, host} = :inet.gethostname()
        name = "Wallboard on " <> (host |> to_string() |> String.replace_suffix(".local", ""))
        port = Keyword.fetch!(opts, :port)

        script =
          ~s("$0" -R "$1" #{@service} local "$2" "path=/" >/dev/null 2>&1 & p=$!; cat >/dev/null; kill $p)

        port_ref =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            args: ["-c", script, dns_sd, name, Integer.to_string(port)]
          ])

        Logger.info("Announcing \"#{name}\" on the local network")
        {:ok, %{port: port_ref}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:shutdown, {:dns_sd_exited, status}}, state}

  def handle_info(_, state), do: {:noreply, state}

  defp existing(path), do: if(File.exists?(path), do: path)
end
