defmodule Wallboard.GitRemote do
  @moduledoc """
  The GitHub repository a folder belongs to, read from its git config
  rather than by running git, so the board can ask for every session on
  every redraw. A git worktree's config lives in its main checkout, which
  this follows.
  """

  @doc ~s(The folder's origin on GitHub as "owner/name", or nil.)
  def github_repo(nil), do: nil

  def github_repo(folder) do
    with {:ok, config} <- config_path(Path.expand(folder)),
         {:ok, text} <- File.read(config) do
      text |> origin_url() |> parse()
    else
      _ -> nil
    end
  end

  @doc ~s("git@github.com:owner/name.git" or "https://github.com/owner/name" to "owner/name".)
  def parse(nil), do: nil

  def parse(url) do
    case Regex.run(~r{github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$}, String.trim(url)) do
      [_, owner, name] -> owner <> "/" <> name
      _ -> nil
    end
  end

  # The url under [remote "origin"].
  defp origin_url(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.reduce({false, nil}, fn line, {inside?, found} ->
      line = String.trim(line)

      cond do
        found ->
          {inside?, found}

        String.starts_with?(line, "[") ->
          {line =~ ~r/^\[remote\s+"origin"\]$/, nil}

        inside? and line =~ ~r/^url\s*=/ ->
          {inside?, line |> String.split("=", parts: 2) |> List.last()}

        true ->
          {inside?, nil}
      end
    end)
    |> elem(1)
  end

  # Walks up from the folder to the nearest .git: a folder in a checkout, or
  # a file ("gitdir: ...") in a worktree, whose commondir leads to the config.
  defp config_path(dir) do
    dot_git = Path.join(dir, ".git")

    cond do
      File.dir?(dot_git) ->
        {:ok, Path.join(dot_git, "config")}

      File.regular?(dot_git) ->
        with {:ok, "gitdir:" <> gitdir} <- File.read(dot_git) do
          gitdir = gitdir |> String.trim() |> Path.expand(dir)

          common =
            case File.read(Path.join(gitdir, "commondir")) do
              {:ok, rel} -> rel |> String.trim() |> Path.expand(gitdir)
              _ -> gitdir
            end

          {:ok, Path.join(common, "config")}
        end

      Path.dirname(dir) == dir ->
        :error

      true ->
        config_path(Path.dirname(dir))
    end
  end
end
