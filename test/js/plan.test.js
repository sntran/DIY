// The tests of assets/js/plan.js: the math of the plan, and the hook Plan.
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {
  numbers,
  surfaceOf,
  heightAt,
  forward,
  inverse,
  delta,
  resize,
  outline,
  zoom,
  arrow,
  onSurface,
  unitsOf,
  planHook,
} from "../../assets/js/plan.js"

// The units of one inch (DIYWeb.Cutaway.k/0).
const K = [0.219964, 0.127, 0.254]
const near = (a, b, e = 1e-6) => assert.ok(Math.abs(a - b) < e, `${a} is not near ${b}`)

test("the numbers of an attribute, and the surface of a room", () => {
  assert.deepEqual(numbers(" 1 2.5  -3 "), [1, 2.5, -3])
  const el = {getAttribute: (name) => ({"data-origin": "10 20", "data-plan": "0 0 100 200", "data-rise": "40"})[name]}
  assert.deepEqual(surfaceOf(el), {origin: [10, 20], plan: [0, 0, 100, 200], rise: 40})
  const flat = {getAttribute: (name) => (name === "data-rise" ? null : "1 2")}
  assert.equal(surfaceOf(flat).rise, 0)
})

test("the height of a roof: 0 at the eaves, the rise at the ridge", () => {
  const roof = {origin: [0, 0], plan: [0, 100, 300, 200], rise: 60}
  assert.equal(heightAt(roof, 100), 0)
  assert.equal(heightAt(roof, 200), 60)
  assert.equal(heightAt(roof, 300), 0)
  assert.equal(heightAt({...roof, rise: 0}, 200), 0)
})

// A surface: a floor (rise 0) or a roof (a pitch of 5 in 12, as
// DIYWeb.Cutaway), at any place of the plan. A point of the plan has x and
// y from 0 to 1 of the surface, or out of it.
const surfaces = fc
  .record({
    origin: fc.tuple(fc.double({min: -200, max: 200, noNaN: true}), fc.double({min: -200, max: 200, noNaN: true})),
    plan: fc.tuple(
      fc.integer({min: -1000, max: 1000}),
      fc.integer({min: -1000, max: 1000}),
      fc.integer({min: 24, max: 2400}),
      fc.integer({min: 24, max: 2400}),
    ),
    roof: fc.boolean(),
  })
  .map(({origin, plan, roof}) => ({origin, plan, rise: roof ? Math.round(((plan[3] / 2) * 5) / 12) : 0}))
const part = (min, max) => fc.double({min, max, noNaN: true})
const at = (s, u, v) => ({x: s.plan[0] + u * s.plan[2], y: s.plan[1] + v * s.plan[3]})

test("a point goes to the SVG and back, on a floor and on a roof", () => {
  fc.assert(
    fc.property(surfaces, part(-0.5, 1.5), part(0, 1), (s, u, v) => {
      const p = at(s, u, v)
      const back = inverse(forward(p, s, K), s, K)
      near(back.x, p.x, 1e-6)
      near(back.y, p.y, 1e-6)
    }),
  )
})

test("a point on a surface is on it; a point out of it is not", () => {
  fc.assert(
    fc.property(surfaces, part(0.01, 0.99), part(0.01, 0.99), (s, u, v) => {
      assert.ok(onSurface(forward(at(s, u, v), s, K), s, K))
      // Out of the surface along x (on its plane).
      assert.ok(!onSurface(forward(at(s, u + 1, v), s, K), s, K))
      assert.ok(!onSurface(forward(at(s, u - 1, v), s, K), s, K))
    }),
  )
})

test("the units of one pixel: the side that limits the view", () => {
  assert.equal(unitsOf({w: 200, h: 400}, 400, 800), 0.5)
  assert.equal(unitsOf({w: 200, h: 400}, 2000, 100), 4)
  assert.equal(unitsOf({w: 200, h: 400}, 0, 0), 400)
})

test("a point on each slope of a roof goes to the SVG and back", () => {
  const roof = {origin: [5, -40], plan: [0, 0, 300, 200], rise: 42}
  for (const point of [{x: 50, y: 30}, {x: 120, y: 170}, {x: 0, y: 100}]) {
    const back = inverse(forward(point, roof, K), roof, K)
    near(back.x, point.x)
    near(back.y, point.y)
  }
})

