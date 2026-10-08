// The tests of assets/js/device.js: the build on the device.
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {KEY, LOCK, stampOf, withLock, save, load, storageOf, deviceHook} from "../../assets/js/device.js"

// A fake localStorage. fail names a method that throws.
function memoryStorage(initial = {}, fail = null) {
  const data = new Map(Object.entries(initial))
  return {
    data,
    getItem(key) {
      if (fail === "getItem") throw new Error("storage is off")
      return data.has(key) ? data.get(key) : null
    },
    setItem(key, value) {
      if (fail === "setItem") throw new Error("QuotaExceededError")
      if (fail === "setItemString") throw "full"
      data.set(key, value)
    },
  }
}

// A fake of navigator.locks: one holder at a time, in order.
function fakeLocks() {
  let tail = Promise.resolve()
  const names = []
  return {
    names,
    request(name, fn) {
      names.push(name)
      const run = tail.then(fn)
      tail = run.catch(() => {})
      return run
    },
  }
}

const doc = (stamp, extra = {}) => JSON.stringify({version: 1, stamp, ...extra})

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

test("withLock uses the Web Lock of the build", async () => {
  const locks = fakeLocks()
  assert.equal(await withLock(locks, () => 5), 5)
  assert.deepEqual(locks.names, [LOCK])
})

test("withLock runs the function with no Web Locks", async () => {
  assert.equal(await withLock(undefined, () => 6), 6)
  assert.equal(await withLock({}, () => 7), 7)
})

test("save writes when the stored stamp is the base", async () => {
  const storage = memoryStorage()
  assert.deepEqual(await save(storage, fakeLocks(), {text: doc("a"), base: ""}), {saved: "a"})
  assert.equal(storage.getItem(KEY), doc("a"))
  assert.deepEqual(await save(storage, fakeLocks(), {text: doc("b"), base: "a"}), {saved: "b"})
  assert.equal(storage.getItem(KEY), doc("b"))
})

test("save refuses a stale base and gives the stored text", async () => {
  const storage = memoryStorage({[KEY]: doc("c")})
  assert.deepEqual(await save(storage, null, {text: doc("d"), base: "b"}), {conflict: doc("c"), stamp: "c"})
  assert.equal(storage.getItem(KEY), doc("c"))
})

test("save gives the errors of the storage", async () => {
  assert.deepEqual(await save(memoryStorage({}, "getItem"), null, {text: doc("a"), base: ""}),
    {error: "storage is off"})
  assert.deepEqual(await save(memoryStorage({}, "setItem"), null, {text: doc("a"), base: ""}),
    {error: "QuotaExceededError"})
  assert.deepEqual(await save(memoryStorage({}, "setItemString"), null, {text: doc("a"), base: ""}),
    {error: "full"})
  const nullThrow = {getItem() { throw null }}
  assert.deepEqual(await save(nullThrow, null, {text: doc("a"), base: ""}), {error: "null"})
})

test("load gives the stored text, or null", () => {
  assert.equal(load(memoryStorage({[KEY]: doc(4)})), doc(4))
  assert.equal(load(memoryStorage()), null)
  assert.equal(load(memoryStorage({}, "getItem")), null)
})

// Two tabs edit one build, as in specs/Device.tla. A tab sends the next
// save before its hook answers the last one: the base of a save is the
// stamp of the build of the last edit. A conflict makes the tab show the
// stored build. An edit that was stored stays stored (no lost update).
test("two tabs never lose a stored change", async () => {
  const action = fc.record({tab: fc.constantFrom(0, 1), kind: fc.constantFrom("edit", "store")})
  await fc.assert(fc.asyncProperty(fc.array(action, {maxLength: 40}), async (actions) => {
    const storage = memoryStorage()
    const locks = fakeLocks()
    const tabs = [0, 1].map(() => ({edits: [], base: "", queue: []}))
    const stored = new Set()
    let next = 0
    for (const {tab, kind} of actions) {
      const t = tabs[tab]
      if (kind === "edit") {
        const stamp = `s${++next}`
        t.edits = [...t.edits, next]
        t.queue.push({text: doc(stamp, {edits: t.edits}), base: t.base})
        t.base = stamp
      } else if (t.queue.length) {
        const result = await save(storage, locks, t.queue.shift())
        if ("saved" in result) {
          for (const e of JSON.parse(storage.getItem(KEY)).edits) stored.add(e)
        } else {
          t.edits = result.conflict ? JSON.parse(result.conflict).edits : []
          t.base = result.stamp
          t.queue = []
        }
      }
      const now = new Set(JSON.parse(storage.getItem(KEY) || '{"edits": []}').edits)
      for (const e of stored) assert.ok(now.has(e), `edit ${e} is lost`)
    }
  }))
})

test("storageOf gives the localStorage, or a storage that refuses each save", () => {
  const local = memoryStorage()
  assert.equal(storageOf({localStorage: local}), local)
  const refused = {get localStorage() { throw new Error("SecurityError") }}
  for (const win of [refused, {}]) {
    const storage = storageOf(win)
    assert.equal(storage.getItem(KEY), null)
    assert.throws(() => storage.setItem(KEY, "x"), /does not let this page keep data/)
  }
})

// A fake LiveView hook context.
function hookContext() {
  const pushed = []
  const handlers = {}
  return {
    pushed,
    handlers,
    pushEvent(name, payload) { pushed.push([name, payload]) },
    handleEvent(name, fn) { handlers[name] = fn },
  }
}

function fakeTarget() {
  const listeners = new Map()
  return {
    listeners,
    addEventListener(name, fn) { listeners.set(name, fn) },
    removeEventListener(name, fn) { if (listeners.get(name) === fn) listeners.delete(name) },
  }
}

test("the hook restores, saves, and tells about conflicts and changes", async () => {
  const storage = memoryStorage({[KEY]: doc("b")})
  const target = fakeTarget()
  const hook = Object.assign(hookContext(), deviceHook({storage, locks: fakeLocks(), target}))

  hook.mounted()
  assert.deepEqual(hook.pushed.shift(), ["device:restore", {text: doc("b"), stamp: "b"}])

  await hook.handlers["device:save"]({text: doc("c"), base: "b", epoch: 0})
  assert.deepEqual(hook.pushed.shift(), ["device:saved", {stamp: "c"}])

  await hook.handlers["device:save"]({text: doc("d"), base: "b", epoch: 2})
  assert.deepEqual(hook.pushed.shift(), ["device:conflict", {text: doc("c"), stamp: "c", epoch: 2}])

  target.listeners.get("storage")({key: "other", newValue: "x"})
  assert.equal(hook.pushed.length, 0)
  target.listeners.get("storage")({key: KEY, newValue: doc("e")})
  assert.deepEqual(hook.pushed.shift(), ["device:changed", {text: doc("e"), stamp: "e"}])

  hook.destroyed()
  assert.equal(target.listeners.size, 0)
})

test("the hook tells about an error of the storage", async () => {
  const storage = memoryStorage({}, "setItem")
  const hook = Object.assign(hookContext(), deviceHook({storage, locks: null, target: fakeTarget()}))
  hook.mounted()
  assert.deepEqual(hook.pushed.shift(), ["device:restore", {text: null, stamp: ""}])
  await hook.handlers["device:save"]({text: doc("a"), base: "", epoch: 0})
  assert.deepEqual(hook.pushed.shift(), ["device:error", {error: "QuotaExceededError"}])
})
