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
  focus,
  frame,
  clamp,
  overlaps,
  planHook,
} from "../../assets/js/plan.js"

// The axes of a camera (DIYWeb.Camera.axes/1): the SVG vectors of one inch
// along x, along y and up, from its yaw and its pitch (degrees).
const axesOf = (yaw, pitch) => {
  const [a, b] = [(yaw * Math.PI) / 180, (pitch * Math.PI) / 180]
  const k = 12.25 * 0.0254
  return [
    k * Math.sin(a),
    k * Math.cos(a) * Math.sin(b),
    -k * Math.cos(a),
    k * Math.sin(a) * Math.sin(b),
    0,
    -k * Math.cos(b),
  ]
}
// The axes of the two cameras of the app, as the SVG has them.
const HOUSE = [0.269464, 0.086996, -0.155575, 0.150682, 0.0, -0.257955]
const VAN = [0.096151, 0.138927, -0.295921, 0.04514, 0.0, -0.274729]
// The move on the SVG of some inches along x, as a transform.
const along = (inches) => `translate(${(inches * HOUSE[0]).toFixed(2)} ${(inches * HOUSE[1]).toFixed(2)})`
const near = (a, b, e = 1e-6) => assert.ok(Math.abs(a - b) < e, `${a} is not near ${b}`)
// A camera that turns and looks down as the cameras of the app do. It looks
// down more than a roof slopes (5 in 12, 23 degrees): so it sees the two
// slopes of a roof.
const cameras = fc.tuple(fc.integer({min: 10, max: 80}), fc.integer({min: 25, max: 80})).map(([y, p]) => axesOf(y, p))

test("the axes of the two cameras", () => {
  axesOf(60, 34).forEach((n, i) => near(n, HOUSE[i]))
  axesOf(18, 28).forEach((n, i) => near(n, VAN[i]))
})

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

test("a point goes to the SVG and back, on a floor and on a roof, for each camera", () => {
  fc.assert(
    fc.property(cameras, surfaces, part(-0.5, 1.5), part(0, 1), (axes, s, u, v) => {
      const p = at(s, u, v)
      const back = inverse(forward(p, s, axes), s, axes)
      near(back.x, p.x, 1e-6)
      near(back.y, p.y, 1e-6)
    }),
  )
})