test("a move on the SVG is a move on the plan", () => {
  const {dx, dy} = delta(K[0] * 10, K[1] * 10, K)
  near(dx, 10)
  near(dy, 0)
})

test("a wall of a room moves", () => {
  const plan = [10, 20, 100, 200]
  assert.deepEqual(resize(plan, "x0", 5, 7), [15, 20, 95, 200])
  assert.deepEqual(resize(plan, "x1", 5, 7), [10, 20, 105, 200])
  assert.deepEqual(resize(plan, "y0", 5, 7), [10, 27, 100, 193])
  assert.deepEqual(resize(plan, "y1", 5, 7), [10, 20, 100, 207])
  assert.equal(outline([0, 0, 10, 10], [1, 2], K), "1.0,2.0 3.2,3.3 1.0,4.5 -1.2,3.3")
})

test("a zoom keeps the point under it, between its two limits", () => {
  const fit = {x: 0, y: 0, w: 120, h: 240}
  const view = zoom(fit, 2, 60, 60, fit)
  assert.deepEqual(view, {x: 30, y: 30, w: 60, h: 120})
  assert.equal(zoom(fit, 100, 0, 0, fit).w, 10)
  assert.equal(zoom(fit, 0.01, 0, 0, fit).w, 240)
})

test("the arrow keys", () => {
  assert.deepEqual(arrow("ArrowRight", false), {dx: 6, dy: 0})
  assert.deepEqual(arrow("ArrowLeft", true), {dx: -24, dy: 0})
  assert.deepEqual(arrow("ArrowDown", false), {dx: 0, dy: 6})
  assert.deepEqual(arrow("ArrowUp", false), {dx: 0, dy: -6})
  assert.equal(arrow("Enter", false), null)
})

// A small DOM: elements with attributes, a parent, classes and listeners.
class El {
  constructor(attrs = {}, parent = null) {
    this.attrs = {...attrs}
    this.parentNode = parent
    this.classes = new Set()
    this.listeners = new Map()
    this.classList = {add: (c) => this.classes.add(c), remove: (c) => this.classes.delete(c)}
    this.style = {props: {}, setProperty: (k, v) => (this.style.props[k] = v)}
  }
  getAttribute(name) {
    return name in this.attrs ? this.attrs[name] : null
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value)
  }
  removeAttribute(name) {
    delete this.attrs[name]
  }
  matches(selector) {
    return selector.split(",").some((one) => {
      const m = one.trim().match(/^\[([\w-]+)(?:="([^"]*)")?\]$|^#([\w-]+)$/)
      if (m[3]) return this.attrs.id === m[3]
      return m[1] in this.attrs && (m[2] === undefined || this.attrs[m[1]] === m[2])
    })
  }
  closest(selector) {
    let el = this
    while (el && !el.matches(selector)) el = el.parentNode
    return el
  }
  addEventListener(type, fun) {
    this.listeners.set(type, fun)
  }
  removeEventListener(type, fun) {
    if (this.listeners.get(type) === fun) this.listeners.delete(type)
  }
  fire(type, event) {
    this.listeners.get(type)(event)
  }
}

