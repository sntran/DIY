// The tests of the direct link to the cloud of a maker
// (assets/js/maker_link.js).
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {IDBFactory} from "fake-indexeddb"
import {
  MAKERS, POLL_WAIT, ANSWER_WAIT, DB, STORE, CHANNEL, MAX_TOKEN, validToken, MakerLink, tokenStore, makerLinkHook,
  makerParts,
} from "../../assets/js/maker_link.js"

const settle = () => new Promise((resolve) => setImmediate(resolve))

// A fake relay: each call waits until the test answers it. The cloud has a
// station for each token (its account): its AC outlets are on or off.
function relay() {
  const fake = {calls: [], cloud: {phk_a1: "on", phk_a2: "on"}}
  fake.fetch = (url, options) => new Promise((resolve, reject) => {
    const call = {url, options, resolve, reject}
    options.signal.addEventListener("abort", () => {
      fake.calls.splice(fake.calls.indexOf(call), 1)
      reject(new Error("aborted"))
    })
    fake.calls.push(call)
  })
  // Answers a call: the cloud reads or writes the station of the token now.
  fake.answer = (call, override = null) => {
    fake.calls.splice(fake.calls.indexOf(call), 1)
    const token = call.options.headers.authorization.slice("Bearer ".length)
    if (override) return call.resolve(override)
    if (call.options.method === "POST") {
      fake.cloud[token] = JSON.parse(call.options.body).on ? "on" : "off"
      return call.resolve(json(200, {ok: true}))
    }
    call.resolve(json(200, {stations: [{id: "s1", account: token, ac: fake.cloud[token]}]}))
  }
  // The relay gives no answer (no network).
  fake.fail = (call) => {
    fake.calls.splice(fake.calls.indexOf(call), 1)
    call.reject(new Error("offline"))
  }
  return fake
}

const json = (status, body) => ({ok: status >= 200 && status < 300, status, json: async () => body})
const broken = (status) => ({ok: status < 300, status, json: async () => { throw new Error("no JSON") }})

// The parts of a link for a test: a store in a Map, the pushes, the timers.
function parts({fetch, visible = () => true, store = null} = {}) {
  const page = {pushes: [], timers: new Map(), notes: 0, next: 1, tokens: new Map()}
  page.deps = {
    maker: "pecron",
    store: store ?? {
      get: async (maker) => page.tokens.get(maker) ?? null,
      put: async (maker, token) => { page.tokens.set(maker, token) },
      delete: async (maker) => { page.tokens.delete(maker) },
    },
    fetch,
    push: (event, payload) => page.pushes.push([event, payload]),
    notify: () => { page.notes += 1 },
    visible,
    setTimer: (f, ms) => {
      const id = page.next++
      page.timers.set(id, {f, ms})
      return id
    },
    clearTimer: (id) => page.timers.delete(id),
  }
  return page
}

const last = (page, event) => page.pushes.findLast(([name]) => name === event)?.[1]
// The timer of the next poll (not the wait of an answer).
const pollTimer = (page) => [...page.timers.entries()].find(([, timer]) => timer.ms === POLL_WAIT)

test("the constants and the form of a token", () => {
  assert.deepEqual(MAKERS, {pecron: {relay: "/relay/pecron", prefix: "phk_"}})
  assert.deepEqual([POLL_WAIT, ANSWER_WAIT, DB, STORE, CHANNEL, MAX_TOKEN],
    [30_000, 20_000, "diy-makers", "tokens", "diy.makers", 512])
  assert.ok(validToken("pecron", "phk_abc.DEF-123"))
  for (const token of ["phk_", "abc", "phk_a b", "phk_é", `phk_${"a".repeat(509)}`, null, 5]) {
    assert.equal(validToken("pecron", token), false, String(token))
  }
  assert.ok(validToken("pecron", `phk_${"a".repeat(508)}`))
})

