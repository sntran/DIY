// The tests of assets/js/home_assistant.js: the sign-in to Home Assistant,
// the store of the session (fake-indexeddb), and the socket (a fake
// WebSocket and a fake fetch).
import {test} from "node:test"
import assert from "node:assert/strict"
import {createHash} from "node:crypto"
import fc from "fast-check"
import {IDBFactory} from "fake-indexeddb"
import {
  DB, STORE, KEY, CHANNEL, PENDING, EARLY, FIRST_WAIT, MAX_WAIT,
  address, blocked, socketUrl, clientOf, wayBack, randomText, pkce, authorizeUrl,
  open, sessionStore, Link, homeAssistantHook, browserParts, key, CommandError,
} from "../../assets/js/home_assistant.js"

const HA = "http://ha.test:8123"
const APP = "http://app.test"

// Lets the promises, IndexedDB and the fake answers run.
async function settle(rounds = 20) {
  for (let i = 0; i < rounds; i++) await new Promise((resolve) => setImmediate(resolve))
}

// A fake WebSocket. The test plays Home Assistant with receive() and
// drop().
class FakeSocket {
  static all = []
  constructor(url) {
    this.url = url
    this.sent = []
    this.closed = false
    FakeSocket.all.push(this)
  }
  send(text) { this.sent.push(JSON.parse(text)) }
  close() { this.closed = true }
  receive(message) { this.onmessage({data: JSON.stringify(message)}) }
  drop() { this.onclose() }
}

const answer = (status, body = {}) => ({ok: status >= 200 && status < 300, status, json: async () => body})

const tokens = (access, refresh, expires = 1800) =>
  answer(200, {access_token: access, refresh_token: refresh, expires_in: expires, token_type: "Bearer"})

// The parts of a browser for a Link, with fakes. fetch gives the answers of
// respond(url, fields).
function parts({search = "", pathname = "/settings", protocol = "http:", respond = () => answer(200), store, factory} = {}) {
  const calls = []
  const pushes = []
  const timers = new Map()
  let nextTimer = 1
  const storage = new Map()
  const listened = {}
  const page = {
    calls, pushes, timers, storage, listened, assigned: [], replaced: [], clock: 1_000_000,
  }
  const notified = []
  page.notified = notified
  page.deps = {
    store: store ?? sessionStore(factory ?? new IDBFactory(), () => notified.push("changed")),
    listen: (onNews, onOnline) => {
      listened.news = onNews
      listened.online = onOnline
      return () => { listened.stopped = true }
    },
    fetch: async (url, init) => {
      const fields = Object.fromEntries(init.body)
      calls.push({url, fields})
      return respond(url, fields)
    },
    WebSocket: FakeSocket,
    location: {
      origin: APP, protocol, pathname, search,
      assign: (url) => page.assigned.push(url),
    },
    history: {state: {type: "patch", id: "phx-1"}, replaceState: (...args) => page.replaced.push(args)},
    storage: {
      getItem: (key) => storage.has(key) ? storage.get(key) : null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: (key) => storage.delete(key),
    },
    crypto: globalThis.crypto,
    now: () => page.clock,
    setTimer: (f, ms) => { const id = nextTimer++; timers.set(id, {f, ms}); return id },
    clearTimer: (id) => timers.delete(id),
    push: (event, payload) => pushes.push([event, payload]),
  }
  return page
}

const last = (page) => page.pushes.at(-1)[1]

// A session in the store, as a sign-in leaves it.
const session = (refresh = "r1", extra = {}) =>
  ({url: HA, client: APP + "/", access: "a-" + refresh, refresh, expires: 1_000_000 + 1_800_000, ...extra})

// A link with a stored session, and its open socket after the sign-in of
// the socket.
async function connected(page, stored = session()) {
  await page.deps.store.write(stored)
  const link = new Link(page.deps)
  await link.start()
  await settle()
  const socket = FakeSocket.all.at(-1)
  socket.receive({type: "auth_required", ha_version: "2026.10.0"})
  await settle()
  socket.receive({type: "auth_ok", ha_version: "2026.10.0"})
  socket.receive({id: 1, type: "result", success: true, result: {location_name: "Test house"}})
  await settle()
  return {link, socket}
}

test("address gives the origin and the path of Home Assistant", () => {
  assert.equal(address("https://Home.Example.com/"), "https://home.example.com")
  assert.equal(address("  http://192.168.1.5:8123  "), "http://192.168.1.5:8123")
  assert.equal(address("https://example.com:443/ha//?x=1#y"), "https://example.com/ha")
  assert.equal(address("ftp://example.com"), null)
  assert.equal(address("home.example.com"), null)
  assert.equal(address("https://user:pass@example.com"), null)
  assert.equal(address(undefined), null)
})