// The page of the plan: a kitchen (chosen, with its outline and handles),
// a living room, a roof, and a fridge in the kitchen. Then the buttons.
function setup({storage = new Map(), chosen = true, width = 400, height = 800} = {}) {
  const els = []
  const add = (attrs, parent) => {
    const el = new El(attrs, parent)
    els.push(el)
    return el
  }
  const svg = add({"data-k": K.join(" "), "data-fit": "0 0 200 400", viewBox: "0 0 200 400"})
  svg.clientWidth = width
  svg.clientHeight = height
  const ground = add({id: "plan-ground", "data-box": "0 100 100 50"}, svg)
  const kitchenG = add({id: "plan-room-r1"}, ground)
  const kitchen = add({"data-room": "r1", "data-plan": "0 0 100 100", "data-origin": "0 0"}, kitchenG)
  const living = add({"data-room": "r2", "data-plan": "100 0 100 100", "data-origin": "0 0"}, ground)
  const roof = add({"data-room": "r3", "data-plan": "0 0 200 100", "data-origin": "0 -50", "data-rise": "20"}, ground)
  const fridgeG = add({"data-item": "i1", "data-in": "r1", "data-at": "18 15"}, ground)
  const fridge = add({}, fridgeG)
  const empty = add({}, svg)
  let selection = null
  let outlineEl = null
  const handles = {}
  if (chosen) {
    selection = add({id: "plan-selection"}, svg)
    outlineEl = add({"data-outline": "r1", "data-plan": "0 0 100 100", "data-origin": "0 0"}, selection)
    for (const edge of ["x0", "x1", "y0", "y1"]) handles[edge] = add({"data-handle": edge, "data-room-id": "r1"}, selection)
  }
  const within = (el, root) => {
    while (el && el !== root) el = el.parentNode
    return el === root
  }
  for (const root of [svg, ground]) {
    root.querySelector = (selector) => els.find((el) => el !== root && within(el, root) && el.matches(selector)) || null
    root.querySelectorAll = (selector) => els.filter((el) => el !== root && within(el, root) && el.matches(selector))
  }
  svg.captured = []
  svg.setPointerCapture = (id) => svg.captured.push(id)
  // The screen: 2 pixels for one SVG unit, from 10, 20.
  svg.getScreenCTM = () => ({a: 2, d: 2, e: 10, f: 20})

  let under = []
  const win = {
    sessionStorage:
      storage === null
        ? {
            getItem: () => {
              throw new Error("no storage")
            },
            setItem: () => {
              throw new Error("no storage")
            },
          }
        : {getItem: (k) => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v)},
  }
  const doc = {defaultView: win, elementsFromPoint: () => under}
  const root = new El({id: "plan"})
  root.ownerDocument = doc
  root.querySelector = (selector) => (selector === "svg" ? svg : null)
  const zoomIn = new El({"data-zoom": "in"}, root)
  const zoomOut = new El({"data-zoom": "out"}, root)
  const fitButton = new El({"data-zoom": "fit"}, root)
  const focus = new El({"data-focus": "ground"}, root)
  const listItem = new El({"data-nudge": "i1"}, root)
  const listRoom = new El({"data-nudge-room": "r1"}, root)
  const other = new El({}, root)

  const pushed = []
  const hook = Object.assign({el: root}, planHook)
  hook.pushEvent = (event, payload, reply) => {
    pushed.push([event, payload])
    if (reply) hook.replies.push(reply)
  }
  hook.replies = []
  hook.mounted()
  const pointer = (type, id, x, y, target = empty) =>
    svg.fire(type, {pointerId: id, clientX: x, clientY: y, target, preventDefault() {}})
  return {
    hook, svg, root, kitchen, living, roof, fridge, fridgeG, kitchenG, empty, selection, outlineEl, handles,
    pushed, pointer, storage, setUnder: (list) => (under = list),
    zoomIn, zoomOut, fitButton, focus, listItem, listRoom, other,
  }
}

test("the view: the box of the house, or the view that the person had", () => {
  const first = setup()
  assert.equal(first.svg.getAttribute("viewBox"), "0.00 0.00 200.00 400.00")
  assert.equal(first.svg.style.props["--p-label"], "6.000px")
  assert.equal(first.storage.get("plan-view"), "0.00 0.00 200.00 400.00")

  const again = setup({storage: new Map([["plan-view", "1 2 30 60"]])})
  assert.deepEqual(again.hook.view, {x: 1, y: 2, w: 30, h: 60})

  // With no storage, and with no size yet.
  const none = setup({storage: null, width: 0, height: 0})
  assert.deepEqual(none.hook.view, {x: 0, y: 0, w: 200, h: 400})
  assert.equal(none.svg.style.props["--p-handle"], "4800.000px")
  none.pointer("pointerdown", 1, 100, 100)
  none.pointer("pointermove", 1, 110, 100)
  assert.equal(none.hook.view.x, -4000)

  // A wide SVG: its height limits the view.
  const wide = setup({width: 2000, height: 100})
  assert.equal(wide.svg.style.props["--p-label"], "48.000px")
})