test("a point on a surface is on it; a point out of it is not", () => {
  fc.assert(
    fc.property(cameras, surfaces, part(0.01, 0.99), part(0.01, 0.99), (axes, s, u, v) => {
      assert.ok(onSurface(forward(at(s, u, v), s, axes), s, axes))
      // Out of the surface along x (on its plane).
      assert.ok(!onSurface(forward(at(s, u + 1, v), s, axes), s, axes))
      assert.ok(!onSurface(forward(at(s, u - 1, v), s, axes), s, axes))
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
  for (const axes of [HOUSE, VAN])
    for (const point of [{x: 50, y: 30}, {x: 120, y: 170}, {x: 0, y: 100}]) {
      const back = inverse(forward(point, roof, axes), roof, axes)
      near(back.x, point.x)
      near(back.y, point.y)
    }
})

test("a move on the SVG is a move on the plan", () => {
  for (const axes of [HOUSE, VAN]) {
    const along = delta(axes[0] * 10, axes[1] * 10, axes)
    near(along.dx, 10)
    near(along.dy, 0)
    const across = delta(axes[2] * 7, axes[3] * 7, axes)
    near(across.dx, 0)
    near(across.dy, 7)
  }
})

test("a wall of a room moves", () => {
  const plan = [10, 20, 100, 200]
  assert.deepEqual(resize(plan, "x0", 5, 7), [15, 20, 95, 200])
  assert.deepEqual(resize(plan, "x1", 5, 7), [10, 20, 105, 200])
  assert.deepEqual(resize(plan, "y0", 5, 7), [10, 27, 100, 193])
  assert.deepEqual(resize(plan, "y1", 5, 7), [10, 20, 100, 207])
  assert.equal(outline([0, 0, 10, 10], [1, 2], HOUSE), "1.0,2.0 3.7,2.9 2.1,4.4 -0.6,3.5")
})

test("a zoom keeps the point under it, between its two limits", () => {
  const fit = {x: 0, y: 0, w: 120, h: 240}
  const view = zoom(fit, 2, 60, 60, fit)
  assert.deepEqual(view, {x: 30, y: 30, w: 60, h: 120})
  assert.equal(zoom(fit, 100, 0, 0, fit).w, 10)
  assert.equal(zoom(fit, 0.01, 0, 0, fit).w, 240)
})

test("the arrow keys move as they point on the screen", () => {
  // The house: x to the right, and y (to the front) down.
  const house = [1, 0, 0, 1]
  assert.deepEqual(arrow("ArrowRight", false, house), {dx: 6, dy: 0})
  assert.deepEqual(arrow("ArrowLeft", true, house), {dx: -24, dy: 0})
  assert.deepEqual(arrow("ArrowDown", false, house), {dx: 0, dy: 6})
  assert.deepEqual(arrow("ArrowUp", false, house), {dx: 0, dy: -6})
  assert.equal(arrow("Enter", false, house), null)
  // A van: its back (y = 0) to the right, and its left side (x) down.
  const van = [0, -1, 1, 0]
  assert.deepEqual(arrow("ArrowRight", false, van), {dx: 0, dy: -6})
  assert.deepEqual(arrow("ArrowLeft", false, van), {dx: 0, dy: 6})
  assert.deepEqual(arrow("ArrowUp", true, van), {dx: -24, dy: 0})
})

test("two boxes overlap, or not; with a gap, two near boxes overlap", () => {
  const a = {x: 0, y: 0, width: 10, height: 4}
  assert.ok(overlaps(a, {x: 9, y: 3, width: 5, height: 5}))
  assert.ok(!overlaps(a, {x: 10, y: 0, width: 5, height: 5}))
  assert.ok(!overlaps(a, {x: 0, y: 4, width: 5, height: 5}))
  assert.ok(!overlaps(a, {x: -6, y: 0, width: 5, height: 5}))
  assert.ok(overlaps(a, {x: -6, y: 0, width: 5, height: 5}, 2))
  assert.ok(!overlaps(a, {x: -6, y: 0, width: 5, height: 5}, 1))
})

const same = (a, b) => ["x", "y", "w", "h"].forEach((k) => near(a[k], b[k]))

test("a zoom in to a room: the room fills the screen, and a smaller view stays", () => {
  const view = {x: 0, y: 0, w: 200, h: 400}
  const fit = {x: 0, y: 0, w: 210, h: 400}
  // A wide room on a tall screen: its width limits the view.
  same(focus(view, {x: 10, y: 10, w: 100, h: 20}, 0.5, fit), {x: 2.5, y: -95, w: 115, h: 230})
  // A tall room on a wide screen: its height limits the view.
  same(focus(view, {x: 10, y: 10, w: 10, h: 100}, 1, fit), {x: -42.5, y: 2.5, w: 115, h: 115})
  // A small room: the view shows a third of the house at least.
  same(focus(view, {x: 10, y: 10, w: 10, h: 10}, 1, fit), {x: -20, y: -20, w: 70, h: 70})
  // The view shows the room in more detail: it stays (a tap).
  const small = {x: 0, y: 0, w: 50, h: 100}
  assert.equal(focus(small, {x: 10, y: 10, w: 100, h: 20}, 0.5, fit), small)
  // A choice in the list or an arrow (all): the view stays when all the
  // room is in it. Else it frames the room.
  assert.equal(focus(small, {x: 10, y: 10, w: 30, h: 20}, 0.5, fit, true), small)
  same(focus(small, {x: 10, y: 10, w: 100, h: 20}, 0.5, fit, true), {x: 2.5, y: -95, w: 115, h: 230})
  same(focus(small, {x: 10, y: 90, w: 30, h: 20}, 0.5, fit, true), {x: -10, y: 30, w: 70, h: 140})
})

test("a frame shows a box with a margin, at the middle, on the shape of the screen", () => {
  same(frame({x: 0, y: 100, w: 100, h: 50}, 0.5, 1.05), {x: -2.5, y: 20, w: 105, h: 210})
  same(frame({x: 0, y: 0, w: 100, h: 100}, 2), {x: -65, y: -7.5, w: 230, h: 115})
  same(frame({x: 0, y: 0, w: 10, h: 10}, 1, 1, 50), {x: -20, y: -20, w: 50, h: 50})
})

test("a view keeps the house on the screen", () => {
  const fit = {x: 0, y: 0, w: 200, h: 400}
  // A smaller view stays in the house.
  same(clamp({x: -30, y: 390, w: 100, h: 50}, fit), {x: 0, y: 350, w: 100, h: 50})
  same(clamp({x: 150, y: -5, w: 100, h: 50}, fit), {x: 100, y: 0, w: 100, h: 50})
  same(clamp({x: 20, y: 30, w: 100, h: 50}, fit), {x: 20, y: 30, w: 100, h: 50})
  // A larger view keeps all the house.
  same(clamp({x: 50, y: -500, w: 400, h: 800}, fit), {x: 0, y: -400, w: 400, h: 800})
  same(clamp({x: -300, y: -100, w: 400, h: 800}, fit), {x: -200, y: -100, w: 400, h: 800})
  fc.assert(
    fc.property(
      fc.double({min: -1000, max: 1000, noNaN: true}),
      fc.double({min: -1000, max: 1000, noNaN: true}),
      fc.double({min: 1, max: 800, noNaN: true}),
      (x, y, w) => {
        const v = clamp({x, y, w, h: w * 2}, fit)
        // The house and the view overlap as much as they can.
        const shared = (a, b, c, d) => Math.min(a + b, c + d) - Math.max(a, c)
        near(shared(v.x, v.w, fit.x, fit.w), Math.min(v.w, fit.w))
        near(shared(v.y, v.h, fit.y, fit.h), Math.min(v.h, fit.h))
      },
    ),
  )
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
  getBBox() {
    return this.bbox || {x: 0, y: 0, width: 0, height: 0}
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

// The page of the plan. Floor 1 has a kitchen (chosen, with its outline
// and handles), a living room with a wall, and a roof. It has a fridge in
// the kitchen, and three labels. Floor 2 has a bedroom. Then the buttons.
// With `start`, it is the house: it shows one layer at a time. With no
// `start`, it is the van: the tab of a layer makes the others pale.
function setup({storage = new Map(), chosen = true, width = 400, height = 800, withHint = true, start, open} = {}) {
  const els = []
  const add = (attrs, parent) => {
    const el = new El(attrs, parent)
    els.push(el)
    return el
  }
  const svg = add({
    "data-axes": HOUSE.join(" "),
    "data-arrows": "1 0 0 1",
    "data-fit": "0 0 200 400",
    viewBox: "0 0 200 400",
    ...(start && {"data-start": start}),
    ...(open && {"data-open": open}),
  })
  svg.clientWidth = width
  svg.clientHeight = height
  // The box of the layer has all its parts.
  const ground = add({id: "plan-ground", "data-box": "0 0 150 80"}, svg)
  const kitchenG = add({id: "plan-room-r1"}, ground)
  const kitchen = add({"data-room": "r1", "data-plan": "0 0 100 100", "data-origin": "0 0"}, kitchenG)
  const living = add({"data-room": "r2", "data-plan": "100 0 100 100", "data-origin": "0 0"}, ground)
  living.bbox = {x: 100, y: 50, width: 40, height: 20}
  const wall = add({"data-of": "r2"}, ground)
  wall.bbox = {x: 100, y: 30, width: 40, height: 25}
  const wallFace = add({}, wall)
  // The edge of the slab under the living room.
  const slab = add({"data-of": "r2"}, ground)
  slab.bbox = {x: 100, y: 65, width: 40, height: 5}
  // Each label has its pill (the house shows it).
  const pills = []
  const labels = [["20000", 10], ["100", 20], ["50", 60]].map(([rank, x], i) => {
    pills.push(add({"data-pill": `p${i}`}, ground))
    const label = add({"data-rank": rank, "data-label": `p${i}`}, ground)
    label.bbox = {x, y: 10, width: 30, height: 6}
    return label
  })
  const roof = add({"data-room": "r3", "data-plan": "0 0 200 100", "data-origin": "0 -50", "data-rise": "20"}, ground)
  roof.bbox = {x: 0, y: 0, width: 50, height: 10}
  // The front slope of the roof: a second polygon of the same room.
  const slope = add({"data-room": "r3", "data-plan": "0 0 200 100", "data-origin": "0 -50", "data-rise": "20"}, ground)
  slope.bbox = {x: 50, y: 0, width: 50, height: 20}
  const fridgeG = add({"data-item": "i1", "data-in": "r1", "data-at": "18 15"}, ground)
  const fridge = add({}, fridgeG)
  // The pill of a Home Assistant hub is a part of its item: here, a pill
  // of the fridge, for the test.
  const fridgePill = add({"data-item": "i1", "data-in": "r1", "data-at": "18 15"}, ground)
  const pillText = add({}, fridgePill)
  // A microwave on the fridge, and a cup on the microwave.
  const microwaveG = add({"data-item": "i5", "data-in": "r1", "data-at": "18 15", "data-on": "i1"}, ground)
  const cupG = add({"data-item": "i6", "data-in": "r1", "data-at": "18 15", "data-on": "i5"}, ground)
  // A table of the kitchen (furniture).
  const tableG = add({"data-with": "r1"}, ground)
  // A ghost of a device of Home Assistant.
  const ghostG = add({"data-ghost": "dev-1"}, ground)
  const ghostFace = add({}, ghostG)
  // Floor 2, over floor 1: a bedroom with its wall, and a lamp in it.
  const upper = add({id: "plan-f2", "data-box": "0 -100 150 80"}, svg)
  const bedroom = add({"data-room": "r4", "data-plan": "0 0 100 100", "data-origin": "0 -100"}, upper)
  bedroom.bbox = {x: 100, y: -60, width: 40, height: 20}
  const bedWall = add({"data-of": "r4"}, upper)
  bedWall.bbox = {x: 100, y: -70, width: 40, height: 40}
  const lamp = add({"data-item": "i2", "data-in": "r4", "data-at": "10 10"}, upper)
  lamp.bbox = {x: 110, y: -55, width: 5, height: 5}
  const empty = add({}, svg)
  let selection = null
  let outlineEl = null
  const handles = {}
  if (chosen) {
    selection = add({id: "plan-selection"}, svg)
    outlineEl = add({"data-outline": "r1", "data-plan": "0 0 100 100", "data-origin": "0 0"}, selection)
    const at = {x0: [0, 50], x1: [100, 50], y0: [50, 0], y1: [50, 100]}
    for (const edge of ["x0", "x1", "y0", "y1"])
      handles[edge] = add({"data-handle": edge, "data-room-id": "r1", cx: at[edge][0], cy: at[edge][1]}, selection)
  }
  const within = (el, root) => {
    while (el && el !== root) el = el.parentNode
    return el === root
  }
  for (const root of [svg, ground, upper]) {
    root.querySelector = (selector) => els.find((el) => el !== root && within(el, root) && el.matches(selector)) || null
    root.querySelectorAll = (selector) => els.filter((el) => el !== root && within(el, root) && el.matches(selector))
  }
  svg.captured = []
  svg.setPointerCapture = (id) => svg.captured.push(id)
  // The screen: 2 pixels for one SVG unit, from 10, 20.
  svg.getScreenCTM = () => ({a: 2, d: 2, e: 10, f: 20})

  let under = []
  const timers = []
  const win = {
    scrolls: [],
    scrollBy: (x, y) => win.scrolls.push([x, y]),
    on: {},
    addEventListener: (type, fun) => (win.on[type] = fun),
    removeEventListener: (type, fun) => win.on[type] === fun && delete win.on[type],
    setTimeout: (fun, ms) => timers.push([fun, ms]) && timers.length,
    clearTimeout: (id) => id && (timers[id - 1][0] = () => {}),
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
        : {
            getItem: (k) => storage.get(k) ?? null,
            setItem: (k, v) => storage.set(k, v),
            removeItem: (k) => storage.delete(k),
          },
  }
  const doc = {
    defaultView: win,
    elementsFromPoint: () => under,
    on: {},
    addEventListener: (type, fun) => (doc.on[type] = fun),
    removeEventListener: (type, fun) => doc.on[type] === fun && delete doc.on[type],
  }
  const root = new El({id: "plan"})
  root.id = "plan"
  root.ownerDocument = doc
  const hint = new El({"data-hint": ""}, root)
  hint.classes.add("opacity-0")
  root.querySelector = (selector) => ({svg, "[data-hint]": withHint && hint})[selector] || null
  const zoomIn = new El({"data-zoom": "in"}, root)
  const zoomOut = new El({"data-zoom": "out"}, root)
  const fitButton = new El({"data-zoom": "fit"}, root)
  const focus = new El({"data-focus": "ground"}, root)
  const focusF2 = new El({"data-focus": "f2"}, root)
  root.querySelectorAll = (selector) => (selector === "[data-focus]" ? [focus, focusF2] : [])
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
  const pointer = (type, id, x, y, target = empty, pointerType = "mouse") =>
    svg.fire(type, {pointerId: id, clientX: x, clientY: y, target, pointerType, preventDefault() {}})
  return {
    hook, svg, root, kitchen, living, roof, fridge, fridgeG, fridgePill, microwaveG, cupG, pillText, kitchenG, empty, selection, outlineEl, handles, labels, pills,
    pushed, pointer, storage, setUnder: (list) => (under = list), win, timers, hint, wallFace, slab,
    zoomIn, zoomOut, fitButton, focus, focusF2, listItem, listRoom, other, tableG, bedroom, upper, ghostFace,
  }
}

test("a tap on a ghost adds its item, and a drag on it moves the view", () => {
  const {pointer, pushed, ghostFace, hook} = setup({chosen: false})
  pointer("pointerdown", 1, 50, 50, ghostFace)
  pointer("pointerup", 1, 50, 50)
  assert.deepEqual(pushed, [["ha_add_device", {id: "dev-1"}]])
  // A drag on a ghost moves the view, as a drag on the floor does.
  pointer("pointerdown", 1, 50, 50, ghostFace)
  pointer("pointermove", 1, 80, 50, ghostFace)
  assert.equal(hook.drag.kind, "pan")
  assert.equal(hook.drag.moved, true)
  pointer("pointerup", 1, 80, 50)
  assert.equal(pushed.length, 1)
})

test("the view: the box of the house, or the view that the person had", () => {
  const first = setup()
  assert.equal(first.svg.getAttribute("viewBox"), "0.00 0.00 200.00 400.00")
  assert.equal(first.svg.style.props["--p-label"], "6.000px")
  assert.equal(first.storage.get("plan-view:plan"), "0.00 0.00 200.00 400.00")

  const again = setup({storage: new Map([["plan-view:plan", "1 2 30 60"]])})
  assert.deepEqual(again.hook.view, {x: 1, y: 2, w: 30, h: 60})

  // With no storage, and with no size yet.
  const none = setup({storage: null, width: 0, height: 0})
  assert.deepEqual(none.hook.view, {x: 0, y: 0, w: 200, h: 400})
  assert.equal(none.svg.style.props["--p-handle"], "4800.000px")
  // A zoom in, and a drag: one pixel is many units, but the house stays on
  // the screen.
  none.root.fire("click", {target: none.zoomIn})
  none.pointer("pointerdown", 1, 100, 100)
  none.pointer("pointermove", 1, 110, 100)
  assert.equal(none.hook.view.x, 0)

  // A wide SVG: its height limits the view.
  const wide = setup({width: 2000, height: 100})
  assert.equal(wide.svg.style.props["--p-label"], "48.000px")
})

test("the page starts on its first layer: its house fills the screen, and the other layers hide", () => {
  // The walls and the slabs of floor 1 (40 by 40) fill the width of the
  // screen, with a margin. The view stays in the box of the layer (150 by
  // 80): it is higher than the layer, so it starts at its top.
  const {svg, hook, kitchenG} = setup({start: "ground", chosen: false})
  assert.equal(svg.getAttribute("viewBox"), "98.40 0.00 43.20 86.40")
  assert.equal(svg.getAttribute("data-dim"), "ground")
  // A chosen room at the start (a link with the room): the view zooms in
  // to it. The kitchen of the test has no size, at 0, 0.
  const start = setup({start: "ground"})
  assert.equal(start.svg.getAttribute("viewBox"), "0.00 -20.00 50.00 100.00")
  // A layer with no walls and no slabs (a roof): its box fills the screen.
  kitchenG.setAttribute("data-box", "0 0 50 100")
  kitchenG.querySelectorAll = () => []
  const roof = hook.layerView("room-r1")
  ;[roof.x, roof.y, roof.w, roof.h].forEach((n, i) => near(n, [-1.25, -2.5, 52.5, 105][i]))

  // The view that the person had wins, with its layer. A view of all the
  // house has no layer.
  const again = setup({start: "ground", chosen: false, storage: new Map([["plan-view:plan", "1 2 30 60"]])})
  assert.deepEqual(again.hook.view, {x: 1, y: 2, w: 30, h: 60})
  assert.equal(again.svg.getAttribute("data-dim"), null)
  const storage = new Map([["plan-view:plan", "100 -90 30 60"], ["plan-view:plan:layer", "f2"]])
  const upper = setup({start: "ground", chosen: false, storage})
  assert.deepEqual(upper.hook.view, {x: 100, y: -90, w: 30, h: 60})
  assert.equal(upper.svg.getAttribute("data-dim"), "f2")
  assert.equal(upper.focusF2.getAttribute("aria-pressed"), "true")
  assert.equal(upper.focus.getAttribute("aria-pressed"), "false")
  // The chosen room (the kitchen) is on floor 1: floor 1 comes.
  const chosen = setup({start: "ground", storage: new Map(storage)})
  assert.equal(chosen.svg.getAttribute("data-dim"), "ground")
  assert.equal(chosen.storage.get("plan-view:plan:layer"), "ground")
  // A first layer that is not there: all the house.
  const gone = setup({start: "f3", chosen: false})
  assert.equal(gone.svg.getAttribute("viewBox"), "0.00 0.00 200.00 400.00")
  assert.equal(gone.svg.getAttribute("data-dim"), null)
})

test("a drag on an empty place moves the view, and a tap clears the choice", () => {
  const {hook, pointer, pushed, svg, root, zoomIn} = setup()
  // All the house shows: a drag keeps it on the screen.
  pointer("pointerdown", 1, 100, 100)
  pointer("pointermove", 1, 140, 100)
  assert.equal(hook.view.x, 0)
  pointer("pointerup", 1, 140, 100)
  // A zoom in: the view is 133 units wide, from 33.3.
  root.fire("click", {target: zoomIn})
  pointer("pointerdown", 1, 100, 100)
  assert.deepEqual(svg.captured, [1, 1])
  pointer("pointermove", 1, 102, 101)
  near(hook.view.x, 100 / 3)
  pointer("pointermove", 1, 140, 100)
  near(hook.view.x, 20)
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
  const {hook, pointer, pushed, living, fridge, handles, wallFace, slab, svg} = setup()
  pointer("pointerdown", 1, 50, 50, living)
  pointer("pointerup", 1, 50, 50)
  // The view zooms in to the room, its wall and its slab: 40 by 40. With a
  // margin, it is 46 wide: less than a third of the van (66.7). The view
  // is at the middle of the room, in the van.
  near(hook.view.w, 200 / 3)
  near(hook.view.h, 400 / 3)
  near(hook.view.x, 120 - 100 / 3)
  near(hook.view.y, 0)
  // In the house, the other layers hide. From all the house, the view
  // zooms in to less than a third of the layer of the room (150 / 3 = 50),
  // in the layer.
  const house = setup({start: "ground"})
  house.root.fire("click", {target: house.fitButton})
  house.pointer("pointerdown", 1, 50, 50, house.living)
  house.pointer("pointerup", 1, 50, 50)
  near(house.hook.view.w, 50)
  near(house.hook.view.h, 100)
  near(house.hook.view.x, 120 - 25)
  near(house.hook.view.y, 0)
  // A tap on a room of a different layer: its layer stands out, and the
  // others hide.
  house.hook.dim("f2")
  house.pointer("pointerdown", 1, 50, 50, house.living)
  house.pointer("pointerup", 1, 50, 50)
  assert.equal(house.svg.getAttribute("data-dim"), "ground")
  // A page with no size yet: a square view.
  const none = setup({width: 0, height: 0})
  none.pointer("pointerdown", 1, 50, 50, none.living)
  none.pointer("pointerup", 1, 50, 50)
  near(none.hook.view.w, 200 / 3)
  near(none.hook.view.h, 200 / 3)
  near(none.hook.view.y, 50 - 100 / 3)
  // A roof has two slopes: the zoom shows the two (100 by 20, with a
  // margin), whatever the slope of the tap.
  const top = setup()
  top.pointer("pointerdown", 1, 50, 50, top.roof)
  top.pointer("pointerup", 1, 50, 50)
  near(top.hook.view.w, 115)
  near(top.hook.view.x, 0)
  pointer("pointerdown", 1, 50, 50, fridge)
  pointer("pointerup", 1, 50, 50)
  pointer("pointerdown", 1, 50, 50, handles.x1)
  pointer("pointerup", 1, 50, 50)
  // A tap on a wall, or on the edge of the slab, chooses the room.
  pointer("pointerdown", 1, 50, 50, wallFace)
  pointer("pointerup", 1, 50, 50)
  pointer("pointerdown", 1, 50, 50, slab)
  pointer("pointerup", 1, 50, 50)
  assert.deepEqual(pushed, [
    ["select_room", {id: "r2"}],
    ["open_item", {id: "i1"}],
    ["select_room", {id: "r2"}],
    ["select_room", {id: "r2"}],
  ])
  // A tab made the layer of the room stand out: it stays. A tap on a room
  // of a different layer: no layer stands out.
  hook.dim("ground")
  pointer("pointerdown", 1, 50, 50, living)
  pointer("pointerup", 1, 50, 50)
  assert.equal(svg.getAttribute("data-dim"), "ground")
  hook.dim("f2")
  pointer("pointerdown", 1, 50, 50, living)
  pointer("pointerup", 1, 50, 50)
  assert.equal(svg.getAttribute("data-dim"), null)
})

test("a finger scrolls the page when the view shows all the house", () => {
  const {hook, pointer, pushed, win, root, zoomIn, kitchen} = setup({chosen: false})
  pointer("pointerdown", 1, 100, 300, undefined, "touch")
  pointer("pointermove", 1, 100, 298, undefined, "touch")
  assert.deepEqual(win.scrolls, [])
  pointer("pointermove", 1, 101, 280, undefined, "touch")
  pointer("pointermove", 1, 101, 250, undefined, "touch")
  assert.deepEqual(win.scrolls, [[0, 20], [0, 30]])
  pointer("pointerup", 1, 101, 250, undefined, "touch")
  assert.deepEqual(pushed, [])
  // On a room that is not chosen, the same.
  pointer("pointerdown", 1, 100, 300, kitchen, "touch")
  pointer("pointermove", 1, 100, 340, kitchen, "touch")
  pointer("pointerup", 1, 100, 340, kitchen, "touch")
  assert.deepEqual(win.scrolls.at(-1), [0, -40])
  assert.deepEqual(pushed, [])
  // After a zoom in, the finger moves the view.
  root.fire("click", {target: zoomIn})
  pointer("pointerdown", 2, 100, 300, undefined, "touch")
  pointer("pointermove", 2, 140, 300, undefined, "touch")
  near(hook.view.x, 20)
  assert.equal(win.scrolls.length, 3)
})

// A plan with a glide: a flick of the finger, and the frames of the page.
const glider = () => {
  const plan = setup({chosen: false})
  const frames = []
  plan.win.requestAnimationFrame = (fun) => frames.push(fun)
  const touch = (type, y, t, id = 1, target = plan.empty) =>
    plan.svg.fire(type, {pointerId: id, clientX: 100, clientY: y, target, pointerType: "touch", timeStamp: t, preventDefault() {}})
  // 10 pixels in 16 ms, then 20 pixels in 16 ms: near 1.1 pixels for each
  // ms.
  const flick = (t = 0) => {
    touch("pointerdown", 300, t)
    touch("pointermove", 290, t + 16)
    touch("pointermove", 270, t + 32)
    touch("pointerup", 270, t + 40)
  }
  // The frames, each `step` ms, until the glide stops: the pixels of each
  // frame.
  const run = (step = 16, from = 1000) => {
    const start = plan.win.scrolls.length
    let t = from
    while (frames.length) frames.shift()((t += step))
    return plan.win.scrolls.slice(start).map(([, y]) => y)
  }
  return {...plan, frames, touch, flick, run}
}

test("a finger that scrolls the page and lifts: the page glides and slows down", () => {
  const {hook, win, root, frames, flick, run} = glider()
  flick()
  assert.equal(frames.length, 1)
  assert.ok(win.on.pointerdown && win.on.wheel && win.on.keydown && root.ownerDocument.on.visibilitychange)
  frames.shift()(1000)
  frames.shift()(1016)
  // The distance of 16 ms at a speed that falls 5% in 16 ms.
  near(win.scrolls.at(-1)[1], (1.1 * 16 * 0.05) / -Math.log(0.95))
  const glide = run(16, 1016)
  // Each frame scrolls less than the frame before it, and the glide stops.
  assert.ok(glide.length > 20)
  assert.ok(glide.every((y, i) => i === 0 || y < glide[i - 1]))
  assert.equal(hook.gliding, null)
  assert.deepEqual(win.on, {})
  assert.deepEqual(root.ownerDocument.on, {})
})

test("the glide is the same at each rate of frames, and a long pause does not jump", () => {
  // The pixels of the glide in 320 ms: the flick itself scrolls 2 times.
  const glide = (step) => {
    const plan = glider()
    plan.flick()
    for (let t = 0; t <= 320; t += step) plan.frames.shift()(t)
    return plan.win.scrolls.slice(2).reduce((sum, [, y]) => sum + y, 0)
  }
  near(glide(8), glide(32))
  assert.ok(glide(8) > 100)

  // A pause of 5 s counts as one frame of 50 ms.
  const paused = glider()
  paused.flick()
  paused.frames.shift()(0)
  paused.frames.shift()(5000)
  assert.ok(paused.win.scrolls.at(-1)[1] < 1.1 * 50)
})

test("a touch, the wheel, a key or a hidden page stops a glide; a tap that stops it does not tap", () => {
  // A finger on the plan: the glide stops, and the tap does not open the
  // fridge.
  const plan = glider()
  plan.flick()
  // The window has the event first, then the plan has the same event.
  const press = {type: "pointerdown", pointerId: 3, clientX: 100, clientY: 300, target: plan.fridge, pointerType: "touch", timeStamp: 100, preventDefault() {}}
  plan.win.on.pointerdown(press)
  assert.equal(plan.hook.gliding, null)
  assert.deepEqual(plan.win.on, {})
  plan.svg.fire("pointerdown", press)
  plan.touch("pointerup", 300, 110, 3, plan.fridge)
  assert.deepEqual(plan.pushed, [])
  // The next tap opens it.
  plan.touch("pointerdown", 300, 200, 4, plan.fridge)
  plan.touch("pointerup", 300, 210, 4, plan.fridge)
  assert.equal(plan.pushed.at(-1)[0], "open_item")
  // A frame after the stop does nothing.
  const scrolls = plan.win.scrolls.length
  plan.run()
  assert.equal(plan.win.scrolls.length, scrolls)

  // A press out of the plan stops the glide. A later tap on the plan, with
  // the same pointer, taps.
  const outside = glider()
  outside.flick()
  outside.win.on.pointerdown({type: "pointerdown", pointerId: 1})
  outside.touch("pointerdown", 300, 500, 1, outside.fridge)
  outside.touch("pointerup", 300, 510, 1, outside.fridge)
  assert.equal(outside.pushed.at(-1)[0], "open_item")

  // With no event on the window (a touch that comes first on the plan),
  // the plan stops the glide too, with no tap.
  const first = glider()
  first.flick()
  first.touch("pointerdown", 300, 100, 5, first.fridge)
  first.touch("pointerup", 300, 110, 5, first.fridge)
  assert.deepEqual(first.pushed, [])

  // The wheel, a key, and a page out of view.
  for (const stop of [(p) => p.win.on.wheel({type: "wheel"}), (p) => p.win.on.keydown({type: "keydown"}), (p) => p.root.ownerDocument.on.visibilitychange({type: "visibilitychange"})]) {
    const other = glider()
    other.flick()
    stop(other)
    assert.equal(other.hook.gliding, null)
    assert.equal(other.hook.halted, null)
  }

  // The plan goes away during a glide.
  const gone = glider()
  gone.flick()
  gone.hook.destroyed()
  const before = gone.win.scrolls.length
  gone.run()
  assert.equal(gone.win.scrolls.length, before)
  assert.deepEqual(gone.win.on, {})

  // A finger that stops before it lifts, and a slow finger: no glide.
  const still = glider()
  still.touch("pointerdown", 300, 3000)
  still.touch("pointermove", 260, 3016)
  still.touch("pointerup", 260, 3100)
  still.touch("pointerdown", 300, 4000)
  still.touch("pointermove", 294, 5000)
  still.touch("pointerup", 294, 5010)
  assert.equal(still.frames.length, 0)
})

test("a finger on an item, or on the chosen room, moves it: the page does not scroll", () => {
  const {pointer, win, fridge, fridgeG, kitchen, kitchenG} = setup()
  pointer("pointerdown", 1, 100, 300, fridge, "touch")
  pointer("pointermove", 1, 100, 340, fridge, "touch")
  assert.ok(fridgeG.classes.has("p-dragging"))
  pointer("pointercancel", 1, 100, 340, fridge, "touch")
  pointer("pointerdown", 1, 100, 300, kitchen, "touch")
  pointer("pointermove", 1, 100, 340, kitchen, "touch")
  assert.ok(kitchenG.classes.has("p-dragging"))
  assert.deepEqual(win.scrolls, [])
})

test("a view as wide as the house but not as high: the finger moves the view", () => {
  // A wide screen: the tab of the layer gives a view of all the width of
  // the house, but not of all its height.
  const {hook, pointer, win, root, focus, slab, svg} = setup({chosen: false, width: 1000, height: 600})
  slab.bbox = {x: 0, y: 100, width: 196, height: 50}
  svg.querySelector("#plan-ground").setAttribute("data-box", "0 0 200 400")
  root.fire("click", {target: focus})
  assert.ok(hook.view.w >= 200 && hook.view.h < 400)
  const y = hook.view.y
  pointer("pointerdown", 1, 100, 300, undefined, "touch")
  pointer("pointermove", 1, 100, 360, undefined, "touch")
  assert.deepEqual(win.scrolls, [])
  assert.ok(hook.view.y < y)
})

test("an item goes to the room under the center of its space, not under the pointer", () => {
  const {hook, pointer, pushed, fridge, fridgeG, fridgePill, microwaveG, cupG, kitchen, living, setUnder} = setup()
  // 40 inches along x: the center stays in the kitchen, but the pointer
  // (on the top of the fridge) is on the living room.
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 100 + 2 * HOUSE[0] * 40, 100 + 2 * HOUSE[1] * 40)
  assert.equal(fridgeG.getAttribute("transform"), along(40))
  // The pill of the item moves with it, and the items on it, and the
  // items on them.
  assert.equal(fridgePill.getAttribute("transform"), along(40))
  assert.equal(microwaveG.getAttribute("transform"), along(40))
  assert.equal(cupG.getAttribute("transform"), along(40))
  assert.ok(fridgeG.classes.has("p-dragging"))
  setUnder([fridge, living])
  pointer("pointerup", 1, 100, 100)
  assert.deepEqual(pushed, [["place_item", {id: "i1", room: "r1", x: 58, y: 15}]])

  // The reply of the server: the item goes back (the server draws it).
  hook.replies.pop()()
  assert.equal(fridgeG.getAttribute("transform"), null)
  assert.equal(fridgePill.getAttribute("transform"), null)
  assert.ok(!fridgeG.classes.has("p-dragging"))

  // 100 inches: the center is in the living room, under the kitchen.
  setUnder([fridge, kitchen])
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 100 + 2 * HOUSE[0] * 100, 100 + 2 * HOUSE[1] * 100)
  pointer("pointerup", 1, 100, 100)
  assert.deepEqual(pushed[1], ["place_item", {id: "i1", room: "r2", x: 118, y: 15}])

  // Far from all the rooms: the room under the pointer, else its own room.
  setUnder([living])
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 100 + 2 * HOUSE[0] * 900, 100 + 2 * HOUSE[1] * 900)
  pointer("pointerup", 1, 100, 100)
  assert.equal(pushed[2][1].room, "r2")
  setUnder([])
  pointer("pointerdown", 1, 100, 100, fridge)
  pointer("pointermove", 1, 100 + 2 * HOUSE[0] * 900, 100 + 2 * HOUSE[1] * 900)
  pointer("pointerup", 1, 100, 100)
  assert.equal(pushed[3][1].room, "r1")
})

test("the chosen room moves with its items, and a wall moves with its handle", () => {
  const {hook, pointer, pushed, kitchen, kitchenG, fridgeG, tableG, selection, outlineEl, handles} = setup()
  pointer("pointerdown", 1, 100, 100, kitchen)
  pointer("pointermove", 1, 100 + 2 * HOUSE[0] * 12, 100 + 2 * HOUSE[1] * 12)
  // The furniture of the room moves too.
  for (const el of [kitchenG, fridgeG, tableG, selection]) assert.equal(el.getAttribute("transform"), along(12))
  pointer("pointerup", 1, 100, 100)
  assert.deepEqual(pushed, [["move_room", {id: "r1", dx: 12, dy: 0}]])
  hook.replies.pop()()
  assert.equal(kitchenG.getAttribute("transform"), null)
  assert.equal(tableG.getAttribute("transform"), null)

  pointer("pointerdown", 1, 100, 100, handles.x1)
  pointer("pointermove", 1, 100 + 2 * HOUSE[0] * 24, 100 + 2 * HOUSE[1] * 24)
  assert.equal(outlineEl.getAttribute("points"), outline([0, 0, 124, 100], [0, 0], HOUSE))
  assert.equal(handles.x1.getAttribute("transform"), along(24))
  pointer("pointerup", 1, 100, 100)
  assert.deepEqual(pushed[1], ["size_room", {id: "r1", edge: "x1", dx: 24, dy: 0}])
  hook.replies.pop()()
  assert.equal(outlineEl.getAttribute("points"), outline([0, 0, 100, 100], [0, 0], HOUSE))
  assert.equal(handles.x1.getAttribute("transform"), null)
})

test("a room that is not chosen does not move: the drag moves the view", () => {
  const {hook, pointer, pushed, kitchen, root, zoomIn} = setup({chosen: false})
  root.fire("click", {target: zoomIn})
  pointer("pointerdown", 1, 100, 100, kitchen)
  pointer("pointermove", 1, 140, 100)
  pointer("pointerup", 1, 140, 100)
  near(hook.view.x, 20)
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

test("Ctrl and the mouse wheel zoom; the wheel alone scrolls the page, and a note tells how to zoom", () => {
  const {hook, svg, hint, timers} = setup()
  let prevented = false
  const wheel = (keys) =>
    svg.fire("wheel", {clientX: 210, clientY: 420, deltaY: -462.1, ...keys, preventDefault: () => (prevented = true)})
  wheel({})
  assert.ok(!prevented)
  assert.equal(hook.view.w, 200)
  assert.ok(!hint.classes.has("opacity-0"))
  // A second wheel: the note stays 1.5 seconds from now.
  wheel({})
  assert.deepEqual(timers.map(([, ms]) => ms), [1500, 1500])
  timers[0][0]()
  assert.ok(!hint.classes.has("opacity-0"))
  timers[1][0]()
  assert.ok(hint.classes.has("opacity-0"))

  wheel({ctrlKey: true})
  assert.ok(prevented)
  near(hook.view.w, 100, 0.1)
  wheel({metaKey: true})
  near(hook.view.w, 50, 0.1)

  // A plan with no note: the wheel only scrolls the page.
  const bare = setup({withHint: false})
  bare.svg.fire("wheel", {clientX: 0, clientY: 0, deltaY: 100, preventDefault: () => assert.fail()})
  assert.deepEqual(bare.timers, [])
})

test("the buttons zoom; the tab of a layer shows the house of the layer, and the other layers hide", () => {
  const {hook, svg, root, zoomIn, zoomOut, fitButton, focus, other, pushed} = setup()
  root.fire("click", {target: zoomIn})
  near(hook.view.w, 200 / 1.5)
  root.fire("click", {target: zoomOut})
  near(hook.view.w, 200)
  // In the van, the parts of the layer with a room (40 by 40) fill the
  // width of the screen, with a margin. The view stays in the van.
  root.fire("click", {target: focus})
  assert.equal(svg.getAttribute("viewBox"), "98.40 6.80 43.20 86.40")
  assert.equal(svg.getAttribute("data-dim"), "ground")
  assert.equal(focus.getAttribute("aria-pressed"), "true")
  root.fire("click", {target: other})
  assert.equal(svg.getAttribute("viewBox"), "98.40 6.80 43.20 86.40")
  root.fire("click", {target: fitButton})
  assert.equal(hook.view.w, 200)
  assert.equal(svg.getAttribute("data-dim"), null)
  assert.equal(focus.getAttribute("aria-pressed"), "false")
  // The chosen room stays chosen in the van.
  root.fire("click", {target: hook.el.querySelectorAll("[data-focus]")[1]})
  assert.deepEqual(pushed, [])

  // In the house, the view stays in the box of the layer. The tab of a
  // different layer: the chosen room (the kitchen, on floor 1) hides, so it
  // is not chosen now.
  const house = setup({start: "ground"})
  house.root.fire("click", {target: house.fitButton})
  house.root.fire("click", {target: house.focus})
  assert.equal(house.svg.getAttribute("viewBox"), "98.40 0.00 43.20 86.40")
  assert.deepEqual(house.pushed, [])
  house.root.fire("click", {target: house.focusF2})
  assert.equal(house.svg.getAttribute("data-dim"), "f2")
  assert.equal(house.svg.getAttribute("viewBox"), "98.40 -100.00 43.20 86.40")
  assert.deepEqual(house.pushed, [["select_room", {id: ""}]])
})

test("a room that the person chooses in the list shows: its layer comes, and the view zooms in to it", () => {
  const {hook, svg, outlineEl, root, zoomIn} = setup({start: "ground"})
  // The kitchen is chosen, on floor 1: the server draws the page again, and
  // the view stays.
  hook.updated()
  assert.equal(svg.getAttribute("viewBox"), "0.00 -20.00 50.00 100.00")
  // The arrow of the bar goes to the living room, on the same floor. It is
  // out of the view of the kitchen: the view zooms in to it (40 by 40 at
  // 100, 30).
  outlineEl.setAttribute("data-outline", "r2")
  hook.updated()
  near(hook.view.x + hook.view.w / 2, 120)
  near(hook.view.w, 50)
  // After a zoom in, the next room comes into the view too.
  root.fire("click", {target: zoomIn})
  outlineEl.setAttribute("data-outline", "r1")
  hook.updated()
  assert.equal(svg.getAttribute("viewBox"), "0.00 -20.00 50.00 100.00")
  // In the van, a choice on the layer that shows does not move the view.
  const van = setup()
  van.outlineEl.setAttribute("data-outline", "r2")
  van.hook.updated()
  assert.equal(van.svg.getAttribute("viewBox"), "0.00 0.00 200.00 400.00")
  // The bedroom on floor 2 is chosen now: floor 2 comes.
  outlineEl.setAttribute("data-outline", "r4")
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "f2")
  near(hook.view.x + hook.view.w / 2, 120)
  // The same choice does not move the view again: the person can move it.
  hook.dim("ground")
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "ground")
  // A choice that is not a room on the plan, and no choice.
  outlineEl.setAttribute("data-outline", "r9")
  hook.updated()
  outlineEl.removeAttribute("data-outline")
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "ground")
})

test("a tap on a room does not zoom out: the room is under the finger", () => {
  const {hook, pointer, living, root, zoomIn} = setup({start: "ground", chosen: false})
  for (let i = 0; i < 3; i++) root.fire("click", {target: zoomIn})
  const view = {...hook.view}
  pointer("pointerdown", 1, 50, 50, living)
  pointer("pointerup", 1, 50, 50)
  assert.deepEqual(hook.view, view)
})

test("the sheet of an item closes after a move to a different layer: the chosen room comes back", () => {
  // The kitchen is chosen, and its fridge is open.
  const {hook, svg, fridgeG, upper} = setup({start: "ground", open: "i1"})
  assert.equal(svg.getAttribute("data-dim"), "ground")
  // The sheet moves the fridge to a room of floor 2: floor 2 comes.
  fridgeG.parentNode = upper
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "f2")
  // The sheet closes: the kitchen comes back, with floor 1.
  svg.removeAttribute("data-open")
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "ground")
})

