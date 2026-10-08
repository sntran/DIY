// The tests of assets/js/device.js: the build on the device, in IndexedDB
// (fake-indexeddb gives the same transactions in Node.js).
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {IDBFactory} from "fake-indexeddb"
import {
  DB, STORE, KEY, BACKUP, stampOf, open, indexedStore, refusedStore, storeOf, deviceHook,
} from "../../assets/js/device.js"

const doc = (stamp, extra = {}) => JSON.stringify({version: 1, stamp, ...extra})

// A text that IndexedDB cannot keep (a function): the transaction stops.
const bad = {f() {}}

function newStore(factory = new IDBFactory()) {
  return indexedStore(factory)
}

// A factory that gives a fake database.
function fakeFactory(db) {
  let opens = 0
  return {
    get opens() { return opens },
    open() {
      opens += 1
      const request = {result: db}
      setTimeout(() => request.onsuccess())
      return request
    },
  }
}

// The result of a save, as report gets it.
function saveOf(store, message) {
  return new Promise((resolve) => { store.save(message, resolve) })
}

async function raw(factory, key) {
  const db = await open(factory)
  return new Promise((resolve) => {
    const request = db.transaction(STORE).objectStore(STORE).get(key)
    request.onsuccess = () => resolve(request.result)
  })
}

test("stampOf reads the stamp of a build", () => {
  assert.equal(stampOf(doc("a1")), "a1")
  assert.equal(stampOf(null), "")
  assert.equal(stampOf(undefined), "")
  assert.equal(stampOf("not json"), "")
  assert.equal(stampOf("null"), "")
  assert.equal(stampOf("{}"), "")
  assert.equal(stampOf(JSON.stringify({stamp: 4})), "")
})

test("stampOf gives a string for each text", () => {
  fc.assert(fc.property(fc.oneof(fc.string(), fc.json()), (text) => {
    assert.equal(typeof stampOf(text), "string")
  }))
})

test("a new store has no build", async () => {
  const store = await newStore()
  assert.equal(await store.read(), null)
})

test("save writes when the stored stamp is the base", async () => {
  const store = await newStore()
  assert.deepEqual(await saveOf(store, {text: doc("a"), base: ""}), {saved: "a"})
  assert.equal(await store.read(), doc("a"))
  assert.deepEqual(await saveOf(store, {text: doc("b"), base: "a"}), {saved: "b"})
  assert.equal(await store.read(), doc("b"))
})

test("save refuses a stale base and gives the stored text", async () => {
  const store = await newStore()
  await saveOf(store, {text: doc("c"), base: ""})
  assert.deepEqual(await saveOf(store, {text: doc("d"), base: "b"}), {conflict: doc("c"), stamp: "c"})
  assert.equal(await store.read(), doc("c"))
})

test("save keeps a copy of the stored text when the message asks for it", async () => {
  const factory = new IDBFactory()
  const store = await newStore(factory)
  await saveOf(store, {text: "an old build", base: ""})
  assert.deepEqual(await saveOf(store, {text: doc("e"), base: "", backup: true}), {saved: "e"})
  assert.equal(await raw(factory, BACKUP), "an old build")
  assert.equal(await raw(factory, KEY), doc("e"))
})

test("a backup of no stored text writes no copy", async () => {
  const factory = new IDBFactory()
  const store = await newStore(factory)
  assert.deepEqual(await saveOf(store, {text: doc("f"), base: "", backup: true}), {saved: "f"})
  assert.equal(await raw(factory, BACKUP), undefined)
})

test("save gives an error with the stored stamp when the transaction stops", async () => {
  const store = await newStore()
  await saveOf(store, {text: doc("g"), base: ""})
  const result = await saveOf(store, {text: bad, base: "g"})
  assert.equal(result.stamp, "g")
  assert.ok(result.error)
  assert.equal(await store.read(), doc("g"))
})

test("a closed database opens again for the next save", async () => {
  const factory = new IDBFactory()
  const store = newStore(factory)
  assert.deepEqual(await saveOf(store, {text: doc("h"), base: ""}), {saved: "h"})
  const db = await store.connection()
  db.close()
  assert.deepEqual(await saveOf(store, {text: doc("i"), base: "h"}), {saved: "i"})
  db.onclose()
  assert.equal(await store.read(), doc("i"))
})

