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
  deviceList, REGISTRY_WAIT, controlList, deviceStates, CONTROLS, STATE_WAIT, CONTROL_WAIT,
  energySources, zoneOf, monthOf, dayOf, monthStart, meterMonths, deviceEnergy, METER_MONTHS, DEVICE_MONTHS,
  MAX_ENERGY_DEVICES, STATION_PARTS, STATION_SWITCHES, STATION_SOURCES, MAX_POWER, stationList, stationStates,
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
    // LiveView calls the third argument with the reply of a push.
    pushEvent: (event, payload, reply) => {
      page.pushes.push(["hook:" + event, payload])
      reply({})
    },
    handleEvent: (event, f) => { handlers[event] = f },
  }
  self.mounted()
  await settle()
  assert.deepEqual(page.pushes.at(-1), ["hook:ha:status", {state: "none", url: null, name: null, version: null, error: null}])
  // The server sends no address: the key Connect gives it to the hook.
  assert.deepEqual(Object.keys(handlers).sort(), [
    "ha:add_areas", "ha:control", "ha:devices_fetch", "ha:disconnect", "ha:energy_fetch", "ha:rooms_fetch",
  ])
  // With no socket, no energy data.
  await handlers["ha:energy_fetch"]()
  assert.deepEqual(page.pushes.at(-1), ["hook:ha:energy", {error: "offline"}])
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
  const self = {...hook, pushEvent: (event, payload, reply) => {
    page.pushes.push(["first:" + event, payload])
    reply({})
  }}
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
function registry({
  floors = [], areas = [], admin = true, fail = () => null, devices = [], entities = [], states = {},
  attributes = {}, prefs = null, statistics = {},
} = {}) {
  const ha = {
    floors: structuredClone(floors), areas: structuredClone(areas), admin, fail, answered: new WeakMap(),
    devices: structuredClone(devices), entities: structuredClone(entities), states: {...states},
    attributes: structuredClone(attributes), watches: [], calls: [], early: [], late: [], prefs, statistics,
    reads: [],
  }
  // A new state of an entity: an event for each watch of it. A person
  // changes a state now (send), a service before its result (early).
  ha.set = (id, state, queue = null) => {
    ha.states[id] = state
    for (const watch of ha.watches.filter((watch) => watch.ids.includes(id))) {
      const event = {id: watch.id, type: "event", event: {c: {[id]: {"+": {s: state, lc: 2}}}}}
      if (queue) queue.push({socket: watch.socket, event})
      else watch.socket.receive(event)
    }
  }
  // A change of the attributes of an entity: "+" with the new attributes,
  // and "-" with the attributes that it removes.
  ha.change = (id, change) => {
    for (const watch of ha.watches.filter((watch) => watch.ids.includes(id))) {
      watch.socket.receive({id: watch.id, type: "event", event: {c: {[id]: change}}})
    }
  }
  ha.reply = (message, socket) => {
    const error = ha.fail(message, ha)
    if (error) return {success: false, error}
    const ok = (result) => ({success: true, result: structuredClone(result)})
    const taken = (list) => list.some((one) => key(one.name) === key(message.name))
    const inUse = () => ({code: "invalid_info", message: `The name ${message.name} (${key(message.name)}) is already in use`})
    switch (message.type) {
      case "config/floor_registry/list": return ok(ha.floors)
      case "config/area_registry/list": return ok(ha.areas)
      case "auth/current_user": return ok({id: "u1", name: "Owner", is_admin: ha.admin})
      case "subscribe_events": return ok(null)
      case "unsubscribe_events": {
        ha.watches = ha.watches.filter((watch) => watch.socket !== socket || watch.id !== message.subscription)
        return ok(null)
      }
      // All the states of the entities first, after the result.
      case "subscribe_entities": {
        ha.watches.push({socket, id: message.id, ids: message.entity_ids})
        const a = Object.fromEntries(message.entity_ids.filter((id) => id in ha.states)
          .map((id) => [id, {s: ha.states[id], a: ha.attributes[id] ?? {}, c: "ctx", lc: 1}]))
        ha.late.push({socket, event: {id: message.id, type: "event", event: {a}}})
        return ok(null)
      }
      // The new states come before the result, as in Home Assistant.
      case "call_service": {
        ha.calls.push({domain: message.domain, service: message.service, ids: message.target.entity_id})
        for (const id of message.target.entity_id) ha.set(id, message.service === "turn_on" ? "on" : "off", ha.early)
        return ok({context: {id: "ctx"}})
      }
      case "config/device_registry/list": return ok(ha.devices)
      // With no energy settings, Home Assistant answers not_found.
      case "energy/get_prefs":
        return ha.prefs ? ok(ha.prefs) : {success: false, error: {code: "not_found", message: "No prefs"}}
      // The rows of each statistic for the period: {day: [...], month: [...]}.
      case "recorder/statistics_during_period": {
        ha.reads.push(message)
        return ok(Object.fromEntries(message.statistic_ids.filter((id) => id in ha.statistics)
          .map((id) => [id, ha.statistics[id][message.period] ?? []])))
      }
      case "config/entity_registry/list": return ok(ha.entities)
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
    const reply = ha.reply(message, socket)
    for (const {socket: to, event} of ha.early.splice(0)) to.receive(event)
    socket.receive({id: message.id, type: "result", ...reply})
    for (const {socket: to, event} of ha.late.splice(0)) to.receive(event)
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

// A device and an entity of the registries of Home Assistant, with the
// fields that the hook reads.
const haDevice = (id, fields = {}) => ({
  id, name: id, name_by_user: null, area_id: null, entry_type: null, disabled_by: null, model: null, ...fields,
})
const haEntity = (entity_id, device_id, fields = {}) => ({
  entity_id, device_id, area_id: null, entity_category: null, hidden_by: null, disabled_by: null, ...fields,
})

test("the devices for the ghosts: the main entities give the domains and the area", () => {
  const devices = [
    haDevice("lamp", {name: "Lamp", area_id: "living", model: "Bulb 2"}),
    haDevice("tv", {name: "TV", name_by_user: "Den TV"}),
    haDevice("sun", {entry_type: "service"}),
    haDevice("old", {disabled_by: "user"}),
    haDevice("hub"),
    haDevice("plug", {name: null, area_id: "hall"}),
    haDevice("strip", {name: null, model: "LED strip", area_id: "hall"}),
    haDevice("lost"),
  ]
  const entities = [
    haEntity("light.lamp", "lamp"),
    haEntity("sensor.lamp_power", "lamp"),
    haEntity("sensor.lamp_signal", "lamp", {entity_category: "diagnostic"}),
    haEntity("media_player.tv", "tv", {area_id: "den"}),
    haEntity("sensor.tv_hidden", "tv", {hidden_by: "user", area_id: "attic"}),
    haEntity("sensor.sun", "sun"),
    haEntity("light.old", "old"),
    haEntity("button.hub_restart", "hub", {entity_category: "config"}),
    haEntity("switch.plug", "plug", {disabled_by: "user"}),
    haEntity("switch.plug_2", "plug"),
    haEntity("light.strip", "strip"),
    haEntity("light.lost", "lost"),
    haEntity("sun.sun", null),
  ]
  // A device in no area can be no ghost: it is not in the list. With no
  // name, a device has the name of its model.
  assert.deepEqual(deviceList(devices, entities), [
    {id: "lamp", name: "Lamp", area: "living", domains: ["light", "sensor"], station: null, model: "Bulb 2"},
    {id: "tv", name: "Den TV", area: "den", domains: ["media_player"], station: null, model: null},
    {id: "plug", name: "", area: "hall", domains: ["switch"], station: null, model: null},
    {id: "strip", name: "LED strip", area: "hall", domains: ["light"], station: null, model: "LED strip"},
  ])
})

test("each device of the list is a device of a person, with a main entity", () => {
  const device = fc.record({
    id: fc.constantFrom("a", "b", "c", "d"),
    name: fc.option(fc.string(), {nil: null}),
    name_by_user: fc.option(fc.string(), {nil: null}),
    area_id: fc.option(fc.constantFrom("x", "y"), {nil: null}),
    entry_type: fc.option(fc.constant("service"), {nil: null}),
    disabled_by: fc.option(fc.constant("user"), {nil: null}),
    model: fc.option(fc.string(), {nil: undefined}),
  })
  const entity = fc.record({
    entity_id: fc.tuple(fc.constantFrom("light", "switch", "sensor"), fc.nat(9)).map(([d, n]) => `${d}.e${n}`),
    device_id: fc.option(fc.constantFrom("a", "b", "c", "d"), {nil: null}),
    area_id: fc.option(fc.constantFrom("x", "z"), {nil: null}),
    entity_category: fc.option(fc.constantFrom("config", "diagnostic"), {nil: null}),
    hidden_by: fc.option(fc.constant("user"), {nil: null}),
    disabled_by: fc.option(fc.constant("user"), {nil: null}),
  })
  fc.assert(fc.property(fc.uniqueArray(device, {selector: (d) => d.id}), fc.array(entity), (devices, entities) => {
    const main = entities.filter((e) => e.device_id && !e.entity_category && !e.hidden_by && !e.disabled_by)
    const list = deviceList(devices, entities)
    for (const item of list) {
      const source = devices.find((d) => d.id === item.id)
      const own = main.filter((e) => e.device_id === item.id)
      assert.ok(source.entry_type !== "service" && !source.disabled_by)
      assert.ok(own.length > 0)
      assert.deepEqual(item.domains, [...new Set(own.map((e) => e.entity_id.split(".")[0]))].sort())
      assert.equal(item.area, source.area_id ?? own.find((e) => e.area_id)?.area_id ?? null)
      assert.equal(typeof item.name, "string")
    }
    // Each device of a person with a main entity and an area is in the
    // list.
    const kept = devices.filter((d) => d.entry_type !== "service" && !d.disabled_by &&
      main.some((e) => e.device_id === d.id) &&
      (d.area_id || main.some((e) => e.device_id === d.id && e.area_id)))
    assert.deepEqual(list.map((d) => d.id), kept.map((d) => d.id))
    assert.ok(list.every((d) => d.area !== null))
  }))
})

test("the hook reads the devices, the entities and the areas of Home Assistant", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const ha = registry({
    areas: [{area_id: "living", name: "Living Room", floor_id: "ground"}, {area_id: "yard", name: "Yard"}],
    devices: [haDevice("lamp", {name: "Lamp", area_id: "living"}), haDevice("sun", {entry_type: "service"})],
    entities: [haEntity("light.lamp", "lamp"), haEntity("sensor.sun", "sun")],
  })
  const done = link.devices()
  await serve(ha, [socket])
  await done
  // The first read also watches the three registries.
  assert.deepEqual(socket.sent.slice(2).map((message) => [message.type, message.event_type]), [
    ["config/device_registry/list", undefined], ["config/entity_registry/list", undefined],
    ["config/area_registry/list", undefined],
    ["subscribe_events", "device_registry_updated"], ["subscribe_events", "entity_registry_updated"],
    ["subscribe_events", "area_registry_updated"], ["subscribe_entities", undefined],
  ])
  assert.deepEqual(page.pushes.at(-1), ["ha:devices", {
    devices: [{id: "lamp", name: "Lamp", area: "living", domains: ["light"], station: null, model: null}],
    areas: [{id: "living", name: "Living Room", floor: "ground"}, {id: "yard", name: "Yard", floor: null}],
  }])
  assert.equal(link.watching, true)
  // The states of the lamp come after a short wait.
  tick(page)
  assert.deepEqual(page.pushes.at(-1), ["ha:states", {states: {lamp: "unavailable"}}])

  // A change of a registry: one new read for many changes, after a wait.
  // A read does not watch again. An event of no subscription changes
  // nothing.
  const subscriptions = socket.sent.filter((message) => message.type === "subscribe_events").map((message) => message.id)
  ha.devices.push(haDevice("fan", {name: "Fan", area_id: "yard"}))
  ha.entities.push(haEntity("fan.fan", "fan"))
  socket.receive({id: 99, type: "event", event: {}})
  assert.equal(page.timers.size, 0)
  socket.receive({id: subscriptions[0], type: "event", event: {action: "create"}})
  socket.receive({id: subscriptions[2], type: "event", event: {action: "update"}})
  assert.equal(page.timers.size, 1)
  assert.equal([...page.timers.values()][0].ms, REGISTRY_WAIT)
  tick(page)
  await serve(ha, [socket])
  assert.deepEqual(page.pushes.at(-1)[1].devices.map((device) => device.id), ["lamp", "fan"])
  assert.equal(socket.sent.filter((message) => message.type === "subscribe_events").length, 3)
  tick(page)

  // The socket closes: no more watch, and no read waits.
  socket.receive({id: subscriptions[1], type: "event", event: {}})
  assert.equal(page.timers.size, 1)
  socket.drop()
  assert.equal(link.watching, false)
  assert.equal(link.reread, null)
  assert.equal(link.events.size, 0)
  link.stop()

  // Home Assistant refuses the watch: the devices still come, and the
  // next read tries again.
  const other = parts()
  const second = await connected(other)
  const refusing = registry({
    devices: [haDevice("lamp", {name: "Lamp", area_id: "living"})], entities: [haEntity("light.lamp", "lamp")],
    fail: (message) => message.type === "subscribe_events" ? {code: "unauthorized", message: "Unauthorized"} : null,
  })
  const read = second.link.devices()
  await serve(refusing, [second.socket])
  await read
  assert.equal(other.pushes.at(-1)[1].devices.length, 1)
  assert.equal(second.link.watching, false)
  // Only the watch of the states stays.
  assert.deepEqual([...second.link.events.keys()], [second.link.statesOf])
  assert.equal(second.socket.sent.filter((message) => message.type === "unsubscribe_events").length, 0)
  second.link.stop()

  // Home Assistant refuses one of the three: the hook ends the other two.
  // An end that Home Assistant refuses changes nothing more.
  const fifth = parts()
  const partial = await connected(fifth)
  const half = registry({
    devices: [haDevice("lamp", {name: "Lamp", area_id: "living"})], entities: [haEntity("light.lamp", "lamp")],
    fail: (message) => message.event_type === "entity_registry_updated" || message.type === "unsubscribe_events"
      ? {code: "unauthorized", message: "Unauthorized"} : null,
  })
  const halfRead = partial.link.devices()
  await serve(half, [partial.socket])
  await halfRead
  await serve(half, [partial.socket])
  const subscribed = partial.socket.sent.filter((message) => message.type === "subscribe_events")
  const ended = partial.socket.sent.filter((message) => message.type === "unsubscribe_events")
  assert.deepEqual(ended.map((message) => message.subscription), [subscribed[0].id, subscribed[2].id])
  assert.equal(partial.link.watching, false)
  assert.deepEqual([...partial.link.events.keys()], [partial.link.statesOf])
  partial.link.stop()

  // A command that Home Assistant refuses, and no socket.
  const third = parts()
  const failed = await connected(third)
  const failing = registry({fail: (message) => message.type === "config/entity_registry/list" ? {code: "unauthorized"} : null})
  const again = failed.link.devices()
  await serve(failing, [failed.socket])
  await again
  assert.deepEqual(third.pushes.at(-1), ["ha:devices", {error: "failed"}])
  failed.link.stop()
  await failed.link.devices()
  assert.deepEqual(third.pushes.at(-1), ["ha:devices", {error: "offline"}])

  // The LiveView asks for the devices.
  const fourth = parts()
  const handlers = {}
  const hook = homeAssistantHook(() => fourth.deps)
  const self = {...hook, pushEvent: (event, payload) => fourth.pushes.push([event, payload]), handleEvent: (event, f) => { handlers[event] = f }}
  self.mounted()
  await handlers["ha:devices_fetch"]()
  assert.deepEqual(fourth.pushes.at(-1), ["ha:devices", {error: "offline"}])
  self.destroyed()
})


// The sign-in of a new socket after a drop: the wait, then the steps of
// the sign-in of the socket.
async function reconnect(page) {
  tick(page)
  await settle()
  const socket = FakeSocket.all.at(-1)
  socket.receive({type: "auth_required", ha_version: "2026.10.0"})
  await settle()
  socket.receive({type: "auth_ok", ha_version: "2026.10.0"})
  socket.receive({id: 1, type: "result", success: true, result: {location_name: "Test house"}})
  await settle()
  return socket
}

// The last states that the hook sent to the LiveView.
const lastStates = (page) => page.pushes.findLast(([event]) => event === "ha:states")?.[1].states

test("the entities that the app turns on and off, and the state of each device", () => {
  assert.deepEqual(CONTROLS, ["fan", "light", "switch"])
  const devices = [
    haDevice("lamp", {area_id: "living"}), haDevice("plug", {area_id: "living"}),
    haDevice("tv", {area_id: "living"}), haDevice("fan", {area_id: "porch"}), haDevice("far"),
  ]
  const entities = [
    haEntity("light.lamp", "lamp"), haEntity("sensor.lamp_power", "lamp"),
    haEntity("light.lamp_night", "lamp", {hidden_by: "user"}),
    haEntity("switch.plug_usb", "plug"), haEntity("switch.plug", "plug"),
    haEntity("switch.plug_led", "plug", {entity_category: "config"}),
    haEntity("media_player.tv", "tv"), haEntity("fan.fan", "fan"), haEntity("light.far", "far"),
  ]
  // Only the main entities of a device of the list (deviceList), of a
  // domain in CONTROLS, in order. A TV has none.
  const controls = controlList(deviceList(devices, entities), entities)
  assert.deepEqual([...controls], [
    ["lamp", ["light.lamp"]], ["plug", ["switch.plug", "switch.plug_usb"]], ["fan", ["fan.fan"]],
  ])
  assert.deepEqual(deviceStates(controls, new Map([["light.lamp", "on"], ["switch.plug", "off"]])), {
    lamp: "on", plug: "off", fan: "unavailable",
  })
  // One entity on: the device is on. Unknown or unavailable: not on or off.
  assert.deepEqual(deviceStates(controls, new Map([
    ["light.lamp", "unknown"], ["switch.plug", "off"], ["switch.plug_usb", "on"], ["fan.fan", "unavailable"],
  ])), {lamp: "unavailable", plug: "on", fan: "unavailable"})
})

test("the state of a device comes from the states of its entities", () => {
  const ids = ["e1", "e2", "e3", "e4"]
  const controls = fc.array(fc.tuple(fc.constantFrom("a", "b", "c"), fc.uniqueArray(fc.constantFrom(...ids), {minLength: 1})))
    .map((pairs) => new Map(pairs))
  const states = fc.dictionary(fc.constantFrom(...ids), fc.constantFrom("on", "off", "unavailable", "unknown"))
  fc.assert(fc.property(controls, states, (controls, states) => {
    const result = deviceStates(controls, new Map(Object.entries(states)))
    assert.deepEqual(Object.keys(result).sort(), [...controls.keys()].sort())
    for (const [device, own] of controls) {
      const values = own.map((id) => states[id])
      if (values.includes("on")) assert.equal(result[device], "on")
      else if (values.includes("off")) assert.equal(result[device], "off")
      else assert.equal(result[device], "unavailable")
    }
  }))
})

// A Home Assistant with a lamp, a plug and a fan in the living room, and a
// TV. The lamp is on, the plug is off, and the fan has no state.
const home = (extra = {}) => registry({
  areas: [{area_id: "living", name: "Living Room"}],
  devices: [
    haDevice("lamp", {area_id: "living"}), haDevice("plug", {area_id: "living"}),
    haDevice("fan", {area_id: "living"}), haDevice("tv", {area_id: "living"}),
  ],
  entities: [
    haEntity("light.lamp", "lamp"), haEntity("switch.plug", "plug"), haEntity("fan.fan", "fan"),
    haEntity("media_player.tv", "tv"),
  ],
  states: {"light.lamp": "on", "switch.plug": "off", "media_player.tv": "playing"},
  ...extra,
})

test("the hook watches the states of the lights, the switches and the fans", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const ha = home()
  const read = link.devices()
  await serve(ha, [socket])
  await read

  // One watch, of the entities that the app turns on and off. One message
  // for many states, after a short wait.
  const watch = socket.sent.find((message) => message.type === "subscribe_entities")
  assert.deepEqual(watch.entity_ids, ["fan.fan", "light.lamp", "switch.plug"])
  assert.deepEqual([...page.timers.values()].map((timer) => timer.ms), [STATE_WAIT])
  assert.equal(lastStates(page), undefined)
  tick(page)
  assert.deepEqual(lastStates(page), {lamp: "on", plug: "off", fan: "unavailable"})

  // A person turns the lamp off, then the fan on: one message.
  ha.set("light.lamp", "off")
  ha.set("fan.fan", "on")
  assert.equal(page.timers.size, 1)
  tick(page)
  assert.deepEqual(lastStates(page), {lamp: "off", plug: "off", fan: "on"})

  // A change of the attributes only sends nothing, and a state that does
  // not change neither. An entity that goes and comes back.
  socket.receive({id: watch.id, type: "event", event: {c: {"light.lamp": {"+": {a: {brightness: 3}}}}}})
  ha.set("light.lamp", "off")
  assert.equal(page.timers.size, 0)
  socket.receive({id: watch.id, type: "event", event: {r: ["switch.plug"]}})
  tick(page)
  assert.deepEqual(lastStates(page), {lamp: "off", plug: "unavailable", fan: "on"})
  socket.receive({id: watch.id, type: "event", event: {a: {"switch.plug": {s: "on", a: {}}}}})
  tick(page)
  assert.deepEqual(lastStates(page), {lamp: "off", plug: "on", fan: "on"})

  // A new read with the same entities: no new watch, and the states again
  // at once (a new LiveView has none). The order of the registry does not
  // count.
  ha.entities.reverse()
  ha.devices.reverse()
  const count = page.pushes.length
  const again = link.devices()
  await serve(ha, [socket])
  await again
  assert.equal(socket.sent.filter((message) => message.type === "subscribe_entities").length, 1)
  assert.deepEqual(page.pushes.slice(count).map(([event]) => event), ["ha:devices", "ha:states"])

  // A new light: the hook ends the old watch, and starts a new one. A late
  // event of the old watch changes nothing.
  ha.devices.push(haDevice("hall", {area_id: "living"}))
  ha.entities.push(haEntity("light.hall", "hall"))
  ha.states["light.hall"] = "on"
  const third = link.devices()
  await serve(ha, [socket])
  await third
  assert.deepEqual(socket.sent.filter((message) => message.type === "unsubscribe_events").at(-1).subscription, watch.id)
  const watch2 = socket.sent.findLast((message) => message.type === "subscribe_entities")
  assert.deepEqual(watch2.entity_ids, ["fan.fan", "light.hall", "light.lamp", "switch.plug"])
  socket.receive({id: watch.id, type: "event", event: {c: {"light.lamp": {"+": {s: "on"}}}}})
  tick(page)
  // The new watch gives all the states again.
  assert.deepEqual(lastStates(page), {lamp: "off", plug: "off", fan: "on", hall: "on"})

  // The socket closes: the hook forgets the states, and sends none.
  ha.set("light.lamp", "on")
  assert.equal(page.timers.size, 1)
  socket.drop()
  assert.equal(link.states.size, 0)
  assert.equal(link.statesTimer, null)
  assert.equal(link.statesOf, null)
  link.stop()
})

test("a new watch starts with no states, and a second read waits for the first states", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const ha = home()
  const read = async () => {
    const done = link.devices()
    await serve(ha, [socket])
    await done
  }
  await read()
  tick(page)
  assert.equal(lastStates(page).lamp, "on")

  // Home Assistant removes the state of the lamp while the hook starts a
  // new watch (a new light). The new watch has no state of the lamp: the
  // lamp is not on.
  delete ha.states["light.lamp"]
  ha.devices.push(haDevice("hall", {area_id: "living"}))
  ha.entities.push(haEntity("light.hall", "hall"))
  await read()
  tick(page)
  assert.equal(lastStates(page).lamp, "unavailable")

  // The end of a watch clears its states and its wait.
  ha.set("fan.fan", "on")
  assert.equal(page.timers.size, 1)
  link.endStates()
  assert.deepEqual([link.states.size, link.statesReady, link.statesTimer, page.timers.size], [0, false, null, 0])
  link.stop()

  // Two reads at once, with the same entities: the second read sends no
  // states before the first states of the watch.
  const other = parts()
  const second = await connected(other)
  const fresh = home()
  const first = second.link.devices()
  const again = second.link.devices()
  await serve(fresh, [second.socket])
  await Promise.all([first, again])
  tick(other)
  const sent = other.pushes.filter(([event]) => event === "ha:states")
  assert.deepEqual(sent, [["ha:states", {states: {lamp: "on", plug: "off", fan: "unavailable"}}]])
  second.link.stop()
})