test("address gives the same address again, and no / at the end", () => {
  fc.assert(fc.property(fc.oneof(fc.webUrl(), fc.string()), (text) => {
    const url = address(text)
    if (url === null) return
    assert.match(url, /^https?:\/\//)
    assert.ok(!url.endsWith("/"))
    assert.equal(address(url), url)
  }))
})

test("an HTTPS page cannot use an http address", () => {
  assert.equal(blocked("https:", "http://ha.local:8123"), true)
  assert.equal(blocked("https:", "https://ha.example.com"), false)
  assert.equal(blocked("http:", "http://ha.local:8123"), false)
  assert.equal(socketUrl("https://ha.example.com"), "wss://ha.example.com/api/websocket")
  assert.equal(socketUrl(HA), "ws://ha.test:8123/api/websocket")
  assert.equal(clientOf({origin: APP}), APP + "/")
})

test("the way back is Settings or the sheet of an item", () => {
  assert.equal(wayBack("/inside?item=i42"), "/inside?item=i42")
  assert.equal(wayBack("/inside?item=" + "a".repeat(40)), "/inside?item=" + "a".repeat(40))
  assert.equal(wayBack("/settings"), "/settings")
  for (const bad of [
    "//evil.example/x", "/\\evil.example", "https://evil.example", "inside", "/plans",
    "/inside?item=x&y=1", "/inside?item=" + "a".repeat(41), "/settings/", undefined, 5,
  ]) {
    assert.equal(wayBack(bad), "/settings", String(bad))
  }
})

test("each way back stays on this app", () => {
  fc.assert(fc.property(fc.oneof(fc.string(), fc.webPath(), fc.webUrl()), (text) => {
    const back = wayBack(text)
    assert.equal(new URL(APP + back).origin, APP)
    assert.ok(back === "/settings" || /^\/inside\?item=[A-Za-z0-9_-]{1,40}$/.test(back))
  }))
})

test("the sign-in page gets the client, the way back, the state and the challenge", async () => {
  const {verifier, challenge} = await pkce(globalThis.crypto)
  assert.match(verifier, /^[A-Za-z0-9_-]{64}$/)
  const digest = createHash("sha256").update(verifier).digest("base64url")
  assert.equal(challenge, digest)
  assert.match(randomText(globalThis.crypto), /^[A-Za-z0-9_-]{22}$/)

  const url = new URL(authorizeUrl(HA, {client: APP + "/", state: "s1", challenge}))
  assert.equal(url.origin + url.pathname, HA + "/auth/authorize")
  assert.deepEqual(Object.fromEntries(url.searchParams), {
    response_type: "code",
    client_id: APP + "/",
    redirect_uri: APP + "/settings",
    state: "s1",
    code_challenge: challenge,
    code_challenge_method: "S256",
  })
  const hub = new URL(authorizeUrl(HA, {client: APP + "/", state: "s1", challenge, back: "/inside?item=i42"}))
  assert.equal(hub.searchParams.get("redirect_uri"), APP + "/inside?item=i42")
})

test("the store reads, writes, updates with a compare and set, and clears", async () => {
  const notified = []
  const store = sessionStore(new IDBFactory(), () => notified.push(1))
  assert.equal(await store.read(), null)
  assert.equal(await store.update("r1", {access: "x"}), false)
  assert.equal(await store.clear(), null)
  assert.equal(notified.length, 0)

  assert.equal(await store.write(session("r1")), null)
  assert.deepEqual(await store.write(session("r2")), session("r1"))
  assert.equal(notified.length, 2)

  assert.equal(await store.update("r1", {access: "x"}), false)
  assert.equal(await store.update("r2", {access: "x"}), true)
  assert.equal((await store.read()).access, "x")
  assert.equal(notified.length, 2)

  assert.equal(await store.clear("r1"), null)
  assert.equal((await store.clear("r2")).refresh, "r2")
  assert.equal(await store.read(), null)
  await store.write(session("r3"))
  assert.equal((await store.clear()).refresh, "r3")
  assert.equal(notified.length, 5)
})

test("the store gives an error when IndexedDB stops the transaction", async () => {
  const store = sessionStore(new IDBFactory(), () => {})
  await assert.rejects(store.write({...session(), f() {}}))
  assert.equal(await store.read(), null)
})

test("the store opens the database again after the browser closes it", async () => {
  const factory = new IDBFactory()
  const dbs = []
  const counting = {open: (...args) => { const request = factory.open(...args); dbs.push(request); return request }}
  const store = sessionStore(counting, () => {})
  await store.write(session())
  dbs[0].result.onclose()
  assert.equal((await store.read()).refresh, "r1")
  assert.equal(dbs.length, 2)

  // A newer version of the app opens the database: this tab closes it, so
  // that the newer version does not wait. This version cannot open it.
  const newer = factory.open(DB, 2)
  await new Promise((resolve) => { newer.onsuccess = resolve })
  newer.result.close()
  await assert.rejects(store.read(), {name: "VersionError"})
  assert.equal(dbs.length, 3)

  // An error at the open: the next operation opens it again.
  const failing = {open: () => { const request = {}; setImmediate(() => request.onerror()); return request }}
  await assert.rejects(sessionStore(failing, () => {}).read())
  const db = await open(new IDBFactory())
  assert.deepEqual([...db.objectStoreNames], [STORE])
  assert.equal(KEY, "session")
})

test("a page with no session shows none", async () => {
  const page = parts()
  await new Link(page.deps).start()
  assert.deepEqual(last(page), {state: "none", url: null, name: null, version: null, error: null})
})

test("a store that the page cannot read shows the error", async () => {
  const page = parts({store: {read: async () => { throw new Error("no") }}})
  await new Link(page.deps).start()
  assert.equal(last(page).error, "storage")
})

test("connect sends the browser to the sign-in page with a new state", async () => {
  const page = parts()
  const link = new Link(page.deps)
  await link.connect(HA + "/")
  const pending = JSON.parse(page.storage.get(PENDING))
  assert.equal(pending.url, HA)
  const url = new URL(page.assigned[0])
  assert.equal(url.searchParams.get("state"), pending.state)
  const challenge = createHash("sha256").update(pending.verifier).digest("base64url")
  assert.equal(url.searchParams.get("code_challenge"), challenge)
  assert.equal(last(page).state, "signing_in")

  // From the sheet of a hub: the sign-in comes back to the sheet. A bad
  // way back gives Settings.
  await link.connect(HA, "/inside?item=i42")
  assert.equal(new URL(page.assigned[1]).searchParams.get("redirect_uri"), APP + "/inside?item=i42")
  await link.connect(HA, "//evil.example")
  assert.equal(new URL(page.assigned[2]).searchParams.get("redirect_uri"), APP + "/settings")

  await link.connect("not an address")
  assert.deepEqual(last(page), {state: "none", url: null, name: null, version: null, error: "url"})
  const https = parts({protocol: "https:"})
  await new Link(https.deps).connect(HA)
  assert.deepEqual(last(https), {state: "none", url: HA, name: null, version: null, error: "blocked"})
  assert.equal(https.assigned.length, 0)
})

test("the way back gets the tokens, keeps them, and connects", async () => {
  const page = parts({
    search: "?code=c1&state=s1",
    respond: (url) => url.endsWith("/auth/token") ? tokens("a1", "r1") : answer(200),
  })
  page.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v1"}))
  const link = new Link(page.deps)
  await link.start()
  await settle()

  assert.deepEqual(page.calls[0], {
    url: HA + "/auth/token",
    fields: {grant_type: "authorization_code", code: "c1", client_id: APP + "/", code_verifier: "v1"},
  })
  assert.equal(page.storage.has(PENDING), false)
  // The state of LiveView stays in the history.
  assert.deepEqual(page.replaced, [[{type: "patch", id: "phx-1"}, "", "/settings"]])
  assert.deepEqual(await page.deps.store.read(), {
    url: HA, client: APP + "/", access: "a1", refresh: "r1", expires: page.clock + 1_800_000,
  })
  assert.equal(page.notified.length, 1)
  assert.ok(page.pushes.some(([, state]) => state.state === "signing_in"))

  const socket = FakeSocket.all.at(-1)
  assert.equal(socket.url, "ws://ha.test:8123/api/websocket")
  assert.equal(last(page).state, "connecting")
  socket.receive({type: "auth_required", ha_version: "2026.10.0"})
  await settle()
  assert.deepEqual(socket.sent[0], {type: "auth", access_token: "a1"})
  socket.receive({type: "auth_ok", ha_version: "2026.10.0"})
  assert.deepEqual(socket.sent[1], {id: 1, type: "get_config"})
  socket.receive({id: 2, type: "result", success: true, result: {}})
  socket.receive({id: 1, type: "result", success: false})
  assert.equal(last(page).state, "connecting")
  socket.receive({id: 1, type: "result", success: true, result: {location_name: "Test house"}})
  assert.deepEqual(last(page), {
    state: "connected", url: HA, name: "Test house", version: "2026.10.0", error: null,
  })

  // The LiveView reconnects: the hook tells the state again.
  link.report()
  assert.equal(last(page).state, "connected")
})

test("the way back to the sheet of a hub keeps the item in the address", async () => {
  const page = parts({
    pathname: "/inside",
    search: "?item=i42&code=c1&state=s1&storeToken=true",
    respond: (url) => url.endsWith("/auth/token") ? tokens("a1", "r1") : answer(200),
  })
  page.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v1"}))
  await new Link(page.deps).start()
  await settle()
  assert.deepEqual(page.replaced, [[{type: "patch", id: "phx-1"}, "", "/inside?item=i42"]])
  assert.equal((await page.deps.store.read()).refresh, "r1")
})

test("a way back with a wrong state, no code, or a bad text keeps nothing", async () => {
  for (const [pending, search, error] of [
    [{url: HA, state: "other", verifier: "v"}, "?code=c&state=s1", "state"],
    [null, "?code=c&state=s1", "state"],
    ["{bad json", "?code=c&state=s1", "state"],
    [{url: HA, state: "s1", verifier: "v"}, "?error=access_denied&state=s1", "denied"],
  ]) {
    const page = parts({search})
    if (pending !== null) page.storage.set(PENDING, typeof pending === "string" ? pending : JSON.stringify(pending))
    await new Link(page.deps).start()
    await settle()
    assert.equal(page.calls.length, 0)
    assert.equal(last(page).error, error)
    assert.equal(await page.deps.store.read(), null)
    // The answer of the sign-in goes away from the address.
    assert.deepEqual(page.replaced.at(-1), [{type: "patch", id: "phx-1"}, "", "/settings"])
  }

  // A wrong state, with a stored session: the page connects with it.
  const page = parts({search: "?code=c&state=s1"})
  await page.deps.store.write(session())
  await new Link(page.deps).start()
  await settle()
  assert.equal(last(page).state, "connecting")
})

test("the exchange of the code can fail", async () => {
  for (const [respond, error] of [
    [() => { throw new Error("offline") }, "unreachable"],
    [() => answer(400, {error: "invalid_request"}), "token"],
    [() => ({ok: true, status: 200, json: async () => { throw new SyntaxError("not JSON") }}), "token"],
  ]) {
    const page = parts({search: "?code=c&state=s1", respond})
    page.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v"}))
    await new Link(page.deps).start()
    await settle()
    assert.deepEqual(last(page), {state: "none", url: HA, name: null, version: null, error})
    assert.equal(await page.deps.store.read(), null)
  }
})

test("a sign-in replaces and revokes the old session, and a store error revokes the new one", async () => {
  const respond = (url) => url.endsWith("/auth/token") ? tokens("a2", "r2") : answer(200)
  const page = parts({search: "?code=c&state=s1", respond})
  page.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v"}))
  await page.deps.store.write(session("r1"))
  await new Link(page.deps).start()
  await settle()
  assert.equal((await page.deps.store.read()).refresh, "r2")
  assert.deepEqual(page.calls.at(-1), {url: HA + "/auth/revoke", fields: {token: "r1"}})

  // The same session again: nothing to revoke.
  const again = parts({search: "?code=c&state=s1", respond})
  again.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v"}))
  await again.deps.store.write(session("r2"))
  await new Link(again.deps).start()
  await settle()
  assert.equal(again.calls.filter((call) => call.url.endsWith("/revoke")).length, 0)

  const failing = parts({
    search: "?code=c&state=s1",
    respond,
    store: {write: async () => { throw new Error("full") }},
  })
  failing.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v"}))
  await new Link(failing.deps).start()
  await settle()
  assert.equal(last(failing).error, "storage")
  assert.deepEqual(failing.calls.at(-1), {url: HA + "/auth/revoke", fields: {token: "r2"}})
})

test("a disconnect during the exchange revokes the new session and keeps nothing", async () => {
  let release
  const page = parts({
    search: "?code=c&state=s1",
    respond: (url) => url.endsWith("/auth/token")
      ? new Promise((resolve) => { release = () => resolve(tokens("a1", "r1")) })
      : Promise.reject(new Error("offline")),
  })
  page.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v"}))
  const link = new Link(page.deps)
  link.start()
  await settle()
  await link.disconnect()
  release()
  await settle()
  assert.equal(await page.deps.store.read(), null)
  assert.deepEqual(page.calls.at(-1), {url: HA + "/auth/revoke", fields: {token: "r1"}})
  assert.equal(last(page).state, "none")
})

test("a disconnect after the store write keeps the disconnect", async () => {
  let stored
  const factory = new IDBFactory()
  const real = sessionStore(factory, () => {})
  const page = parts({
    search: "?code=c&state=s1",
    respond: (url) => url.endsWith("/auth/token") ? tokens("a1", "r1") : answer(200),
    store: {...real, write: async (s) => { const old = await real.write(s); stored(); return old }},
  })
  page.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v"}))
  const link = new Link(page.deps)
  stored = () => link.disconnect()
  link.start()
  await settle()
  assert.equal(await real.read(), null)
  assert.ok(page.calls.some((call) => call.url.endsWith("/auth/revoke")))
  assert.equal(last(page).state, "none")
})

test("a disconnect clears the store, revokes the session and closes the socket", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  assert.equal(last(page).state, "connected")
  await link.disconnect()
  assert.equal(socket.closed, true)
  assert.equal(await page.deps.store.read(), null)
  assert.deepEqual(page.calls.at(-1), {url: HA + "/auth/revoke", fields: {token: "r1"}})
  assert.equal(last(page).state, "none")

  // The socket closes later: no new try.
  socket.drop()
  assert.equal(page.timers.size, 0)

  // A revoke that fails, and a store that fails: the page is still not
  // connected.
  const other = parts({respond: () => { throw new Error("offline") }})
  const second = await connected(other)
  await second.link.disconnect()
  await settle()
  assert.equal(last(other).state, "none")
  const broken = parts({store: {read: async () => null, clear: async () => { throw new Error("no") }}})
  const alone = new Link(broken.deps)
  await alone.disconnect()
  assert.equal(last(broken).state, "none")
})