test("a tap zooms in to a room one time: a zoom of the person before the reply of the server stays", () => {
  const {hook, pointer, living, outlineEl, root, zoomOut} = setup({start: "ground"})
  pointer("pointerdown", 1, 50, 50, living)
  pointer("pointerup", 1, 50, 50)
  root.fire("click", {target: zoomOut})
  const view = {...hook.view}
  // The reply: the living room is chosen.
  outlineEl.setAttribute("data-outline", "r2")
  hook.updated()
  assert.deepEqual(hook.view, view)
})

test("the label of the chosen room shows first", () => {
  const {hook, labels, outlineEl} = setup()
  assert.deepEqual(labels.map((l) => l.style.visibility), ["", "hidden", ""])
  // The middle room is chosen: its label shows, and the label of the
  // larger room over it hides.
  labels[1].attrs["data-label"] = "r1"
  outlineEl.setAttribute("data-outline", "r1")
  hook.updated()
  assert.deepEqual(labels.map((l) => l.style.visibility), ["hidden", "", ""])
  // No choice: the larger room first.
  outlineEl.removeAttribute("data-outline")
  hook.updated()
  assert.deepEqual(labels.map((l) => l.style.visibility), ["", "hidden", ""])
})

test("an item with an open sheet shows: its layer comes, also after a move to a different layer", () => {
  // The lamp on floor 2 is open when the page starts: floor 2 comes.
  const first = setup({start: "ground", chosen: false, open: "i2"})
  assert.equal(first.svg.getAttribute("data-dim"), "f2")

  // The fridge on floor 1 is open: the view stays.
  const {hook, svg, fridgeG, upper} = setup({start: "ground", chosen: false, open: "i1"})
  assert.equal(svg.getAttribute("data-dim"), "ground")
  // The same item: the person can show a different layer.
  hook.dim("f2")
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "f2")
  hook.dim("ground")
  // The sheet moves the fridge to a room of floor 2: floor 2 comes.
  fridgeG.parentNode = upper
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "f2")
  // An item that is not on the plan, and no open item.
  svg.setAttribute("data-open", "i9")
  hook.dim("ground")
  hook.updated()
  svg.removeAttribute("data-open")
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "ground")
})