test("a watch of the states that Home Assistant refuses, and a Home Assistant with no light", async () => {
  // No entity to turn on or off: no watch (Home Assistant sends all the
  // states then), and no states.
  const page = parts()
  const {link, socket} = await connected(page)
  const bare = registry({
    devices: [haDevice("tv", {area_id: "living"})], entities: [haEntity("media_player.tv", "tv")],
  })
  const read = link.devices()
  await serve(bare, [socket])
  await read
  assert.equal(socket.sent.filter((message) => message.type === "subscribe_entities").length, 0)
  assert.deepEqual(lastStates(page), {})
  link.stop()

  // Home Assistant refuses the watch: the next read tries again.
  const other = parts()
  const second = await connected(other)
  let refuse = true
  const ha = home({fail: (message) => refuse && message.type === "subscribe_entities" ? {code: "unauthorized"} : null})
  const first = second.link.devices()
  await serve(ha, [second.socket])
  await first
  assert.equal(second.link.statesOf, null)
  assert.equal(second.link.watched, null)
  assert.equal(second.link.events.size, 3)
  refuse = false
  const next = second.link.devices()
  await serve(ha, [second.socket])
  await next
  assert.equal(second.socket.sent.filter((message) => message.type === "subscribe_entities").length, 2)
  tick(other)
  assert.deepEqual(lastStates(other), {lamp: "on", plug: "off", fan: "unavailable"})
  second.link.stop()
})