test("a token: the stations, then a poll each POLL_WAIT while the page shows", async () => {
  const fake = relay()
  let shows = true
  const page = parts({fetch: fake.fetch, visible: () => shows})
  const link = new MakerLink(page.deps)
  await link.start()
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "none", error: null})
  assert.deepEqual(last(page, "maker:stations"), {maker: "pecron", stations: null})

  // A token that is not a token of Pecron, or no token: an error, and no
  // call.
  await link.connect(undefined)
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "none", error: "format"})
  await link.connect("abc")
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "none", error: "format"})
  assert.equal(fake.calls.length, 0)

  // The token goes to the store. The other tabs get the news.
  await link.connect("  phk_a1 ")
  assert.equal(page.tokens.get("pecron"), "phk_a1")
  assert.equal(page.notes, 1)
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "connecting", error: null})
  const [call] = fake.calls
  assert.equal(call.url, "/relay/pecron/stations")
  assert.equal(call.options.method, "GET")
  assert.deepEqual(call.options.headers, {authorization: "Bearer phk_a1"})
  assert.equal(call.options.credentials, "omit")
  assert.equal(call.options.cache, "no-store")
  assert.equal(call.options.body, undefined)

  // One poll at a time.
  link.poll()
  assert.equal(fake.calls.length, 1)
  fake.answer(call)
  await settle()
  assert.deepEqual(last(page, "maker:stations"), {maker: "pecron", stations: [{id: "s1", account: "phk_a1", ac: "on"}]})
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "connected", error: null})

  // The timer polls while the page shows.
  const [id, timer] = pollTimer(page)
  page.timers.delete(id)
  timer.f()
  assert.equal(fake.calls.length, 1)
  fake.answer(fake.calls[0])
  await settle()

  // A hidden page waits. The page shows again: a poll at once.
  shows = false
  const [id2, timer2] = pollTimer(page)
  page.timers.delete(id2)
  timer2.f()
  assert.equal(fake.calls.length, 0)
  shows = true
  link.shown()
  assert.equal(fake.calls.length, 1)
  link.shown()
  assert.equal(fake.calls.length, 1)
  fake.answer(fake.calls[0])
  await settle()

  // A new LiveView gets the state and the stations again.
  const count = page.pushes.length
  link.report()
  assert.deepEqual(page.pushes.slice(count).map(([event]) => event), ["maker:status", "maker:stations"])
  link.stop()
  assert.equal(pollTimer(page), undefined)
})

test("a disconnect or a new token: the answers of the old token change nothing", async () => {
  const fake = relay()
  const page = parts({fetch: fake.fetch})
  const link = new MakerLink(page.deps)
  await link.start()
  await link.connect("phk_a1")
  const old = fake.calls[0]

  // A new token while the poll of the old token waits.
  await link.connect("phk_a2")
  assert.equal(fake.calls.length, 2)
  fake.answer(old)
  await settle()
  assert.deepEqual(last(page, "maker:stations"), {maker: "pecron", stations: null})
  fake.answer(fake.calls[0])
  await settle()
  assert.equal(last(page, "maker:stations").stations[0].account, "phk_a2")

  // A control, then a disconnect before its end: its end changes nothing.
  link.control("s1", "ac", false)
  await settle()
  const command = fake.calls[0]
  assert.equal(command.url, "/relay/pecron/command/s1")
  assert.equal(command.options.method, "POST")
  assert.deepEqual(command.options.headers, {authorization: "Bearer phk_a2", "content-type": "application/json"})
  assert.deepEqual(JSON.parse(command.options.body), {part: "ac", on: false})
  await link.disconnect()
  assert.equal(page.tokens.has("pecron"), false)
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "none", error: null})
  const count = page.pushes.length
  fake.answer(command)
  await settle()
  assert.equal(page.pushes.length, count)
  assert.equal(fake.calls.length, 0)

  // A control with no token ends at once.
  await link.control("s1", "dc", true)
  assert.deepEqual(last(page, "maker:control_done"), {maker: "pecron", device: "s1", part: "dc", error: "failed"})
  // A late start (the store answers after a connect) changes nothing.
  const slow = parts({fetch: fake.fetch})
  let release
  slow.deps.store.get = () => new Promise((resolve) => { release = resolve })
  const other = new MakerLink(slow.deps)
  const starting = other.start()
  await other.connect("phk_a1")
  release(null)
  await starting
  assert.equal(other.token, "phk_a1")
  other.stop()
})