test("a drag on an empty place moves the view, and a tap clears the choice", () => {
  const {hook, pointer, pushed, svg} = setup()
  pointer("pointerdown", 1, 100, 100)
  assert.deepEqual(svg.captured, [1])
  pointer("pointermove", 1, 102, 101)
  assert.equal(hook.view.x, 0)
  pointer("pointermove", 1, 140, 100)
  assert.equal(hook.view.x, -20)
  pointer("pointerup", 1, 140, 100)
  assert.deepEqual(pushed, [])

  pointer("pointerdown", 2, 100, 100)
  pointer("pointerup", 2, 100, 100)
  assert.deepEqual(pushed, [["select_room", {id: ""}]])

  // Events of a pointer that is not down do nothing.
  pointer("pointermove", 9, 1, 1)
  pointer("pointerup", 9, 1, 1)
  assert.equal(pushed.length, 1)
})

test("a tap chooses a room or opens an item; a tap on a handle does nothing", () => {
  const {pointer, pushed, living, fridge, handles} = setup()
  pointer("pointerdown", 1, 50, 50, living)
  pointer("pointerup", 1, 50, 50)
  pointer("pointerdown", 1, 50, 50, fridge)
  pointer("pointerup", 1, 50, 50)
  pointer("pointerdown", 1, 50, 50, handles.x1)
  pointer("pointerup", 1, 50, 50)
  assert.deepEqual(pushed, [
    ["select_room", {id: "r2"}],
    ["open_item", {id: "i1"}],
  ])
})

test("an item goes to the room under the center of its space, not under the pointer", () => {
  const {hook, pointer, pushed, fridge, fridgeG, kitchen, living, setUnder} = setup()
  // 40 inches along x: the center stays in the kitchen, but the pointer
  // (on the top of the fridge) is on the living room.
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 100 + 2 * K[0] * 40, 100 + 2 * K[1] * 40)
  assert.equal(fridgeG.getAttribute("transform"), "translate(8.80 5.08)")
  assert.ok(fridgeG.classes.has("p-dragging"))
  setUnder([fridge, living])
  pointer("pointerup", 1, 100, 100)
  assert.deepEqual(pushed, [["place_item", {id: "i1", room: "r1", x: 58, y: 15}]])

  // The reply of the server: the item goes back (the server draws it).
  hook.replies.pop()()
  assert.equal(fridgeG.getAttribute("transform"), null)
  assert.ok(!fridgeG.classes.has("p-dragging"))

  // 100 inches: the center is in the living room, under the kitchen.
  setUnder([fridge, kitchen])
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 100 + 2 * K[0] * 100, 100 + 2 * K[1] * 100)
  pointer("pointerup", 1, 100, 100)
  assert.deepEqual(pushed[1], ["place_item", {id: "i1", room: "r2", x: 118, y: 15}])

  // Far from all the rooms: the room under the pointer, else its own room.
  setUnder([living])
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 100 + 2 * K[0] * 900, 100 + 2 * K[1] * 900)
  pointer("pointerup", 1, 100, 100)
  assert.equal(pushed[2][1].room, "r2")
  setUnder([])
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 100 + 2 * K[0] * 900, 100 + 2 * K[1] * 900)
  pointer("pointerup", 1, 100, 100)
  assert.equal(pushed[3][1].room, "r1")
})

test("the chosen room moves with its items, and a wall moves with its handle", () => {
  const {hook, pointer, pushed, kitchen, kitchenG, fridgeG, selection, outlineEl, handles} = setup()
  pointer("pointerdown", 1, 100, 100, kitchen)
  pointer("pointermove", 1, 100 + 2 * K[0] * 12, 100 + 2 * K[1] * 12)
  for (const el of [kitchenG, fridgeG, selection]) assert.equal(el.getAttribute("transform"), "translate(2.64 1.52)")
  pointer("pointerup", 1, 100, 100)
  assert.deepEqual(pushed, [["move_room", {id: "r1", dx: 12, dy: 0}]])
  hook.replies.pop()()
  assert.equal(kitchenG.getAttribute("transform"), null)

  pointer("pointerdown", 1, 100, 100, handles.x1)
  pointer("pointermove", 1, 100 + 2 * K[0] * 24, 100 + 2 * K[1] * 24)
  assert.equal(outlineEl.getAttribute("points"), outline([0, 0, 124, 100], [0, 0], K))
  assert.equal(handles.x1.getAttribute("transform"), "translate(5.28 3.05)")
  pointer("pointerup", 1, 100, 100)
  assert.deepEqual(pushed[1], ["size_room", {id: "r1", edge: "x1", dx: 24, dy: 0}])
  hook.replies.pop()()
  assert.equal(outlineEl.getAttribute("points"), outline([0, 0, 100, 100], [0, 0], K))
  assert.equal(handles.x1.getAttribute("transform"), null)
})

