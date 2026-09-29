defmodule Wallboard.Advertise do
  @moduledoc """
  Announces the board on the local network (Bonjour, `_wallboard._tcp`), so
  the Wallboard app on another Mac lists it without anyone typing an
  address.

  It runs macOS's own `dns-sd`, or on Linux `avahi-publish-service` (from
  the avahi-utils package), for as long as the board runs. Neither notices
  when the board stops, so it runs under a small shell that waits on the
  board: when the board goes away its pipe closes, the shell stops waiting
  and ends the announcement. With neither tool, the board is not announced
  and collectors type the hub's address.
  """

  use GenServer
  require Logger

  @service "_wallboard._tcp"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case announcer() do
      nil ->
        :ignore

      {tool, args} ->
        {:ok, host} = :inet.gethostname()
        name = "Wallboard on " <> (host |> to_string() |> String.replace_suffix(".local", ""))
        port = Keyword.fetch!(opts, :port)

        script =
          ~s("$0" #{args} >/dev/null 2>&1 & p=$!; cat >/dev/null; kill $p)

        port_ref =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            args: ["-c", script, tool, name, Integer.to_string(port)]
          ])

        Logger.info("Announcing \"#{name}\" on the local network")
        {:ok, %{port: port_ref}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:shutdown, {:dns_sd_exited, status}}, state}

  def handle_info(_, state), do: {:noreply, state}

  # The tool to announce with, and its arguments ($1 is the name, $2 the port).
  defp announcer do
    cond do
      dns_sd = System.find_executable("dns-sd") || existing("/usr/bin/dns-sd") ->
        {dns_sd, ~s(-R "$1" #{@service} local "$2" "path=/")}

      avahi = System.find_executable("avahi-publish-service") ->
        {avahi, ~s("$1" #{@service} "$2" "path=/")}

      true ->
        nil
    end
  end

  defp existing(path), do: if(File.exists?(path), do: path)
end