test("the switch of an item turns its device on and off", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const ha = home({
    devices: [haDevice("lamp", {area_id: "living"}), haDevice("combo", {area_id: "living"})],
    entities: [haEntity("light.lamp", "lamp"), haEntity("light.combo", "combo"), haEntity("switch.combo", "combo")],
  })
  const read = link.devices()
  await serve(ha, [socket])
  await read
  tick(page)

  // One call for each domain of the device. The new state comes with the
  // watch, before the end.
  const done = link.control("lamp", false)
  await serve(ha, [socket])
  await done
  assert.deepEqual(ha.calls, [{domain: "light", service: "turn_off", ids: ["light.lamp"]}])
  // The new state comes before the end, with no wait: the LiveView never
  // shows the old state after the end.
  assert.deepEqual(page.pushes.slice(-2), [
    ["ha:states", {states: {lamp: "off", combo: "unavailable"}}],
    ["ha:control_done", {device: "lamp", part: null, error: null}],
  ])
  assert.equal(page.timers.size, 0)

  ha.calls = []
  const both = link.control("combo", true)
  await serve(ha, [socket])
  await both
  assert.deepEqual(ha.calls, [
    {domain: "light", service: "turn_on", ids: ["light.combo"]},
    {domain: "switch", service: "turn_on", ids: ["switch.combo"]},
  ])
  assert.deepEqual(page.pushes.at(-1), ["ha:control_done", {device: "combo", part: null, error: null}])

  // A device that the app does not turn on or off, and a call that Home
  // Assistant refuses.
  await link.control("tv", true)
  assert.deepEqual(page.pushes.at(-1), ["ha:control_done", {device: "tv", part: null, error: "failed"}])
  ha.fail = (message) => message.type === "call_service" ? {code: "home_assistant_error", message: "No"} : null
  const refused = link.control("lamp", true)
  await serve(ha, [socket])
  await refused
  assert.deepEqual(page.pushes.at(-1), ["ha:control_done", {device: "lamp", part: null, error: "failed"}])

  // Home Assistant does not answer: after a wait, the hook stops the wait
  // (timeout). A late answer then changes nothing.
  ha.fail = () => null
  const late = link.control("lamp", false)
  const [timer] = [...page.timers.values()].filter((one) => one.ms === CONTROL_WAIT)
  timer.f()
  assert.deepEqual(page.pushes.at(-1), ["ha:control_done", {device: "lamp", part: null, error: "timeout"}])
  const count = page.pushes.filter(([event]) => event === "ha:control_done").length
  await serve(ha, [socket])
  await late
  assert.equal(page.pushes.filter(([event]) => event === "ha:control_done").length, count)

  // The socket closes while the call waits: offline.
  const waiting = link.control("lamp", true)
  socket.drop()
  await waiting
  assert.deepEqual(page.pushes.at(-1), ["ha:control_done", {device: "lamp", part: null, error: "offline"}])
  link.stop()

  // The LiveView asks for a control.
  const other = parts()
  const handlers = {}
  const hook = homeAssistantHook(() => other.deps)
  const self = {...hook, pushEvent: (event, payload) => other.pushes.push([event, payload]), handleEvent: (event, f) => { handlers[event] = f }}
  self.mounted()
  await handlers["ha:control"]({device: "lamp", on: true})
  assert.deepEqual(other.pushes.at(-1), ["ha:control_done", {device: "lamp", part: null, error: "failed"}])
  self.destroyed()
})

// The entities of the power stations, as each integration gives them. The
// integration of Pecron: "entry:device:code". pecron-monitor, through
// MQTT: "pecron_key_name". EcoFlow Cloud: "ecoflow-sn-key". EcoFlow BLE:
// "ef_sn_key". The integration of the community for Pecron
// (jsight/ha-pecron): "pecron_key_code", not a source of the app.
const official = (code, fields = {}) => ({platform: "pecron", unique_id: `01J:dev1:${code}`, ...fields})
const community = (code) => ({platform: "pecron", unique_id: `pecron_ABC1_${code}`})
const monitor = (name) => ({platform: "mqtt", unique_id: `pecron_aabbccddeeff_${name}`})
const cloud = (key) => ({platform: "ecoflow_cloud", unique_id: `ecoflow-MR51ZAS-${key}`})
const ble = (key) => ({platform: "ef_ble", unique_id: `ef_DCABZ8_${key}`})