test("a control: its end, then a poll; while a poll waits, the poll comes again", async () => {
  const fake = relay()
  const page = parts({fetch: fake.fetch})
  const link = new MakerLink(page.deps)
  await link.start()
  await link.connect("phk_a1")
  fake.answer(fake.calls[0])
  await settle()

  // No poll waits: the end of the control starts a poll.
  link.control("s/1", "ac", false)
  await settle()
  assert.equal(fake.calls[0].url, "/relay/pecron/command/s%2F1")
  fake.answer(fake.calls[0])
  await settle()
  assert.deepEqual(last(page, "maker:control_done"), {maker: "pecron", device: "s/1", part: "ac", error: null})
  assert.equal(fake.calls.length, 1)
  fake.answer(fake.calls[0])
  await settle()
  assert.equal(last(page, "maker:stations").stations[0].ac, "off")

  // A poll waits (it read the cloud before the control): the poll comes
  // again at its end, and the page shows the new state.
  const [id, timer] = pollTimer(page)
  page.timers.delete(id)
  timer.f()
  const poll = fake.calls[0]
  link.control("s1", "ac", true)
  await settle()
  const command = fake.calls[1]
  fake.answer(poll, json(200, {stations: [{id: "s1", account: "phk_a1", ac: "off"}]}))
  fake.answer(command)
  await settle()
  await settle()
  assert.equal(fake.calls.length, 1)
  fake.answer(fake.calls[0])
  await settle()
  assert.equal(last(page, "maker:stations").stations[0].ac, "on")
  link.stop()
})

test("the errors of the relay and of the maker", async () => {
  const fake = relay()
  const page = parts({fetch: fake.fetch})
  const link = new MakerLink(page.deps)
  await link.start()
  await link.connect("phk_a1")

  // The maker does not answer, or answers with an error: the polls go on.
  for (const [answer, error] of [
    [json(502, {error: "unreachable"}), "unreachable"],
    [json(502, {error: "failed"}), "failed"],
    [broken(500), "failed"],
    [json(200, {stations: "none"}), "failed"],
    [broken(200), "failed"],
  ]) {
    fake.answer(fake.calls[0], answer)
    await settle()
    assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "offline", error})
    const [id, timer] = pollTimer(page)
    page.timers.delete(id)
    timer.f()
  }

  // No answer of the relay (no network), and no answer in ANSWER_WAIT.
  fake.fail(fake.calls[0])
  await settle()
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "offline", error: "offline"})
  const [id, timer] = pollTimer(page)
  page.timers.delete(id)
  timer.f()
  const [, wait] = [...page.timers.entries()].find(([, one]) => one.ms === ANSWER_WAIT)
  wait.f()
  await settle()
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "offline", error: "timeout"})

  // A control that the maker refuses, and a token that the maker refuses:
  // the polls stop.
  link.control("s1", "dc", true)
  await settle()
  fake.answer(fake.calls[0], json(502, {error: "failed"}))
  await settle()
  assert.deepEqual(last(page, "maker:control_done"), {maker: "pecron", device: "s1", part: "dc", error: "failed"})
  fake.answer(fake.calls[0], json(401, {error: "token"}))
  await settle()
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "refused", error: "token"})
  assert.equal(pollTimer(page), undefined)
  link.control("s1", "dc", true)
  await settle()
  fake.answer(fake.calls[0], json(401, {error: "token"}))
  await settle()
  assert.deepEqual(last(page, "maker:control_done"), {maker: "pecron", device: "s1", part: "dc", error: "token"})
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "refused", error: "token"})
  assert.equal(fake.calls.length, 0)
  assert.equal(pollTimer(page), undefined)

  // The store fails: the link tells it, and keeps its state.
  page.deps.store.put = async () => { throw new Error("no store") }
  await link.connect("phk_a2")
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "refused", error: "storage"})
  await link.connect("bad")
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "refused", error: "format"})
  page.deps.store.delete = async () => { throw new Error("no store") }
  await link.disconnect()
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "none", error: null})
  const fresh = new MakerLink({...page.deps, store: {...page.deps.store, get: async () => { throw new Error("no") }}})
  await fresh.start()
  assert.equal(fresh.state, "none")
  await fresh.connect("bad")
  assert.equal(fresh.error, "format")
  page.deps.store.put = async () => { throw new Error("no store") }
  await fresh.connect("phk_a1")
  assert.deepEqual([fresh.state, fresh.error], ["none", "storage"])
})

test("the news of a different tab", async () => {
  const fake = relay()
  const page = parts({fetch: fake.fetch})
  const link = new MakerLink(page.deps)
  await link.start()
  page.tokens.set("pecron", "phk_a1")
  await link.news()
  assert.equal(link.token, "phk_a1")
  const count = page.pushes.length
  await link.news()
  assert.equal(page.pushes.length, count)
  page.tokens.delete("pecron")
  await link.news()
  assert.equal(link.state, "none")
})

