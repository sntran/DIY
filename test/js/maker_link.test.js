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
// station for each token (its account): its AC outlets are on or off. As
// in the TLA+ model, the cloud serves a call (it reads or writes the
// station), and later the answer comes (deliver).
function relay() {
  const fake = {calls: [], cloud: {phk_a1: "on", phk_a2: "on"}}
  fake.fetch = (url, options) => new Promise((resolve, reject) => {
    const call = {url, options, resolve, reject}
    options.signal.addEventListener("abort", () => {
      if (fake.calls.includes(call)) fake.calls.splice(fake.calls.indexOf(call), 1)
      reject(new Error("aborted"))
    })
    fake.calls.push(call)
  })
  // The cloud reads or writes the station of the token now.
  fake.serve = (call) => {
    if (call.response) return
    const token = call.options.headers.authorization.slice("Bearer ".length)
    if (call.options.method === "POST") {
      fake.cloud[token] = JSON.parse(call.options.body).on ? "on" : "off"
      call.response = json(200, {ok: true})
    } else {
      call.response = json(200, {stations: [{id: "s1", account: token, ac: fake.cloud[token]}]})
    }
  }
  // The answer comes.
  fake.deliver = (call) => {
    fake.serve(call)
    fake.calls.splice(fake.calls.indexOf(call), 1)
    call.resolve(call.response)
  }
  // Serves a call and answers it, or answers it with a different answer.
  fake.answer = (call, override = null) => {
    if (!override) return fake.deliver(call)
    fake.calls.splice(fake.calls.indexOf(call), 1)
    call.resolve(override)
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
// Fires a timer of the page: the next poll, or the wait of an answer.
const fire = (page, ms = POLL_WAIT) => {
  const [id, timer] = [...page.timers.entries()].find(([, one]) => one.ms === ms)
  page.timers.delete(id)
  timer.f()
}

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
  fake.serve(poll)
  link.control("s1", "ac", true)
  await settle()
  const command = fake.calls[1]
  // The control ends first, while the poll waits: no poll now.
  fake.answer(command)
  await settle()
  assert.equal(fake.calls.length, 1)
  // The old poll ends with the old state, then the poll comes again.
  fake.deliver(poll)
  await settle()
  await settle()
  assert.equal(last(page, "maker:stations").stations[0].ac, "off")
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

  // A first poll gives the stations. Then the maker does not answer, or
  // answers with an error: the polls go on, and the page keeps the last
  // stations. An error that the hook does not know is "failed".
  fake.answer(fake.calls[0])
  await settle()
  const shown = last(page, "maker:stations")
  fire(page)
  for (const [answer, error] of [
    [json(502, {error: "unreachable"}), "unreachable"],
    [json(502, {error: "failed"}), "failed"],
    [json(502, {error: "<b>other</b>"}), "failed"],
    [broken(500), "failed"],
    [json(200, {stations: "none"}), "failed"],
    [broken(200), "failed"],
  ]) {
    fake.answer(fake.calls[0], answer)
    await settle()
    assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "offline", error})
    assert.equal(last(page, "maker:stations"), shown)
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

  // A control that fails. Then a control that the maker refuses for the
  // token ("denied"): the token can still read, so the poll after the
  // control goes on. Then a poll that the maker refuses: the polls stop.
  link.control("s1", "dc", true)
  await settle()
  fake.answer(fake.calls[0], json(502, {error: "failed"}))
  await settle()
  assert.deepEqual(last(page, "maker:control_done"), {maker: "pecron", device: "s1", part: "dc", error: "failed"})
  fake.answer(fake.calls[0])
  await settle()
  assert.equal(last(page, "maker:status").state, "connected")
  link.control("s1", "dc", true)
  await settle()
  fake.answer(fake.calls[0], json(403, {error: "token"}))
  await settle()
  assert.deepEqual(last(page, "maker:control_done"), {maker: "pecron", device: "s1", part: "dc", error: "denied"})
  assert.equal(last(page, "maker:status").state, "connected")
  assert.equal(fake.calls[0].options.method, "GET")
  fake.answer(fake.calls[0], json(401, {error: "token"}))
  await settle()
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "refused", error: "token"})
  assert.equal(pollTimer(page), undefined)
  assert.equal(fake.calls.length, 0)

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
  // As in the TLA+ model: the cloud serves a call, and its answer comes
  // later. "synced": a poll of this generation read the cloud after the
  // last change of a person. When all is quiet and synced, the page shows
  // the cloud, with no new timer.
  const step = fc.oneof(
    fc.constantFrom("phk_a1", "phk_a2", null).map((token) => ({kind: "switch", token})),
    fc.constant({kind: "timer"}),
    fc.boolean().map((on) => ({kind: "control", on})),
    fc.nat(5).map((index) => ({kind: "serve", index})),
    fc.nat(5).map((index) => ({kind: "deliver", index})),
    fc.constantFrom("phk_a1", "phk_a2").map((token) => ({kind: "person", token})),
  )
  await fc.assert(fc.asyncProperty(fc.array(step, {maxLength: 25}), async (steps) => {
    const fake = relay()
    let link = null
    // Each call has the generation of the hook when it starts.
    const fetch = (url, options) => {
      const answer = fake.fetch(url, options)
      fake.calls.at(-1).generation = link.generation
      return answer
    }
    const page = parts({fetch})
    link = new MakerLink(page.deps)
    let synced = false
    // A command of an old generation (the person connected the same
    // account again) is as a change of a person, as in the model.
    const serve = (call) => {
      if (!call.response && call.generation === link.generation && call.options.method === "GET") synced = true
      if (!call.response && call.generation !== link.generation && call.options.method === "POST" &&
        call.options.headers.authorization === `Bearer ${link.token}`) synced = false
      fake.serve(call)
    }
    await link.start()
    for (const one of steps) {
      if (one.kind === "switch") {
        if (one.token) await link.connect(one.token)
        else await link.disconnect()
        synced = false
      } else if (one.kind === "timer") {
        if (pollTimer(page)) fire(page)
      } else if (one.kind === "control") {
        if (link.token) link.control("s1", "ac", one.on)
      } else if (one.kind === "serve" || one.kind === "deliver") {
        const call = fake.calls[one.index % Math.max(fake.calls.length, 1)]
        if (call) serve(call)
        if (call && one.kind === "deliver") fake.deliver(call)
      } else {
        fake.cloud[one.token] = fake.cloud[one.token] === "on" ? "off" : "on"
        if (one.token === link.token) synced = false
      }
      await settle()
      await settle()
      // The page shows only the station of the account of the token.
      const shown = last(page, "maker:stations").stations
      if (shown) assert.equal(shown[0].account, link.token)
      if (!link.token) assert.equal(shown, null)
    }
    // All the answers come, in order.
    while (fake.calls.length) {
      serve(fake.calls[0])
      fake.deliver(fake.calls[0])
      await settle()
      await settle()
    }
    if (link.token && synced) assert.equal(last(page, "maker:stations").stations[0].ac, fake.cloud[link.token])
    link.stop()
  }), {
    numRuns: 1000,
    // Always this case of the rule "again": a poll reads the cloud, then
    // a control ends while the poll waits.
    examples: [
      [[
        {kind: "switch", token: "phk_a1"}, {kind: "control", on: false}, {kind: "serve", index: 0},
        {kind: "deliver", index: 1},
      ]],
      // A control of an old generation of the same account.
      [[
        {kind: "switch", token: "phk_a1"}, {kind: "control", on: false}, {kind: "switch", token: "phk_a1"},
        {kind: "deliver", index: 5},
      ]],
    ],
  })
})

