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
    * `:approved`: signed; the collector fetches its certificate
    * `:refused`: the collector is told so

  Whatever its state, a request is forgotten ten minutes after it was
  made (an approved one, ten minutes after Approve, so the collector has
  time to fetch its certificate). A waiting collector asks for the answer
  every two seconds; a request nobody has asked about for a minute is
  taken out of the mailbox, since the machine has gone, and Approve is
  refused for one that has been quiet for fifteen seconds, so a
  certificate is never made for a machine that is no longer there to take
  it. A hub that restarts forgets every request, and the collector asks
  again.

  Every change is announced on the mailbox's topic (`Wallboard.Mailbox`).
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
  with `:bad_name`, `:bad_key`, `:bad_request` or `:busy`. `commit` is the
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
  `{:ok, :refused}`, or `{:error, :gone}` once it is forgotten.
  """
  def status(from, id), do: call({:status, from, id})

  @doc "The requests in the mailbox, oldest first: `%{id, name, code, replaces?, at}`."
  def pending, do: call(:pending, [])

  @doc """
  Approves a request: signs the machine's key. `:ok`, `{:error, :gone}` when
  it ran out or was already decided, `{:error, :left}` when the machine has
  stopped waiting for the answer, or `{:error, :unavailable}` when the
  certificate could not be made just now (the request stays).
  """
  def approve(id), do: call({:approve, id}, {:error, :unavailable})

  @doc "Refuses a request. `:ok`, or `{:error, :gone}`."
  def refuse(id), do: call({:refuse, id}, {:error, :unavailable})

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
         true <- not same_name?(name, s.hub_name) || {:error, :bad_name},
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
          %{state: :approved, cert_pem: cert} -> {{:ok, {:approved, cert}}, s}
          %{state: :refused} -> {{:ok, :refused}, s}
          %{state: :pending} = r -> {{:ok, :waiting}, put_in(s.requests[id], %{r | asked: now()})}
          _ -> {{:error, :gone}, s}
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
        if now() - r.asked > s.limits.quiet_ms do
          # Nobody is there to take the certificate. Signing would still
          # revoke the one the machine may hold now, for nothing.
          Logger.info("Pairing: #{r.name} stopped waiting before it was approved.")
          changed()
          {:reply, {:error, :left}, %{s | requests: Map.delete(s.requests, id)}}
        else
          # A machine that pairs again gets a new certificate, and its old
          # one stops working.
          case sign(s.dir, r) do
            {:ok, %{cert_pem: cert}} ->
              Logger.info("Pairing: #{r.name} was approved.")
              # Its ten minutes start again, so the answer is there to fetch
              # however late Approve came.
              s = put_in(s.requests[id], %{r | state: :approved, cert_pem: cert, made: now()})
              changed()
              {:reply, :ok, s}

            {:error, reason} ->
              Logger.warning("Pairing: no certificate for #{r.name}: #{inspect(reason)}")
              {:reply, {:error, :unavailable}, s}
          end
        end

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

  defp changed, do: Mailbox.changed()

  defp now, do: System.monotonic_time(:millisecond)
end
