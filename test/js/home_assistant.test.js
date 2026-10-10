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
  address, blocked, socketUrl, clientOf, randomText, pkce, authorizeUrl,
  open, sessionStore, Link, homeAssistantHook, browserParts,
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
function parts({search = "", protocol = "http:", respond = () => answer(200), store, factory} = {}) {
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
    listen: (onNews, onOnline) => { listened.news = onNews; listened.online = onOnline },
    fetch: async (url, init) => {
      const fields = Object.fromEntries(init.body)
      calls.push({url, fields})
      return respond(url, fields)
    },
    WebSocket: FakeSocket,
    location: {
      origin: APP, protocol, pathname: "/settings", search,
      assign: (url) => page.assigned.push(url),
    },
    history: {replaceState: (...args) => page.replaced.push(args)},
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
  assert.deepEqual(page.replaced, [[null, "", "/settings"]])
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

  // A server error or no network: no auth, the socket closes later.
  for (const respond of [() => answer(500), () => { throw new Error("offline") }]) {
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
  second.receive({type: "auth_invalid"})
  await settle()
  assert.equal(last(page).state, "signed_out")
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

  // A timer after a stop does nothing.
  now.drop()
  const [, timer] = [...page.timers][0]
  link.stop()
  timer.f()
  assert.equal(FakeSocket.all.at(-1), now)
  link.again()
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
  await handlers["ha:connect"]({url: HA})
  assert.equal(page.assigned.length, 1)
  await handlers["ha:disconnect"]()
  assert.equal(page.pushes.at(-1)[1].state, "none")
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
  browser.listen(news, online)
  assert.equal(Channel.last.onmessage, news)
  assert.deepEqual(events, [["online", online]])
  assert.deepEqual(await browser.fetch("u", {method: "POST"}), ["fetched", "u", {method: "POST"}])
  assert.ok(Math.abs(browser.now() - Date.now()) < 1000)
  assert.deepEqual(browser.setTimer(() => {}, 5), ["timer", 5])
  browser.clearTimer(7)
  assert.deepEqual(events.at(-1), ["clear", 7])

  // A browser with no BroadcastChannel: the hook works in this tab only.
  const alone = browserParts({...window, BroadcastChannel: undefined, indexedDB: new IDBFactory()})
  await alone.store.write(session())
  alone.listen(news, online)
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
    // other answers wait for an "answer" step.
    const respond = (tab) => (url, fields) => {
      if (url.endsWith("/auth/revoke")) {
        revoked.add(fields.token)
        return answer(200)
      }
      return new Promise((resolve) => {
        inFlight.push(() => {
          if (fields.grant_type === "authorization_code") {
            sessions += 1
            writer.set("r" + sessions, tab)
            resolve(tokens("a" + sessions, "r" + sessions))
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
  }), {numRuns: 300})
})
