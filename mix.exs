defmodule Wallboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :wallboard,
      version: "0.4.2",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      # Settings files the tests load are Elixir too, but not tests.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")]
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
      {:exqlite, "~> 0.41.0"},
      # The messages a collector and the hub send each other (see
      # Wallboard.Collector.Filter).
      {:protobuf, "~> 0.17.1"},
      # The stream those messages travel on (see Wallboard.Link): the hub's
      # side and the collector's side.
      {:grpc_server, "~> 1.0"},
      {:grpc, "~> 1.0"},
      # The HTTP/2 client the collector's side of grpc runs on.
      {:mint, "~> 1.9"},
      # Security scanner for Phoenix code. CI runs it; run it yourself with
      # `mix sobelow`.
      {:sobelow, "~> 0.16", only: [:dev, :test], runtime: false},
      # Reads the board page in tests that tap it (LiveView's test helpers
      # need it).
      {:lazy_html, ">= 0.1.0", only: :test}
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
          &Wallboard.ReleaseSteps.check_version/1,
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

  @doc """
  Stops a release built from a version tag whose version differs from this
  file's. The board compares this file's version with GitHub's latest tag to
  say a new version is out, so a mismatch would tell people forever to
  download the build they already run.
  """
  def check_version(release) do
    git = System.find_executable("git")
    args = ["tag", "--points-at", "HEAD", "--list", "v[0-9]*"]

    case git && System.cmd(git, args) do
      {out, 0} ->
        tags = String.split(out, "\n", trim: true)
        wanted = "v#{release.version}"

        if tags != [] and wanted not in tags do
          Mix.raise(
            "This commit is tagged #{Enum.join(tags, ", ")} but mix.exs says #{release.version}. " <>
              "Change version in mix.exs to match the tag."
          )
        end

      # Not a git checkout, or no git: nothing to compare.
      _ ->
        :ok
    end

    release
  end

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