test("the power stations of each integration, and the entities of their parts", () => {
  assert.deepEqual(STATION_PARTS, {
    battery: ["sensor"], input: ["sensor"], output: ["sensor"], ac: ["switch"], dc: ["switch"],
    link: ["binary_sensor", "sensor"],
  })
  assert.deepEqual(STATION_SWITCHES, ["ac", "dc"])
  assert.equal(MAX_POWER, 1_000_000)
  assert.deepEqual(STATION_SOURCES.map((source) => [source.maker, source.platform]), [
    ["pecron", "pecron"], ["pecron", "mqtt"], ["ecoflow", "ecoflow_cloud"], ["ecoflow", "ef_ble"],
  ])
  // The names are not the models: the rule "others" reads the model.
  const models = {
    wave: "Wave 3", glacier: "GLACIER", wave2: "WAVE_2", wb: "Pecron WB12200", wbp: "WB12200", both: "E3800LFP",
  }
  const devices = ["e3800", "f5000", "monitor", "dp3", "ultra", "dpro", "wave", "half", "plug", "glacier", "wave2",
    "wb", "both", "wbp"]
    .map((id, index) => haDevice(id, {area_id: "garage", name: `Unit ${index}`, model: models[id] ?? null}))
  const entities = [
    haEntity("sensor.e3800_battery", "e3800", official("battery_percentage")),
    // A disabled entity does not count. A different code, a part in the
    // wrong domain, and an entity with no unique id: no part.
    haEntity("sensor.e3800_in_old", "e3800", official("total_input_power", {disabled_by: "user"})),
    haEntity("sensor.e3800_in", "e3800", official("total_input_power")),
    haEntity("sensor.e3800_out", "e3800", official("total_output_power")),
    haEntity("switch.e3800_ac", "e3800", official("ac_switch_hm")),
    haEntity("switch.e3800_dc", "e3800", official("dc_switch_hm")),
    haEntity("binary_sensor.e3800_online", "e3800", official("online")),
    haEntity("switch.e3800_online", "e3800", official("online")),
    haEntity("sensor.e3800_volts", "e3800", official("battery_voltage")),
    haEntity("sensor.e3800_ac", "e3800", official("ac_switch_hm")),
    haEntity("sensor.e3800_odd", "e3800", {platform: "pecron"}),
    // The integration of the community for Pecron is not a source.
    haEntity("sensor.f5000_battery", "f5000", community("battery_percentage")),
    haEntity("sensor.f5000_out", "f5000", community("total_output_power")),
    haEntity("switch.f5000_ac", "f5000", community("ac_switch")),
    // A switch with the unique id of a part, of a different platform.
    haEntity("switch.e3800_dc_2", "e3800", {platform: "template", unique_id: "01J:dev1:dc_switch_hm"}),
    // pecron-monitor does not tell the link. The temperature of its battery
    // is not its battery.
    haEntity("sensor.monitor_battery", "monitor", monitor("battery")),
    haEntity("sensor.monitor_battery_temp", "monitor", monitor("battery_temp")),
    haEntity("sensor.monitor_in", "monitor", monitor("total_input")),
    haEntity("sensor.monitor_out", "monitor", monitor("total_output")),
    haEntity("switch.monitor_ac", "monitor", monitor("ac")),
    haEntity("switch.monitor_dc", "monitor", monitor("dc")),
    haEntity("switch.monitor_ups", "monitor", monitor("ups")),
    // The battery of all the packs, not of the main pack. Two AC outlets,
    // and the 12 V outlets. The 24 V outlet is not a part.
    haEntity("sensor.dp3_battery", "dp3", cloud("cms-batt-soc")),
    haEntity("sensor.dp3_main", "dp3", cloud("bms-batt-soc")),
    haEntity("sensor.dp3_in", "dp3", cloud("pow-in-sum-w")),
    haEntity("sensor.dp3_out", "dp3", cloud("pow-out-sum-w")),
    haEntity("switch.dp3_lv", "dp3", cloud("cfg-lv-ac-out-open")),
    haEntity("switch.dp3_hv", "dp3", cloud("cfg-hv-ac-out-open")),
    haEntity("switch.dp3_12v", "dp3", cloud("cfg-dc-12v-out-open")),
    haEntity("switch.dp3_24v", "dp3", cloud("cfg-dc-24v-out-open")),
    haEntity("sensor.dp3_status", "dp3", cloud("status")),
    // The public API of EcoFlow: no switch of the outlets.
    haEntity("sensor.ultra_battery", "ultra", {platform: "ecoflow_cloud", unique_id: "ecoflow-api-Y711Z-hs-yj751-pd-appshow-addr-soc"}),
    haEntity("sensor.ultra_out", "ultra", {platform: "ecoflow_cloud", unique_id: "ecoflow-api-Y711Z-hs-yj751-pd-appshow-addr-wattsOutSum"}),
    haEntity("sensor.ultra_status", "ultra", {platform: "ecoflow_cloud", unique_id: "ecoflow-api-Y711Z-status"}),
    // EcoFlow BLE: the battery is also the link. The battery of the main
    // pack and of an extra pack are not the battery.
    haEntity("sensor.dpro_battery", "dpro", ble("battery_level")),
    haEntity("sensor.dpro_main", "dpro", ble("battery_level_main")),
    haEntity("sensor.dpro_pack", "dpro", ble("battery_1_battery_level")),
    haEntity("sensor.dpro_in", "dpro", ble("input_power")),
    haEntity("sensor.dpro_out", "dpro", ble("output_power")),
    haEntity("switch.dpro_ac", "dpro", ble("ac_ports")),
    haEntity("switch.dpro_ac2", "dpro", ble("ac_ports_2")),
    haEntity("switch.dpro_dc", "dpro", ble("dc_12v_port")),
    haEntity("switch.dpro_usb", "dpro", ble("usb_ports")),
    // A Wave and a Glacier have a battery and a power out, but they are
    // not stations. A WB12200 of pecron-monitor is not a station either. A
    // battery with no power out is not a station.
    haEntity("sensor.wave_battery", "wave", ble("battery_level")),
    haEntity("sensor.wave_out", "wave", ble("output_power")),
    haEntity("sensor.glacier_battery", "glacier", cloud("bms-emsStatus-lcdShowSoc")),
    haEntity("sensor.glacier_out", "glacier", cloud("pd-wattsOutSum")),
    haEntity("sensor.wave2_battery", "wave2", cloud("pd-soc")),
    haEntity("sensor.wave2_out", "wave2", cloud("pd-wattsOutSum")),
    haEntity("sensor.wb_battery", "wb", monitor("battery")),
    haEntity("sensor.wb_out", "wb", monitor("total_output")),
    haEntity("switch.wb_ac", "wb", monitor("ac")),
    haEntity("sensor.half_battery", "half", monitor("battery")),
    haEntity("sensor.wbp_battery", "wbp", official("battery_percentage")),
    haEntity("sensor.wbp_out", "wbp", official("total_output_power")),
    haEntity("switch.plug", "plug", {platform: "tplink", unique_id: "ac_switch"}),
    // A station of pecron-monitor and of the integration of Pecron: all
    // its parts come from the first source, the integration of Pecron.
    haEntity("sensor.both_monitor_battery", "both", monitor("battery")),
    haEntity("sensor.both_monitor_out", "both", monitor("total_output")),
    haEntity("switch.both_monitor_ac", "both", monitor("ac")),
    haEntity("sensor.both_battery", "both", official("battery_percentage")),
    haEntity("sensor.both_out", "both", official("total_output_power")),
  ]
  const stations = stationList(devices, entities)
  assert.deepEqual([...stations], [
    ["e3800", {maker: "pecron", parts: {
      battery: ["sensor.e3800_battery"], input: ["sensor.e3800_in"], output: ["sensor.e3800_out"],
      ac: ["switch.e3800_ac"], dc: ["switch.e3800_dc"], link: ["binary_sensor.e3800_online"],
    }}],
    ["monitor", {maker: "pecron", parts: {
      battery: ["sensor.monitor_battery"], input: ["sensor.monitor_in"], output: ["sensor.monitor_out"],
      ac: ["switch.monitor_ac"], dc: ["switch.monitor_dc"],
    }}],
    ["dp3", {maker: "ecoflow", parts: {
      battery: ["sensor.dp3_battery"], input: ["sensor.dp3_in"], output: ["sensor.dp3_out"],
      ac: ["switch.dp3_hv", "switch.dp3_lv"], dc: ["switch.dp3_12v"], link: ["sensor.dp3_status"],
    }}],
    ["ultra", {maker: "ecoflow", parts: {
      battery: ["sensor.ultra_battery"], output: ["sensor.ultra_out"], link: ["sensor.ultra_status"],
    }}],
    ["dpro", {maker: "ecoflow", parts: {
      battery: ["sensor.dpro_battery"], input: ["sensor.dpro_in"], output: ["sensor.dpro_out"],
      ac: ["switch.dpro_ac", "switch.dpro_ac2"], dc: ["switch.dpro_dc"], link: ["sensor.dpro_battery"],
    }}],
    ["both", {maker: "pecron", parts: {battery: ["sensor.both_battery"], output: ["sensor.both_out"]}}],
  ])
  // The list of the devices has the maker of each station.
  assert.deepEqual(deviceList(devices, entities).map((device) => [device.id, device.station]), [
    ["e3800", "pecron"], ["f5000", null], ["monitor", "pecron"], ["dp3", "ecoflow"], ["ultra", "ecoflow"],
    ["dpro", "ecoflow"], ["wave", null], ["half", null], ["plug", null], ["glacier", null], ["wave2", null],
    ["wb", null], ["both", "pecron"], ["wbp", null],
  ])

  // The numbers of the sensors, and the states of the switches. A part
  // that the station does not have is null. The AC outlets of a DELTA Pro
  // 3 are on when one of them is on.
  const states = new Map([
    ["sensor.e3800_battery", "82"], ["sensor.e3800_in", "12.5"], ["sensor.e3800_out", "unavailable"],
    ["switch.e3800_ac", "on"], ["switch.e3800_dc", "unknown"], ["binary_sensor.e3800_online", "off"],
    ["sensor.monitor_battery", "unknown"], ["switch.monitor_ac", "off"], ["sensor.dp3_battery", "40"],
    ["switch.dp3_hv", "off"], ["switch.dp3_lv", "on"], ["switch.dp3_12v", "off"], ["sensor.dp3_status", "online"],
    ["sensor.ultra_status", "assume_offline"], ["sensor.dpro_battery", "unavailable"],
  ])
  const parts = new Map([...stations].map(([id, station]) => [id, station.parts]))
  const shown = stationStates(parts, states)
  assert.deepEqual(shown.e3800, {battery: 82, input: 12.5, output: null, ac: "on", dc: "unavailable", link: false})
  assert.deepEqual(shown.monitor, {battery: null, input: null, output: null, ac: "off", dc: "unavailable", link: null})
  assert.deepEqual(shown.dp3, {battery: 40, input: null, output: null, ac: "on", dc: "off", link: true})
  assert.deepEqual(shown.ultra, {battery: null, input: null, output: null, ac: null, dc: null, link: false})
  assert.deepEqual(shown.dpro, {battery: null, input: null, output: null, ac: "unavailable", dc: "unavailable", link: false})
})

