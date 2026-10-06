defmodule Wallboard.KeyStore do
  @moduledoc """
  Keeps the keys a person types in, such as the New Relic API key, out of
  the settings files. Each key has a short name (`"new_relic"`), and only
  this machine's own user can read it back.

    * On a Mac, the login keychain, in an item of VitalAIze's own
      (`Wallboard.KeyStore.Keychain`).
    * Elsewhere, a file only this user can read (mode 0600), in a `keys`
      folder only this user can open (mode 0700), in the board's data
      folder (`Wallboard.KeyStore.File`). Many Linux machines have no
      keychain.

  The settings file holds only a note that a key is kept, never the key
  (see `Wallboard.Settings`). Tests put a stand-in in place with the
  `:key_store` application setting, so no test reaches a real keychain.

  No message from here holds a key: an error says what could not be done
  and, at most, a program's exit status.
  """

  @doc "Keeps `key` under `name`, in place of any key kept there before."
  @callback put(name :: String.t(), key :: String.t(), opts :: keyword) ::
              :ok | {:error, String.t()}

  @doc "The key kept under `name`, `:none` when there is none, or why it cannot be read."
  @callback fetch(name :: String.t(), opts :: keyword) ::
              {:ok, String.t()} | :none | {:error, String.t()}

  @doc "Takes the key kept under `name` away. `:ok` when there was none."
  @callback delete(name :: String.t(), opts :: keyword) :: :ok | {:error, String.t()}

  @doc "Where keys are kept, in words for a message: \"the keychain\"."
  @callback place() :: String.t()

  @doc """
  Where the key kept under `name` is, in words that let a person find it:
  the keychain item, or the file's path.
  """
  @callback where(name :: String.t(), opts :: keyword) :: String.t()

  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/

  def put(name, key, opts \\ []) when is_binary(key),
    do: with(:ok <- name!(name), do: store(opts).put(name, key, opts))

  def fetch(name, opts \\ []), do: with(:ok <- name!(name), do: store(opts).fetch(name, opts))
  def delete(name, opts \\ []), do: with(:ok <- name!(name), do: store(opts).delete(name, opts))

  @doc "Where this machine keeps keys, in words for a message."
  def place(opts \\ []), do: store(opts).place()

  @doc "Where the key kept under `name` is, in words that let a person find it."
  def where(name, opts \\ []), do: store(opts).where(name, opts)

  @doc """
  The store this machine uses: the `:store` option, then the `:key_store`
  application setting (tests), then the keychain on a Mac and a file
  anywhere else.
  """
  def store(opts \\ []) do
    opts[:store] || Application.get_env(:wallboard, :key_store) ||
      case :os.type() do
        {:unix, :darwin} -> Wallboard.KeyStore.Keychain
        _ -> Wallboard.KeyStore.File
      end
  end

  # A name becomes part of a file path or a keychain item, so only a plain
  # word is taken.
  defp name!(name) do
    if is_binary(name) and name =~ @name, do: :ok, else: {:error, "not a key name"}
  end
end

defmodule Wallboard.KeyStore.Keychain do
  @moduledoc """
  Keys in the Mac's login keychain, through the `security` command: one
  item per key, with the service `VitalAIze` and the key's name as its
  account. The VITALAIZE_KEYCHAIN environment variable names another
  keychain file to use instead (the app's click-through test does).

  A key is written through `security -i`, which reads the command on its
  standard input, so the key is never on a command line (see
  `Wallboard.Cmd`). `security -i` says it succeeded even when the command
  failed, so every write is read back before it counts.
  """

  @behaviour Wallboard.KeyStore

  alias Wallboard.Cmd

  @service "VitalAIze"
  # security's status when there is no such item.
  @not_found 44

  @impl true
  def place, do: "the keychain"

  @impl true
  def where(name, _opts), do: ~s(the keychain, as the item "#{@service} #{name}")

  @impl true
  def put(name, key, opts) do
    # The words go to security's own parser, so only plain characters are
    # taken; a key from New Relic has no others. A space would let a key
    # add an option of its own, such as one that lets any app read it.
    with true <- key =~ ~r/\A[\w.\-]+\z/ || {:error, "it holds characters a key does not"},
         {:ok, keychain} <- keychain(opts) do
      line =
        Enum.join(
          ["add-generic-password -U -s #{@service} -a #{name} -l \"VitalAIze #{name}\" -w #{key}"] ++
            Enum.map(keychain, &~s("#{&1}")),
          " "
        )

      # Its own result says little; reading it back says whether it is kept.
      _ = Cmd.run("security", ["-i"], input: line, timeout: 30_000)

      case fetch(name, opts) do
        {:ok, ^key} -> :ok
        _ -> {:error, "the keychain did not keep it"}
      end
    end
  end

  @impl true
  def fetch(name, opts) do
    with {:ok, keychain} <- keychain(opts) do
      case Cmd.run(
             "security",
             ["find-generic-password", "-s", @service, "-a", name, "-w" | keychain],
             timeout: 30_000
           ) do
        {:ok, out} ->
          case String.trim(out) do
            "" -> :none
            key -> {:ok, key}
          end

        {:error, why} ->
          if not_found?(why), do: :none, else: {:error, "the keychain could not be read (#{why})"}
      end
    end
  end

  @impl true
  def delete(name, opts) do
    with {:ok, keychain} <- keychain(opts) do
      case Cmd.run(
             "security",
             ["delete-generic-password", "-s", @service, "-a", name | keychain],
             timeout: 30_000
           ) do
        {:ok, _} ->
          :ok

        {:error, why} ->
          if not_found?(why), do: :ok, else: {:error, "the keychain could not remove it (#{why})"}
      end
    end
  end

  defp not_found?(why), do: String.starts_with?(why, "security exited with #{@not_found}:")

  # `{:ok, [path]}` for the keychain file to use, as the last argument, or
  # `{:ok, []}` for the person's own keychains. A path `security -i` cannot
  # take as one word is refused, never passed over: the key would then go
  # to the person's own keychain instead of the one named.
  defp keychain(opts) do
    case opts[:keychain] || System.get_env("VITALAIZE_KEYCHAIN") do
      path when is_binary(path) and path != "" ->
        if String.contains?(path, ["\"", "\\"]),
          do: {:error, "the keychain named in VITALAIZE_KEYCHAIN has a quote or a backslash"},
          else: {:ok, [Path.expand(path)]}

      _ ->
        {:ok, []}
    end
  end