test("a body of an answer that never ends: the wait ends after ANSWER_WAIT", async () => {
  const fake = relay()
  const page = parts({fetch: fake.fetch})
  const link = new MakerLink(page.deps)
  await link.start()
  await link.connect("phk_a1")
  // The headers come, and the body stops until the signal stops it.
  const call = fake.calls[0]
  fake.answer(call, {
    ok: true, status: 200,
    json: () => new Promise((_resolve, reject) => call.options.signal.addEventListener("abort", () => reject(new Error("aborted")))),
  })
  await settle()
  assert.equal(link.busy, true)
  fire(page, ANSWER_WAIT)
  await settle()
  await settle()
  assert.deepEqual(last(page, "maker:status"), {maker: "pecron", state: "offline", error: "timeout"})
  assert.equal(link.busy, false)
  assert.ok(pollTimer(page))
  link.stop()
})

test("a new generation forgets the poll again and the wait for the page", async () => {
  const fake = relay()
  let visible = true
  const page = parts({fetch: fake.fetch, visible: () => visible})
  const link = new MakerLink(page.deps)
  await link.start()
  await link.connect("phk_a1")
  link.control("s1", "ac", false)
  await settle()
  fake.answer(fake.calls[1])
  await settle()
  assert.equal(link.again, true)
  await link.connect("phk_a2")
  assert.equal(link.again, false)
  fake.answer(fake.calls.find((call) => call.options.headers.authorization === "Bearer phk_a2"))
  await settle()
  visible = false
  fire(page)
  assert.equal(link.waiting, true)
  await link.disconnect()
  assert.equal(link.waiting, false)
  // The other tabs get the news of a connect and of a disconnect.
  assert.equal(page.notes, 3)
  link.stop()
})

