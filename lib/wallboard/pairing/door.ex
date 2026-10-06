defmodule Wallboard.Pairing.Door do
  @moduledoc """
  The hub's side of pairing (see `Wallboard.Pairing`): the requests of
  machines that want to connect, kept in memory until the owner decides or
  they run out.

  Start it with `{Wallboard.Pairing.Door, dir: folder, link_port: port}`,
  where `dir` is the certificate authority's folder. A request goes through
  these states:

    * `:opening`: asked, and not yet shown; it still owes its random number
    * `:pending`: in the mailbox, waiting for Approve or Refuse
    * `:approved`: the owner said yes; the certificate is made when the
      collector comes for it
    * `:refused`: the collector is told so
    * `:failed`: approved, but the certificate could not be made; the
      collector is told so, and asks again

  Whatever its state, a request is forgotten ten minutes after it was
  made (an approved one, ten minutes after Approve, so the collector has
  time to come for its certificate). A waiting collector asks for the
  answer every two seconds; a request its machine has not asked about for
  a minute is taken out of the mailbox, since the machine has gone.

  Approve itself signs nothing. The certificate is made, and an older one
  of the same machine revoked, at the moment the machine that asked comes
  for the answer. So a machine that gave up before Approve loses nothing:
  no certificate is made that nobody takes, and the one it holds keeps
  working. A hub that restarts forgets every request, and the collector
  asks again.

  Every change is announced on the mailbox's topic (`Wallboard.Mailbox`).

  The door also answers a machine that already paired and whose link keeps
  failing: is its certificate still good? (`challenge/1`, then `check/4`.)
  The TLS handshake refuses a removed machine without saying why, so
  without this a machine removed while it was off would try for ever. It
  answers only a machine that proves it holds the certificate's key, and
  signs the answer with the hub's key.
  """

  use GenServer
  require Logger

  alias Wallboard.{Mailbox, Pairing}
  alias Wallboard.Link.Authority

  @sweep_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Step 1: a machine asks to pair. `from` is its network address. Returns
  `{:ok, %{id, commit, ca_pem, link_port, expires_in}}` or `{:error, reason}`
  with `:bad_name`, `:name_taken` (the name is the hub's own), `:bad_key`,
  `:bad_request` or `:busy`. `commit` is the
  fingerprint of the hub's random number; the number itself comes from
  `confirm/3`, so nobody learns a request's code before the owner sees it.
  """
  def start(from, params), do: call({:start, from, params})

  @doc """
  Step 3: the machine shows the random number it was bound to. The request
  goes into the mailbox, and `{:ok, hub_number}` is the answer. A wrong
  number forgets the request.
  """
  def confirm(from, id, nonce), do: call({:confirm, from, id, nonce})

  @doc """
  What became of a request: `{:ok, :waiting}`, `{:ok, {:approved, cert_pem}}`,
  `{:ok, :refused}`, `{:ok, :failed}` when it was approved and the hub
  could not make the certificate, or `{:error, :gone}` once it is forgotten.
  """
  def status(from, id), do: call({:status, from, id})

  @doc "The requests in the mailbox, oldest first: `%{id, name, code, replaces?, at}`."
  def pending, do: call(:pending, [])

  @doc """
  Approves a request. `:ok`, or `{:error, :gone}` when it ran out or was
  already decided. The machine's key is signed when the machine next asks
  for the answer (see the module doc).
  """
  def approve(id), do: call({:approve, id}, {:error, :unavailable})

  @doc "Refuses a request. `:ok`, or `{:error, :gone}`."
  def refuse(id), do: call({:refuse, id}, {:error, :unavailable})

  @doc """
  A challenge for `check/4`, good for a minute (`check_ms`): `{:ok, bytes}`,
  or `{:error, :busy}` for an address that asked too often. The door keeps
  no list of them. Each carries the moment it was made and a seal that
  only this running door can make, so one it made before a restart is
  simply refused.
  """
  def challenge(from), do: call({:challenge, from})

  @doc """
  Whether a machine's certificate still works, asked by a machine whose
  link keeps failing (`Wallboard.Pairing.check/2`). `proof` is the
  machine's signature of `Wallboard.Pairing.check_text/2` over a challenge
  from `challenge/1`.

  `{:ok, %{answer, signature, hub_pem}}`, where `answer` is `"approved"` or
  `"removed"` and `signature` is the hub's, over
  `Wallboard.Pairing.answer_text/3`. `{:error, :bad_request}` for a
  challenge this door did not make or that ran out, a certificate that is
  not one of this hub's machines, or a proof not made with its key: such
  a caller learns nothing. `{:error, :busy}` when the list of machines
  cannot be read just now, or the address asked too often.
  """
  def check(from, challenge, cert_pem, proof),
    do: call({:check, from, challenge, cert_pem, proof})

  # A hub with the link turned off has no door: every call says so.
  defp call(message, down \\ {:error, :unavailable}) do
    GenServer.call(__MODULE__, message, 15_000)
  catch
    :exit, _ -> down
  end

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    limits = Map.merge(Pairing.limits(), Map.new(opts[:limits] || %{}))
    Process.send_after(self(), :sweep, min(@sweep_ms, limits.confirm_ms))

    {:ok,
     %{
       dir: Keyword.fetch!(opts, :dir),
       link_port: Keyword.fetch!(opts, :link_port),
       hub_name: opts[:hub_name],
       limits: limits,
       # Seals the challenges of `check/4`. Never leaves this process.
       secret: :crypto.strong_rand_bytes(32),
       requests: %{},
       # Calls and starts in the minute that began at `since`.
       window: %{since: now(), calls: %{}, starts: %{}, all: 0}
     }}
  end

  @impl true
  def handle_call({:start, from, params}, _from, s) do
    s = s |> prune() |> roll()

    with :ok <- spend(s, from, :start),
         {:ok, name, key_pem, key_bytes, commit} <- read_start(params),
         # The hub's own name is taken: two rows with one name in the list
         # of machines would be one too many.
         true <- not same_name?(name, s.hub_name) || {:error, :name_taken},
         :ok <- room(s, from, name) do
      id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      request = %{
        id: id,
        from: from,
        name: name,
        key_pem: key_pem,
        key_bytes: key_bytes,
        commit: commit,
        nonce: :crypto.strong_rand_bytes(32),
        state: :opening,
        made: now(),
        # When the machine last asked about it.
        asked: now(),
        at: System.os_time(:second),
        code: nil,
        cert_pem: nil
      }

      reply = %{
        id: id,
        commit: Pairing.hub_commit(request.nonce),
        ca_pem: Authority.ca_pem(s.dir),
        link_port: s.link_port,
        expires_in: div(s.limits.expire_ms, 1000)
      }

      {:reply, {:ok, reply}, s |> count(from, :start) |> put_in([:requests, id], request)}
    else
      {:error, reason} -> {:reply, {:error, reason}, count(s, from, :call)}
    end
  rescue
    # The authority's folder could not be read just now.
    _ -> {:reply, {:error, :busy}, s}
  end

  def handle_call({:confirm, from, id, nonce}, _from, s) do
    s = s |> prune() |> roll()

    with :ok <- spend(s, from, :call),
         %{state: :opening, from: ^from} = r <- s.requests[id],
         true <- is_binary(nonce) and byte_size(nonce) == 32 do
      s = count(s, from, :call)

      cond do
        not Plug.Crypto.secure_compare(Pairing.commit(nonce, r.key_bytes, r.name), r.commit) ->
          # One try per request: a second number would be a second guess.
          {:reply, {:error, :bad_request}, %{s | requests: Map.delete(s.requests, id)}}

        # The mailbox's own limits are asked here, where a request enters
        # it, however many were started at once.
        not mailbox_room?(s, r.name) ->
          {:reply, {:error, :busy}, %{s | requests: Map.delete(s.requests, id)}}

        true ->
          confirmed(s, r, nonce)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, count(s, from, :call)}
      nil -> {:reply, {:error, :gone}, count(s, from, :call)}
      _ -> {:reply, {:error, :bad_request}, count(s, from, :call)}
    end
  rescue
    _ -> {:reply, {:error, :busy}, s}
  end

  def handle_call({:status, from, id}, _from, s) do
    s = s |> prune() |> roll()

    {reply, s} =
      with :ok <- spend(s, from, :call) do
        case s.requests[id] do
          %{state: :approved, cert_pem: cert} when is_binary(cert) ->
            {{:ok, {:approved, cert}}, s}

          # Approved, and the machine that asked is here for it: now the
          # certificate is made. Anyone else who knows the id is told to
          # wait, and changes nothing.
          %{state: :approved, from: ^from} = r ->
            case sign(s.dir, r) do
              {:ok, %{cert_pem: cert}} ->
                Logger.info("Pairing: #{r.name} has its certificate.")
                {{:ok, {:approved, cert}}, put_in(s.requests[id], %{r | cert_pem: cert})}

              # The owner said yes and the hub cannot keep its word (its
              # list of machines is locked or cannot be read). The machine
              # is told that, not left to wait for an answer that never
              # comes; it asks again once the hub is mended.
              {:error, reason} ->
                Logger.error(
                  "Pairing: #{r.name} was approved, but its certificate could not be made: " <>
                    "#{inspect(reason)}. It has to pair again."
                )

                {{:ok, :failed}, put_in(s.requests[id], %{r | state: :failed})}
            end

          %{state: :approved} ->
            {{:ok, :waiting}, s}

          %{state: :refused} ->
            {{:ok, :refused}, s}

          %{state: :failed} ->
            {{:ok, :failed}, s}

          # Only the machine that asked keeps its request alive.
          %{state: :pending, from: ^from} = r ->
            {{:ok, :waiting}, put_in(s.requests[id], %{r | asked: now()})}

          %{state: :pending} ->
            {{:ok, :waiting}, s}

          _ ->
            {{:error, :gone}, s}
        end
      else
        error -> {error, s}
      end

    {:reply, reply, count(s, from, :call)}
  end

  def handle_call(:pending, _from, s) do
    s = prune(s)
    working = working(s.dir)

    items =
      for {_, %{state: :pending} = r} <- s.requests do
        %{id: r.id, name: r.name, code: r.code, at: r.at, replaces?: r.name in working}
      end
      |> Enum.sort_by(&{&1.at, &1.id})

    {:reply, items, s}
  end

  def handle_call({:approve, id}, _from, s) do
    s = prune(s)

    case s.requests[id] do
      %{state: :pending} = r ->
        Logger.info("Pairing: #{r.name} was approved.")
        # Its ten minutes start again, so the answer is there to fetch
        # however late Approve came.
        s = put_in(s.requests[id], %{r | state: :approved, made: now()})
        changed()
        {:reply, :ok, s}

      _ ->
        {:reply, {:error, :gone}, s}
    end
  end

  def handle_call({:refuse, id}, _from, s) do
    s = prune(s)

    case s.requests[id] do
      %{state: :pending} = r ->
        Logger.info("Pairing: #{r.name} was refused.")
        s = put_in(s.requests[id], %{r | state: :refused})
        changed()
        {:reply, :ok, s}

      _ ->
        {:reply, {:error, :gone}, s}
    end
  end

  def handle_call({:challenge, from}, _from, s) do
    s = roll(s)

    reply =
      with :ok <- spend(s, from, :call),
           do: {:ok, seal(s.secret, :crypto.strong_rand_bytes(16), now())}

    {:reply, reply, count(s, from, :call)}
  end

  def handle_call({:check, from, challenge, cert_pem, proof}, _from, s) do
    s = roll(s)

    reply =
      with :ok <- spend(s, from, :call),
           true <- fresh?(s, challenge) || {:error, :bad_request},
           {:ok, der} <- Authority.cert_bytes(cert_pem),
           text = Pairing.check_text(challenge, der),
           {:ok, serial, standing} <- Authority.standing(s.dir, der, text, proof) do
        answer = if standing == :working, do: "approved", else: "removed"
        text = Pairing.answer_text(challenge, serial, answer)
        {signature, hub_pem} = Authority.hub_sign(s.dir, text)
        {:ok, %{answer: answer, signature: signature, hub_pem: hub_pem}}
      else
        {:error, reason} when reason in [:busy, :unreadable] -> {:error, :busy}
        _ -> {:error, :bad_request}
      end

    {:reply, reply, count(s, from, :call)}
  rescue
    # The authority's folder could not be read just now.
    _ -> {:reply, {:error, :busy}, count(s, from, :call)}
  end

  @impl true
  def handle_info(:sweep, s) do
    Process.send_after(self(), :sweep, min(@sweep_ms, s.limits.confirm_ms))
    {:noreply, s |> prune() |> roll()}
  end

  def handle_info(_, s), do: {:noreply, s}

  # ---------------------------------------------------------------------------

  # The authority's list can be locked or unreadable for a moment. That
  # must not take the door down with it.
  defp sign(dir, r) do
    Authority.sign(dir, r.name, r.key_pem, replace: true)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The names that hold a working certificate now.
  defp working(dir) do
    for %{machine: name, revoked_at: nil} <- Authority.machines(dir), do: name
  rescue
    _ -> []
  end

  defp read_start(%{"name" => name, "key" => key_pem, "commit" => commit})
       when is_binary(name) and is_binary(key_pem) and is_binary(commit) do
    with true <- Authority.machine_name?(name) || {:error, :bad_name},
         {:ok, key_bytes} <- Authority.public_bytes(key_pem),
         {:ok, <<_::binary-size(32)>> = commit} <- Base.decode16(commit, case: :mixed) do
      {:ok, name, key_pem, key_bytes, commit}
    else
      {:error, reason} when reason in [:bad_name, :bad_key] -> {:error, reason}
      _ -> {:error, :bad_request}
    end
  end

  defp read_start(_), do: {:error, :bad_request}

  # One request per address, and only so many in all. A name is held only
  # by a request the owner can see: one that has not shown its number yet
  # holds nothing but its address, so nobody can keep a machine's name
  # busy without appearing in the mailbox.
  defp room(s, from, name) do
    live = for {_, r} <- s.requests, r.state in [:opening, :pending], do: r
    opening = Enum.count(live, &(&1.state == :opening))

    cond do
      Enum.any?(live, &(&1.from == from)) -> {:error, :busy}
      not mailbox_room?(s, name) -> {:error, :busy}
      opening >= s.limits.max_opening -> {:error, :busy}
      true -> :ok
    end
  end

  # Room in the mailbox for one more request under this name: one per
  # name, and only so many in all.
  defp mailbox_room?(s, name) do
    pending = for {_, %{state: :pending} = r} <- s.requests, do: r
    length(pending) < s.limits.max_pending and not Enum.any?(pending, &same_name?(&1.name, name))
  end

  defp same_name?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_name?(_, _), do: false

  defp confirmed(s, r, nonce) do
    {:ok, ca_bytes} = Authority.cert_bytes(Authority.ca_pem(s.dir))
    code = Pairing.code(r.key_bytes, r.name, ca_bytes, nonce, r.nonce)
    Logger.info("Pairing: #{r.name} asks to connect, code #{code}.")
    s = put_in(s.requests[r.id], %{r | state: :pending, code: code, asked: now()})
    changed()
    {:reply, {:ok, r.nonce}, s}
  end

  defp spend(s, from, :start) do
    cond do
      Map.get(s.window.starts, from, 0) >= s.limits.starts_per_minute -> {:error, :busy}
      s.window.all >= s.limits.starts_per_minute_all -> {:error, :busy}
      true -> spend(s, from, :call)
    end
  end

  defp spend(s, from, :call) do
    if Map.get(s.window.calls, from, 0) >= s.limits.calls_per_minute,
      do: {:error, :busy},
      else: :ok
  end

  defp count(s, from, kind) do
    w = s.window
    w = %{w | calls: Map.update(w.calls, from, 1, &(&1 + 1))}

    w =
      if kind == :start,
        do: %{w | starts: Map.update(w.starts, from, 1, &(&1 + 1)), all: w.all + 1},
        else: w

    %{s | window: w}
  end

  # A new minute starts every count from nothing.
  defp roll(s) do
    if now() - s.window.since >= 60_000,
      do: %{s | window: %{since: now(), calls: %{}, starts: %{}, all: 0}},
      else: s
  end

  # Forgets what ran out, and says so when the mailbox lost an item.
  defp prune(s) do
    t = now()

    {keep, drop} =
      Enum.split_with(s.requests, fn {_, r} ->
        age = t - r.made

        age < s.limits.expire_ms and
          not (r.state == :opening and age >= s.limits.confirm_ms) and
          not (r.state == :pending and t - r.asked >= s.limits.gone_ms)
      end)

    if Enum.any?(drop, fn {_, r} -> r.state == :pending end), do: changed()
    %{s | requests: Map.new(keep)}
  end

  # A challenge: a random number and the moment it was made, sealed with
  # the door's secret.
  defp seal(secret, random, at) do
    body = <<random::binary-size(16), at::signed-64>>
    body <> :crypto.mac(:hmac, :sha256, secret, body)
  end

  # One this door made, less than `check_ms` ago.
  defp fresh?(s, <<body::binary-size(24), mac::binary-size(32)>>) do
    <<_random::binary-size(16), at::signed-64>> = body

    Plug.Crypto.secure_compare(:crypto.mac(:hmac, :sha256, s.secret, body), mac) and
      (now() - at) in 0..s.limits.check_ms
  end

  defp fresh?(_s, _challenge), do: false

  defp changed, do: Mailbox.changed()

  defp now, do: System.monotonic_time(:millisecond)
end
