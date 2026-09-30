defmodule Wallboard.Fixtures do
  @moduledoc "Reads saved real command output from test/fixtures, and names temp folders."

  alias Wallboard.Archive.MachineKeys

  @dir Path.expand("../fixtures", __DIR__)

  def read!(name), do: File.read!(Path.join(@dir, name))

  @doc """
  A temp path starting with `prefix` that no other test, and no other test
  run on the same machine, uses. `unique_integer` starts over in every run,
  so the OS process id keeps two runs at once apart.
  """
  def tmp_path(prefix),
    do:
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

  @doc """
  Connects `machine` to the running Store's board, as the connect command
  would, and leaves its wallboard-key file in `dir`, beside an upload
  script. Returns {key_id, key}.
  """
  def connect_machine(dir, machine) do
    id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    :ok = MachineKeys.connect(machine, id, nil, MachineKeys.connect_key())
    key = MachineKeys.derive(MachineKeys.connect_key(), id)
    write_key(dir, id, machine, key)
    {id, key}
  end

  @doc "Writes a wallboard-key file, as the connect command leaves it."
  def write_key(dir, id, machine, key) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "wallboard-key"), "#{id}\n#{machine}\n#{key}\n")
  end

  @doc """
  Posts `body` to the hub at `target` (a path and query) with curl, signed
  with `key_id` and `key` unless `opts` changes a part: :time, :nonce,
  :body_sha256, :signature, or :headers to send instead. Returns {status
  code, reply}.
  """
  def signed_post(hub, target, body, key_id, key, opts \\ []) do
    [path | rest] = String.split(target, "?", parts: 2)
    query = List.first(rest) || ""
    time = opts[:time] || to_string(System.os_time(:second))
    nonce = opts[:nonce] || 12 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    # The body hash the request states, and signs: :body_sha256 states another.
    stated = opts[:body_sha256] || MachineKeys.sha256(body)

    headers =
      opts[:headers] ||
        [
          "X-Vitalaize-Key: #{key_id}",
          "X-Vitalaize-Time: #{time}",
          "X-Vitalaize-Nonce: #{nonce}",
          "X-Vitalaize-Content-SHA256: #{stated}",
          "X-Vitalaize-Signature: " <>
            (opts[:signature] ||
               MachineKeys.hmac(
                 key,
                 MachineKeys.message("POST", path, query, time, nonce, {:sha256, stated})
               ))
        ]

    file = tmp_path("wallboard-body")
    File.write!(file, body)

    try do
      {out, 0} =
        System.cmd(
          "curl",
          # A type of its own, or curl says it is a form and the body is
          # read as one before the signature is checked.
          ["-s", "-g", "-w", "\n%{http_code}", "-X", "POST", "--data-binary", "@" <> file] ++
            ["-H", "Content-Type: application/octet-stream"] ++
            Enum.flat_map(headers, &["-H", &1]) ++ [hub <> target]
        )

      [code | reply] = out |> String.split("\n") |> Enum.reverse()
      {code, reply |> Enum.reverse() |> Enum.join("\n") |> String.trim()}
    after
      File.rm(file)
    end
  end
end
