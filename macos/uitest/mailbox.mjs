#!/usr/bin/env node
// Uses the mailbox on a board the way its owner does in a browser, for
// macos/uitest/run.sh: opens the board's page over its live connection,
// opens the mailbox, and presses Approve or Refuse on a pairing request.
//
//   node mailbox.mjs PORT list              print the codes waiting, one a line
//   node mailbox.mjs PORT approve [CODE]    approve the request with that code
//   node mailbox.mjs PORT refuse [CODE]     (with no CODE, the first one)
//
// Prints the code it acted on. Exits 1 when nothing is waiting, or the
// board would not let this connection decide.
const [port, action = "list", wanted] = process.argv.slice(2)
if (!port || !["list", "approve", "refuse"].includes(action)) {
  console.error("Usage: node mailbox.mjs PORT list|approve|refuse [CODE]")
  process.exit(2)
}

const base = `http://localhost:${port}`
const page = await fetch(base + "/")
const html = await page.text()
const cookie = (page.headers.getSetCookie?.() ?? []).map((c) => c.split(";")[0]).join("; ")
const csrf = html.match(/name="csrf-token" content="([^"]+)"/)?.[1]
const root = html.match(/<div[^>]*data-phx-main[^>]*>/)?.[0]
if (!csrf || !root) {
  console.error(`The board on port ${port} did not give its page (status ${page.status}).`)
  process.exit(1)
}
const attr = (name) => root.match(new RegExp(`${name}="([^"]*)"`))[1]
const topic = `lv:${attr("id")}`

// What the page sends back is in pieces: fixed text ("s") with the changing
// parts between them. Put together, any piece that carries its fixed text
// reads as HTML again.
function text(node, shared) {
  if (node == null) return ""
  if (typeof node !== "object") return String(node)
  const templates = node.p ?? shared
  let fixed = node.s
  if (typeof fixed === "number") fixed = templates?.[fixed]
  if (!Array.isArray(fixed)) {
    return Object.keys(node).filter((k) => /^\d+$/.test(k)).map((k) => text(node[k], templates)).join("")
  }
  const row = (part) => fixed.reduce((out, piece, i) => out + piece + (i < fixed.length - 1 ? text(part(i), templates) : ""), "")
  // A list comes as its rows, by number ("k") or in order ("d").
  if (node.k) {
    const keys = Object.keys(node.k).filter((k) => /^\d+$/.test(k)).sort((a, b) => a - b)
    return keys.map((key) => row((i) => node.k[key][i])).join("")
  }
  if (Array.isArray(node.d)) return node.d.map((parts) => row((i) => parts[i])).join("")
  return row((i) => node[i])
}

// The requests in an opened mailbox: each one's code and the id its buttons send.
function requests(markup) {
  const found = []
  for (const item of markup.split('class="mailbox-item"').slice(1)) {
    const code = item.match(/class="mailbox-code">([^<]+)</)?.[1]
    const id = item.match(/phx-value-id="([^"]+)"/)?.[1]
    if (code && id) found.push({ code, id, canDecide: !/phx-value-action="approve"[^>]*disabled/.test(item) })
  }
  return found
}

const socket = new WebSocket(
  `ws://localhost:${port}/live/websocket?_csrf_token=${encodeURIComponent(csrf)}&vsn=2.0.0`,
  { headers: { Cookie: cookie, Origin: base } },
)
let ref = 0
const waiting = new Map()
const send = (event, payload) =>
  new Promise((resolve, reject) => {
    const mine = String(++ref)
    waiting.set(mine, resolve)
    socket.send(JSON.stringify(["1", mine, topic, event, payload]))
    setTimeout(() => reject(new Error(`The board did not answer "${event}" in 15 seconds.`)), 15000)
  })
socket.addEventListener("message", (message) => {
  const [, replyTo, , event, payload] = JSON.parse(message.data)
  if (event === "phx_reply" && waiting.has(replyTo)) {
    waiting.get(replyTo)(payload)
    waiting.delete(replyTo)
  }
})
socket.addEventListener("error", () => {
  console.error(`Could not open the live connection to the board on port ${port}.`)
  process.exit(1)
})
await new Promise((resolve) => socket.addEventListener("open", resolve))

const fail = (words) => {
  console.error(words)
  socket.close()
  process.exit(1)
}

try {
  const joined = await send("phx_join", {
    url: base + "/",
    // The board reloads a page whose styles are older than its own; this
    // says ours are the ones it just sent.
    params: { _csrf_token: csrf, _mounts: 0, asset_version: html.match(/name="asset-version" content="([^"]+)"/)?.[1] },
    session: attr("data-phx-session"),
    static: attr("data-phx-static"),
  })
  if (joined.status !== "ok") fail(`The board refused the live connection: ${JSON.stringify(joined.response)}`)

  const opened = await send("event", { type: "click", event: "mailbox_open", value: {} })
  const found = requests(text(opened.response?.diff))

  if (action === "list") {
    for (const request of found) console.log(request.code)
  } else {
    const request = wanted ? found.find((r) => r.code === wanted) : found[0]
    if (!request) fail(wanted ? `No request with the code ${wanted} is waiting.` : "Nothing is waiting in the mailbox.")
    if (!request.canDecide) fail("The board does not let this connection decide: its buttons are greyed out.")
    const acted = await send("event", {
      type: "click",
      event: "mailbox_act",
      value: { id: request.id, action },
    })
    const note = text(acted.response?.diff).match(/class="mailbox-note">([^<]+)</)?.[1]
    if (note) fail(`The mailbox said: ${note}`)
    console.log(request.code)
  }
} catch (error) {
  fail(error.message)
}
socket.close()
process.exit(0)