test("the access token gets a refresh before its end, with a compare and set", async () => {
  const page = parts({respond: () => answer(200, {access_token: "a-new", expires_in: 1800})})
  const stored = session("r1", {expires: 1_000_000 + EARLY})
  await page.deps.store.write(stored)
  const link = new Link(page.deps)
  await link.start()
  const socket = FakeSocket.all.at(-1)
  socket.receive({type: "auth_required"})
  await settle()
  assert.deepEqual(page.calls[0], {
    url: HA + "/auth/token", fields: {grant_type: "refresh_token", refresh_token: "r1", client_id: APP + "/"},
  })
  assert.deepEqual(socket.sent[0], {type: "auth", access_token: "a-new"})
  assert.equal((await page.deps.store.read()).access, "a-new")
})

test("a refresh can fail, end the session, or come too late", async () => {
  const expired = session("r1", {expires: 0})

  // A server error, no network, a refusal that can pass (403), or a bad
  // answer: no auth, the socket closes later, and the session stays.
  for (const respond of [
    () => answer(500),
    () => { throw new Error("offline") },
    () => answer(403, {error: "access_denied"}),
    () => ({ok: true, status: 200, json: async () => { throw new SyntaxError("not JSON") }}),
  ]) {
    const page = parts({respond})
    await page.deps.store.write(expired)
    await new Link(page.deps).start()
    const socket = FakeSocket.all.at(-1)
    socket.receive({type: "auth_required"})
    await settle()
    assert.deepEqual(socket.sent, [])
    assert.ok(await page.deps.store.read())
  }

  // Home Assistant refuses the refresh token: the session ended.
  const ended = parts({respond: () => answer(400, {error: "invalid_grant"})})
  await ended.deps.store.write(expired)
  await new Link(ended.deps).start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  assert.deepEqual(last(ended), {state: "signed_out", url: HA, name: null, version: null, error: "signed_out"})
  assert.equal(await ended.deps.store.read(), null)

  // The same, with a disconnect in the clear of the store: the disconnect
  // wins.
  const both = parts({respond: () => answer(400, {error: "invalid_grant"})})
  await both.deps.store.write(expired)
  const bothLink = new Link(both.deps)
  const clear = both.deps.store.clear
  both.deps.store.clear = async (...args) => { const result = await clear(...args); bothLink.epoch += 1; return result }
  await bothLink.start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  assert.equal(last(both).state, "connecting")

  // A different tab changed the store: the refresh keeps nothing, and the
  // tab uses the new session.
  const factory = new IDBFactory()
  const other = sessionStore(factory, () => {})
  const changed = parts({
    factory,
    respond: async () => { await other.write(session("r2")); return answer(200, {access_token: "a-old", expires_in: 1800}) },
  })
  await changed.deps.store.write(expired)
  await new Link(changed.deps).start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  assert.deepEqual(await other.read(), session("r2"))
  assert.equal(FakeSocket.all.at(-1).url, socketUrl(HA))

  // The person disconnects while the refresh is in flight.
  let release
  const late = parts({respond: (url) => url.endsWith("/token")
    ? new Promise((resolve) => { release = () => resolve(answer(200, {access_token: "a-late", expires_in: 1800})) })
    : answer(200)})
  await late.deps.store.write(expired)
  const link = new Link(late.deps)
  await link.start()
  const socket = FakeSocket.all.at(-1)
  socket.receive({type: "auth_required"})
  await settle()
  await link.disconnect()
  release()
  await settle()
  assert.equal(await late.deps.store.read(), null)
  assert.deepEqual(socket.sent, [])

  // A store that fails at the write of the new access token.
  const full = parts({respond: () => answer(200, {access_token: "a-full", expires_in: 1800})})
  await full.deps.store.write(expired)
  full.deps.store.update = async () => { throw new Error("full") }
  await new Link(full.deps).start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  assert.deepEqual(FakeSocket.all.at(-1).sent, [])

  // The refresh ends after a disconnect, in the store write.
  const slow = parts({respond: () => answer(200, {access_token: "a-slow", expires_in: 1800})})
  await slow.deps.store.write(expired)
  const slowLink = new Link(slow.deps)
  const update = slow.deps.store.update
  slow.deps.store.update = async (...args) => { const result = await update(...args); slowLink.epoch += 1; return result }
  await slowLink.start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  assert.deepEqual(FakeSocket.all.at(-1).sent, [])
})