test("the unique id of each key of each integration gives its part, and other keys give none", () => {
  // The parts of an entity: a station of the source, with a battery and a
  // power out, and the entity "x" to check. This table is the list of the
  // keys of the integrations, not a copy of STATION_SOURCES.
  const bases = {
    pecron: [official("battery_percentage"), official("total_output_power")],
    mqtt: [monitor("battery"), monitor("total_output")],
    ecoflow_cloud: [cloud("pd-soc"), cloud("pd-wattsOutSum")],
    ef_ble: [ble("battery_level"), ble("output_power")],
  }
  const partsOf = (platform, uniqueId, domain) => {
    const [battery, output] = bases[platform]
    const entities = [
      haEntity("sensor.base_battery", "s", battery), haEntity("sensor.base_out", "s", output),
      haEntity(`${domain}.x`, "s", {platform, unique_id: uniqueId}),
    ]
    const station = stationList([haDevice("s")], entities).get("s")
    return Object.entries(station.parts).filter(([, ids]) => ids.includes(`${domain}.x`)).map(([part]) => part)
  }
  const keys = [
    ["pecron", "01J:dev1:battery_percentage", "sensor", ["battery"]],
    ["pecron", "01J:dev1:total_input_power", "sensor", ["input"]],
    ["pecron", "01J:dev1:total_output_power", "sensor", ["output"]],
    ["pecron", "01J:dev1:ac_switch_hm", "switch", ["ac"]],
    ["pecron", "01J:dev1:dc_switch_hm", "switch", ["dc"]],
    ["pecron", "01J:dev1:online", "binary_sensor", ["link"]],
    ["pecron", "01J:dev1online", "binary_sensor", []],
    ["pecron", "01J:dev1:battery_voltage", "sensor", []],
    ["pecron", "01J:dev1:ac_output_power", "sensor", []],
    ["pecron", "01J:dev1:online_time", "binary_sensor", []],
    ["pecron", "pecron_ABC1_battery_percentage", "sensor", []],
    ["mqtt", "pecron_aabbccddeeff_battery", "sensor", ["battery"]],
    ["mqtt", "pecron_aabbccddeeff_total_input", "sensor", ["input"]],
    ["mqtt", "pecron_aabbccddeeff_total_output", "sensor", ["output"]],
    ["mqtt", "pecron_aabbccddeeff_ac", "switch", ["ac"]],
    ["mqtt", "pecron_aabbccddeeff_dc", "switch", ["dc"]],
    ["mqtt", "pecron_aabbccddeeff_battery_temp", "sensor", []],
    ["mqtt", "pecron_aabbccddeeff_host_battery", "sensor", []],
    ["mqtt", "pecron_aabbccddeeff_ac_output", "sensor", []],
    ["mqtt", "pecron_aabbccddeeff_ups", "switch", []],
    ["mqtt", "pecron_aabbccddeeff_online", "binary_sensor", []],
    ...[
      "ems-lcdShowSoc", "bms-emsStatus-lcdShowSoc", "cms-batt-soc", "cmsBattSoc", "pd-soc",
      "hs-yj751-pd-appshow-addr-soc",
    ].map((key) => ["ecoflow_cloud", `ecoflow-MR51ZAS-${key}`, "sensor", ["battery"]]),
    ...["pd-wattsInSum", "pow-in-sum-w", "powInSumW", "hs-yj751-pd-appshow-addr-wattsInSum"]
      .map((key) => ["ecoflow_cloud", `ecoflow-api-MR51ZAS-${key}`, "sensor", ["input"]]),
    ...["pd-wattsOutSum", "pow-out-sum-w", "powOutSumW", "hs-yj751-pd-appshow-addr-wattsOutSum"]
      .map((key) => ["ecoflow_cloud", `ecoflow-MR51ZAS-${key}`, "sensor", ["output"]]),
    ...[
      "inv-cfgAcEnabled", "mppt-cfgAcEnabled", "cfg-ac-out-open", "cfg-hv-ac-out-open", "cfg-lv-ac-out-open",
      "cfgHvAcOutOpen", "cfgLvAcOutOpen", "flowInfoAcOut", "flowInfoAc2Out",
    ].map((key) => ["ecoflow_cloud", `ecoflow-MR51ZAS-${key}`, "switch", ["ac"]]),
    ...[
      "mppt-carState", "pd-carState", "pd-carSwitch", "cfg-dc12v-out-open", "cfg-dc-12v-out-open",
      "cfgDc12vOutOpen", "flowInfo12v",
    ].map((key) => ["ecoflow_cloud", `ecoflow-MR51ZAS-${key}`, "switch", ["dc"]]),
    ["ecoflow_cloud", "ecoflow-MR51ZAS-status", "sensor", ["link"]],
    ["ecoflow_cloud", "ecoflow-api-MR51ZAS-status", "sensor", ["link"]],
    ["ecoflow_cloud", "ecoflow-api-Y711ZAS-status-scheduled", "sensor", ["link"]],
    ["ecoflow_cloud", "ecoflow-MR51ZAS-statusx", "sensor", []],
    ["ecoflow_cloud", "ecoflow-MR51ZAS-status-scheduledx", "sensor", []],
    ...[
      "bms-batt-soc", "bmsMaster-soc", "inv-soc", "pd-wattsInSumX", "cfgAcOutOpen", "cfgAc2OutOpen",
      "cfg-dc-24v-out-open", "cfgDc24vOutOpen", "pd-dcOutState", "cfg-usb-open", "pd-status-x",
    ].map((key) => ["ecoflow_cloud", `ecoflow-MR51ZAS-${key}`, key.startsWith("cfg") || key.startsWith("pd-dc") ? "switch" : "sensor", []]),
    ["ecoflow_cloud", "ecoflow-MR51ZAS-x-status", "sensor", []],
    ["ef_ble", "ef_DCABZ8_battery_level", "sensor", ["battery", "link"]],
    ["ef_ble", "ef_DCABZ8_input_power", "sensor", ["input"]],
    ["ef_ble", "ef_DCABZ8_output_power", "sensor", ["output"]],
    ...["ac_ports", "ac_ports_2", "ac_lv_port", "ac_hv_port"]
      .map((key) => ["ef_ble", `ef_DCABZ8_${key}`, "switch", ["ac"]]),
    ["ef_ble", "ef_DCABZ8_dc_12v_port", "switch", ["dc"]],
    ["ef_ble", "ef_DCABZ8_dc_ports", "switch", []],
    ["ef_ble", "ef_DCABZ8_usb_ports", "switch", []],
    ["ef_ble", "ef_DCABZ8_battery_level_main", "sensor", []],
    ["ef_ble", "ef_DCABZ8_battery_1_battery_level", "sensor", []],
    ["ef_ble", "ef_DCABZ8_ac_port", "switch", []],
  ]
  for (const [platform, uniqueId, domain, expected] of keys) {
    assert.deepEqual(partsOf(platform, uniqueId, domain), expected, `${platform} ${uniqueId}`)
  }
})

test("a sensor gives the first number of its entities, in W or %, in its range", () => {
  const parts = new Map([["s", {
    battery: ["sensor.b1", "sensor.b2", "sensor.b3"], input: ["sensor.in"], output: ["sensor.out"],
  }]])
  const shown = (states, units = new Map()) => stationStates(parts, new Map(Object.entries(states)), units).s
  // The first entity with a number, in the order of the ids.
  assert.equal(shown({"sensor.b1": "unknown", "sensor.b2": "81", "sensor.b3": "70"}).battery, 81)
  assert.equal(shown({"sensor.b1": "12", "sensor.b2": "81"}).battery, 12)
  // The units: % for a battery, and W or kW for a power. No unit is W or
  // %. A different unit is not known.
  const units = (entries) => new Map(Object.entries(entries))
  assert.deepEqual(shown({"sensor.b1": "50", "sensor.in": "1.25", "sensor.out": "300"},
    units({"sensor.b1": "%", "sensor.in": "kW", "sensor.out": "W"})), {
    battery: 50, input: 1250, output: 300, ac: null, dc: null, link: null,
  })
  assert.deepEqual(shown({"sensor.b1": "50", "sensor.in": "1.25", "sensor.out": "300"},
    units({"sensor.b1": "W", "sensor.in": "Wh", "sensor.out": "toString"})), {
    battery: null, input: null, output: null, ac: null, dc: null, link: null,
  })
  // The ranges: a battery from 0 to 100, and a power from 0 to MAX_POWER.
  assert.deepEqual(shown({"sensor.b1": "100", "sensor.in": "0", "sensor.out": "1000000"}), {
    battery: 100, input: 0, output: 1_000_000, ac: null, dc: null, link: null,
  })
  assert.deepEqual(shown({"sensor.b1": "100.5", "sensor.in": "-5", "sensor.out": "1000001"}), {
    battery: null, input: null, output: null, ac: null, dc: null, link: null,
  })
  assert.deepEqual(shown({"sensor.b1": "-1", "sensor.in": "1000", "sensor.out": "1000.001"},
    units({"sensor.in": "kW", "sensor.out": "kW"})), {
    battery: null, input: 1_000_000, output: null, ac: null, dc: null, link: null,
  })
})

test("the link of a station: on, online or a number, else off, offline or unavailable", () => {
  const link = (...values) => {
    const ids = values.map((_value, i) => `sensor.l${i}`)
    const states = new Map(values.map((value, i) => [`sensor.l${i}`, value]))
    return stationStates(new Map([["s", {link: ids}]]), states).s.link
  }
  assert.equal(link("on"), true)
  assert.equal(link("online"), true)
  assert.equal(link("57"), true)
  assert.equal(link("off"), false)
  assert.equal(link("offline"), false)
  assert.equal(link("assume_offline"), false)
  assert.equal(link("unavailable"), false)
  assert.equal(link("unknown"), null)
  assert.equal(link(undefined), null)
  assert.equal(link("off", "on"), true)
  assert.equal(link("unknown", "off"), false)
})