test("the handles show only when they are far apart on the screen", () => {
  const {hook, handles} = setup()
  // All the house shows: the handles are 70.7 units (141 pixels) apart.
  const shown = () => Object.values(handles).map((h) => h.style.visibility)
  assert.deepEqual(shown(), ["", "", "", ""])
  // The server draws a small room: 7.1 units (14 pixels).
  const at = {x0: [0, 5], x1: [10, 5], y0: [5, 0], y1: [5, 10]}
  for (const [edge, [x, y]] of Object.entries(at)) {
    handles[edge].setAttribute("cx", x)
    handles[edge].setAttribute("cy", y)
  }
  hook.updated()
  assert.deepEqual(shown(), ["hidden", "hidden", "hidden", "hidden"])
  // A zoom in, 3 times: 42 pixels.
  hook.show({x: 0, y: 0, w: 200 / 3, h: 400 / 3})
  assert.deepEqual(shown(), ["", "", "", ""])
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

  // In the house, an item or a room on a layer that hides: its layer comes.
  const house = setup({start: "ground"})
  const press = (attrs) => house.root.fire("keydown", {target: new El(attrs, house.root), key: "ArrowDown", preventDefault() {}})
  press({"data-nudge": "i1"})
  assert.equal(house.svg.getAttribute("data-dim"), "ground")
  press({"data-nudge": "i2"})
  assert.equal(house.svg.getAttribute("data-dim"), "f2")
  press({"data-nudge-room": "r1"})
  assert.equal(house.svg.getAttribute("data-dim"), "ground")
  // An item that is not on the plan.
  press({"data-nudge": "i9"})
  assert.equal(house.svg.getAttribute("data-dim"), "ground")
  assert.equal(house.pushed.length, 4)
})