test("a late refusal of an old session does not end the new session", async () => {
  // Tab A sends a refresh of r1. A different tab signs in again (r2) and
  // revokes r1. Tab A gets the news, and uses r2. Then the refusal of r1
  // comes: tab A keeps r2.
  let refuse
  const page = parts({respond: (url) => url.endsWith("/token")
    ? new Promise((resolve) => { refuse = () => resolve(answer(400, {error: "invalid_grant"})) })
    : answer(200)})
  await page.deps.store.write(session("r1", {expires: 0}))
  const link = new Link(page.deps)
  await link.start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  await page.deps.store.write(session("r2"))
  await page.listened.news()
  const second = FakeSocket.all.at(-1)
  refuse()
  await settle()
  assert.equal(second.closed, false)
  assert.equal(link.session.refresh, "r2")
  assert.equal((await page.deps.store.read()).refresh, "r2")
  assert.equal(last(page).state, "connecting")

  // The other tab disconnects instead: tab A shows "none", not the end of
  // a session.
  const other = parts({respond: (url) => url.endsWith("/token")
    ? new Promise((resolve) => { refuse = () => resolve(answer(400, {error: "invalid_grant"})) })
    : answer(200)})
  await other.deps.store.write(session("r1", {expires: 0}))
  await new Link(other.deps).start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  await other.deps.store.clear()
  await other.listened.news()
  refuse()
  await settle()
  assert.deepEqual(last(other), {state: "none", url: null, name: null, version: null, error: null})
})

