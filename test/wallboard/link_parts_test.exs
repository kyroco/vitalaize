defmodule Wallboard.LinkPartsTest do
  # The link's parts on their own: the certificate authority, the waits
  # between tries and the buffer on disk. `link_test.exs` runs them together.
  use ExUnit.Case, async: true

  import Bitwise

  alias Wallboard.Collector.Proto
  alias Wallboard.Link.{Authority, Backoff, Buffer}

  setup do
    dir = Wallboard.Fixtures.tmp_path("wallboard-link-parts")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  describe "the certificate authority" do
    test "its files are for the owner only, and a second start changes nothing", %{dir: dir} do
      link = Path.join(dir, "link")
      :ok = Authority.ensure!(link)

      assert mode(link) == 0o700

      for name <- ~w(ca.key ca.pem hub.key hub.pem machines.json) do
        assert mode(Path.join(link, name)) == 0o600, "#{name} is readable by others"
      end

      before =
        for name <- File.ls!(link), into: %{}, do: {name, File.read!(Path.join(link, name))}

      :ok = Authority.ensure!(link)

      assert before ==
               for(
                 name <- File.ls!(link),
                 into: %{},
                 do: {name, File.read!(Path.join(link, name))}
               )
    end

    test "issues one certificate per machine name, and tells whose a certificate is",
         %{dir: dir} do
      :ok = Authority.ensure!(dir)
      assert {:ok, papa} = Authority.issue(dir, "papa")
      assert papa.ca_pem == Authority.ca_pem(dir)
      assert {:ok, "papa"} = Authority.machine(dir, der(papa.cert_pem))

      # The name is taken while its certificate works.
      assert {:error, :taken} = Authority.issue(dir, "papa")
      assert {:ok, newer} = Authority.issue(dir, "papa", replace: true)
      assert {:error, :revoked} = Authority.machine(dir, der(papa.cert_pem))
      assert {:ok, "papa"} = Authority.machine(dir, der(newer.cert_pem))

      assert [at, nil] = dir |> Authority.machines() |> Enum.map(& &1.revoked_at) |> Enum.sort()
      assert is_integer(at)
      assert Enum.all?(Authority.machines(dir), &(&1.machine == "papa"))

      hub = String.upcase(Authority.hub_name())

      for bad <- ["", "a/b", "../x", " lead", String.duplicate("a", 64), "new\nline", nil, hub] do
        assert {:error, :bad_name} = Authority.issue(dir, bad)
      end
    end

    test "signs a machine's own public key, so its private key never leaves it", %{dir: dir} do
      :ok = Authority.ensure!(dir)
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      {:ECPrivateKey, _, _, params, public, _} = key

      pem =
        :public_key.pem_encode([
          :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, public}, params})
        ])

      assert {:ok, signed} = Authority.sign(dir, "mama", pem)
      refute Map.has_key?(signed, :key_pem)
      assert {:ok, "mama"} = Authority.machine(dir, der(signed.cert_pem))

      # The certificate holds the key that was sent, and no other.
      cert = :public_key.pkix_decode_cert(der(signed.cert_pem), :otp)
      assert inspect(cert, limit: :infinity) =~ inspect(public, limit: :infinity)

      assert {:error, :bad_key} = Authority.sign(dir, "nana", "not a key")
      assert {:error, :bad_key} = Authority.sign(dir, "nana", signed.cert_pem)
    end

    test "revoking stops a certificate, and one from elsewhere is unknown", %{dir: dir} do
      here = Path.join(dir, "here")
      there = Path.join(dir, "there")
      :ok = Authority.ensure!(here)
      :ok = Authority.ensure!(there)
      {:ok, papa} = Authority.issue(here, "papa")
      {:ok, stranger} = Authority.issue(there, "papa")

      assert {:error, :unknown} = Authority.machine(here, der(stranger.cert_pem))
      assert {:error, :unknown} = Authority.machine(here, "not a certificate")
      assert {:error, :unknown} = Authority.machine(here, :undefined)

      assert {:ok, [_]} = Authority.revoke(here, "papa")
      assert {:ok, []} = Authority.revoke(here, "papa")
      assert {:error, :revoked} = Authority.machine(here, der(papa.cert_pem))

      # A list of machines that cannot be read vouches for nobody.
      {:ok, mama} = Authority.issue(here, "mama")
      File.write!(Path.join(here, "machines.json"), "{broken")
      assert {:error, :unknown} = Authority.machine(here, der(mama.cert_pem))
    end
  end

  describe "the waits between tries" do
    test "grow from the base and never pass the cap, whatever the dice say" do
      for random <- [0.0, 0.37, 1.0] do
        {waits, _} =
          Enum.map_reduce(1..40, Backoff.new(), fn _, b -> Backoff.next(b, random) end)

        assert Enum.all?(waits, &(&1 <= 60_000))
        assert waits == Enum.sort(waits)
        assert hd(waits) <= 1_000 and List.last(waits) >= 30_000
      end

      # Half a ceiling at the least, the whole of it at the most, doubling.
      {low, _} = Enum.map_reduce(1..8, Backoff.new(), fn _, b -> Backoff.next(b, 0.0) end)
      assert low == [500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]
      {high, _} = Enum.map_reduce(1..8, Backoff.new(), fn _, b -> Backoff.next(b, 1.0) end)
      assert high == [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000]
    end

    test "\"back soon\" makes the first wait longer, and a reset starts over" do
      {plain, _} = Backoff.next(Backoff.new(), 1.0)
      {soon_low, b} = Backoff.back_soon(Backoff.new(), 0.0)
      {soon_high, _} = Backoff.back_soon(Backoff.new(), 1.0)
      assert plain == 1_000
      assert soon_low == 5_000 and soon_high == 15_000

      # The try after it carries on doubling; it does not start from scratch.
      assert {2_000, b} = Backoff.next(b, 1.0)
      assert {1_000, _} = b |> Backoff.reset() |> Backoff.next(1.0)

      # Even the long wait obeys the cap.
      assert {300, _} = Backoff.back_soon(Backoff.new(cap_ms: 300), 1.0)
    end
  end

  describe "the buffer on disk" do
    defp event(n, opts \\ []) do
      %Proto.Event{
        session_id: opts[:session] || "s1",
        file: Keyword.get(opts, :file, "s1.jsonl"),
        position: n * 10,
        at: n,
        items:
          opts[:items] ||
            [%Proto.Item{body: {:summary, %Proto.Summary{title: String.duplicate("t", 100)}}}]
      }
    end

    defp status(session, n) do
      %Proto.Event{
        session_id: session,
        at: n,
        items: [%Proto.Item{body: {:status, %Proto.Status{state: :WORKING, since: n}}}]
      }
    end

    defp ended(session, n) do
      %Proto.Event{
        session_id: session,
        at: n,
        items: [%Proto.Item{body: {:ended, %Proto.SessionEnded{}}}]
      }
    end

    defp seqs(buffer), do: for({seq, _} <- Buffer.after_seq(buffer, 0, 1_000_000), do: seq)

    defp events(buffer) do
      for {_, payload} <- Buffer.after_seq(buffer, 0, 1_000_000), do: Proto.Event.decode(payload)
    end

    test "keeps events across a restart, in order, for the owner only", %{dir: dir} do
      path = Path.join(dir, "link.buffer")
      buffer = path |> Buffer.open() |> Buffer.push(Enum.map(1..5, &event/1))
      assert mode(path) == 0o600
      assert seqs(buffer) == [1, 2, 3, 4, 5]
      assert Buffer.after_seq(buffer, 3, 1) |> Enum.map(&elem(&1, 0)) == [4]
      Buffer.close(buffer)

      again = Buffer.open(path)
      assert events(again) == Enum.map(1..5, &event/1)
      # Numbers carry on; none is used twice.
      again = Buffer.push(again, event(6))
      assert seqs(again) == [1, 2, 3, 4, 5, 6]
    end

    test "forgets what the hub confirmed, and what the hub already has", %{dir: dir} do
      path = Path.join(dir, "link.buffer")

      buffer =
        path
        |> Buffer.open()
        |> Buffer.push(
          Enum.map(1..6, &event/1) ++ [status("s1", 7), event(8, session: "s2", file: "s2.jsonl")]
        )

      buffer = Buffer.ack(buffer, 2)
      assert seqs(buffer) == [3, 4, 5, 6, 7, 8]

      # The hub has s1's file up to position 50. A status has no position
      # and stays; so does another session's file.
      buffer = Buffer.drop_stored(buffer, %{{"s1", "s1.jsonl"} => 50})
      assert seqs(buffer) == [6, 7, 8]
      Buffer.close(buffer)

      assert seqs(Buffer.open(path)) == [6, 7, 8]

      buffer = path |> Buffer.open() |> Buffer.ack(8)
      assert Buffer.size(buffer) == {0, 0}
      Buffer.close(buffer)
      # Nothing is left but a note of the last number given out.
      assert File.stat!(path).size == 16
      assert path |> Buffer.open() |> Buffer.push(event(9)) |> seqs() == [9]
    end

    test "a record cut short by a crash is dropped, and the rest is kept", %{dir: dir} do
      path = Path.join(dir, "link.buffer")
      path |> Buffer.open() |> Buffer.push(Enum.map(1..3, &event/1)) |> Buffer.close()
      whole = File.read!(path)

      # Half of a fourth record, as a power cut would leave it.
      File.write!(path, whole <> binary_part(whole, 0, 40))
      buffer = Buffer.open(path)
      assert seqs(buffer) == [1, 2, 3]
      assert File.stat!(path).size == byte_size(whole)
      Buffer.close(buffer)

      # A record whose bytes were damaged ends the read there.
      head = binary_part(whole, 0, byte_size(whole) - 5)
      File.write!(path, head <> "wrong")
      assert seqs(Buffer.open(path)) == [1, 2]
    end

    test "when full it sheds old file events, never a session's last status or its end",
         %{dir: dir} do
      path = Path.join(dir, "link.buffer")
      buffer = Buffer.open(path, max_bytes: 4_000)
      assert {false, buffer} = Buffer.take_shed(buffer)

      buffer =
        buffer
        |> Buffer.push([status("s1", 1), status("s1", 2), ended("s2", 3)])
        |> Buffer.push(Enum.map(4..60, &event/1))

      {count, bytes} = Buffer.size(buffer)
      assert bytes <= 4_000 and count < 60
      assert {true, buffer} = Buffer.take_shed(buffer)
      assert {false, buffer} = Buffer.take_shed(buffer)

      kept = events(buffer)
      # The older status of s1 went; its latest and s2's end stayed.
      assert status("s1", 2) in kept and ended("s2", 3) in kept
      refute status("s1", 1) in kept
      # The newest file events stayed, the oldest went.
      assert event(60) in kept
      refute event(4) in kept
      # What is left on disk is what is left in memory.
      Buffer.close(buffer)
      assert events(Buffer.open(path, max_bytes: 4_000)) == kept
    end
  end

  defp der(pem) do
    [{:Certificate, der, _}] = :public_key.pem_decode(pem)
    der
  end
end