test("the label of a larger room shows; a label over it hides until a zoom in", () => {
  const {hook, labels} = setup()
  assert.deepEqual(labels.map((l) => l.style.visibility), ["", "hidden", ""])
  // The server draws the SVG again: the labels come again, and hide again.
  for (const label of labels) label.style.visibility = ""
  labels[1].bbox = {x: 45, y: 10, width: 10, height: 6}
  hook.updated()
  assert.deepEqual(labels.map((l) => l.style.visibility), ["", "", ""])
  // Nearer than 4 pixels (2 units): it hides.
  labels[1].bbox = {x: 41, y: 10, width: 10, height: 6}
  hook.updated()
  assert.deepEqual(labels.map((l) => l.style.visibility), ["", "hidden", ""])
  labels[1].bbox = {x: 45, y: 10, width: 10, height: 6}
  hook.updated()
  // A pan keeps the scale: the labels stay as they are.
  labels[1].style.visibility = "hidden"
  hook.show({...hook.view, x: hook.view.x + 5})
  assert.equal(labels[1].style.visibility, "hidden")
  // A zoom in: the labels are smaller on the SVG. So the label of the small
  // room shows again, next to the label of the large room.
  labels[1].bbox = {x: 20, y: 10, width: 30, height: 6}
  hook.show({...hook.view, w: hook.view.w / 2, h: hook.view.h / 2})
  assert.equal(labels[1].style.visibility, "hidden")
  for (const label of labels) label.bbox = {...label.bbox, width: 8, height: 2}
  hook.show({...hook.view, w: hook.view.w / 2, h: hook.view.h / 2})
  assert.deepEqual(labels.map((l) => l.style.visibility), ["", "", ""])

  // In the house, a label is on a pill. Its margin is half the height of
  // the text at the sides, and a quarter of it at the top and the bottom. The
  // pill hides with its label. The pills are larger: so the label of the
  // middle room hides earlier.
  const house = setup({start: "ground"})
  const pill = (i) => ["x", "y", "width", "height", "rx"].map((k) => house.pills[i].getAttribute(k))
  assert.deepEqual(pill(0), ["7.00", "8.50", "36.00", "9.00", "4.50"])
  assert.deepEqual(house.pills.map((p) => p.style.visibility), ["", "hidden", ""])
  house.labels[1].bbox = {x: 45, y: 10, width: 10, height: 6}
  house.hook.updated()
  assert.equal(house.labels[1].style.visibility, "hidden")
  house.labels[1].bbox = {x: 49, y: 10, width: 10, height: 6}
  house.hook.updated()
  assert.equal(house.pills[1].style.visibility, "")
  // A label with no pill (a page that the server has not drawn again).
  house.pills[0].attrs["data-pill"] = "gone"
  house.hook.updated()
  assert.equal(house.labels[0].style.visibility, "")
})