test("a refused access token: one new try, then the session ended", async () => {
  const page = parts({respond: () => answer(200, {access_token: "a2", expires_in: 1800})})
  const {socket} = await connected(page)
  socket.receive({type: "auth_invalid"})
  assert.equal(socket.closed, true)
  const second = FakeSocket.all.at(-1)
  assert.notEqual(second, socket)
  second.receive({type: "auth_required"})
  await settle()
  assert.deepEqual(second.sent[0], {type: "auth", access_token: "a2"})
  const before = page.pushes.length
  second.receive({type: "auth_invalid"})
  // Home Assistant closes the socket too: the page does not show offline.
  second.drop()
  await settle()
  assert.equal(second.closed, true)
  assert.deepEqual(page.pushes.slice(before).map(([, state]) => state.state), ["signed_out"])
  assert.equal(page.timers.size, 0)
  assert.equal(await page.deps.store.read(), null)

  // The store cannot clear: the page shows the end anyway.
  const broken = parts({respond: () => answer(200, {access_token: "a2", expires_in: 1800})})
  const {link, socket: first} = await connected(broken)
  broken.deps.store.clear = async () => { throw new Error("no") }
  first.receive({type: "auth_invalid"})
  FakeSocket.all.at(-1).receive({type: "auth_invalid"})
  await settle()
  assert.equal(last(broken).state, "signed_out")
  assert.equal(link.session, null)
})

test("a socket that closes: offline, then new tries with longer waits", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  socket.drop()
  assert.equal(last(page).state, "offline")
  const waits = []
  for (let i = 0; i < 8; i++) {
    const [id, timer] = [...page.timers][0]
    waits.push(timer.ms)
    page.timers.delete(id)
    timer.f()
    FakeSocket.all.at(-1).drop()
  }
  assert.deepEqual(waits, [1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000])
  assert.equal(FIRST_WAIT, 1000)
  assert.equal(MAX_WAIT, 60000)

  // The device is online again: a new try now, and the first wait again.
  page.listened.online()
  assert.equal(page.timers.size, 0)
  const now = FakeSocket.all.at(-1)
  assert.equal(last(page).state, "connecting")
  page.listened.online()
  assert.equal(FakeSocket.all.at(-1), now)

  // A message of an old socket changes nothing.
  socket.receive({type: "auth_ok"})
  assert.deepEqual(socket.sent.length, 2)

  // A stop: no news, no session, and a timer or the device online again
  // opens no socket.
  now.drop()
  const [, timer] = [...page.timers][0]
  link.stop()
  assert.equal(page.listened.stopped, true)
  assert.equal(link.session, null)
  timer.f()
  link.again()
  assert.equal(FakeSocket.all.at(-1), now)
})

test("the news of a different tab: the tab reads the store", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const count = FakeSocket.all.length

  // The same session: nothing changes.
  await page.listened.news()
  assert.equal(FakeSocket.all.length, count)

  // A new session: a new socket.
  await page.deps.store.write(session("r2"))
  await page.listened.news()
  assert.equal(socket.closed, true)
  assert.equal(FakeSocket.all.length, count + 1)

  // No session: no socket.
  await page.deps.store.clear()
  await page.listened.news()
  assert.equal(FakeSocket.all.at(-1).closed, true)
  assert.equal(last(page).state, "none")
  assert.equal(link.socket, null)

  // News for an old epoch changes nothing.
  await page.deps.store.write(session("r3"))
  const reading = link.load(link.epoch - 1)
  await reading
  assert.equal(link.session, null)
})

test("the hook of LiveView", async () => {
  const page = parts()
  const handlers = {}
  const hook = homeAssistantHook(() => page.deps)
  const self = {
    ...hook,
    pushEvent: (event, payload) => page.pushes.push(["hook:" + event, payload]),
    handleEvent: (event, f) => { handlers[event] = f },
  }
  self.mounted()
  await settle()
  assert.deepEqual(page.pushes.at(-1), ["hook:ha:status", {state: "none", url: null, name: null, version: null, error: null}])
  await handlers["ha:connect"]({url: HA, back: "/inside?item=i1"})
  assert.equal(page.assigned.length, 1)
  assert.equal(new URL(page.assigned[0]).searchParams.get("redirect_uri"), APP + "/inside?item=i1")
  await handlers["ha:disconnect"]()
  assert.equal(page.pushes.at(-1)[1].state, "none")
  // With no socket, the match of the rooms gets no floors and no areas.
  await handlers["ha:rooms_fetch"]()
  assert.deepEqual(page.pushes.at(-1), ["hook:ha:rooms", {error: "offline"}])
  await handlers["ha:add_areas"]({areas: [{room: "r1", name: "Den", level: null, floor: null}]})
  assert.deepEqual(page.pushes.at(-1), ["hook:ha:areas_added", {
    links: [], errors: [{room: "r1", message: "Home Assistant does not answer"}],
  }])
  self.reconnected()
  assert.equal(page.pushes.at(-1)[1].state, "none")
  self.destroyed()
  assert.equal(self.link.epoch, 2)
})