test("each part of a station is an entity of its source, and each state is a state of the page", () => {
  const ids = ["sensor.a", "sensor.b", "sensor.c", "switch.a", "switch.b", "binary_sensor.a"]
  const uniques = [
    "x:y:battery_percentage", "x:y:total_output_power", "pecron_K_total_input_power", "pecron_K_ac_switch",
    "pecron_aabb_battery", "pecron_aabb_total_output", "pecron_aabb_dc", "ecoflow-S1-pd-soc",
    "ecoflow-S1-pd-wattsOutSum", "ecoflow-S1-inv-cfgAcEnabled", "ef_S1_battery_level", "ef_S1_output_power",
    "ef_S1_ac_ports", "ef_S1_battery_1_battery_level", "x:y:battery_voltage", "x:y:online", "ecoflow-S1-status",
  ]
  const entity = fc.record({
    entity_id: fc.constantFrom(...ids),
    device_id: fc.constantFrom("s1", "s2", "s3"),
    platform: fc.constantFrom("pecron", "mqtt", "ecoflow_cloud", "ef_ble", "other"),
    unique_id: fc.constantFrom(...uniques),
    disabled_by: fc.constantFrom(null, "user"),
  })
  const devices = [{id: "s1", model: null}, {id: "s2", model: "Wave 3"}, {id: "s3", model: "WB12200"}]
  const value = fc.constantFrom("on", "off", "online", "offline", "unknown", "unavailable", "0", "57", "100",
    "101", "1e3", "1000000", "1e7", "-4.5", "")
  const unit = fc.constantFrom("W", "kW", "%", "Wh")
  fc.assert(fc.property(fc.array(entity), fc.dictionary(fc.constantFrom(...ids), value),
    fc.dictionary(fc.constantFrom(...ids), unit), (entities, raw, rawUnits) => {
      const stations = stationList(devices, entities)
      for (const device of devices) {
        // The first source that gives a battery and a power out.
        const live = entities.filter((one) => one.device_id === device.id && !one.disabled_by)
        const gives = (source, part) => live.some((one) => one.platform === source.platform &&
          STATION_PARTS[part].includes(one.entity_id.split(".")[0]) && source.parts[part].test(one.unique_id))
        const source = STATION_SOURCES.find((source) => !source.others?.test(device.model ?? "") &&
          gives(source, "battery") && gives(source, "output"))
        assert.equal(stations.get(device.id)?.maker, source?.maker)
        for (const [part, own] of Object.entries(stations.get(device.id)?.parts ?? {})) {
          assert.deepEqual(own, [...own].sort())
          for (const id of own) {
            assert.ok(live.some((one) => one.entity_id === id && one.platform === source.platform &&
              source.parts[part].test(one.unique_id)), `${device.id} ${part} ${id}`)
            assert.ok(STATION_PARTS[part].includes(id.split(".")[0]))
          }
        }
      }
      const states = new Map(Object.entries(raw))
      const units = new Map(Object.entries(rawUnits))
      const parts = new Map([...stations].map(([id, station]) => [id, station.parts]))
      const result = stationStates(parts, states, units)
      for (const [device, own] of parts) {
        for (const part of Object.keys(STATION_PARTS)) {
          const shown = result[device][part]
          const values = (own[part] ?? []).map((id) => states.get(id))
          const first = (own[part] ?? []).find((id) => Number.isFinite(Number.parseFloat(states.get(id))))
          if (!own[part]) assert.equal(shown, null)
          else if (STATION_SWITCHES.includes(part)) {
            assert.equal(shown, values.includes("on") ? "on" : values.includes("off") ? "off" : "unavailable")
          } else if (part === "link") {
            const expected = first !== undefined || values.some((one) => ["on", "online"].includes(one)) ? true
              : values.some((one) => ["off", "offline", "unavailable"].includes(one)) ? false : null
            assert.equal(shown, expected)
          } else if (first === undefined) {
            assert.equal(shown, null)
          } else {
            // The first number, in its unit, in its range: else null.
            const number = Number.parseFloat(states.get(first))
            const factor = part === "battery" ? {undefined: 1, "%": 1}[units.get(first)]
              : {undefined: 1, W: 1, kW: 1000}[units.get(first)]
            const top = part === "battery" ? 100 : MAX_POWER
            const expected = factor !== undefined && number * factor >= 0 && number * factor <= top ? number * factor : null
            assert.equal(shown, expected)
            if (shown !== null) assert.ok(shown >= 0 && shown <= top)
          }
        }
      }
    }))
})

// A Home Assistant with a lamp, a power station of Pecron and a DELTA Pro
// 3 of EcoFlow in the garage. The station of Pecron has a battery, its
// power out, two switches and its link. The DELTA Pro 3 has two AC
// outlets. The sensors have their units.
const garage = (extra = {}) => registry({
  areas: [{area_id: "garage", name: "Garage"}],
  devices: [
    haDevice("lamp", {area_id: "garage"}), haDevice("e3800", {area_id: "garage", model: "E3800LFP"}),
    haDevice("dp3", {area_id: "garage", model: "DELTA_PRO_3"}),
  ],
  entities: [
    haEntity("light.lamp", "lamp"),
    haEntity("sensor.e3800_battery", "e3800", official("battery_percentage")),
    haEntity("sensor.e3800_out", "e3800", official("total_output_power")),
    haEntity("switch.e3800_ac", "e3800", official("ac_switch_hm")),
    haEntity("switch.e3800_dc", "e3800", official("dc_switch_hm")),
    haEntity("binary_sensor.e3800_online", "e3800", official("online")),
    haEntity("sensor.dp3_battery", "dp3", cloud("cms-batt-soc")),
    haEntity("sensor.dp3_out", "dp3", cloud("pow-out-sum-w")),
    haEntity("switch.dp3_hv", "dp3", cloud("cfg-hv-ac-out-open")),
    haEntity("switch.dp3_lv", "dp3", cloud("cfg-lv-ac-out-open")),
  ],
  states: {
    "light.lamp": "on", "sensor.e3800_battery": "64", "sensor.e3800_out": "350",
    "switch.e3800_ac": "on", "switch.e3800_dc": "off", "binary_sensor.e3800_online": "on",
    "sensor.dp3_battery": "90", "sensor.dp3_out": "2.5", "switch.dp3_hv": "on", "switch.dp3_lv": "off",
  },
  attributes: {
    "light.lamp": {brightness: 200}, "sensor.e3800_battery": {unit_of_measurement: "%"},
    "sensor.e3800_out": {unit_of_measurement: "W"}, "sensor.dp3_out": {unit_of_measurement: "kW"},
  },
  ...extra,
})

// The last parts of the stations that the hook sent to the LiveView.
const lastStations = (page) => page.pushes.findLast(([event]) => event === "ha:stations")?.[1].stations

test("the hook watches the parts of the stations, and turns their AC and DC outlets on and off", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const ha = garage()
  const read = link.devices()
  await serve(ha, [socket])
  await read
  tick(page)

  // One watch for the lamp and the parts of the stations. The switches of
  // a station are not a switch of the whole device.
  const watch = socket.sent.find((message) => message.type === "subscribe_entities")
  assert.deepEqual(watch.entity_ids, [
    "binary_sensor.e3800_online", "light.lamp", "sensor.dp3_battery", "sensor.dp3_out", "sensor.e3800_battery",
    "sensor.e3800_out", "switch.dp3_hv", "switch.dp3_lv", "switch.e3800_ac", "switch.e3800_dc",
  ])
  assert.deepEqual(lastStates(page), {lamp: "on"})
  assert.deepEqual(lastStations(page), {
    e3800: {battery: 64, input: null, output: 350, ac: "on", dc: "off", link: true},
    dp3: {battery: 90, input: null, output: 2500, ac: "on", dc: null, link: null},
  })

  // A new number of the battery.
  ha.set("sensor.e3800_battery", "63")
  tick(page)
  assert.equal(lastStations(page).e3800.battery, 63)

  // A new unit: the power in kW becomes W. A change of the other
  // attributes sends nothing. With no unit, the power is in W.
  const sent = page.pushes.length
  ha.change("sensor.e3800_out", {"+": {a: {unit_of_measurement: "kW"}}})
  tick(page)
  assert.equal(lastStations(page).e3800.output, 350_000)
  ha.change("sensor.e3800_out", {"+": {a: {icon: "mdi:flash", unit_of_measurement: "kW"}}})
  ha.change("light.lamp", {"+": {a: {brightness: 3}}})
  tick(page)
  assert.equal(page.pushes.length, sent + 2)
  // A change of a different attribute keeps the unit.
  ha.change("sensor.e3800_out", {"+": {a: {friendly_name: "Out"}}, "-": {a: ["icon"]}})
  ha.set("sensor.e3800_out", "0.35")
  tick(page)
  assert.equal(lastStations(page).e3800.output, 350)
  ha.set("sensor.e3800_out", "350")
  tick(page)
  ha.change("sensor.e3800_out", {"-": {a: ["unit_of_measurement"]}})
  tick(page)
  assert.equal(lastStations(page).e3800.output, 350)
  ha.change("sensor.e3800_out", {"+": {a: {unit_of_measurement: "MWh"}}})
  tick(page)
  assert.equal(lastStations(page).e3800.output, null)
  ha.change("sensor.e3800_out", {"+": {a: {unit_of_measurement: "W"}}})
  tick(page)

  // The station goes offline: its link is false, and its numbers stay.
  ha.set("binary_sensor.e3800_online", "off")
  tick(page)
  assert.deepEqual(lastStations(page).e3800, {battery: 63, input: null, output: 350, ac: "on", dc: "off", link: false})
  ha.set("binary_sensor.e3800_online", "on")
  tick(page)

  // The AC outlets go off: one call for their switch only. The new state
  // comes before the end.
  const done = link.control("e3800", false, "ac")
  await serve(ha, [socket])
  await done
  assert.deepEqual(ha.calls, [{domain: "switch", service: "turn_off", ids: ["switch.e3800_ac"]}])
  assert.deepEqual(page.pushes.slice(-3), [
    ["ha:states", {states: {lamp: "on"}}],
    ["ha:stations", {stations: {
      e3800: {battery: 63, input: null, output: 350, ac: "off", dc: "off", link: true},
      dp3: {battery: 90, input: null, output: 2500, ac: "on", dc: null, link: null},
    }}],
    ["ha:control_done", {device: "e3800", part: "ac", error: null}],
  ])

  // The AC outlets of 120 V and of 240 V of the DELTA Pro 3 go off
  // together.
  ha.calls = []
  const both = link.control("dp3", false, "ac")
  await serve(ha, [socket])
  await both
  assert.deepEqual(ha.calls, [{domain: "switch", service: "turn_off", ids: ["switch.dp3_hv", "switch.dp3_lv"]}])
  assert.equal(lastStations(page).dp3.ac, "off")

  // The hook does not know three controls: a part that the station does
  // not have, a part of a lamp, and the whole station.
  ha.calls = []
  await link.control("lamp", true, "ac")
  assert.deepEqual(page.pushes.at(-1), ["ha:control_done", {device: "lamp", part: "ac", error: "failed"}])
  await link.control("dp3", true, "dc")
  assert.deepEqual(page.pushes.at(-1), ["ha:control_done", {device: "dp3", part: "dc", error: "failed"}])
  await link.control("e3800", true)
  assert.deepEqual(page.pushes.at(-1), ["ha:control_done", {device: "e3800", part: null, error: "failed"}])
  assert.deepEqual(ha.calls, [])
  link.stop()

  // The LiveView asks for a control of a part. A part that is not a
  // switch is no part.
  const other = parts()
  const handlers = {}
  const hook = homeAssistantHook(() => other.deps)
  const self = {...hook, pushEvent: (event, payload) => other.pushes.push([event, payload]), handleEvent: (event, f) => { handlers[event] = f }}
  self.mounted()
  await handlers["ha:control"]({device: "e3800", on: true, part: "dc"})
  assert.deepEqual(other.pushes.at(-1), ["ha:control_done", {device: "e3800", part: "dc", error: "failed"}])
  await handlers["ha:control"]({device: "e3800", on: true, part: "battery"})
  assert.deepEqual(other.pushes.at(-1), ["ha:control_done", {device: "e3800", part: null, error: "failed"}])
  self.destroyed()
})

test("the hook sends the stations when Home Assistant has one, and one time more to clear them", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const read = async (ha) => {
    const done = link.devices()
    await serve(ha, [socket])
    await done
    tick(page)
  }
  const sent = () => page.pushes.filter(([event]) => event === "ha:stations").length

  // No station: no message of the stations.
  await read(home())
  assert.equal(sent(), 0)
  await read(garage())
  assert.equal(Object.keys(lastStations(page)).length, 2)

  // The stations go, and no entity is left to watch: the page gets no
  // station, one time.
  const bare = registry({
    devices: [haDevice("tv", {area_id: "living"})], entities: [haEntity("media_player.tv", "tv")],
  })
  await read(bare)
  assert.deepEqual(lastStates(page), {})
  assert.deepEqual(lastStations(page), {})
  const count = sent()
  await read(home())
  assert.equal(sent(), count)
  link.stop()
})