test("a newer version of the database closes this connection", async () => {
  const factory = new IDBFactory()
  const store = newStore(factory)
  await saveOf(store, {text: doc("v"), base: ""})
  const newer = await new Promise((resolve, reject) => {
    const request = factory.open(DB, 2)
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
  assert.equal(newer.version, 2)
  newer.close()
  const result = await saveOf(store, {text: doc("w"), base: "v"})
  assert.match(result.error, /version/i)
})

test("a database that stays closed gives an error", async () => {
  const closed = () => {
    const error = new Error("closed")
    error.name = "InvalidStateError"
    throw error
  }
  const factory = fakeFactory({transaction: closed})
  const store = newStore(factory)
  assert.deepEqual(await saveOf(store, {text: doc("j"), base: ""}), {error: "closed", stamp: ""})
  assert.equal(factory.opens, 2)
  await assert.rejects(() => store.read(), /closed/)
})

test("another error of a transaction gives an error, with no new open", async () => {
  const factory = fakeFactory({transaction() { throw new Error("broken") }})
  const store = newStore(factory)
  assert.deepEqual(await saveOf(store, {text: doc("k"), base: ""}), {error: "broken", stamp: ""})
  assert.equal(factory.opens, 1)
  const odd = newStore(fakeFactory({transaction() { throw null }}))
  assert.deepEqual(await saveOf(odd, {text: doc("k"), base: ""}), {error: "null", stamp: ""})
})

test("a read that fails rejects", async () => {
  const db = {
    transaction: () => ({
      objectStore: () => ({
        get() {
          const request = {error: new Error("broken")}
          setTimeout(() => request.onerror())
          return request
        },
      }),
    }),
  }
  await assert.rejects(() => newStore(fakeFactory(db)).read(), /broken/)
})

test("an abort with no error of the transaction gives a general error", async () => {
  let tx
  const db = {
    transaction() {
      tx = {
        error: null,
        objectStore: () => ({
          get() {
            const request = {result: undefined}
            setTimeout(() => request.onsuccess())
            return request
          },
          put() { setTimeout(() => tx.onabort()) },
        }),
      }
      return tx
    },
  }
  assert.deepEqual(await saveOf(newStore(fakeFactory(db)), {text: doc("a"), base: ""}),
    {error: "The browser stopped the save.", stamp: ""})
})

test("open fails when the browser refuses the database, and tries again later", async () => {
  let opens = 0
  const factory = {
    open() {
      opens += 1
      const request = {}
      setTimeout(() => {
        request.error = new Error("refused")
        request.onerror()
      })
      return request
    },
  }
  await assert.rejects(() => open(factory), /refused/)
  const store = storeOf({indexedDB: factory})
  await assert.rejects(() => store.read(), /refused/)
  assert.deepEqual(await saveOf(store, {text: doc("i"), base: ""}), {error: "refused", stamp: ""})
  assert.equal(opens, 3)
})

test("storeOf gives a refused store with no IndexedDB", async () => {
  for (const win of [{}, {get indexedDB() { throw new Error("SecurityError") }}]) {
    const store = storeOf(win)
    assert.equal(await store.read(), null)
    assert.deepEqual(await saveOf(store, {text: doc("j"), base: ""}),
      {error: "The browser does not let this page keep data.", stamp: ""})
  }
})

test("storeOf opens the database of the window", async () => {
  const factory = new IDBFactory()
  const store = storeOf({indexedDB: factory})
  assert.deepEqual(await saveOf(store, {text: doc("k"), base: ""}), {saved: "k"})
  assert.equal(await raw(factory, KEY), doc("k"))
})

// Two tabs edit one build, as in specs/Device.tla, with two connections to
// one IndexedDB. A tab sends the next save before its hook answers the last
// one, and keeps its queue after a conflict. Each hook takes one save at a
// time, and the saves of the two tabs run at the same time. A conflict of
// the current epoch makes the tab show the stored build, in a new epoch; an
// error takes the stored stamp as the base. Some saves fail. An edit that
// was stored stays stored (no lost update).
test("two tabs never lose a stored edit", async () => {
  const action = fc.record({
    tab: fc.constantFrom(0, 1),
    kind: fc.constantFrom("edit", "edit", "store", "store", "fail", "settle", "deliver"),
  })
  await fc.assert(fc.asyncProperty(fc.array(action, {maxLength: 40}), async (actions) => {
    const factory = new IDBFactory()
    const reader = newStore(factory)
    const tabs = [0, 1].map(() => ({
      store: newStore(factory), edits: [], base: "", epoch: 0, queue: [], inbox: [], running: null,
    }))
    const stored = new Set()
    let next = 0

    const settle = async () => {
      for (const t of tabs) {
        if (!t.running) continue
        const {save, result} = await t.running
        t.running = null
        if ("saved" in result) for (const e of JSON.parse(save.text).edits) stored.add(e)
        else t.inbox.push({...result, epoch: save.epoch})
      }
      const now = new Set(JSON.parse((await reader.read()) || '{"edits": []}').edits)
      for (const e of stored) assert.ok(now.has(e), `edit ${e} is lost`)
    }

    for (const {tab, kind} of [...actions, {kind: "settle"}]) {
      const t = tabs[tab]
      if (kind === "settle") {
        await settle()
      } else if (kind === "edit") {
        const stamp = `s${++next}`
        t.edits = [...t.edits, next]
        t.queue.push({text: doc(stamp, {edits: t.edits}), base: t.base, epoch: t.epoch})
        t.base = stamp
      } else if ((kind === "store" || kind === "fail") && t.queue.length && !t.running) {
        const save = t.queue.shift()
        const message = kind === "fail" ? {...save, text: bad} : save
        t.running = saveOf(t.store, message).then((result) => ({save, result}))
      } else if (kind === "deliver" && t.inbox.length) {
        const result = t.inbox.shift()
        if (result.epoch === t.epoch) {
          if ("conflict" in result) t.edits = result.conflict ? JSON.parse(result.conflict).edits : []
          t.base = result.stamp
          t.epoch += 1
        }
      }
    }
  }), {numRuns: 200})
})

// A fake LiveView hook context.
function hookContext({fail = false} = {}) {
  const pushed = []
  const handlers = {}
  return {
    pushed,
    handlers,
    pushEvent(name, payload) {
      if (fail === "throw") throw new Error("not connected")
      if (fail === "none") return undefined
      pushed.push([name, payload])
      return fail === "reject" ? Promise.reject(new Error("not connected")) : Promise.resolve()
    },
    handleEvent(name, fn) { handlers[name] = fn },
  }
}

// A fake BroadcastChannel: the channels of one bus get the messages of the
// others.
function bus() {
  const channels = []
  return () => {
    const channel = {
      closed: false,
      postMessage(data) {
        for (const other of channels) if (other !== channel && !other.closed) other.onmessage({data})
      },
      close() { channel.closed = true },
    }
    channels.push(channel)
    return channel
  }
}

test("the hook restores, saves, tells the other tabs, and gives conflicts", async () => {
  const factory = new IDBFactory()
  const channel = bus()
  const one = Object.assign(hookContext(), deviceHook({store: () => storeOf({indexedDB: factory}), channel}))
  const two = Object.assign(hookContext(), deviceHook({store: () => storeOf({indexedDB: factory}), channel}))
  const settled = async () => {
    await one.queue
    await two.queue
  }

  one.mounted()
  two.mounted()
  await one.queue
  await two.queue
  assert.deepEqual(one.pushed.shift(), ["device:restore", {text: null, stamp: ""}])
  assert.deepEqual(two.pushed.shift(), ["device:restore", {text: null, stamp: ""}])

  one.handlers["device:save"]({text: doc("a"), base: "", epoch: 3})
  await settled()
  await settled()
  assert.deepEqual(one.pushed.shift(), ["device:saved", {stamp: "a"}])
  assert.deepEqual(two.pushed.shift(), ["device:changed", {text: doc("a"), stamp: "a"}])

  two.handlers["device:save"]({text: doc("b"), base: "", epoch: 5})
  await two.queue
  assert.deepEqual(two.pushed.shift(), ["device:conflict", {text: doc("a"), stamp: "a", epoch: 5}])

  // A reconnect reads the store after the saves of the queue.
  one.handlers["device:save"]({text: doc("c"), base: "a", epoch: 3})
  one.reconnected()
  await one.queue
  assert.deepEqual(one.pushed.shift(), ["device:saved", {stamp: "c"}])
  assert.deepEqual(one.pushed.shift(), ["device:restore", {text: doc("c"), stamp: "c"}])

  // Two reconnects before the hook reads: only the last read restores.
  one.handlers["device:save"]({text: doc("d"), base: "c", epoch: 3})
  one.reconnected()
  one.reconnected()
  await one.queue
  assert.deepEqual(one.pushed.shift(), ["device:saved", {stamp: "d"}])
  assert.deepEqual(one.pushed, [["device:restore", {text: doc("d"), stamp: "d"}]])

  one.destroyed()
  two.destroyed()
})

test("the hook gives the errors of the store", async () => {
  const hook = Object.assign(hookContext(), deviceHook({
    store: () => refusedStore("full"),
    channel: () => null,
  }))
  hook.mounted()
  hook.handlers["device:save"]({text: doc("a"), base: "", epoch: 2})
  await hook.queue
  assert.deepEqual(hook.pushed, [
    ["device:restore", {text: null, stamp: ""}],
    ["device:error", {error: "full", stamp: "", epoch: 2}],
  ])
  hook.destroyed()
})

test("the hook restores an empty build when the read fails", async () => {
  const hook = Object.assign(hookContext(), deviceHook({
    store: () => ({read: () => Promise.reject(new Error("no")), save() {}}),
    channel: bus(),
  }))
  hook.mounted()
  await hook.queue
  assert.deepEqual(hook.pushed, [["device:restore", {text: null, stamp: ""}]])
  // A write of a different tab, with a read that fails, sends nothing.
  hook.channel.onmessage({data: "write"})
  await hook.queue
  assert.equal(hook.pushed.length, 1)
})

test("a push with no connection goes nowhere", async () => {
  for (const fail of ["throw", "reject", "none"]) {
    const hook = Object.assign(hookContext({fail}), deviceHook({
      store: () => refusedStore("x"),
      channel: () => null,
    }))
    hook.mounted()
    await hook.queue
    assert.equal(hook.pushed.length, fail === "reject" ? 1 : 0)
  }
})