test("the parts of the browser", async () => {
  const events = []
  const posted = []
  class Channel {
    constructor(name) { this.name = name; Channel.last = this }
    postMessage(message) { posted.push([this.name, message]) }
  }
  const window = {
    BroadcastChannel: Channel,
    indexedDB: new IDBFactory(),
    addEventListener: (event, f) => events.push([event, f]),
    removeEventListener: (event, f) => events.push(["remove " + event, f]),
    fetch: async (...args) => ["fetched", ...args],
    WebSocket: FakeSocket,
    location: {},
    history: {},
    sessionStorage: {},
    crypto: globalThis.crypto,
    setTimeout: (f, ms) => ["timer", ms],
    clearTimeout: (id) => events.push(["clear", id]),
  }
  const browser = browserParts(window)
  await browser.store.write(session())
  assert.deepEqual(posted, [[CHANNEL, "changed"]])
  const news = () => {}
  const online = () => {}
  const unlisten = browser.listen(news, online)
  assert.equal(Channel.last.onmessage, news)
  assert.deepEqual(events, [["online", online]])
  unlisten()
  assert.equal(Channel.last.onmessage, null)
  assert.deepEqual(events.at(-1), ["remove online", online])
  assert.deepEqual(await browser.fetch("u", {method: "POST"}), ["fetched", "u", {method: "POST"}])
  assert.ok(Math.abs(browser.now() - Date.now()) < 1000)
  assert.deepEqual(browser.setTimer(() => {}, 5), ["timer", 5])
  browser.clearTimer(7)
  assert.deepEqual(events.at(-1), ["clear", 7])

  // A browser with no BroadcastChannel: the hook works in this tab only.
  const alone = browserParts({...window, BroadcastChannel: undefined, indexedDB: new IDBFactory()})
  await alone.store.write(session())
  alone.listen(news, online)()
  assert.equal(posted.length, 1)
})

