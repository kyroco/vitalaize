defmodule Mix.Tasks.Wallboard.Link.Issue do
  @shortdoc "Issues a link certificate for one machine"

  @moduledoc """
  Makes a certificate that lets one machine open the link to this hub (see
  `Wallboard.Link`), for setting a collector up by hand or trying the link
  out. Pairing by code (VIT-39) is how machines normally get one.

      mix wallboard.link.issue papa --out /tmp/papa

  Writes `cert.pem`, `key.pem` and `ca.pem` into the `--out` folder,
  readable only by you. Copy the three to the collector.

  Options:

    * `--dir`: the hub's link folder. Unless given, the one beside the
      database in your settings.
    * `--out`: where to write the files. Unless given, a folder named
      after the machine in the current folder.
    * `--replace`: revoke the machine's older certificate, if it has one.
  """

  use Mix.Task

  alias Wallboard.Link.Authority

  @impl true
  def run(args) do
    {opts, names} =
      OptionParser.parse!(args, strict: [dir: :string, out: :string, replace: :boolean])

    machine =
      case names do
        [name] -> name
        _ -> Mix.raise("Give one machine name: mix wallboard.link.issue papa")
      end

    dir = opts[:dir] || Authority.dir(Wallboard.Settings.base())
    out = opts[:out] || Path.join(File.cwd!(), machine)
    :ok = Authority.ensure!(dir)

    case Authority.issue(dir, machine, replace: opts[:replace] == true) do
      {:ok, files} ->
        File.mkdir_p!(out)
        File.chmod!(out, 0o700)

        for {name, key} <- [{"cert.pem", :cert_pem}, {"key.pem", :key_pem}, {"ca.pem", :ca_pem}] do
          path = Path.join(out, name)
          File.write!(path, "")
          File.chmod!(path, 0o600)
          File.write!(path, Map.fetch!(files, key))
        end

        Mix.shell().info("Certificate for #{machine} written to #{out}")

      {:error, :taken} ->
        Mix.raise(
          "#{machine} already has a certificate. Add --replace to revoke it and make a new one."
        )

      {:error, :bad_name} ->
        Mix.raise("Use letters, numbers, spaces, dots, - and _ for the name, 63 at most.")
    end
  end
end
