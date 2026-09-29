defmodule Wallboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :wallboard,
      version: "0.2.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {Wallboard.Application, []},
      extra_applications: [:logger, :inets, :ssl, :public_key, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Only what Phoenix and LiveView need. Calls to New Relic use Erlang's
  # built-in :httpc, so there is no HTTP client dependency.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.2"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.41.0"}
    ]
  end

  # The release bundles Erlang (include_erts), so whoever runs it needs no
  # Elixir or Erlang. The extra step copies OpenSSL into the release, because
  # Homebrew's Erlang loads it from /opt/homebrew, which a friend may not have.
  defp releases do
    [
      wallboard: [
        include_executables_for: [:unix],
        include_erts: true,
        steps: [
          :assemble,
          &Wallboard.ReleaseSteps.bundle_openssl/1,
          &Wallboard.ReleaseSteps.add_docs/1,
          :tar
        ]
      ]
    ]
  end
end

# Lives here, not in lib/, because it runs only while building the release.
defmodule Wallboard.ReleaseSteps do
  @moduledoc """
  A `mix release` step that makes the release run on a Mac without Homebrew.

  Homebrew's Erlang loads OpenSSL from /opt/homebrew. This copies that
  library into the release next to Erlang's crypto library, points crypto at
  the copy, and re-signs both, since macOS refuses to load a changed library
  whose signature no longer matches.
  """

  # Only a Mac build needs this; on Linux, Erlang uses the system's OpenSSL.
  def bundle_openssl(release) do
    if match?({:unix, :darwin}, :os.type()), do: do_bundle_openssl(release), else: release
  end

  defp do_bundle_openssl(release) do
    for crypto <- Path.wildcard(Path.join(release.path, "lib/crypto-*/priv/lib/crypto.so")) do
      {out, 0} = System.cmd("otool", ["-L", crypto])

      for line <- String.split(out, "\n"),
          [_, lib] <- [
            Regex.run(~r/^\s+(\S*(?:homebrew|usr\/local)\S*libcrypto[^\s]*\.dylib)/, line)
          ] do
        dir = Path.dirname(crypto)
        copy = Path.join(dir, Path.basename(lib))
        File.cp!(lib, copy)
        File.chmod!(copy, 0o755)
        run!("install_name_tool", ["-id", "@loader_path/" <> Path.basename(lib), copy])
        run!("install_name_tool", ["-change", lib, "@loader_path/" <> Path.basename(lib), crypto])
        run!("codesign", ["--force", "--sign", "-", copy])
        run!("codesign", ["--force", "--sign", "-", crypto])

        Mix.shell().info(
          "Bundled #{Path.basename(lib)} into the release for #{Path.relative_to(crypto, release.path)}"
        )
      end

      # Erlang's own crypto test engine also points at Homebrew. Nothing
      # loads it outside Erlang's test suite, so leave it out.
      File.rm(Path.join(Path.dirname(crypto), "otp_test_engine.so"))
    end

    release
  end

  @doc """
  Puts the README, the example settings, the license and the Linux service
  script in the release folder.
  """
  def add_docs(release) do
    files = ["README.md", "settings.example.exs", "LICENSE", "NOTICE"]
    for file <- files, do: File.cp!(file, Path.join(release.path, file))

    File.cp!("scripts/systemd.sh", Path.join(release.path, "systemd.sh"))
    File.chmod!(Path.join(release.path, "systemd.sh"), 0o755)
    files = files ++ ["systemd.sh"]

    # Listing them as overlays puts them in the tarball too.
    %{release | overlays: Enum.uniq(release.overlays ++ files)}
  end

  defp run!(cmd, args) do
    {out, status} = System.cmd(cmd, args, stderr_to_stdout: true)
    if status != 0, do: Mix.raise("#{cmd} #{Enum.join(args, " ")} failed: #{out}")
    out
  end
end