end

defmodule Wallboard.KeyStore.File do
  @moduledoc """
  Keys in files only this machine's user can read: `keys/NAME` in the
  board's data folder (beside its database, see
  `Wallboard.Settings.db_path/1`), each mode 0600, in a folder of mode
  0700. A new key is written beside the old one and then put in its
  place, so a key is never half written.

  A key file others can read, such as one restored from a backup, is made
  0600 again before it is read, with a warning in the log. When that
  cannot be done (another user owns it), the key is not read at all.

  Options: `:dir` names another folder (tests); `:settings`, the settings
  to find the data folder in, for a caller that may have none loaded;
  `:chmod`, in place of `File.chmod/2` (tests).
  """

  @behaviour Wallboard.KeyStore

  require Logger

  @impl true
  def place, do: "a file only you can read"

  @impl true
  def where(name, opts), do: Path.join(dir(opts), name)

  @impl true
  def put(name, key, opts) do
    dir = dir(opts)
    path = Path.join(dir, name)
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      # Made empty and closed to others before the key goes in.
      File.write!(tmp, "")
      File.chmod!(tmp, 0o600)
      File.write!(tmp, key)
      File.rename!(tmp, path)
      :ok
    rescue
      e in File.Error ->
        File.rm(tmp)
        {:error, "#{e.path} could not be written (#{:file.format_error(e.reason)})"}
    end
  end

  @impl true
  def fetch(name, opts) do
    path = Path.join(dir(opts), name)

    with :ok <- private(path, opts) do
      case File.read(path) do
        {:ok, text} ->
          case String.trim(text) do
            "" -> :none
            key -> {:ok, key}
          end

        {:error, :enoent} ->
          :none

        {:error, reason} ->
          {:error, "#{path} could not be read (#{:file.format_error(reason)})"}
      end
    end
  end

  # A key file open to the group or to others is closed to them before
  # the key is read. A missing file is fetch's to answer.
  defp private(path, opts) do
    with {:ok, %{mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o077) != 0 do
      chmod = opts[:chmod] || (&File.chmod/2)

      case chmod.(path, 0o600) do
        :ok ->
          Logger.warning(
            "#{path} could be read by other users of this machine. Made it 0600, " <>
              "so only you can read it."
          )

          :ok

        {:error, reason} ->
          {:error,
           "#{path} can be read by other users of this machine, and could not be made " <>
             "private (#{:file.format_error(reason)}). Run chmod 600 #{path} to use it."}
      end
    else
      _ -> :ok
    end
  end

  @impl true
  def delete(name, opts) do
    path = Path.join(dir(opts), name)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "#{path} could not be deleted (#{:file.format_error(reason)})"}
    end
  end

  @doc "The folder the keys are in."
  def dir(opts \\ []) do
    case opts[:dir] do
      dir when is_binary(dir) ->
        dir

      _ ->
        (opts[:settings] || Wallboard.Settings.get())
        |> get_in([:archive, :path])
        |> Wallboard.Settings.db_path()
        |> Path.dirname()
        |> Path.join("keys")
    end
  end
end