test("after any steps, the page shows only the station of the token, and the cloud when all is quiet", async () => {
  const step = fc.oneof(
    fc.constantFrom("phk_a1", "phk_a2", null).map((token) => ({kind: "switch", token})),
    fc.constant({kind: "timer"}),
    fc.boolean().map((on) => ({kind: "control", on})),
    fc.nat(5).map((index) => ({kind: "answer", index})),
    fc.constantFrom("phk_a1", "phk_a2").map((token) => ({kind: "person", token})),
  )
  await fc.assert(fc.asyncProperty(fc.array(step, {maxLength: 25}), async (steps) => {
    const fake = relay()
    const page = parts({fetch: fake.fetch})
    const link = new MakerLink(page.deps)
    await link.start()
    for (const one of steps) {
      if (one.kind === "switch") {
        if (one.token) await link.connect(one.token)
        else await link.disconnect()
      } else if (one.kind === "timer") {
        const found = pollTimer(page)
        if (found) {
          page.timers.delete(found[0])
          found[1].f()
        }
      } else if (one.kind === "control") {
        if (link.token) link.control("s1", "ac", one.on)
      } else if (one.kind === "answer") {
        if (fake.calls.length) fake.answer(fake.calls[one.index % fake.calls.length])
      } else {
        fake.cloud[one.token] = fake.cloud[one.token] === "on" ? "off" : "on"
      }
      await settle()
      await settle()
      // The page shows only the station of the account of the token.
      const shown = last(page, "maker:stations").stations
      if (shown) assert.equal(shown[0].account, link.token)
      if (!link.token) assert.equal(shown, null)
    }
    // All the answers come, in order: the page shows the cloud.
    while (fake.calls.length) {
      fake.answer(fake.calls[0])
      await settle()
      await settle()
    }
    if (link.token) {
      const found = pollTimer(page)
      page.timers.delete(found[0])
      found[1].f()
      fake.answer(fake.calls[0])
      await settle()
      assert.equal(last(page, "maker:stations").stations[0].ac, fake.cloud[link.token])
    }
    link.stop()
  }), {numRuns: 200})
})

test("the store of the tokens in IndexedDB", async () => {
  const factory = new IDBFactory()
  const store = tokenStore(factory)
  assert.equal(await store.get("pecron"), null)
  await store.put("pecron", "phk_a1")
  assert.equal(await store.get("pecron"), "phk_a1")
  await store.delete("pecron")
  assert.equal(await store.get("pecron"), null)

  // The database opens again after the browser closes it.
  let opens = 0
  const memory = new Map()
  const dbs = []
  const counting = tokenStore({open: () => {
    opens += 1
    const request = {}
    setImmediate(() => {
      const db = {transaction: () => {
        const tx = {}
        const done = (result) => {
          setImmediate(() => tx.oncomplete())
          return {result}
        }
        tx.objectStore = () => ({
          get: (key) => done(memory.get(key)),
          put: (value, key) => done(memory.set(key, value) && undefined),
        })
        return tx
      }}
      dbs.push(db)
      request.result = db
      request.onsuccess()
    })
    return request
  }})
  await counting.put("pecron", "phk_a2")
  assert.equal(await counting.get("pecron"), "phk_a2")
  assert.equal(opens, 1)
  dbs[0].onclose()
  assert.equal(await counting.get("pecron"), "phk_a2")
  assert.equal(opens, 2)

  // A database that does not open, and a transaction that fails.
  const failing = tokenStore({open: () => {
    const request = {}
    setImmediate(() => { request.error = new Error("blocked"); request.onerror() })
    return request
  }})
  await assert.rejects(failing.get("pecron"))
  const aborts = tokenStore({open: () => {
    const request = {}
    setImmediate(() => {
      request.result = {transaction: () => {
        const tx = {objectStore: () => ({get: () => ({})}), error: new Error("abort")}
        setImmediate(() => tx.onabort())
        return tx
      }}
      request.onsuccess()
    })
    return request
  }})
  await assert.rejects(aborts.get("pecron"))
})

