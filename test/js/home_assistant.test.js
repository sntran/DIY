// The tests of assets/js/home_assistant.js: the sign-in to Home Assistant
// in its own tab, and the store of the session (fake-indexeddb). Also the
// socket, with a fake WebSocket and a fake fetch.
import {test} from "node:test"
import assert from "node:assert/strict"
import {createHash} from "node:crypto"
import fc from "fast-check"
import {IDBFactory} from "fake-indexeddb"
import {
  DB, STORE, KEY, GENERATION, CHANNEL, PENDING, SIGN_IN, TAB, TAB_CHECK, EARLY, FIRST_WAIT, MAX_WAIT,
  address, blocked, socketUrl, clientOf, signInPage, signInId, randomText, pkce, authorizeUrl,
  open, sessionStore, Link, SignIn, homeAssistantHook, signInHook, browserParts, signInParts, key, CommandError,
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

// The parts of a browser for a Link or a SignIn, with fakes. The fake
// fetch gives the answers of respond(url, fields). The fake openTab gives a
// fake tab, or null when the browser blocks it (tabs: false).
function parts({
  search = "", pathname = "/settings", protocol = "http:", respond = () => answer(200), store, factory,
  tabs = true, storage = new Map(),
} = {}) {
  const calls = []
  const pushes = []
  const timers = new Map()
  let nextTimer = 1
  const listened = {}
  const page = {
    calls, pushes, timers, storage, listened, went: [], replaced: [], opened: [], told: [], closes: 0,
    inits: [], clock: 1_000_000,
  }
  const notified = []
  page.notified = notified
  page.deps = {
    store: store ?? sessionStore(factory ?? new IDBFactory(), () => notified.push("changed")),
    listen: (onNews, onOnline, onConnect) => {
      listened.news = onNews
      listened.online = onOnline
      listened.connect = onConnect
      return () => { listened.stopped = true }
    },
    fetch: async (url, init) => {
      const fields = Object.fromEntries(init.body)
      calls.push({url, fields})
      page.inits.push(init)
      return respond(url, fields)
    },
    WebSocket: FakeSocket,
    location: {
      origin: APP, protocol, pathname, search,
      replace: (url) => page.went.push(url),
    },
    history: {replaceState: (...args) => page.replaced.push(args)},
    storage: {
      getItem: (key) => storage.has(key) ? storage.get(key) : null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: (key) => storage.delete(key),
    },
    crypto: globalThis.crypto,
    openTab: (path) => {
      if (!tabs) return null
      const tab = {path, closed: false, close() { this.closed = true }}
      page.opened.push(tab)
      return tab
    },
    tell: (message) => page.told.push(message),
    closeTab: () => { page.closes += 1 },
    fromApp: true,
    now: () => page.clock,
    setTimer: (f, ms) => { const id = nextTimer++; timers.set(id, {f, ms}); return id },
    clearTimer: (id) => timers.delete(id),
    push: (event, payload) => pushes.push([event, payload]),
  }
  return page
}

const last = (page) => page.pushes.at(-1)[1]

// Lets the page run until cond() is true (for example, WebCrypto).
async function until(cond) {
  for (let i = 0; i < 1000 && !cond(); i++) await settle(1)
  assert.ok(cond())
}

// Runs the timers that wait now.
function tick(page) {
  for (const [id, timer] of [...page.timers]) {
    page.timers.delete(id)
    timer.f()
  }
}

// A session in the store, as a sign-in leaves it.
const session = (refresh = "r1", extra = {}) =>
  ({url: HA, client: APP + "/", access: "a-" + refresh, refresh, expires: 1_000_000 + 1_800_000, ...extra})

// Keeps a session in the store, as a sign-in of this generation does.
const keep = async (store, stored) => store.write(stored, await store.generation())

// A link with a stored session, and its open socket after the sign-in of
// the socket.
async function connected(page, stored = session()) {
  await keep(page.deps.store, stored)
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

// The tab of a sign-in, from its page: it goes to Home Assistant. Then
// Home Assistant sends it back with the code (back(query)). It shares the
// store of the test, and has its own sessionStorage.
async function signInTab({path, factory, store, respond, protocol = "http:", tell} = {}) {
  const storage = new Map()
  const options = {factory, store, respond, protocol, storage}
  const first = parts({...options, pathname: SIGN_IN, search: new URL(APP + path).search})
  if (tell) first.deps.tell = tell
  const begin = new SignIn(first.deps)
  await begin.start()
  const authorize = first.went[0] ? new URL(first.went[0]) : null
  return {
    first,
    begin,
    authorize,
    state: authorize?.searchParams.get("state"),
    back: (query) => {
      const page = parts({...options, pathname: SIGN_IN, search: "?" + query})
      if (tell) page.deps.tell = tell
      page.signIn = new SignIn(page.deps)
      page.done = page.signIn.start()
      return page
    },
  }
}

test("address gives the origin and the path of Home Assistant", () => {
  assert.equal(address("https://Home.Example.com/"), "https://home.example.com")
  assert.equal(address("  http://192.168.1.5:8123  "), "http://192.168.1.5:8123")
  assert.equal(address("https://example.com:443/ha//?x=1#y"), "https://example.com/ha")
  assert.equal(address("http://[::1]:8123"), "http://[::1]:8123")
  assert.equal(address("ftp://example.com"), null)
  assert.equal(address("home.example.com"), null)
  assert.equal(address("https://user:pass@example.com"), null)
  assert.equal(address(undefined), null)
  assert.equal(address(null), null)
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

test("the sign-in page of the app gets the address and the id of the sign-in", () => {
  assert.equal(SIGN_IN, "/ha/sign-in")
  assert.equal(signInPage(HA, "s1"), "/ha/sign-in?url=http%3A%2F%2Fha.test%3A8123&id=s1")
  assert.equal(signInId("abc_D-9"), "abc_D-9")
  assert.equal(signInId("a".repeat(64)), "a".repeat(64))
  for (const bad of ["", "a".repeat(65), "a b", "a&b", "ä", null, undefined, 5]) {
    assert.equal(signInId(bad), null, String(bad))
  }
})

test("the page of a sign-in stays on this app, and gives back its address and its id", () => {
  fc.assert(fc.property(fc.webUrl(), fc.string(), (text, id) => {
    const url = address(text)
    if (url === null) return
    const page = new URL(APP + signInPage(url, id))
    assert.equal(page.origin, APP)
    assert.equal(page.pathname, SIGN_IN)
    assert.equal(address(page.searchParams.get("url")), url)
    assert.equal(page.searchParams.get("id"), id)
    const safe = signInId(id)
    assert.ok(safe === null || safe === id)
  }))
})

test("the sign-in page of Home Assistant gets the client, the way back, the state and the challenge", async () => {
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
    redirect_uri: APP + "/ha/sign-in",
    state: "s1",
    code_challenge: challenge,
    code_challenge_method: "S256",
  })
})

test("the store reads, writes in its generation, updates with a compare and set, and clears", async () => {
  const notified = []
  const store = sessionStore(new IDBFactory(), () => notified.push(1))
  assert.equal(await store.read(), null)
  assert.equal(await store.generation(), 0)
  assert.equal(await store.update("r1", {access: "x"}), false)
  assert.equal(await store.clear("r1"), null)
  assert.equal(notified.length, 0)

  assert.deepEqual(await store.write(session("r1"), 0), {kept: true, old: null})
  assert.deepEqual(await store.write(session("r2"), 0), {kept: true, old: session("r1")})
  assert.equal(notified.length, 2)

  assert.equal(await store.update("r1", {access: "x"}), false)
  assert.equal(await store.update("r2", {access: "x"}), true)
  assert.equal((await store.read()).access, "x")
  assert.equal(notified.length, 2)

  // Home Assistant ended a session: only that session goes.
  assert.equal(await store.clear("r1"), null)
  assert.equal((await store.clear("r2")).refresh, "r2")
  assert.equal(await store.read(), null)
  assert.equal(await store.generation(), 0)
  assert.equal(notified.length, 3)

  // A disconnect: a new generation, and no session. A sign-in of the old
  // generation writes nothing.
  await store.write(session("r3"), 0)
  assert.equal((await store.disconnect()).refresh, "r3")
  assert.equal(await store.generation(), 1)
  assert.equal(await store.read(), null)
  assert.equal(notified.length, 5)
  assert.deepEqual(await store.write(session("r4"), 0), {kept: false, old: null})
  assert.equal(await store.read(), null)
  assert.equal(notified.length, 5)

  // A disconnect with no session: a new generation, and no news.
  assert.equal(await store.disconnect(), null)
  assert.equal(await store.generation(), 2)
  assert.equal(notified.length, 5)
  assert.deepEqual(await store.write(session("r5"), 2), {kept: true, old: null})
})

test("the store gives an error when IndexedDB stops the transaction", async () => {
  const store = sessionStore(new IDBFactory(), () => {})
  await assert.rejects(store.write({...session(), f() {}}, 0))
  assert.equal(await store.read(), null)
})

test("the store opens the database again after the browser closes it", async () => {
  const factory = new IDBFactory()
  const dbs = []
  const counting = {open: (...args) => { const request = factory.open(...args); dbs.push(request); return request }}
  const store = sessionStore(counting, () => {})
  await keep(store, session())
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
  assert.equal(GENERATION, "generation")
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

test("connect opens the sign-in page of the app in a new tab, in the tap", async () => {
  const page = parts()
  const link = new Link(page.deps)
  await link.start()
  // The key Connect gives the text of the field (browserParts).
  page.listened.connect(HA + "/")
  // The tab opens before any wait: a browser blocks a tab that opens later.
  assert.equal(page.opened.length, 1)
  const url = new URL(APP + page.opened[0].path)
  assert.equal(url.pathname, SIGN_IN)
  assert.equal(url.searchParams.get("url"), HA)
  const id = url.searchParams.get("id")
  assert.equal(signInId(id), id)
  assert.deepEqual(last(page), {state: "signing_in", url: HA, name: null, version: null, error: null})
  assert.equal(link.tab.id, id)
  assert.equal(page.timers.size, 1)
  assert.equal([...page.timers.values()][0].ms, TAB_CHECK)

  // A second connect: a new id, and one check of the tab.
  link.connect(HA)
  assert.notEqual(new URL(APP + page.opened[1].path).searchParams.get("id"), id)
  assert.equal(page.timers.size, 1)

  // A bad address: no tab. The field keeps the text, so the person can
  // correct it.
  const other = parts()
  const second = new Link(other.deps)
  second.connect("home.example.com")
  assert.deepEqual(last(other), {state: "none", url: "home.example.com", name: null, version: null, error: "url"})
  second.connect(undefined)
  assert.deepEqual(last(other), {state: "none", url: null, name: null, version: null, error: "url"})
  const https = parts({protocol: "https:"})
  new Link(https.deps).connect(HA)
  assert.deepEqual(last(https), {state: "none", url: HA, name: null, version: null, error: "blocked"})
  assert.equal(other.opened.length + https.opened.length, 0)

  // The browser blocks the tab.
  const blocking = parts({tabs: false})
  const third = new Link(blocking.deps)
  third.connect(HA)
  assert.deepEqual(last(blocking), {state: "none", url: HA, name: null, version: null, error: "tab"})
  assert.equal(third.tab, null)
  assert.equal(blocking.timers.size, 0)
})

test("the tab of a sign-in that closes: the page reads the store", async () => {
  const page = parts()
  const link = new Link(page.deps)
  await link.start()
  link.connect(HA)
  const tab = page.opened[0]

  // The tab is still open: a new check later.
  tick(page)
  assert.equal(page.timers.size, 1)
  assert.equal(last(page).state, "signing_in")

  // The person closed the tab before the end.
  tab.closed = true
  tick(page)
  await settle()
  assert.deepEqual(last(page), {state: "none", url: null, name: null, version: null, error: "closed"})
  assert.equal(link.tab, null)
  assert.equal(page.timers.size, 0)

  // The tab closed after the end, and its news did not come (a browser
  // with no BroadcastChannel): the store has the session.
  link.connect(HA)
  await keep(page.deps.store, session())
  page.opened[1].closed = true
  tick(page)
  await settle()
  assert.equal(last(page).state, "connecting")
  link.stop()
})

test("the end of a sign-in comes to the tab that opened it", async () => {
  const page = parts()
  const link = new Link(page.deps)
  await link.start()
  link.connect(HA)
  const {id} = link.tab

  // The end of a different sign-in, or the news of the store, changes
  // nothing.
  await page.listened.news({ended: "other", error: "denied"})
  await page.listened.news("changed")
  assert.equal(last(page).state, "signing_in")
  assert.equal(link.tab.id, id)

  // An error: the page shows it, and does not check the tab again.
  await page.listened.news({ended: id, error: "denied"})
  assert.deepEqual(last(page), {state: "none", url: null, name: null, version: null, error: "denied"})
  assert.equal(link.tab, null)
  assert.equal(page.timers.size, 0)

  // A sign-in that worked: the page uses the session.
  link.connect(HA)
  await keep(page.deps.store, session())
  await page.listened.news({ended: link.tab.id})
  assert.equal(last(page).state, "connecting")
  // A late end changes nothing.
  await page.listened.news({ended: id, error: "denied"})
  assert.equal(last(page).state, "connecting")
  link.stop()
})

test("a stop of the sign-in: its session does not count, also in a tab that stays open", async () => {
  const factory = new IDBFactory()
  let release
  const respond = (url) => url.endsWith("/auth/token")
    ? new Promise((resolve) => { release = () => resolve(tokens("a1", "r1")) })
    : answer(200)
  const page = parts({factory, respond})
  const link = new Link(page.deps)
  await link.start()
  link.connect(HA)
  const tab = page.opened[0]
  const told = []
  const signIn = await signInTab({path: tab.path, factory, respond, tell: (message) => told.push(message)})
  const back = signIn.back(`code=c1&state=${signIn.state}`)
  await settle()

  // The person stops the sign-in on the first tab, while the exchange
  // waits. The tab shows a page of Home Assistant and has no opener, so the
  // browser does not close it.
  let asked = 0
  tab.close = () => { asked += 1 }
  await link.disconnect()
  assert.equal(asked, 1)
  assert.equal(tab.closed, false)
  assert.equal(link.tab, null)
  assert.equal(page.timers.size, 0)
  release()
  await back.done
  await settle()
  assert.equal(await page.deps.store.read(), null)
  assert.deepEqual(back.calls.at(-1), {url: HA + "/auth/revoke", fields: {token: "r1"}})
  assert.deepEqual(last(back), {state: "none", url: HA, name: null, version: null, error: "cancelled"})
  assert.deepEqual(told, [{ended: tab.path.split("id=")[1], error: "cancelled"}])
  assert.equal(back.closes, 0)
  assert.equal(last(page).state, "none")
})

test("the sign-in tab goes to Home Assistant with a new state and the generation", async () => {
  const factory = new IDBFactory()
  const store = sessionStore(factory, () => {})
  await store.disconnect()
  const tab = await signInTab({path: signInPage(HA, "s1"), factory})
  const pending = JSON.parse(tab.first.storage.get(PENDING))
  assert.deepEqual(Object.keys(pending).sort(), ["generation", "id", "state", "url", "verifier"])
  assert.equal(pending.url, HA)
  assert.equal(pending.id, "s1")
  assert.equal(pending.generation, 1)
  assert.equal(tab.state, pending.state)
  assert.equal(tab.authorize.origin + tab.authorize.pathname, HA + "/auth/authorize")
  assert.equal(tab.authorize.searchParams.get("redirect_uri"), APP + SIGN_IN)
  const challenge = createHash("sha256").update(pending.verifier).digest("base64url")
  assert.equal(tab.authorize.searchParams.get("code_challenge"), challenge)
  assert.deepEqual(last(tab.first), {state: "signing_in", url: HA, name: null, version: null, error: null})
  assert.deepEqual(tab.first.told, [])

  // A page with a bad address, an http address on an HTTPS page, or a
  // store that the page cannot read. The tab shows the error, and the
  // first tab gets it.
  for (const [path, protocol, broken, error, id] of [
    [SIGN_IN + "?url=home.example.com&id=s2", "http:", false, "url", "s2"],
    [SIGN_IN + "?id=s3", "http:", false, "url", "s3"],
    [signInPage(HA, "s4"), "https:", false, "blocked", "s4"],
    [signInPage(HA, "s5"), "http:", true, "storage", "s5"],
  ]) {
    const store = broken ? {generation: async () => { throw new Error("no") }} : undefined
    const bad = await signInTab({path, protocol, store, factory})
    assert.equal(bad.authorize, null)
    assert.equal(last(bad.first).state, "none")
    assert.equal(last(bad.first).error, error)
    assert.deepEqual(bad.first.told, [{ended: id, error}])
  }
  // An id that is not safe: the sign-in goes on, and no tab waits for it.
  const unsafe = await signInTab({path: signInPage(HA, "a b"), factory})
  assert.equal(JSON.parse(unsafe.first.storage.get(PENDING)).id, null)
  const respond = (url) => url.endsWith("/auth/token") ? tokens("a1", "r1") : answer(200)
  const bad = await signInTab({path: SIGN_IN + "?url=x", factory, respond})
  assert.deepEqual(bad.first.told, [])
  const back = (await signInTab({path: signInPage(HA, "a b"), factory, respond})).back("x")
  await back.done
  assert.deepEqual(back.told, [])
})

test("a sign-in page that no tab of the app opened does not leave the app", async () => {
  // For example, a link of a different site to the sign-in page, with the
  // address of a server of its choice.
  const page = parts({pathname: SIGN_IN, search: "?" + new URLSearchParams({url: "https://evil.example", id: "s1"})})
  page.deps.fromApp = false
  await new SignIn(page.deps).start()
  assert.deepEqual(page.went, [])
  assert.equal(page.storage.has(PENDING), false)
  assert.deepEqual(page.told, [])
  assert.deepEqual(last(page), {state: "none", url: null, name: null, version: null, error: "unasked"})
  assert.equal(page.closes, 0)
})

test("the sign-in tab gets the tokens, keeps them, tells the first tab, and closes", async () => {
  const factory = new IDBFactory()
  const respond = (url) => url.endsWith("/auth/token") ? tokens("a1", "r1") : answer(200)
  const tab = await signInTab({path: signInPage(HA, "s1"), factory, respond})
  const pending = JSON.parse(tab.first.storage.get(PENDING))
  const back = tab.back(`code=c1&state=${tab.state}&storeToken=true`)
  await back.done

  assert.deepEqual(back.calls[0], {
    url: HA + "/auth/token",
    fields: {grant_type: "authorization_code", code: "c1", client_id: APP + "/", code_verifier: pending.verifier},
  })
  assert.equal(back.storage.has(PENDING), false)
  // The code and the state go away from the address.
  assert.deepEqual(back.replaced, [[null, "", SIGN_IN]])
  assert.deepEqual(await back.deps.store.read(), {
    url: HA, client: APP + "/", access: "a1", refresh: "r1", expires: back.clock + 1_800_000,
  })
  assert.equal(back.notified.length, 1)
  assert.deepEqual(back.pushes.map(([, state]) => state.state), ["signing_in", "done"])
  assert.deepEqual(last(back), {state: "done", url: HA, name: null, version: null, error: null})
  assert.deepEqual(back.told, [{ended: "s1", error: null}])
  assert.equal(back.closes, 1)

  // The first tab gets the end, and connects.
  const page = parts({factory})
  const link = new Link(page.deps)
  await link.start()
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
  link.stop()
})

test("a way back with a wrong state, no code, or a bad text keeps nothing", async () => {
  for (const [pending, search, error, told] of [
    [{url: HA, state: "other", verifier: "v", generation: 0, id: "s1"}, "?code=c&state=s1", "state",
      [{ended: "s1", error: "state"}]],
    [null, "?code=c&state=s1", "state", []],
    ["{bad json", "?code=c&state=s1", "state", []],
    ["5", "?code=c&state=s1", "state", []],
    [{url: HA, state: "s1", verifier: "v", generation: 0, id: "s1"}, "?error=access_denied&state=s1", "denied",
      [{ended: "s1", error: "denied"}]],
  ]) {
    const page = parts({pathname: SIGN_IN, search})
    if (pending !== null) page.storage.set(PENDING, typeof pending === "string" ? pending : JSON.stringify(pending))
    await new SignIn(page.deps).start()
    assert.equal(page.calls.length, 0)
    assert.equal(last(page).error, error)
    assert.deepEqual(page.told, told)
    assert.equal(page.closes, 0)
    assert.equal(await page.deps.store.read(), null)
    assert.deepEqual(page.replaced.at(-1), [null, "", SIGN_IN])
  }
})

test("the exchange of the code can fail", async () => {
  for (const [respond, error] of [
    [() => { throw new Error("offline") }, "unreachable"],
    [() => answer(400, {error: "invalid_request"}), "token"],
    [() => ({ok: true, status: 200, json: async () => { throw new SyntaxError("not JSON") }}), "token"],
  ]) {
    const page = parts({pathname: SIGN_IN, search: "?code=c&state=s1", respond})
    page.storage.set(PENDING, JSON.stringify({url: HA, state: "s1", verifier: "v", generation: 0, id: "s1"}))
    await new SignIn(page.deps).start()
    assert.deepEqual(last(page), {state: "none", url: HA, name: null, version: null, error})
    assert.deepEqual(page.told, [{ended: "s1", error}])
    assert.equal(await page.deps.store.read(), null)
  }
})

test("a sign-in replaces and revokes the old session, and a store error revokes the new one", async () => {
  const respond = (url) => url.endsWith("/auth/token") ? tokens("a2", "r2") : answer(200)
  const pending = JSON.stringify({url: HA, state: "s1", verifier: "v", generation: 0, id: "s1"})
  const page = parts({pathname: SIGN_IN, search: "?code=c&state=s1", respond})
  page.storage.set(PENDING, pending)
  await keep(page.deps.store, session("r1"))
  await new SignIn(page.deps).start()
  assert.equal((await page.deps.store.read()).refresh, "r2")
  assert.deepEqual(page.calls.at(-1), {url: HA + "/auth/revoke", fields: {token: "r1"}})
  // The tab closes at once: the revoke continues after it (keepalive). The
  // exchange of the code does not need it.
  assert.equal(page.closes, 1)
  assert.equal(page.inits.at(-1).keepalive, true)
  assert.equal(page.inits[0].keepalive, undefined)

  // The same session again: nothing to revoke.
  const again = parts({pathname: SIGN_IN, search: "?code=c&state=s1", respond})
  again.storage.set(PENDING, pending)
  await keep(again.deps.store, session("r2"))
  await new SignIn(again.deps).start()
  assert.equal(again.calls.filter((call) => call.url.endsWith("/revoke")).length, 0)

  const failing = parts({
    pathname: SIGN_IN,
    search: "?code=c&state=s1",
    respond,
    store: {write: async () => { throw new Error("full") }},
  })
  failing.storage.set(PENDING, pending)
  await new SignIn(failing.deps).start()
  assert.equal(last(failing).error, "storage")
  assert.deepEqual(failing.told, [{ended: "s1", error: "storage"}])
  assert.deepEqual(failing.calls.at(-1), {url: HA + "/auth/revoke", fields: {token: "r2"}})
})

test("a disconnect after the store write keeps the disconnect", async () => {
  const factory = new IDBFactory()
  const respond = (url) => url.endsWith("/auth/token") ? tokens("a1", "r1") : answer(200)
  const page = parts({factory, respond})
  const link = new Link(page.deps)
  await link.start()
  const tab = await signInTab({path: signInPage(HA, "s1"), factory, respond})
  await tab.back(`code=c1&state=${tab.state}`).done
  assert.equal((await page.deps.store.read()).refresh, "r1")
  await link.disconnect()
  assert.equal(await page.deps.store.read(), null)
  assert.deepEqual(page.calls.at(-1), {url: HA + "/auth/revoke", fields: {token: "r1"}})
  assert.equal(last(page).state, "none")
})

test("a disconnect clears the store, revokes the session and closes the socket", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  assert.equal(last(page).state, "connected")
  await link.disconnect()
  assert.equal(socket.closed, true)
  assert.equal(await page.deps.store.read(), null)
  assert.equal(await page.deps.store.generation(), 1)
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
  const broken = parts({store: {read: async () => null, disconnect: async () => { throw new Error("no") }}})
  const alone = new Link(broken.deps)
  await alone.disconnect()
  assert.equal(last(broken).state, "none")
})

test("the access token gets a refresh before its end, with a compare and set", async () => {
  const page = parts({respond: () => answer(200, {access_token: "a-new", expires_in: 1800})})
  const stored = session("r1", {expires: 1_000_000 + EARLY})
  await keep(page.deps.store, stored)
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
    await keep(page.deps.store, expired)
    await new Link(page.deps).start()
    const socket = FakeSocket.all.at(-1)
    socket.receive({type: "auth_required"})
    await settle()
    assert.deepEqual(socket.sent, [])
    assert.ok(await page.deps.store.read())
  }

  // Home Assistant refuses the refresh token: the session ended.
  const ended = parts({respond: () => answer(400, {error: "invalid_grant"})})
  await keep(ended.deps.store, expired)
  await new Link(ended.deps).start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  assert.deepEqual(last(ended), {state: "signed_out", url: HA, name: null, version: null, error: "signed_out"})
  assert.equal(await ended.deps.store.read(), null)

  // The same, with a disconnect in the clear of the store: the disconnect
  // wins.
  const both = parts({respond: () => answer(400, {error: "invalid_grant"})})
  await keep(both.deps.store, expired)
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
    respond: async () => { await keep(other, session("r2")); return answer(200, {access_token: "a-old", expires_in: 1800}) },
  })
  await keep(changed.deps.store, expired)
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
  await keep(late.deps.store, expired)
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
  await keep(full.deps.store, expired)
  full.deps.store.update = async () => { throw new Error("full") }
  await new Link(full.deps).start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  assert.deepEqual(FakeSocket.all.at(-1).sent, [])

  // The refresh ends after a disconnect, in the store write.
  const slow = parts({respond: () => answer(200, {access_token: "a-slow", expires_in: 1800})})
  await keep(slow.deps.store, expired)
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
  await keep(page.deps.store, session("r1", {expires: 0}))
  const link = new Link(page.deps)
  await link.start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  await keep(page.deps.store, session("r2"))
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
  await keep(other.deps.store, session("r1", {expires: 0}))
  await new Link(other.deps).start()
  FakeSocket.all.at(-1).receive({type: "auth_required"})
  await settle()
  await other.deps.store.disconnect()
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
  await keep(page.deps.store, session("r2"))
  await page.listened.news()
  assert.equal(socket.closed, true)
  assert.equal(FakeSocket.all.length, count + 1)

  // No session: no socket.
  await page.deps.store.disconnect()
  await page.listened.news()
  assert.equal(FakeSocket.all.at(-1).closed, true)
  assert.equal(last(page).state, "none")
  assert.equal(link.socket, null)

  // News for an old epoch changes nothing.
  await keep(page.deps.store, session("r3"))
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
  // The server sends no address: the key Connect gives it to the hook.
  assert.deepEqual(Object.keys(handlers).sort(), ["ha:add_areas", "ha:disconnect", "ha:rooms_fetch"])
  page.listened.connect(HA)
  assert.equal(page.opened.length, 1)
  await handlers["ha:disconnect"]()
  assert.equal(page.opened[0].closed, true)
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

test("the hook of the sign-in page starts the sign-in one time", async () => {
  const page = parts({pathname: SIGN_IN, search: "?" + new URLSearchParams({url: HA, id: "s1"})})
  let made = 0
  const hook = signInHook(() => { made += 1; return page.deps })
  const self = {...hook, pushEvent: (event, payload) => page.pushes.push(["first:" + event, payload])}
  self.mounted()
  await until(() => page.went.length > 0)
  assert.equal(page.went.length, 1)
  assert.deepEqual(page.pushes.at(-1), ["first:ha:status", {state: "signing_in", url: HA, name: null, version: null, error: null}])
  self.reconnected()
  assert.equal(page.pushes.at(-1)[0], "first:ha:status")

  // LiveView mounts the page again: the hook tells the state, and does not
  // start again.
  const again = {...hook, pushEvent: (event, payload) => page.pushes.push(["again:" + event, payload])}
  again.mounted()
  await settle()
  assert.equal(made, 1)
  assert.equal(page.went.length, 1)
  assert.deepEqual(page.pushes.at(-1), ["again:ha:status", {state: "signing_in", url: HA, name: null, version: null, error: null}])
})

test("the parts of the browser", async () => {
  const events = []
  const posted = []
  const opened = []
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
    open: (...args) => { opened.push(args); return "tab" },
    close: () => events.push(["close"]),
    opener: {},
    setTimeout: (f, ms) => ["timer", ms],
    clearTimeout: (id) => events.push(["clear", id]),
  }
  const browser = browserParts(window)
  await keep(browser.store, session())
  assert.deepEqual(posted, [[CHANNEL, "changed"]])
  const news = []
  const online = () => {}
  const connects = []
  const unlisten = browser.listen((message) => news.push(message), online, (text) => connects.push(text))
  // The channel gives the message, not the event.
  Channel.last.onmessage({data: {ended: "s1", error: null}})
  assert.deepEqual(news, [{ended: "s1", error: null}])
  assert.deepEqual(events.map(([event]) => event), ["online", "ha:connect"])
  // The key Connect: the text of the field url of its form.
  const connect = events[1][1]
  const form = (value) => ({target: {elements: {namedItem: (name) => name === "url" && value !== undefined ? {value} : null}}})
  connect(form("https://ha.example.com"))
  connect(form(undefined))
  assert.deepEqual(connects, ["https://ha.example.com", undefined])
  unlisten()
  assert.equal(Channel.last.onmessage, null)
  assert.deepEqual(events.slice(-2).map(([event, f]) => [event, f]), [["remove online", online], ["remove ha:connect", connect]])
  assert.deepEqual(await browser.fetch("u", {method: "POST"}), ["fetched", "u", {method: "POST"}])
  assert.equal(browser.openTab("/ha/sign-in?url=x"), "tab")
  assert.deepEqual(opened, [["/ha/sign-in?url=x", TAB]])
  assert.ok(Math.abs(browser.now() - Date.now()) < 1000)
  assert.deepEqual(browser.setTimer(() => {}, 5), ["timer", 5])
  browser.clearTimer(7)
  assert.deepEqual(events.at(-1), ["clear", 7])

  // A browser with no BroadcastChannel: the hook works in this tab only.
  const alone = browserParts({...window, BroadcastChannel: undefined, indexedDB: new IDBFactory()})
  await keep(alone.store, session())
  alone.listen(() => {}, online, () => {})()
  assert.equal(posted.length, 1)

  // The sign-in page: a page of the app opened it. The pages of Home
  // Assistant in its tab get no link to the tab of the app.
  window.location = {origin: APP}
  window.opener = {location: {origin: APP}}
  const tab = signInParts(window)
  assert.equal(tab.fromApp, true)
  assert.equal(window.opener, null)
  // No opener, or the page of a different site: its origin throws.
  assert.equal(signInParts(window).fromApp, false)
  window.opener = {location: {get origin() { throw new DOMException("cross origin", "SecurityError") }}}
  assert.equal(signInParts(window).fromApp, false)
  assert.equal(window.opener, null)
  window.opener = {location: {origin: "https://evil.example"}}
  assert.equal(signInParts(window).fromApp, false)
  await keep(tab.store, session())
  tab.tell({ended: "s1", error: null})
  assert.deepEqual(posted.slice(1), [[CHANNEL, "changed"], [CHANNEL, {ended: "s1", error: null}]])
  assert.deepEqual(await tab.fetch("u"), ["fetched", "u"])
  assert.equal(tab.location, window.location)
  assert.equal(tab.history, window.history)
  assert.equal(tab.storage, window.sessionStorage)
  assert.equal(tab.crypto, window.crypto)
  assert.ok(Math.abs(tab.now() - Date.now()) < 1000)
  tab.closeTab()
  assert.deepEqual(events.at(-1), ["close"])
  const lone = signInParts({...window, BroadcastChannel: undefined, indexedDB: new IDBFactory()})
  await keep(lone.store, session())
  lone.tell({ended: "s2", error: null})
  assert.equal(posted.length, 3)
})

// The property of the model (specs/HomeAssistant.tla) on the real code. It
// has two tabs of the app, the tabs of their sign-ins, one store, and a
// fake Home Assistant that answers in any order. The sign-ins, refreshes,
// disconnects, news and checks of the tabs come in any order. The store
// never has a revoked session, and never has the session of a sign-in that
// started before the last disconnect (the generation). After a disconnect
// on a tab, the tab has no socket of a sign-in that started before it.
test("two tabs and their sign-ins in any order: no revoked or old session in the store", async () => {
  const step = fc.oneof(
    fc.record({kind: fc.constant("signIn"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("disconnect"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("refresh"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("news"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("tick"), tab: fc.integer({min: 0, max: 1})}),
    fc.record({kind: fc.constant("answer"), index: fc.nat()}),
  )

  await fc.assert(fc.asyncProperty(fc.array(step, {maxLength: 25}), async (steps) => {
    const factory = new IDBFactory()
    const inFlight = []
    const revoked = new Set()
    // The count of the disconnects, and its value at the start of the
    // sign-in of each code and of each session. The test counts them: it
    // does not read the generation of the store.
    let disconnects = 0
    const codes = new Map()
    const born = new Map()
    let sessions = 0
    const tabs = []
    const offAt = new Map()

    // The answers of Home Assistant. A revoke is at once. The other
    // answers wait for an "answer" step. Home Assistant answers a refresh
    // as the session is at the request: a new access token, or a refusal
    // of a revoked session.
    const respond = (url, fields) => {
      if (url.endsWith("/auth/revoke")) {
        revoked.add(fields.token)
        return answer(200)
      }
      const refused = fields.grant_type === "refresh_token" && revoked.has(fields.refresh_token)
      return new Promise((resolve) => {
        inFlight.push(() => {
          if (fields.grant_type === "authorization_code") {
            sessions += 1
            born.set("r" + sessions, codes.get(fields.code))
            resolve(tokens("a" + sessions, "r" + sessions))
          } else if (refused) {
            resolve(answer(400, {error: "invalid_grant"}))
          } else {
            resolve(answer(200, {access_token: "a-" + fields.refresh_token, expires_in: 1800}))
          }
        })
      })
    }
    // The BroadcastChannel: each tab of the app gets each message.
    const broadcast = (message) => {
      for (const {page} of tabs) setImmediate(() => page.listened.news(message))
    }
    const store = () => sessionStore(factory, () => broadcast("changed"))

    for (let tab = 0; tab < 2; tab++) {
      const page = parts({factory, respond, store: store()})
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
          // The key Connect opens the tab. The tab goes to Home Assistant,
          // and the person signs in there: the exchange waits for its
          // answer.
          link.connect(HA)
          const opened = page.opened.at(-1)
          const tab = await signInTab({path: opened.path, store: store(), respond, tell: broadcast})
          const code = "c" + (codes.size + 1)
          codes.set(code, disconnects)
          const back = tab.back(`code=${code}&state=${tab.state}`)
          back.deps.closeTab = () => { opened.closed = true }
        } else if (s.kind === "disconnect") {
          await link.disconnect()
          disconnects += 1
          offAt.set(s.tab, disconnects)
        } else if (s.kind === "refresh" && link.socket) {
          link.session = {...link.session, expires: 0}
          link.socket.receive({type: "auth_required"})
        } else if (s.kind === "news") {
          page.listened.news("changed")
        } else if (s.kind === "tick") {
          tick(page)
        }
      }
      await settle(6)

      const stored = await tabs[0].page.deps.store.read()
      assert.ok(!stored || !revoked.has(stored.refresh), `the store has a revoked session: ${stored?.refresh}`)
      assert.ok(!stored || born.get(stored.refresh) === disconnects,
        `the store has ${stored?.refresh} of a sign-in before a disconnect`)
      for (const [tab, at] of offAt) {
        const {link} = tabs[tab]
        assert.ok(
          !link.socket || born.get(link.session.refresh) >= at,
          `tab ${tab} has a socket of a sign-in before its disconnect`,
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
      [[{kind: "signIn", tab: 0}, {kind: "disconnect", tab: 1}, {kind: "answer", index: 0}]],
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
  await keep(page.deps.store, session())
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
      if (message.type === "config/floor_registry/create" && message.level === 2) {
        return {code: "unauthorized", message: "Unauthorized"}
      }
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
    {room: "r6", name: "Loft", level: 2, floor: "Floor 3"},
  ])
  await serve(ha, [socket])
  await done
  // Home Assistant has "Floor 2" at level 5: the bath (level 1) does not go
  // on it.
  assert.deepEqual(page.pushes.at(-1), ["ha:areas_added", {
    links: [],
    errors: [
      {room: "r1", message: "Home Assistant has a floor Floor 2 at a different level"},
      {room: "r2", message: "Unauthorized"},
      {room: "r3", message: "The name Den (den) is already in use"},
      {room: "r6", message: "Unauthorized"},
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
        // A new area is on the floor of its level, or on none.
        if (!area.area_id.startsWith("old_")) {
          assert.equal(ha.floors.find((floor) => floor.floor_id === area.floor_id)?.level ?? null, rooms[i].level)
        }
      })
    }
    for (const {link} of tabs) link.stop()
  }), {numRuns: 300})
})