test("the hook goes: it removes its listeners, and the note does not wait", () => {
  const {hook, svg, root, hint, timers} = setup()
  svg.fire("wheel", {clientX: 0, clientY: 0, deltaY: 100, preventDefault: () => assert.fail()})
  hook.destroyed()
  assert.equal(svg.listeners.size, 0)
  assert.equal(root.listeners.size, 0)
  timers[0][0]()
  assert.ok(!hint.classes.has("opacity-0"))
})

test("a pale state for a layer that is not there stops when the server draws the SVG", () => {
  const {hook, svg, storage} = setup()
  hook.dim("ground")
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), "ground")
  hook.dim("attic")
  hook.updated()
  assert.equal(svg.getAttribute("data-dim"), null)
  assert.equal(storage.has("plan-view:plan:layer"), false)
  // In the house, the view stays in all the house until then.
  const house = setup({start: "ground"})
  house.hook.dim("attic")
  assert.deepEqual(house.hook.fit(), {x: 0, y: 0, w: 200, h: 400})
})

test("a tap on the pill of a hub opens the hub", () => {
  const {pointer, pushed, pillText} = setup()
  pointer("pointerdown", 1, 50, 50, pillText)
  pointer("pointerup", 1, 50, 50)
  assert.deepEqual(pushed, [["open_item", {id: "i1"}]])
})
