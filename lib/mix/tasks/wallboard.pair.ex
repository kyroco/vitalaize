defmodule Mix.Tasks.Wallboard.Pair do
  @shortdoc "Pairs this machine with a hub: prints a code and waits for Approve"

  @moduledoc """
  Asks a hub for a certificate, so this machine can open the link to it
  (see `Wallboard.Pairing`).

      mix wallboard.pair 192.168.1.20

  It prints a short code and waits. Open the mailbox on the hub's board,
  check the code there is the same, and tap Approve. The certificate is
  then saved here. Nothing secret is typed or copied.

  With no address, it looks for a hub on the local network and uses the
  one it finds.

  Options:

    * `--name`: this machine's name on the hub. Its host name unless given.
    * `--out`: where to save the files. Unless given, the collector's
      folder from your settings.

  An installed VitalAIze has no `mix`; there the same command is
  `bin/wallboard eval 'Wallboard.Pairing.run("192.168.1.20")'`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [name: :string, out: :string])

    hub =
      case rest do
        [address] -> address
        [] -> nil
        _ -> Mix.raise("Give one address: mix wallboard.pair 192.168.1.20")
      end

    case Wallboard.Pairing.run(hub, name: opts[:name], dir: opts[:out]) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