test("a new part of a station starts a new watch, also when the controls stay", async () => {
  const page = parts()
  const {link, socket} = await connected(page)
  const read = async (ha) => {
    const done = link.devices()
    await serve(ha, [socket])
    await done
    tick(page)
  }
  const watches = () => socket.sent.filter((message) => message.type === "subscribe_entities")
  await read(garage())
  assert.equal(watches().length, 1)

  // The DELTA Pro 3 gets its 12 V outlets. The lamp stays the only
  // control.
  const more = garage()
  more.entities.push(haEntity("switch.dp3_12v", "dp3", cloud("cfg-dc-12v-out-open")))
  more.states["switch.dp3_12v"] = "on"
  await read(more)
  assert.equal(watches().length, 2)
  assert.ok(watches()[1].entity_ids.includes("switch.dp3_12v"))
  assert.equal(lastStations(page).dp3.dc, "on")
  link.stop()
})

test("after any steps, the LiveView gets the states of Home Assistant, and none while the socket is closed", async () => {
  const entity = fc.constantFrom("light.lamp", "switch.plug", "fan.fan", "light.hall")
  const step = fc.oneof(
    fc.record({kind: fc.constant("set"), entity, state: fc.constantFrom("on", "off", "unavailable")}),
    fc.record({kind: fc.constant("gone"), entity}),
    fc.record({kind: fc.constant("control"), device: fc.constantFrom("lamp", "plug", "fan", "hall"), on: fc.boolean()}),
    fc.record({kind: fc.constant("hall"), add: fc.boolean()}),
    fc.constant({kind: "drop"}),
    fc.constant({kind: "reconnect"}),
    fc.constant({kind: "tick"}),
  )
  await fc.assert(fc.asyncProperty(fc.array(step, {maxLength: 14}), fc.array(fc.nat(5), {maxLength: 30}), async (steps, picks) => {
    const page = parts()
    let {link, socket} = await connected(page)
    let open = true
    const ha = home()
    let pick = 0
    const order = () => picks[pick++ % Math.max(picks.length, 1)] ?? 0
    // The LiveView reads the devices when the link is connected, and after
    // a change of a registry.
    const read = async () => {
      const done = link.devices()
      await serve(ha, [socket], order)
      await done
    }
    await read()
    const pending = []
    for (const one of steps) {
      if (one.kind === "set") {
        ha.set(one.entity, one.state)
      } else if (one.kind === "gone") {
        // Home Assistant has no state of the entity now.
        delete ha.states[one.entity]
        for (const watch of ha.watches.filter((watch) => watch.ids.includes(one.entity))) {
          watch.socket.receive({id: watch.id, type: "event", event: {r: [one.entity]}})
        }
      } else if (one.kind === "control") {
        pending.push(link.control(one.device, one.on))
        if (open) await serve(ha, [socket], order)
      } else if (one.kind === "hall") {
        const has = ha.devices.some((device) => device.id === "hall")
        if (one.add && !has) {
          ha.devices.push(haDevice("hall", {area_id: "living"}))
          ha.entities.push(haEntity("light.hall", "hall"))
        } else if (!one.add && has) {
          ha.devices = ha.devices.filter((device) => device.id !== "hall")
          ha.entities = ha.entities.filter((entity) => entity.device_id !== "hall")
        }
        if (open) await read()
      } else if (one.kind === "drop" && open) {
        // Home Assistant ends the watches of a closed socket.
        socket.drop()
        ha.watches = ha.watches.filter((watch) => watch.socket !== socket)
        open = false
      } else if (one.kind === "reconnect" && !open) {
        socket = await reconnect(page)
        open = true
        await read()
      } else if (one.kind === "tick" && open) {
        tick(page)
      }
    }
    if (!open) {
      socket = await reconnect(page)
      await read()
    }
    await serve(ha, [socket], order)
    await Promise.all(pending)
    tick(page)

    // Quiet now: the last states are the states of Home Assistant, and
    // Home Assistant has one watch of the states at most.
    const controls = controlList(deviceList(ha.devices, ha.entities), ha.entities)
    assert.deepEqual(lastStates(page), deviceStates(controls, new Map(Object.entries(ha.states))))
    assert.ok(ha.watches.length <= 1)

    // Between a status that is not connected and the next connected one,
    // no states.
    let connectedNow = true
    for (const [event, payload] of page.pushes) {
      if (event === "ha:status") connectedNow = payload.state === "connected"
      if (event === "ha:states") assert.ok(connectedNow)
    }
    link.stop()
  }), {numRuns: 80})
})

// The start of a day in Chicago in October 2026 (daylight time: UTC-5).
const chicago = (month, day) => Date.UTC(2026, month - 1, day, 5)

test("the sensors of the energy settings, and the months in the time zone of Home Assistant", () => {
  // No settings, then the new form of the settings, then the lists of the
  // old form. A sensor counts one time.
  assert.deepEqual(energySources(null), {from: [], to: [], devices: []})
  assert.deepEqual(energySources({
    energy_sources: [
      {type: "grid", stat_energy_from: "sensor.grid_in", stat_energy_to: "sensor.grid_out"},
      {type: "grid", stat_energy_from: "sensor.grid_in", stat_energy_to: null},
      {type: "solar", stat_energy_from: "sensor.solar"},
    ],
    device_consumption: [
      {stat_consumption: "sensor.fridge_energy", name: "Fridge"},
      {stat_consumption: "sensor.tv_energy"},
      {stat_consumption: 5},
    ],
  }), {
    from: ["sensor.grid_in"], to: ["sensor.grid_out"],
    devices: [{statistic: "sensor.fridge_energy", name: "Fridge"}, {statistic: "sensor.tv_energy", name: null}],
  })
  assert.deepEqual(energySources({
    energy_sources: [{type: "grid", flow_from: [{stat_energy_from: "a"}, {stat_energy_from: "b"}], flow_to: [{stat_energy_to: "c"}]}],
  }), {from: ["a", "b"], to: ["c"], devices: []})
  const many = {device_consumption: Array.from({length: MAX_ENERGY_DEVICES + 5}, (_, i) => ({stat_consumption: `sensor.e${i}`}))}
  assert.equal(energySources(many).devices.length, MAX_ENERGY_DEVICES)

  // A sensor that is a part of a different sensor of its device does not
  // count. A part of a sensor of a different device, or of a sensor that
  // the registry does not know, counts.
  const parts = {
    device_consumption: [
      {stat_consumption: "sensor.strip_total"},
      {stat_consumption: "sensor.strip_outlet_1", included_in_stat: "sensor.strip_total"},
      {stat_consumption: "sensor.lamp_energy", included_in_stat: "sensor.strip_total"},
      {stat_consumption: "sensor.unknown", included_in_stat: "sensor.other_unknown"},
      {stat_consumption: "sensor.tv_energy", included_in_stat: 7},
    ],
  }
  const registered = [
    haEntity("sensor.strip_total", "strip"), haEntity("sensor.strip_outlet_1", "strip"), haEntity("sensor.lamp_energy", "lamp"),
    haEntity("sensor.unknown", null), haEntity("sensor.other_unknown", null),
  ]
  assert.deepEqual(energySources(parts, registered).devices.map((one) => one.statistic),
    ["sensor.strip_total", "sensor.lamp_energy", "sensor.unknown", "sensor.tv_energy"])
  assert.equal(energySources(parts).devices.length, 5)

  // A time zone that the browser does not know is UTC.
  assert.equal(zoneOf("America/Chicago"), "America/Chicago")
  assert.equal(zoneOf("Mars/Base"), "UTC")
  assert.equal(zoneOf(null), "UTC")
  // 3 in the morning of the first of October in UTC is still September in
  // Chicago.
  assert.equal(monthOf(Date.UTC(2026, 9, 1, 3), "America/Chicago"), "2026-09")
  assert.equal(monthOf(Date.UTC(2026, 9, 1, 3), "UTC"), "2026-10")
  // The first month of the data: 24 or 13 months with this month.
  assert.equal(monthStart(Date.UTC(2026, 9, 11), METER_MONTHS), Date.UTC(2024, 10, 1))
  assert.equal(monthStart(Date.UTC(2026, 9, 11), DEVICE_MONTHS), Date.UTC(2025, 9, 1))
})