// The property of the model (specs/HomeAssistant.tla) on the real code. It
// has two tabs, one store, and a fake Home Assistant that answers in any
// order. The sign-ins, refreshes, disconnects and news come in any order. The store never
// has a revoked session. After a disconnect, a tab has no socket of its own
// sign-ins, until the person signs in again on it. It can follow a session
// of a sign-in on the other tab (Notice in the model).
test("two tabs in any order: no revoked session in the store, no socket after a disconnect", async () => {
  const step = fc.oneof(
    fc.record({kind: fc.constant("signIn"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("disconnect"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("refresh"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("news"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("answer"), index: fc.nat()}),
  )

  await fc.assert(fc.asyncProperty(fc.array(step, {maxLength: 25}), async (steps) => {
    const factory = new IDBFactory()
    const inFlight = []
    const revoked = new Set()
    const writer = new Map()
    let sessions = 0
    const tabs = []
    const off = new Set()

    // The answers of Home Assistant for a tab. A revoke is at once. The
    // other answers wait for an "answer" step. Home Assistant answers a
    // refresh as the session is at the request: a new access token, or a
    // refusal of a revoked session.
    const respond = (tab) => (url, fields) => {
      if (url.endsWith("/auth/revoke")) {
        revoked.add(fields.token)
        return answer(200)
      }
      const refused = fields.grant_type === "refresh_token" && revoked.has(fields.refresh_token)
      return new Promise((resolve) => {
        inFlight.push(() => {
          if (fields.grant_type === "authorization_code") {
            sessions += 1
            writer.set("r" + sessions, tab)
            resolve(tokens("a" + sessions, "r" + sessions))
          } else if (refused) {
            resolve(answer(400, {error: "invalid_grant"}))
          } else {
            resolve(answer(200, {access_token: "a-" + fields.refresh_token, expires_in: 1800}))
          }
        })
      })
    }

    for (const tab of [0, 1]) {
      const page = parts({factory, respond: respond(tab), store: sessionStore(factory, () => {
        const other = tabs[1 - tab]
        if (other) setImmediate(() => other.page.listened.news())
      })})
      const link = new Link(page.deps)
      tabs.push({page, link})
      await link.start()
    }

    for (const s of steps) {
      if (s.kind === "answer") {
        if (inFlight.length > 0) inFlight.splice(s.index % inFlight.length, 1)[0]()
      } else {
        const {page, link} = tabs[s.tab]
        if (s.kind === "signIn") {
          off.delete(s.tab)
          page.storage.set(PENDING, JSON.stringify({url: HA, state: "s", verifier: "v"}))
          link.finish(new URLSearchParams("code=c&state=s"))
        } else if (s.kind === "disconnect") {
          off.add(s.tab)
          link.disconnect()
        } else if (s.kind === "refresh" && link.socket) {
          link.session = {...link.session, expires: 0}
          link.socket.receive({type: "auth_required"})
        } else if (s.kind === "news") {
          page.listened.news()
        }
      }
      await settle(6)

      const stored = await tabs[0].page.deps.store.read()
      assert.ok(!stored || !revoked.has(stored.refresh), `the store has a revoked session: ${stored?.refresh}`)
      for (const tab of off) {
        const {link} = tabs[tab]
        assert.ok(
          !link.socket || writer.get(link.session.refresh) !== tab,
          `tab ${tab} has a socket of its own sign-in after a disconnect`,
        )
      }
    }
    for (const {link} of tabs) link.stop()
  }), {
    numRuns: 1000,
    // The shortest steps to each fault of the model, for the runs where
    // the random steps miss them. The first is a refresh that comes after
    // a disconnect of the other tab. The second is a sign-in that ends
    // after a disconnect.
    examples: [
      [[{kind: "signIn", tab: 0}, {kind: "answer", index: 0}, {kind: "refresh", tab: 0},
        {kind: "disconnect", tab: 1}, {kind: "answer", index: 0}]],
      [[{kind: "signIn", tab: 0}, {kind: "disconnect", tab: 0}, {kind: "answer", index: 0}]],
    ],
  })
})

// A fake registry of Home Assistant: the floors, the areas and the user.
// Home Assistant refuses a second floor or area with the same name
// (invalid_info). fail(message) can give the error of a command.
function registry({floors = [], areas = [], admin = true, fail = () => null} = {}) {
  const ha = {floors: structuredClone(floors), areas: structuredClone(areas), admin, fail, answered: new WeakMap()}
  ha.reply = (message) => {
    const error = ha.fail(message, ha)
    if (error) return {success: false, error}
    const ok = (result) => ({success: true, result: structuredClone(result)})
    const taken = (list) => list.some((one) => key(one.name) === key(message.name))
    const inUse = () => ({code: "invalid_info", message: `The name ${message.name} (${key(message.name)}) is already in use`})
    switch (message.type) {
      case "config/floor_registry/list": return ok(ha.floors)
      case "config/area_registry/list": return ok(ha.areas)
      case "auth/current_user": return ok({id: "u1", name: "Owner", is_admin: ha.admin})
      case "config/floor_registry/create": {
        if (taken(ha.floors)) return {success: false, error: inUse()}
        const floor = {floor_id: "floor_" + (ha.floors.length + 1), name: message.name, level: message.level, aliases: []}
        ha.floors.push(floor)
        return ok(floor)
      }
      case "config/area_registry/create": {
        if (taken(ha.areas)) return {success: false, error: inUse()}
        const area = {area_id: "area_" + (ha.areas.length + 1), name: message.name, floor_id: message.floor_id ?? null}
        ha.areas.push(area)
        return ok(area)
      }
      default: return {success: false, error: {code: "unknown_command", message: "Unknown command."}}
    }
  }
  return ha
}

// Home Assistant answers each new command on the socket, until no command
// waits. pick(n) chooses which of n waiting commands it answers next.
async function serve(ha, sockets, pick = () => 0) {
  for (let round = 0; round < 500; round++) {
    await settle(4)
    const waiting = []
    for (const socket of sockets) {
      const done = ha.answered.get(socket) ?? new Set()
      ha.answered.set(socket, done)
      for (const message of socket.sent) {
        if (message.id > 1 && !done.has(message.id) && !socket.closed) waiting.push({socket, message, done})
      }
    }
    if (waiting.length === 0) return
    const {socket, message, done} = waiting[pick(waiting.length) % waiting.length]
    done.add(message.id)
    socket.receive({id: message.id, type: "result", ...ha.reply(message)})
  }
  throw new Error("the commands do not end")
}

test("the key of a name has no case and no spaces", () => {
  assert.equal(key("Living Room"), "livingroom")
  assert.equal(key(" LIVING  room "), "livingroom")
  assert.equal(key("Große Halle"), "grossehalle")
})

test("the hook reads the floors, the areas and the user of Home Assistant", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const ha = registry({
    floors: [{floor_id: "ground", name: "Ground", level: 0}, {floor_id: "loft", name: "Loft"}],
    areas: [{area_id: "kitchen", name: "Kitchen", floor_id: "ground"}, {area_id: "yard", name: "Yard"}],
    admin: false,
  })
  const done = link.rooms()
  await serve(ha, [socket])
  await done
  assert.deepEqual(socket.sent.slice(2).map((message) => [message.id, message.type]), [
    [2, "config/floor_registry/list"], [3, "config/area_registry/list"], [4, "auth/current_user"],
  ])
  assert.deepEqual(last(page), {
    floors: [{id: "ground", name: "Ground", level: 0}, {id: "loft", name: "Loft", level: null}],
    areas: [{id: "kitchen", name: "Kitchen", floor: "ground"}, {id: "yard", name: "Yard", floor: null}],
    admin: false,
  })
  assert.equal(page.pushes.at(-1)[0], "ha:rooms")
  link.stop()
})

test("the rooms are offline with no socket, a socket that closes, or an error", async () => {
  // A socket that does not have the sign-in yet takes no commands.
  const page = parts()
  await page.deps.store.write(session())
  const link = new Link(page.deps)
  await link.start()
  await settle()
  assert.equal(link.state.state, "connecting")
  await link.rooms()
  assert.deepEqual(last(page), {error: "offline"})
  link.stop()

  // The socket closes before the answers.
  const other = parts()
  const {link: second, socket} = await connected(other)
  const waiting = second.rooms()
  socket.drop()
  await waiting
  assert.deepEqual(other.pushes.at(-1), ["ha:rooms", {error: "offline"}])
  assert.equal(second.commands.size, 0)

  // An old Home Assistant with no floors: a command fails.
  const third = parts()
  const {link: link3, socket: socket3} = await connected(third)
  const ha = registry({fail: (message) => message.type === "config/floor_registry/list" ? {code: "unknown_command"} : null})
  const done = link3.rooms()
  await serve(ha, [socket3])
  await done
  assert.deepEqual(last(third), {error: "failed"})

  // A disconnect ends the commands on the socket, and the ids start again.
  const late = assert.rejects(link3.command("auth/current_user"), (error) => error instanceof CommandError && error.code === "offline")
  await link3.disconnect()
  await late
  assert.equal(link3.next, 2)
  link3.stop()
})

test("an error of Home Assistant gives its code and its message", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const one = assert.rejects(link.command("x/one", {a: 1}), {code: "unauthorized", message: "Unauthorized"})
  const two = assert.rejects(link.command("x/two"), {code: undefined, message: "error"})
  assert.deepEqual(socket.sent.slice(2), [{a: 1, id: 2, type: "x/one"}, {id: 3, type: "x/two"}])
  socket.receive({id: 2, type: "result", success: false, error: {code: "unauthorized", message: "Unauthorized"}})
  socket.receive({id: 3, type: "result", success: false})
  await one
  await two
  // An answer that no command waits for changes nothing.
  socket.receive({id: 9, type: "result", success: true, result: {}})
  assert.equal(link.state.state, "connected")
  link.stop()
})

test("the hook adds the floors and the areas of the rooms, and uses an area of the same name", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const ha = registry({
    floors: [{floor_id: "ground", name: "Ground", level: 0}],
    areas: [{area_id: "kitchen", name: "Kitchen", floor_id: "ground"}],
  })
  const done = link.addAreas([
    {room: "r1", name: "Office", level: 0, floor: "Floor 1"},
    {room: "r2", name: "Den", level: 1, floor: "Floor 2"},
    {room: "r3", name: "KITCHEN", level: 1, floor: "Floor 2"},
    {room: "r4", name: "Shed", level: null, floor: "Around the house"},
  ])
  await serve(ha, [socket])
  await done

  assert.deepEqual(page.pushes.at(-1), ["ha:areas_added", {
    links: [
      {room: "r1", area: "area_2"}, {room: "r2", area: "area_3"},
      {room: "r3", area: "kitchen"}, {room: "r4", area: "area_4"},
    ],
    errors: [],
  }])
  // One new floor for level 1, and each area on its floor.
  assert.deepEqual(ha.floors.map((floor) => [floor.name, floor.level]), [["Ground", 0], ["Floor 2", 1]])
  assert.deepEqual(ha.areas.map((area) => [area.name, area.floor_id]), [
    ["Kitchen", "ground"], ["Office", "ground"], ["Den", "floor_2"], ["Shed", null],
  ])
  assert.equal(socket.sent.filter((message) => message.type === "config/floor_registry/list").length, 1)
  link.stop()
})

test("a floor of the same name at a different level, and the rooms that the hook did not add", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const ha = registry({
    floors: [{floor_id: "upstairs", name: "Floor 2", level: 5}],
    fail: (message, ha) => {
      if (message.type === "config/area_registry/create" && message.name === "Vault") {
        return {code: "unauthorized", message: "Unauthorized"}
      }
      // A name in use that the list does not show (for example, an alias).
      if (message.type === "config/area_registry/create" && message.name === "Den") {
        return {code: "invalid_info", message: "The name Den (den) is already in use"}
      }
      return null
    },
  })
  const done = link.addAreas([
    {room: "r1", name: "Bath", level: 1, floor: "Floor 2"},
    {room: "r2", name: "Vault", level: null, floor: "Around the house"},
    {room: "r3", name: "Den", level: null, floor: "Around the house"},
  ])
  await serve(ha, [socket])
  await done
  // Home Assistant has "Floor 2" at level 5: the bath (level 1) does not go
  // on it.
  assert.deepEqual(page.pushes.at(-1), ["ha:areas_added", {
    links: [],
    errors: [
      {room: "r1", message: "The name Floor 2 (floor2) is already in use"},
      {room: "r2", message: "Unauthorized"},
      {room: "r3", message: "The name Den (den) is already in use"},
    ],
  }])
  assert.deepEqual(ha.areas, [])
  assert.equal(ha.floors.length, 1)

  // The socket closes: the rooms that wait are not added.
  const waiting = link.addAreas([{room: "r4", name: "Nook", level: 0, floor: "Floor 1"}, {room: "r5", name: "Hall", level: null, floor: "x"}])
  socket.drop()
  await waiting
  assert.deepEqual(page.pushes.at(-1), ["ha:areas_added", {
    links: [],
    errors: [
      {room: "r4", message: "Home Assistant does not answer"},
      {room: "r5", message: "Home Assistant does not answer"},
    ],
  }])
  link.stop()
})