test("a room that is not chosen does not move: the drag moves the view", () => {
  const {hook, pointer, pushed, kitchen} = setup({chosen: false})
  pointer("pointerdown", 1, 100, 100, kitchen)
  pointer("pointermove", 1, 140, 100)
  pointer("pointerup", 1, 140, 100)
  assert.equal(hook.view.x, -20)
  assert.deepEqual(pushed, [])
})

test("two fingers zoom; a third does nothing; a cancel stops a drag", () => {
  const {hook, pointer, fridge, fridgeG} = setup()
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 120, 100)
  // A second finger: the item goes back, and the fingers zoom.
  pointer("pointerdown", 2, 200, 100)
  assert.equal(fridgeG.getAttribute("transform"), null)
  pointer("pointerdown", 3, 300, 300)
  pointer("pointerup", 3, 300, 300)
  pointer("pointermove", 2, 280, 100)
  assert.equal(hook.view.w, 100)
  pointer("pointerup", 2, 280, 100)
  // The pinch ends: the finger that stays does nothing.
  pointer("pointermove", 1, 130, 100)
  assert.equal(hook.view.w, 100)
  pointer("pointerup", 1, 130, 100)

  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 120, 100)
  pointer("pointercancel", 1, 120, 100)
  assert.equal(fridgeG.getAttribute("transform"), null)
  assert.equal(hook.drag, null)

  // A cancel of a drag of the view, and of nothing.
  pointer("pointerdown", 1, 100, 100)
  pointer("pointercancel", 1, 100, 100)
  pointer("pointercancel", 1, 100, 100)
  assert.equal(hook.drag, null)
})

test("the wheel and the buttons zoom", () => {
  const {hook, svg, root, zoomIn, zoomOut, fitButton, focus, other} = setup()
  let prevented = false
  svg.fire("wheel", {clientX: 210, clientY: 420, deltaY: -462.1, preventDefault: () => (prevented = true)})
  assert.ok(prevented)
  near(hook.view.w, 100, 0.1)

  root.fire("click", {target: fitButton})
  assert.equal(hook.view.w, 200)
  root.fire("click", {target: zoomIn})
  near(hook.view.w, 200 / 1.5)
  root.fire("click", {target: zoomOut})
  near(hook.view.w, 200)
  root.fire("click", {target: focus})
  assert.equal(svg.getAttribute("viewBox"), "-5.00 97.50 110.00 55.00")
  root.fire("click", {target: other})
  assert.equal(svg.getAttribute("viewBox"), "-5.00 97.50 110.00 55.00")
})

test("the arrow keys move an item or a room of the list", () => {
  const {root, pushed, listItem, listRoom, other} = setup()
  let prevented = 0
  const key = (target, k, shiftKey = false) =>
    root.fire("keydown", {target, key: k, shiftKey, preventDefault: () => prevented++})
  key(listItem, "ArrowRight")
  key(listRoom, "ArrowUp", true)
  key(listItem, "Enter")
  key(other, "ArrowLeft")
  key({}, "ArrowLeft")
  assert.equal(prevented, 2)
  assert.deepEqual(pushed, [
    ["nudge_item", {id: "i1", dx: 6, dy: 0}],
    ["nudge_room", {id: "r1", dx: 0, dy: -24}],
  ])
})

test("the hook goes: it removes its listeners", () => {
  const {hook, svg, root} = setup()
  hook.destroyed()
  assert.equal(svg.listeners.size, 0)
  assert.equal(root.listeners.size, 0)
})