test("the months of the meter and of each device, from the rows of the statistics", () => {
  const stats = {
    "sensor.in": [
      {start: chicago(9, 29), end: 0, change: 10.5},
      {start: chicago(9, 30), end: 0, change: 12},
      {start: chicago(10, 1), end: 0, change: 9.25},
      {start: chicago(10, 2), end: 0, change: null},
      // A dip of the sensor at night: 1000 kWh, then 995, then 1001. The
      // month counts 1 kWh for the two days, not 6. The row with no change
      // has no sum: the next change is for its day too.
      {start: chicago(10, 3), end: 0, change: -5},
      {start: chicago(10, 4), end: 0, change: 6},
    ],
    "sensor.out": [{start: chicago(9, 30), end: 0, change: 3}, {start: chicago(10, 4), end: 0, change: 1.5}],
  }
  assert.deepEqual(meterMonths(stats, ["sensor.in"], ["sensor.out"], "America/Chicago"), [
    {month: "2026-09", kwh: 22.5, export: 3, days: 2},
    {month: "2026-10", kwh: 10.25, export: 1.5, days: 4},
  ])
  assert.deepEqual(meterMonths({}, ["sensor.in"], [], "UTC"), [])
  // A month under zero counts as zero.
  assert.deepEqual(meterMonths({in: [{start: chicago(11, 2), change: -3}]}, ["in"], [], "America/Chicago"),
    [{month: "2026-11", kwh: 0, export: 0, days: 1}])

  // Home Assistant stops from 1 to 15 April. When it starts again, the
  // first row has the kWh of all the days since the row before: they go
  // to these days. April has 720 kWh in its 30 days, not 720 kWh in 15
  // days.
  const april = (d) => Date.UTC(2026, 3, d, 5)
  const stop = {in: [{start: Date.UTC(2026, 2, 31, 5), change: 24}, {start: april(16), change: 24 * 16}]}
  for (let d = 17; d <= 30; d++) stop.in.push({start: april(d), change: 24})
  assert.deepEqual(meterMonths(stop, ["in"], [], "America/Chicago"), [
    {month: "2026-03", kwh: 24, export: 0, days: 1},
    {month: "2026-04", kwh: 720, export: 0, days: 30},
  ])
  // A stop over the end of a month: each month gets the kWh of its days.
  const end = {in: [{start: Date.UTC(2026, 2, 29, 5), change: 24}, {start: april(2), change: 96}]}
  assert.deepEqual(meterMonths(end, ["in"], [], "America/Chicago"), [
    {month: "2026-03", kwh: 72, export: 0, days: 3},
    {month: "2026-04", kwh: 48, export: 0, days: 2},
  ])
  // The date of a time in the time zone: 3 in the morning of 1 October in
  // UTC is 30 September in Chicago.
  assert.equal(dayOf(Date.UTC(2026, 9, 1, 3), "America/Chicago"), Date.UTC(2026, 8, 30) / 86_400_000)

  // The last METER_MONTHS months only: west of UTC, the statistics start
  // one month earlier, and DIY.Usage takes 24 months at most.
  const years = {in: Array.from({length: 26}, (_, i) => ({start: Date.UTC(2024, 8 + i, 15), change: 1}))}
  const kept = meterMonths(years, ["in"], [], "UTC")
  assert.equal(kept.length, METER_MONTHS)
  assert.equal(kept[0].month, "2024-11")
  assert.equal(kept.at(-1).month, "2026-10")

  // The months of each device: only a sensor of a device, with data. A
  // row with no time does not count.
  const entities = [
    haEntity("sensor.fridge_energy", "fridge"), haEntity("sensor.lost", "lost"), haEntity("sensor.alone", null),
  ]
  entities.push(haEntity("sensor.plug_energy", "plug"), haEntity("sensor.new_energy", "new"), haEntity("sensor.dip_energy", "dip"))
  const used = {
    // The first month of a sensor does not count: a new sensor has only a
    // part of it.
    "sensor.fridge_energy": [
      {start: chicago(10, 1), end: 0, change: 31},
      {start: chicago(9, 1), end: 0, change: 30.1234},
      {start: chicago(8, 1), end: 0, change: 29},
      {start: "today", end: 0, change: 5},
    ],
    // A plug that starts on 25 September: 6 days are not a month.
    "sensor.plug_energy": [{start: chicago(9, 1), end: 0, change: 144}, {start: chicago(10, 1), end: 0, change: 50}],
    // A sensor that starts this month: this month counts, as a part of a
    // month.
    "sensor.new_energy": [{start: chicago(10, 1), end: 0, change: 2}],
    // A month under zero counts as zero.
    "sensor.dip_energy": [{start: chicago(9, 1), end: 0, change: 8}, {start: chicago(10, 1), end: 0, change: -1}],
    "opower:meter": [{start: chicago(10, 1), end: 0, change: 900}],
    "sensor.alone": [{start: chicago(10, 1), end: 0, change: 4}],
  }
  const devices = [
    {statistic: "sensor.fridge_energy", name: "Fridge"},
    {statistic: "sensor.plug_energy", name: null},
    {statistic: "sensor.new_energy", name: null},
    {statistic: "sensor.dip_energy", name: null},
    {statistic: "opower:meter", name: null},
    {statistic: "sensor.lost", name: null},
    {statistic: "sensor.alone", name: null},
  ]
  assert.deepEqual(deviceEnergy(devices, null, entities, "UTC", "2026-10"), [])
  assert.deepEqual(deviceEnergy(devices, used, entities, "America/Chicago", "2026-10"), [
    {
      device: "fridge", statistic: "sensor.fridge_energy", name: "Fridge",
      months: [{month: "2026-09", kwh: 30.123}, {month: "2026-10", kwh: 31}],
    },
    {device: "plug", statistic: "sensor.plug_energy", name: null, months: [{month: "2026-10", kwh: 50}]},
    {device: "new", statistic: "sensor.new_energy", name: null, months: [{month: "2026-10", kwh: 2}]},
    {device: "dip", statistic: "sensor.dip_energy", name: null, months: [{month: "2026-10", kwh: 0}]},
  ])
  // The last DEVICE_MONTHS months only.
  const long = {"sensor.fridge_energy": Array.from({length: 20}, (_, i) => ({start: Date.UTC(2025, i, 15), change: 1}))}
  assert.equal(deviceEnergy(devices.slice(0, 1), long, entities, "UTC", "2026-08")[0].months.length, DEVICE_MONTHS)
})

test("the months of the meter keep the sum and the days of the rows", () => {
  const day = 86_400_000
  const row = fc.record({day: fc.nat(700), change: fc.option(fc.double({min: -5, max: 80, noNaN: true}), {nil: null})})
  fc.assert(fc.property(fc.array(row, {maxLength: 60}), fc.array(row, {maxLength: 30}), (from, to) => {
    const start = Date.UTC(2024, 10, 1)
    const rows = (list) => list.map(({day: d, change}) => ({start: start + d * day, end: 0, change}))
    const months = meterMonths({in: rows(from), out: rows(to)}, ["in"], ["out"], "UTC")
    // A model: the change of a row goes to the days since the row before.
    // The sum of each month, with zero for a month under zero, and the
    // days that the rows cover.
    const covered = new Set()
    const sum = (list) => {
      const each = new Map()
      let before = null
      for (const one of list.filter((row) => row.change !== null).sort((a, b) => a.day - b.day)) {
        const span = before === null ? 1 : Math.max(1, one.day - before)
        for (let back = 0; back < span; back++) {
          const month = monthOf(start + (one.day - back) * day, "UTC")
          each.set(month, (each.get(month) ?? 0) + one.change / span)
          covered.add(one.day - back)
        }
        before = one.day
      }
      return [...each.values()].reduce((total, kwh) => total + Math.max(kwh, 0), 0)
    }
    // 700 days are in 24 months: no month goes away.
    assert.ok(Math.abs(months.reduce((total, one) => total + one.kwh, 0) - sum(from)) < 0.01 * (months.length + 1))
    assert.ok(Math.abs(months.reduce((total, one) => total + one.export, 0) - sum(to)) < 0.01 * (months.length + 1))
    assert.equal(months.reduce((total, one) => total + one.days, 0), covered.size)
    assert.deepEqual(months.map((one) => one.month), [...new Set(months.map((one) => one.month))].sort())
    for (const one of months) assert.ok(one.days >= 1 && one.days <= 31 && one.kwh >= 0 && one.export >= 0)
  }))
})

test("the hook reads the energy data of Home Assistant", async () => {
  // The time zone comes with the configuration.
  const zone = parts()
  await keep(zone.deps.store, session())
  const linked = new Link(zone.deps)
  await linked.start()
  await settle()
  const first = FakeSocket.all.at(-1)
  first.receive({type: "auth_required", ha_version: "2026.10.0"})
  await settle()
  first.receive({type: "auth_ok", ha_version: "2026.10.0"})
  first.receive({id: 1, type: "result", success: true, result: {location_name: "Home", time_zone: "America/Chicago"}})
  await settle()
  assert.equal(linked.timeZone, "America/Chicago")
  linked.stop()

  const page = parts()
  const {link, socket} = await connected(page)
  link.timeZone = "America/Chicago"
  // 31 October 2026 at 20:00 in Chicago: it is 1 November in UTC. The
  // months are in the time zone of Home Assistant.
  page.clock = Date.UTC(2026, 10, 1, 1)
  const ha = registry({
    entities: [haEntity("sensor.fridge_energy", "fridge"), haEntity("sensor.fridge_compressor", "fridge")],
    prefs: {
      energy_sources: [{type: "grid", stat_energy_from: "sensor.in", stat_energy_to: "sensor.out"}],
      // The compressor is a part of the fridge: it does not count.
      device_consumption: [
        {stat_consumption: "sensor.fridge_energy", name: "Fridge"},
        {stat_consumption: "sensor.fridge_compressor", included_in_stat: "sensor.fridge_energy"},
      ],
    },
    statistics: {
      // 3 in the morning of 1 October in UTC is 30 September in Chicago.
      "sensor.in": {day: [
        {start: Date.UTC(2026, 9, 1, 3), end: 0, change: 7},
        {start: chicago(10, 1), end: 0, change: 20},
        {start: chicago(10, 2), end: 0, change: 22},
      ]},
      "sensor.out": {day: [{start: chicago(10, 2), end: 0, change: 4}]},
      // A sensor that starts in the month of now: this month counts.
      "sensor.fridge_energy": {month: [{start: chicago(10, 1), end: 0, change: 31}]},
      "sensor.fridge_compressor": {month: [{start: chicago(10, 1), end: 0, change: 20}]},
    },
  })
  const read = link.energy()
  await serve(ha, [socket])
  await read
  assert.deepEqual(page.pushes.at(-1), ["ha:energy", {
    meter: {source: "home_assistant", months: [
      {month: "2026-09", kwh: 7, export: 0, days: 1},
      {month: "2026-10", kwh: 42, export: 4, days: 2},
    ]},
    devices: [{device: "fridge", statistic: "sensor.fridge_energy", name: "Fridge", months: [{month: "2026-10", kwh: 31}]}],
    month: "2026-10",
  }])
  // The meter for each day of 24 months, in kWh. The devices for each
  // month of 13 months and one more: the first month of a sensor does not
  // count.
  assert.deepEqual(ha.reads.map(({statistic_ids, period, types, units, start_time}) =>
    ({statistic_ids, period, types, units, start_time})), [
    {statistic_ids: ["sensor.in", "sensor.out"], period: "day", types: ["change"], units: {energy: "kWh"},
      start_time: new Date(monthStart(page.clock, METER_MONTHS)).toISOString()},
    {statistic_ids: ["sensor.fridge_energy"], period: "month", types: ["change"], units: {energy: "kWh"},
      start_time: new Date(monthStart(page.clock, DEVICE_MONTHS + 1)).toISOString()},
  ])

  // No energy settings, or settings with no meter and no device: no
  // statistics.
  ha.prefs = null
  ha.reads = []
  const none = link.energy()
  await serve(ha, [socket])
  await none
  assert.deepEqual(page.pushes.at(-1), ["ha:energy", {meter: null, devices: [], month: "2026-10"}])
  ha.prefs = {energy_sources: [{type: "solar", stat_energy_from: "sensor.solar"}], device_consumption: []}
  const empty = link.energy()
  await serve(ha, [socket])
  await empty
  assert.deepEqual(page.pushes.at(-1), ["ha:energy", {meter: null, devices: [], month: "2026-10"}])
  assert.equal(ha.reads.length, 0)

  // A command that Home Assistant refuses, and no socket.
  ha.prefs = {energy_sources: [{type: "grid", stat_energy_from: "sensor.in"}]}
  ha.fail = (message) => message.type === "recorder/statistics_during_period" ? {code: "unauthorized"} : null
  const refused = link.energy()
  await serve(ha, [socket])
  await refused
  assert.deepEqual(page.pushes.at(-1), ["ha:energy", {error: "failed"}])
  link.stop()
  await link.energy()
  assert.deepEqual(page.pushes.at(-1), ["ha:energy", {error: "offline"}])
})
