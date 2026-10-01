defmodule Wallboard.Link do
  @moduledoc """
  The link: one live, encrypted, two-way stream between a collector and the
  hub. It carries the messages `Wallboard.Collector.Filter` builds, over
  gRPC, with a certificate on both ends.

  ## The parts

    * `Wallboard.Link.Authority`: the hub's certificate authority. It makes
      the hub's certificate, issues one per machine and revokes them.
    * `Wallboard.Link.Hub`: the hub's side. It listens on its own port, takes
      each machine's name from its certificate, saves what arrives and says
      how far it got. Started only on a hub, and only when `link.enabled` is
      on in settings.
    * `Wallboard.Link.Client`: the collector's side. It keeps one stream
      open, sends events from a buffer on disk, and reconnects by itself.
    * `Wallboard.Link.Buffer`: that buffer.
    * `Wallboard.Link.Backoff`: how long to wait between tries.
    * `Wallboard.Pairing`: how a new machine gets its certificate, by a
      code the owner approves in the mailbox.
    * `Wallboard.Link.Machines`: the connected machines, for the settings
      page, where one can be disconnected.
    * `Wallboard.Collector.Sender`: on the collector, hands the watcher's
      outbox to the client, and goes back to the hub's place in each file
      on every connect.
    * `Wallboard.Link.Sessions`: on the hub, turns the saved events into
      live cards on the board and rows in the archive
      (`Wallboard.Link.Session` is one session's picture).

  ## Who may connect

  The port speaks TLS 1.3 and nothing else, and a connection without a
  certificate from this hub's authority never gets past the handshake. A
  revoked certificate is refused the same way, and revoking a machine
  while it is connected sends it `Disconnected` and closes its stream.

  The collector trusts only its hub's authority, and only a certificate
  made for a hub, so another machine's certificate cannot stand in for it.

  The machine in a `Hello` is only a label. Everything a stream sends is
  saved under the name in its certificate.

  ## What is never lost

  Every event a collector sends carries a number, `seq`, that counts up.
  The collector keeps each event in its buffer on disk until the hub
  answers `Stored` with that number or a later one, which the hub does
  only after the event is in its database. So a stream cut at any moment
  loses nothing: what was not confirmed is sent again.

  On every connect the hub first sends `Resume`: the last position it has
  for each session file. The collector drops what the hub already has and
  sends the rest. A repeat is harmless either way, because the hub keeps
  one row per machine, session, file, position, time and kind, and saves
  each batch to the disk before it answers.

  The hub's position in a file is only the furthest it has seen, so the
  collector must never send a line of a file while an earlier one is
  missing. That shapes what a full buffer does: it drops the newest events
  of a file, never an older one, never a status or an end, and takes no
  more of that file for now. The dropped lines are not lost: they are
  still in the session file. Once the buffer has emptied, or after half a
  minute, the client restarts the stream and a `Resume` arrives. Whoever
  reads the files goes back to the hub's position in each, says so
  (`Wallboard.Link.Client.rewound/1`), and sends from there. Only then
  does the buffer take those files again.

  An open stream looks its certificate up again every few seconds, so a
  certificate revoked or replaced by another program (the `mix` task)
  stops working on a live stream too.

  ## Reconnects

  A collector that loses the hub waits before each try: about a second at
  first, doubling, never more than a minute, with some randomness so a room
  full of collectors does not return at the same instant. Before a planned
  restart the hub sends `BackSoon`, and each collector then waits 5 to 15
  seconds before its first try.

  ## Limits

  One collector cannot flood the hub. The numbers are in `limits/0`:

    * a message larger than `max_message_bytes` closes the stream
    * more than `messages_per_second` or `bytes_per_second`, beyond a
      short burst, closes the stream; the collector's own pace
      (`Wallboard.Link.Client`) stays well under both
    * one stream per machine: a second one replaces the first
    * a connection that sends nothing for `idle_ms` is closed; a collector
      says it is alive every 20 seconds
    * a connection gets three seconds to finish its TLS handshake, and the
      port holds `max_connections` at once. Someone with no certificate
      can still fill those places with unfinished handshakes for as long
      as they keep at it. That delays collectors, which wait and lose
      nothing; it does not stop the hub.
    * the port takes gRPC over HTTP/2 only: no HTTP/1, no JSON, no
      compression, no reflection

  ## Where "safe enough" ends

  This defends against anyone on the local network who holds no approved
  certificate: they cannot read the stream, send events, pose as a machine
  or as the hub. It does not defend against someone with admin access to
  the hub's own machine, or against an approved collector that turns
  hostile, beyond the size and rate limits above.
  """

  @limits %{
    max_message_bytes: 262_144,
    messages_per_second: 2_000,
    message_burst: 4_000,
    bytes_per_second: 4_000_000,
    byte_burst: 8_000_000,
    idle_ms: 90_000,
    # How often an open stream looks its certificate up again.
    recheck_ms: 5_000,
    # Few machines pair with one hub, and a hub started from the Mac's
    # launcher may open only 256 files at once. The port must never use
    # them all up.
    max_connections: 128,
    resume_points: 20_000,
    resume_days: 30
  }

  @doc "The hub's limits on one collector."
  def limits, do: @limits

  @doc "True when these settings make this board a hub that listens for collectors."
  def hub?(settings) do
    get_in(settings, [:archive, :enabled]) == true and get_in(settings, [:link, :enabled]) == true
  end
end