test("two tabs add rooms in any order: one area for each name, and each room gets its area", async () => {
  // The server sends one room for each name (DIY.HomeAssistant.blocked/2),
  // so a name has one level.
  const levels = {Den: 1, den: 1, Office: 0, "Living Room": 0, livingroom: 0, Bath: null}
  const names = Object.keys(levels)
  const room = fc.constantFrom(...names).map((name) => ({name, level: levels[name]}))
  const plan = fc.record({
    first: fc.array(room, {maxLength: 5}),
    second: fc.array(room, {maxLength: 5}),
    existing: fc.subarray(names, {maxLength: 2}),
    order: fc.array(fc.nat(), {minLength: 1, maxLength: 40}),
  })
  await fc.assert(fc.asyncProperty(plan, async ({first, second, existing, order}) => {
    const areas = []
    for (const name of existing) {
      if (!areas.some((area) => key(area.name) === key(name))) areas.push({area_id: "old_" + key(name), name, floor_id: null})
    }
    const ha = registry({areas})
    const tabs = []
    for (const rooms of [first, second]) {
      const page = parts()
      tabs.push({page, rooms, ...(await connected(page))})
    }
    let turn = 0
    const done = tabs.map(({link, rooms}, tab) =>
      link.addAreas(rooms.map((one, i) => ({room: `t${tab}r${i}`, ...one, floor: `Floor ${one.level + 1}`}))))
    await serve(ha, tabs.map((tab) => tab.socket), (n) => order[turn++ % order.length] % n)
    await Promise.all(done)

    // Each room gets an area of its name, on the floor of its level. (The
    // fake, as Home Assistant, refuses a second area or floor of one name.)
    for (const {page, rooms} of tabs) {
      const {links, errors} = page.pushes.at(-1)[1]
      assert.deepEqual(errors, [])
      assert.equal(links.length, rooms.length)
      links.forEach((link, i) => {
        const area = ha.areas.find((one) => one.area_id === link.area)
        assert.equal(key(area.name), key(rooms[i].name))
        if (area.floor_id) {
          assert.equal(ha.floors.find((floor) => floor.floor_id === area.floor_id).level, rooms[i].level)
        }
      })
    }
    for (const {link} of tabs) link.stop()
  }), {numRuns: 300})
})
