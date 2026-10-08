// The tests of assets/js/sheet.js.
import {test} from "node:test"
import assert from "node:assert/strict"
import {sheetHook, FOCUSABLE} from "../../assets/js/sheet.js"

// An element that can have the focus.
function focusable(doc, name, {tabIndex = 0, visible = true} = {}) {
  return {
    name,
    tabIndex,
    isConnected: true,
    getClientRects: () => (visible ? [{}] : []),
    focus() {
      doc.activeElement = this
    },
  }
}

function setup(names = ["close", "field", "save"]) {
  const listeners = new Map()
  const doc = {
    activeElement: null,
    addEventListener: (type, fun) => listeners.set(type, fun),
    removeEventListener: (type, fun) => listeners.get(type) === fun && listeners.delete(type),
  }
  const before = focusable(doc, "item link")
  doc.activeElement = before
  const backdrop = focusable(doc, "backdrop", {tabIndex: -1})
  const hidden = focusable(doc, "hidden", {visible: false})
  const items = names.map((name) => focusable(doc, name))
  let closed = 0
  const el = {
    ownerDocument: doc,
    querySelector(selector) {
      assert.equal(selector, "[data-close]")
      return {click: () => closed++}
    },
    querySelectorAll(selector) {
      assert.equal(selector, FOCUSABLE)
      return [backdrop, ...items, hidden]
    },
    contains: (node) => node === backdrop || node === hidden || items.includes(node),
  }
  const hook = Object.assign({el}, sheetHook)
  hook.mounted()
  const press = (key, shiftKey = false) => {
    let prevented = false
    listeners.get("keydown")({key, shiftKey, preventDefault: () => (prevented = true)})
    return prevented
  }
  return {hook, doc, before, items, listeners, press, closed: () => closed}
}

test("the Escape key closes the sheet", () => {
  const {press, closed} = setup()
  assert.equal(press("Escape"), true)
  assert.equal(closed(), 1)
})

test("the Tab key keeps the focus in the sheet", () => {
  const {doc, items, press} = setup()
  const [close, field, save] = items

  // From outside of the sheet, Tab goes to the first, Shift+Tab to the last.
  assert.equal(press("Tab"), true)
  assert.equal(doc.activeElement, close)
  doc.activeElement = {name: "page"}
  assert.equal(press("Tab", true), true)
  assert.equal(doc.activeElement, save)

  // After the last, the first; before the first, the last.
  assert.equal(press("Tab"), true)
  assert.equal(doc.activeElement, close)
  assert.equal(press("Tab", true), true)
  assert.equal(doc.activeElement, save)

  // In the middle, the browser moves the focus.
  doc.activeElement = field
  assert.equal(press("Tab"), false)
  assert.equal(press("Tab", true), false)
  assert.equal(press("Enter"), false)
})

test("a sheet with nothing to focus does not trap the Tab key", () => {
  const {press} = setup([])
  assert.equal(press("Tab"), false)
})

test("the focus goes back when the sheet closes, if the element is there", () => {
  const {hook, doc, before, items, listeners} = setup()
  doc.activeElement = items[1]
  hook.destroyed()
  assert.equal(doc.activeElement, before)
  assert.equal(listeners.has("keydown"), false)

  const second = setup()
  second.before.isConnected = false
  second.doc.activeElement = second.items[0]
  second.hook.destroyed()
  assert.equal(second.doc.activeElement, second.items[0])

  const third = setup()
  third.hook.previous = null
  third.hook.destroyed()
})