test("the hook: the links, the events of the LiveView and of the page", async () => {
  const fake = relay()
  const page = parts({fetch: fake.fetch})
  let listeners = null
  let unlistened = false
  const notes = []
  const deps = () => ({
    ...page.deps,
    notify: (maker) => notes.push(maker),
    listen: (handlers) => {
      listeners = handlers
      return () => { unlistened = true }
    },
  })
  const handlers = {}
  const pushes = []
  const hook = makerLinkHook(deps)
  const self = {
    ...hook,
    pushEvent: (event, payload, reply) => { pushes.push([event, payload]); reply() },
    handleEvent: (event, f) => { handlers[event] = f },
  }
  self.mounted()
  await settle()
  assert.deepEqual(pushes.at(-1), ["maker:status", {maker: "pecron", state: "none", error: null}])

  // The key Connect of the card, through the page.
  listeners.connect("pecron", "phk_a1")
  await settle()
  assert.deepEqual(notes, ["pecron"])
  assert.equal(fake.calls.length, 1)
  fake.answer(fake.calls[0])
  await settle()

  // A control of the LiveView. A part that is not a switch, a device that
  // is not an id, and a maker that the hook does not know do nothing.
  handlers["maker:control"]({maker: "pecron", device: "s1", part: "battery", on: true})
  handlers["maker:control"]({maker: "pecron", device: 5, part: "ac", on: true})
  handlers["maker:control"]({maker: "other", device: "s1", part: "ac", on: true})
  assert.equal(fake.calls.length, 0)
  handlers["maker:control"]({maker: "pecron", device: "s1", part: "ac", on: "yes"})
  await settle()
  assert.deepEqual(JSON.parse(fake.calls[0].options.body), {part: "ac", on: false})
  fake.answer(fake.calls[0])
  await settle()
  fake.answer(fake.calls[0])
  await settle()

  // The news of a tab, and the page that shows again.
  page.tokens.set("pecron", "phk_a2")
  listeners.news("pecron")
  await settle()
  assert.equal(fake.calls[0].options.headers.authorization, "Bearer phk_a2")
  fake.answer(fake.calls[0])
  await settle()
  listeners.shown()
  const count = pushes.length
  self.reconnected()
  assert.equal(pushes.length, count + 2)
  await handlers["maker:disconnect"]({maker: "pecron"})
  assert.equal(page.tokens.has("pecron"), false)
  handlers["maker:disconnect"]({maker: "other"})
  listeners.connect("other", "phk_a1")
  listeners.news("other")
  self.destroyed()
  assert.ok(unlistened)
})

test("the parts of the browser", async () => {
  const events = new EventTarget()
  const documentEvents = new EventTarget()
  const channels = []
  class FakeChannel {
    constructor(name) {
      this.name = name
      this.sent = []
      channels.push(this)
    }
    postMessage(data) { this.sent.push(data) }
  }
  const window = {
    BroadcastChannel: FakeChannel,
    indexedDB: new IDBFactory(),
    fetch: async (url) => url,
    setTimeout: (f) => { f(); return 7 },
    clearTimeout: () => {},
    addEventListener: (...args) => events.addEventListener(...args),
    removeEventListener: (...args) => events.removeEventListener(...args),
    document: {
      visibilityState: "visible",
      addEventListener: (...args) => documentEvents.addEventListener(...args),
      removeEventListener: (...args) => documentEvents.removeEventListener(...args),
    },
  }
  const browser = makerParts(window)
  assert.equal(channels[0].name, CHANNEL)
  assert.equal(await browser.fetch("/x"), "/x")
  let ran = false
  assert.equal(browser.setTimer(() => { ran = true }, 5), 7)
  assert.ok(ran)
  browser.clearTimer(7)
  assert.equal(browser.visible(), true)
  browser.notify("pecron")
  assert.deepEqual(channels[0].sent, ["pecron"])
  await browser.store.put("pecron", "phk_a1")
  assert.equal(await browser.store.get("pecron"), "phk_a1")

  // The key Connect: the token goes to the hook, and the field goes empty.
  const got = []
  const stop = browser.listen({
    connect: (maker, token) => got.push(["connect", maker, token]),
    news: (maker) => got.push(["news", maker]),
    shown: () => got.push(["shown"]),
  })
  const field = {value: "phk_a1"}
  const form = {dataset: {maker: "pecron"}, elements: {namedItem: (name) => (name === "token" ? field : null)}}
  const event = new Event("maker:connect")
  Object.defineProperty(event, "target", {value: form})
  events.dispatchEvent(event)
  assert.equal(field.value, "")
  channels[0].onmessage({data: "pecron"})
  documentEvents.dispatchEvent(new Event("visibilitychange"))
  window.document.visibilityState = "hidden"
  documentEvents.dispatchEvent(new Event("visibilitychange"))
  assert.equal(browser.visible(), false)
  assert.deepEqual(got, [["connect", "pecron", "phk_a1"], ["news", "pecron"], ["shown"]])
  stop()
  assert.equal(channels[0].onmessage, null)

  // A browser with no BroadcastChannel.
  const lone = makerParts({...window, BroadcastChannel: undefined})
  lone.notify("pecron")
  lone.listen({connect: () => {}, news: () => {}, shown: () => {}})()
})