test("a stopped link does nothing: a late read of the store, or a late news", async () => {
  const fake = relay()
  const page = parts({fetch: fake.fetch})
  page.tokens.set("pecron", "phk_a1")
  const link = new MakerLink(page.deps)
  const started = link.start()
  link.stop()
  await started
  await link.news()
  await link.connect("phk_a2")
  await link.disconnect()
  assert.equal(fake.calls.length, 0)
  assert.equal(page.timers.size, 0)
  assert.deepEqual(page.pushes.filter(([event]) => event === "maker:stations"), [])

  // A poll waits when the link stops: its answer changes nothing, and no
  // timer polls again.
  page.tokens.set("pecron", "phk_a1")
  const other = new MakerLink(page.deps)
  await other.start()
  await settle()
  assert.equal(fake.calls.length, 1)
  const count = page.pushes.length
  other.stop()
  fake.answer(fake.calls[0])
  await settle()
  assert.equal(page.pushes.length, count)
  assert.equal(pollTimer(page), undefined)
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
      const db = {close: () => { db.closed = true }, transaction: () => {
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

  // The page goes: the store closes its connection. A next call opens it
  // again. A store with no connection closes too.
  counting.close()
  await settle()
  assert.equal(dbs[1].closed, true)
  assert.equal(await counting.get("pecron"), "phk_a2")
  assert.equal(opens, 3)
  tokenStore(factory).close()

  // A database that does not open, and a transaction that fails.
  const failing = tokenStore({open: () => {
    const request = {}
    setImmediate(() => { request.error = new Error("blocked"); request.onerror() })
    return request
  }})
  await assert.rejects(failing.get("pecron"))
  // The store closes while its database does not open.
  const read = failing.get("pecron")
  failing.close()
  await assert.rejects(read)
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
  let closed = false
  const notes = []
  const deps = () => ({
    ...page.deps,
    close: () => { closed = true },
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
  assert.ok(closed)
  // The links stop: the answer of a poll that waits changes nothing.
  assert.ok(Object.values(self.links).every((one) => one.stopped))
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
    close() { this.closed = true }
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
  lone.close()

  // The page goes: the channel closes.
  browser.close()
  assert.equal(channels[0].closed, true)
})
