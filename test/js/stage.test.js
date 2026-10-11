// The tests of assets/js/stage.js: the math of the flight, and the hook
// with a fake page and a fake clock.
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {
  OUT, BACK, PING, FRONT, SCREEN_W, SCREEN_MIN, screenAt, numbers, easeOut, easeIn, frameAt, rectOf, restPose, areaOf, placement, pointAt,
  screenOf, between, transformOf, fly, inside, cssString, browserParts, pageParts, stageHook,
} from "../../assets/js/stage.js"

const close = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) < eps, `${a} is not ${b}`)

test("the numbers of an attribute", () => {
  assert.deepEqual(numbers(" 1 -2.5  3 "), [1, -2.5, 3])
  assert.deepEqual(numbers(""), [])
  assert.deepEqual(numbers(undefined), [])
})

test("the eases start at 0 and end at 1", () => {
  for (const ease of [easeOut, easeIn]) {
    assert.equal(ease(0), 0)
    assert.equal(ease(1), 1)
  }
  assert.ok(easeOut(0.5) > 0.5)
  assert.ok(easeIn(0.5) < 0.5)
})

test("the frame of a part of the flight", () => {
  assert.equal(frameAt(0, 12), 0)
  assert.equal(frameAt(1, 12), 11)
  assert.equal(frameAt(0.5, 12), 6)
  assert.equal(frameAt(-1, 12), 0)
  assert.equal(frameAt(2, 12), 11)
})

const rect = (left, top, width, height) => ({left, top, width, height, right: left + width, bottom: top + height})
const polygon = (r) => ({getBoundingClientRect: () => r})

test("the box of an item on the plan has its polygons, but not its shadow", () => {
  const group = {
    querySelectorAll(selector) {
      assert.equal(selector, "polygon:not(.p-shadow)")
      return [polygon(rect(10, 20, 5, 5)), polygon(rect(12, 18, 10, 3)), polygon(rect(0, 0, 0, 0))]
    },
  }
  assert.deepEqual(rectOf(group), {left: 10, top: 18, width: 12, height: 7})
  assert.equal(rectOf(null), null)
  assert.equal(rectOf({querySelectorAll: () => [polygon(rect(5, 5, 0, 0))]}), null)
})

test("the rest pose puts the first frame on the item of the plan", () => {
  // A box of 200 by 100 with a view of 100 by 100. The SVG is 100 by 100,
  // at the middle of the box: 50 px from its left.
  const box = rect(20, 30, 200, 100)
  const view = [-50, -50, 100, 100]
  const start = [-10, -20, 20, 40]
  const target = rect(300, 400, 4, 8)
  const pose = restPose(box, view, start, target)
  close(pose.s, 0.2)
  // The center of the start box: 50 px + 50 - 0 = 100 from the left of
  // the box, and 50 from its top. After the pose, it is at the center of
  // the target.
  const at = (u, v) => ({x: box.left + pose.x + pose.s * u, y: box.top + pose.y + pose.s * v})
  const center = at(100, 50)
  close(center.x, 302)
  close(center.y, 404)
  // With no rect: small, at the middle of the box.
  assert.deepEqual(restPose(box, view, start, null), {x: 80, y: 40, s: 0.2})
})

test("the rest pose of any box puts the center of the start on the center of the rect", () => {
  const n = (min, max) => fc.double({min, max, noNaN: true})
  fc.assert(fc.property(
    n(50, 600), n(50, 600), n(10, 200), n(10, 200), n(0.1, 1), n(0.1, 1), n(0, 500), n(0, 500), n(1, 50),
    (bw, bh, vw, vh, fw, fh, rx, ry, rw) => {
      const box = rect(5, 7, bw, bh)
      const view = [-vw / 2, -vh / 2, vw, vh]
      const start = [-vw * fw / 2, -vh * fh / 2, vw * fw, vh * fh]
      const target = rect(rx, ry, rw, rw * (vh * fh) / (vw * fw))
      const pose = restPose(box, view, start, target)
      const k = Math.min(bw / vw, bh / vh)
      const [ox, oy] = [(bw - k * vw) / 2, (bh - k * vh) / 2]
      const u = ox + k * (start[0] + start[2] / 2 - view[0])
      const v = oy + k * (start[1] + start[3] / 2 - view[1])
      close(box.left + pose.x + pose.s * u, rx + rw / 2, 1e-6 * (1 + rx))
      close(box.top + pose.y + pose.s * v, target.top + target.height / 2, 1e-6 * (1 + ry))
      close(pose.s * k * start[2], rw, 1e-6 * (1 + rw))
    },
  ))
})

test("a pose between two poses, and its transform", () => {
  assert.deepEqual(between({x: 0, y: 10, s: 0}, {x: 10, y: 20, s: 1}, 0.5), {x: 5, y: 15, s: 0.5})
  assert.equal(transformOf({x: 1, y: 2, s: 0.5}), "translate(1px, 2px) scale(0.5)")
})

// A fake clock: frame() keeps the steps, and tick() moves the time and
// runs them.
function clock() {
  let t = 0
  let next = []
  return {
    now: () => t,
    frame: (f) => { next.push(f) },
    tick(ms) {
      t += ms
      const steps = next
      next = []
      for (const f of steps) f()
    },
    waiting: () => next.length > 0,
  }
}

test("a flight shows each frame on its way, and ends with done", () => {
  const time = clock()
  const shown = []
  let done = 0
  fly({
    from: {x: 0, y: 0, s: 0}, to: {x: 100, y: 0, s: 1}, first: 0, last: 11, count: 12, time: 100,
    ease: (t) => t, now: time.now, frame: time.frame, show: (i, pose) => shown.push([i, pose.x]), done: () => done++,
  })
  assert.deepEqual(shown, [[0, 0]])
  time.tick(50)
  assert.deepEqual(shown.at(-1), [6, 50])
  time.tick(60)
  assert.deepEqual(shown.at(-1), [11, 100])
  assert.equal(done, 1)
  assert.equal(time.waiting(), false)

  // The other direction: from the last frame to the first.
  const back = []
  fly({
    from: FRONT, to: {x: 0, y: 0, s: 0}, first: 11, last: 0, count: 12, time: 100,
    ease: (t) => t, now: time.now, frame: time.frame, show: (i) => back.push(i), done: () => {},
  })
  time.tick(100)
  assert.deepEqual(back, [11, 0])
})

test("the parts of the browser", () => {
  const calls = []
  const win = {
    performance: {now: () => 42},
    requestAnimationFrame: (f) => calls.push(f),
    matchMedia: (query) => ({matches: query === "(prefers-reduced-motion: reduce)"}),
    document: {documentElement: "root"},
    getComputedStyle: (el) => ({fontSize: el === "root" ? "20px" : ""}),
    setTimeout: (f, ms) => calls.push([f, ms]),
  }
  const parts = browserParts(win)
  assert.equal(parts.now(), 42)
  parts.frame("f")
  parts.wait("g", 900)
  assert.deepEqual(calls, ["f", ["g", 900]])
  assert.equal(parts.reduce(), true)
  assert.equal(parts.rem(), 20)
  assert.equal(browserParts({...win, matchMedia: undefined}).reduce(), false)
  assert.equal(browserParts({...win, getComputedStyle: () => ({fontSize: ""})}).rem(), 16)
  assert.equal(pageParts({ownerDocument: {defaultView: win}}).now(), 42)
  assert.equal(typeof stageHook().mounted, "function")
})

test("a flight stops when it is not alive", () => {
  const time = clock()
  const shown = []
  let alive = true
  let done = 0
  fly({
    from: FRONT, to: FRONT, first: 0, last: 11, count: 12, time: 100, ease: (t) => t,
    now: time.now, frame: time.frame, show: (i) => shown.push(i), done: () => done++, alive: () => alive,
  })
  alive = false
  time.tick(200)
  assert.deepEqual(shown, [0])
  assert.equal(done, 0)
})

test("the area of the model, its place, a point on it, and the screen of a hub", () => {
  // A wide page: the panel is at the right. A narrow page: at the bottom.
  assert.deepEqual(
    areaOf({width: 1280, height: 800}, {left: 840, top: 24, width: 416, height: 752}),
    {left: 24, top: 24, width: 784, height: 752},
  )
  assert.deepEqual(
    areaOf({width: 390, height: 844}, {left: 0, top: 354, width: 390, height: 490}),
    {left: 16, top: 16, width: 358, height: 314},
  )

  // The whole model fits at the middle of its area.
  const view = [-50, -25, 100, 50]
  const box = placement(view, [], {left: 0, top: 0, width: 1000, height: 800})
  close(box.k, 9.2)
  close(box.width, 920)
  close(box.left + box.width / 2, 500)
  close(box.top + box.height / 2, 400)
  const low = placement(view, [], {left: 10, top: 20, width: 1000, height: 100})
  close(low.k, 1.88)
  close(low.top, 20 + 3)
  // A point of the view on the page: the center of the view is the middle.
  const [x, y] = pointAt(box, view, [0, 0])
  close(x, 500)
  close(y, 400)

  // A hub comes near: its screen is SCREEN_W px wide, at the middle of the
  // area, with no slant here.
  const region = [-20, -10, 20, -10, -20, 10]
  const area = {left: 0, top: 0, width: 1000, height: 800}
  const hub = placement(view, region, area, {screen: true})
  close(hub.k, SCREEN_W / 40)
  const screen = screenOf(hub, view, region)
  close(screen.width, SCREEN_W)
  close(screen.height, SCREEN_W / 2)
  assert.deepEqual(screen.matrix.slice(0, 4), [1, 0, 0, 1])
  close(screen.matrix[4] + screen.width / 2, 500)
  close(screen.matrix[5] + screen.height / 2, 400)
  // It is not wider or higher than its area, and a large font makes it
  // larger. On a short area (a zoom of 400 %), the whole screen shows.
  close(placement(view, region, {left: 0, top: 0, width: 200, height: 300}, {screen: true}).k, 176 / 40)
  const short = placement(view, region, {left: 0, top: 16, width: 280, height: 90}, {screen: true})
  close(short.k, 66 / 20)
  const led = screenOf(short, view, region)
  assert.ok(led.matrix[5] >= 16 && led.matrix[5] + led.height <= 16 + 90)
  // That screen is too small to read on the model: it covers the area.
  const near = {left: 0, top: 16, width: 280, height: 90}
  assert.deepEqual(screenAt(short, view, region, near), {width: 280, height: 90, matrix: [1, 0, 0, 1, 0, 16]})
  // A screen of SCREEN_MIN px or more stays on the model. On a narrow area,
  // a screen as wide as the area (less 24 px) stays too.
  assert.deepEqual(screenAt(hub, view, region, area).matrix.slice(0, 4), [1, 0, 0, 1])
  close(screenAt(hub, view, region, area).width, SCREEN_W)
  const thin = {left: 0, top: 0, width: 200, height: 300}
  close(screenAt(placement(view, region, thin, {screen: true}), view, region, thin).width, 176)
  assert.ok(SCREEN_MIN < SCREEN_W)
  close(placement(view, region, area, {screen: true, rem: 20}).k, (SCREEN_W * 1.25) / 40)
  // A slant: the screen goes along the sides of its region.
  const [a, b, c, d] = screenOf(hub, view, [0, 0, 30, 3, 1, 20]).matrix
  close(Math.hypot(a, b), 1)
  close(Math.hypot(c, d), 1)
  close(b / a, 0.1)
})

test("a rect in a box, and a text in a CSS string", () => {
  const box = {left: 0, top: 0, width: 100, height: 100}
  assert.equal(inside({left: 40, top: 40, width: 10, height: 10}, box), true)
  assert.equal(inside({left: 140, top: 40, width: 10, height: 10}, box), false)
  assert.equal(inside({left: 40, top: -40, width: 10, height: 10}, box), false)
  assert.equal(cssString('i7"] { x } [a="'), 'i7\\"] { x } [a=\\"')
})

// An element with attributes, as the DOM has them.
function element(extra = {}) {
  const attrs = new Map()
  return {
    attrs,
    style: {setProperty(name, value) { this[name] = value }},
    toggleAttribute: (name, on) => (on ? attrs.set(name, "") : attrs.delete(name)),
    hasAttribute: (name) => attrs.has(name),
    ...extra,
  }
}

// A list of classes, as the DOM has it.
const classes = () => {
  const set = new Set()
  return {set, add: (name) => set.add(name), remove: (name) => set.delete(name), contains: (name) => set.has(name)}
}

// A fake page: a plan with the item, and the stage of the item. The plan
// can be up (top < 0) and out of the page. As with LiveView, an attribute
// that a command sets is on the element at once, and a patch keeps it. A
// patch puts the other attributes back to those of the server. The title
// takes the focus only when the panel shows. The page is narrow (the panel
// at the bottom), or wide (the panel at the right). A hub has its screen.
function page({reduce = false, plan = true, onPlan = true, start = "-5 -10 10 20", top = 0, rem = 16, screen = false} = {}) {
  const time = clock()
  const timers = []
  const listeners = new Map()
  const resize = new Map()
  const head = []
  const focus = []
  const doc = {
    activeElement: null,
    head: {append: (el) => head.push(el)},
    defaultView: {
      addEventListener: (type, f) => resize.set(type, f),
      removeEventListener: (type, f) => resize.get(type) === f && resize.delete(type),
    },
    addEventListener: (type, f) => listeners.set(type, f),
    removeEventListener: (type, f) => listeners.get(type) === f && listeners.delete(type),
    createElement: (tag) => ({tag, textContent: "", remove() { head.splice(head.indexOf(this), 1) }}),
    getElementById(id) {
      if (id === "plan-svg") return {getBoundingClientRect: () => rect(0, top, 390, onPlan ? 800 : 100)}
      if (plan && id === "plan-item-i7") return {querySelectorAll: () => [polygon(rect(100, 500 + top, 6, 12))]}
      if (id === "param-watts-field") return field
      return null
    },
  }
  const before = {isConnected: true, focus: () => focus.push("before")}
  doc.activeElement = before
  const frames = Array.from({length: 12}, (_, i) => element({frame: i}))
  frames.forEach((f, i) => i < 11 && f.toggleAttribute("hidden", true))
  const model = element({
    dataset: {view: "-50 -50 100 100"},
    querySelectorAll: (selector) => (assert.equal(selector, ".stage-frame"), frames),
    getBoundingClientRect() { return rect(Number.parseFloat(this.style.left), Number.parseFloat(this.style.top), 300, 300) },
  })
  const panel = element({offsetLeft: 0, offsetTop: 354, offsetWidth: 390, offsetHeight: 490})
  const attrs = new Map()
  const kept = new Map()
  const title = {focus: () => attrs.get("data-stage") === "landed" && focus.push("title")}
  // Two tags: the watts on the face, and a tag with no field in the panel.
  const spots = ["watts", "nothing"].map((key) =>
    element({dataset: {spot: key, at: key === "watts" ? "10 0" : "0 0"}, classList: classes(), offsetWidth: 80}))
  const input = {focus: () => focus.push("field")}
  const field = {
    classList: classes(), scrolls: [],
    scrollIntoView(options) { this.scrolls.push(options) },
    querySelector: (selector) => (assert.equal(selector, "input:not([type=hidden]), select"), input),
  }
  const hubScreen = screen && element({
    classList: classes(), offsetWidth: 300,
    querySelector: (selector) => (assert.equal(selector, "input:not([type=hidden])"), {focus: () => focus.push("address")}),
  })
  const closeLink = {getAttribute: (name) => (assert.equal(name, "href"), "/inside?room=r2")}
  let clicked = null
  const js = {patches: [], states: []}
  const el = {
    ownerDocument: doc,
    dataset: {item: "i7", start, region: "-20 -10 20 -10 -20 10"},
    clientWidth: 390,
    clientHeight: 844,
    addEventListener: (type, f) => { clicked = f },
    getBoundingClientRect: () => rect(0, 0, 390, 844),
    querySelector(selector) {
      if (selector === ".stage-model") return model
      if (selector === ".stage-panel") return panel
      if (selector === ".stage-screen") return hubScreen || null
      if (selector === ".stage-title") return title
      if (selector === "[data-close]") return closeLink
      throw new Error(selector)
    },
    querySelectorAll: (selector) => (selector === "[data-spot]" ? spots : []),
    contains: () => true,
  }
  const hook = Object.assign({el, js: () => ({
    patch: (href) => js.patches.push(href),
    setAttribute(node, name, value) {
      assert.equal(node, el)
      js.states.push(value)
      kept.set(name, value)
      attrs.set(name, value)
    },
  })}, stageHook(() => ({
    now: time.now, frame: time.frame, reduce: () => reduce, rem: () => rem, wait: (f, ms) => timers.push([f, ms]),
  })))
  hook.mounted()
  const press = (key, target = null) => {
    let prevented = false
    listeners.get("keydown")({key, shiftKey: false, target, preventDefault: () => (prevented = true)})
    return prevented
  }
  // A click on an element: the closest element of each selector.
  const click = (target, selector = "[data-close]") => {
    const event = {
      target: {closest: (wanted) => (wanted === selector ? target : null)},
      prevented: false, stopped: false,
      preventDefault() { this.prevented = true },
      stopPropagation() { this.stopped = true },
    }
    clicked(event)
    return event
  }
  // A patch of the LiveView, for example after a key of the panel.
  const patch = () => {
    attrs.clear()
    kept.forEach((value, name) => attrs.set(name, value))
  }
  const visible = () => frames.findIndex((f) => !f.hasAttribute("hidden"))
  const scale = () => Number(model.style.transform.match(/scale\((.*)\)/)[1])
  return {
    hook, time, timers, head, focus, frames, model, panel, js, attrs, patch, listeners, resize, press, click, closeLink,
    visible, scale, el, spots, field, screen: hubScreen,
  }
}

test("the stage places the model and its tags, and flies the item out of the plan", () => {
  const p = page()
  assert.deepEqual(p.js.states, ["placed"])
  // A narrow page: the model is over the panel, in an area of 358 by 314
  // px. The view is 100 units: 2.9516 px for each unit, at the middle.
  close(Number.parseFloat(p.model.style.width), 295.16)
  close(Number.parseFloat(p.model.style.left), 16 + (358 - 295.16) / 2)
  close(Number.parseFloat(p.model.style.top), 25.42)
  // The tag of the watts is at 10, 0 in the view.
  close(Number.parseFloat(p.spots[0].style.left), 16 + (358 - 295.16) / 2 + 60 * 2.9516)
  close(Number.parseFloat(p.spots[0].style.top), 25.42 + 50 * 2.9516)
  // The notch of the panel points at the middle of the model.
  assert.equal(p.panel.style["--notch"], "24px")
  // The item on the plan does not show, with its id in a CSS string.
  assert.equal(p.head[0].textContent, '[id="plan-item-i7"] { opacity: 0 }')
  // The flight starts at the next frame of the page.
  assert.equal(p.model.style.visibility, "hidden")
  p.time.tick(0)
  assert.equal(p.model.style.visibility, "")
  assert.equal(p.visible(), 0)
  // The item on the plan is 6 px wide. The first frame is 10 units wide,
  // with 3 px for each unit: a box of 300 px for 100 units.
  close(p.scale(), 0.2)
  p.time.tick(OUT / 2)
  assert.ok(p.visible() > 0 && p.visible() < 11)
  // Only one frame shows: the others have the attribute hidden.
  assert.equal(p.frames.filter((f) => !f.hasAttribute("hidden")).length, 1)
  assert.deepEqual(p.focus, [])
  p.time.tick(OUT)
  assert.equal(p.visible(), 11)
  assert.equal(p.model.style.transform, transformOf(FRONT))
  // The panel shows, and its title takes the focus.
  assert.deepEqual(p.js.states, ["placed", "landed"])
  assert.deepEqual(p.focus, ["title"])
  // A patch (a key of the panel, a number) keeps the state of the stage.
  p.patch()
  assert.equal(p.attrs.get("data-stage"), "landed")

  // A new size of the page places them again. A wide page: the panel is
  // at the right, and the model at the left of it.
  Object.assign(p.el, {clientWidth: 1280, clientHeight: 800})
  Object.assign(p.panel, {offsetLeft: 840, offsetTop: 24, offsetWidth: 416, offsetHeight: 752})
  p.resize.get("resize")()
  close(Number.parseFloat(p.model.style.width), 752 * 0.94)
  close(Number.parseFloat(p.panel.style["--notch"]), 400 - 24)
})

test("a close flies the item back, and then closes the stage", () => {
  const p = page()
  p.time.tick(0)
  p.time.tick(OUT)
  const event = p.click(p.closeLink)
  assert.equal(event.prevented, true)
  assert.equal(event.stopped, true)
  assert.equal(p.js.states.at(-1), "closing")
  p.patch()
  assert.equal(p.attrs.get("data-stage"), "closing")
  assert.equal(p.visible(), 11)
  // A second close while it flies does nothing.
  assert.equal(p.press("Escape"), true)
  p.time.tick(BACK / 2)
  assert.deepEqual(p.js.patches, [])
  p.time.tick(BACK)
  assert.equal(p.visible(), 0)
  assert.deepEqual(p.js.patches, ["/inside?room=r2"])

  // The stage goes away: the item shows again, and the focus goes back.
  p.hook.destroyed()
  assert.equal(p.head.length, 0)
  assert.equal(p.listeners.has("keydown"), false)
  assert.equal(p.resize.has("resize"), false)
  assert.equal(p.focus.at(-1), "before")
})

test("a close in the flight out goes back from where the model is", () => {
  const p = page()
  p.time.tick(0)
  p.time.tick(OUT / 4)
  const [frame, scale] = [p.visible(), p.scale()]
  assert.ok(frame > 0 && frame < 11)
  p.press("Escape")
  // No jump: the flight back starts at the same frame and the same pose.
  assert.equal(p.visible(), frame)
  close(p.scale(), scale)
  p.time.tick(BACK)
  assert.deepEqual(p.js.patches, ["/inside?room=r2"])
  // The flight out stopped: it does not land after the close.
  p.time.tick(OUT)
  assert.equal(p.js.states.includes("landed"), false)
})

test("a close before the flight out starts, and a stage that goes away before or in a flight", () => {
  for (const options of [{}, {plan: false}]) {
    const p = page(options)
    p.press("Escape")
    p.time.tick(0)
    // The flight out does not start after the close.
    assert.equal(p.js.states.includes("landed"), false)
    p.time.tick(BACK)
    assert.deepEqual(p.js.patches, ["/inside?room=r2"])
  }

  // The stage goes away while the item flies back: no close after it.
  const q = page()
  q.time.tick(0)
  q.time.tick(OUT)
  q.press("Escape")
  q.hook.destroyed()
  q.time.tick(BACK)
  assert.deepEqual(q.js.patches, [])

  // The stage goes away before the first frame of the page: the flight
  // does not start, because the stage is not on the page.
  for (const reduce of [false, true]) {
    const r = page({reduce})
    r.hook.destroyed()
    r.time.tick(0)
    r.time.tick(OUT)
    assert.deepEqual(r.js.states, ["placed"])
    assert.equal(r.model.style.transform, undefined)
    assert.equal(r.visible(), 11)
  }
})

test("a tag goes to its number, and Show me where shows the tag", () => {
  const p = page()
  p.time.tick(0)
  p.time.tick(OUT)

  // A tap on the tag: the field comes to the middle of the panel, shows a
  // flash, and its input takes the focus.
  p.click(p.spots[0], "[data-spot]")
  assert.deepEqual(p.field.scrolls, [{block: "center", behavior: "smooth"}])
  assert.equal(p.field.classList.contains("stage-flash"), true)
  assert.deepEqual(p.focus.at(-1), "field")
  const [[unflash, ms]] = p.timers
  assert.equal(ms, 900)
  unflash()
  assert.equal(p.field.classList.contains("stage-flash"), false)
  // A tag with no field in the panel: nothing.
  p.click(p.spots[1], "[data-spot]")
  assert.equal(p.field.scrolls.length, 1)

  // Show me where: a ring on the tag. It goes after PING ms. A second tap
  // starts the time again: the timer of the first tap does nothing.
  p.click({dataset: {show: "watts"}}, "[data-show]")
  assert.equal(p.spots[0].classList.contains("stage-ping"), true)
  p.click({dataset: {show: "watts"}}, "[data-show]")
  const [[first, pingMs], [second]] = p.timers.slice(-2)
  assert.equal(pingMs, PING)
  first()
  assert.equal(p.spots[0].classList.contains("stage-ping"), true)
  second()
  assert.equal(p.spots[0].classList.contains("stage-ping"), false)
  p.click({dataset: {show: "fuel"}}, "[data-show]")
  // A click on no link, no tag and no Show me: nothing.
  assert.equal(p.click(null, "nothing").prevented, false)

  // With less motion, the field comes at once. With no screen, Show me the
  // screen does nothing.
  const q = page({reduce: true})
  q.time.tick(0)
  q.click(q.spots[0], "[data-spot]")
  assert.deepEqual(q.field.scrolls, [{block: "center", behavior: "auto"}])
  q.click({dataset: {show: "screen"}}, "[data-show]")
})

test("a hub has its screen on its top, and Show me the screen gives it the focus", () => {
  const p = page({screen: true})
  // The model comes near: the screen is 300 px wide (the area is wider).
  assert.equal(p.screen.style.width, `${SCREEN_W}px`)
  assert.equal(p.screen.style.height, `${SCREEN_W / 2}px`)
  assert.match(p.screen.style.transform, /^matrix\(1, 0, 0, 1, /)
  p.time.tick(0)
  p.time.tick(OUT)
  p.click({dataset: {show: "screen"}}, "[data-show]")
  assert.equal(p.screen.classList.contains("stage-ping"), true)
  assert.equal(p.focus.at(-1), "address")
})

test("Escape puts the item back, and Tab keeps the focus on the stage", () => {
  const p = page()
  p.time.tick(0)
  p.time.tick(OUT)
  // A different key does nothing. The Tab key: the trap of the hook Sheet
  // (no element: no change).
  assert.equal(p.press("a"), false)
  assert.equal(p.press("Tab"), false)
  assert.equal(p.press("Escape", {}), true)
  assert.equal(p.js.states.at(-1), "closing")
})

test("with less motion, the item is at once in front, and a close is at once", () => {
  const p = page({reduce: true})
  p.time.tick(0)
  assert.equal(p.visible(), 11)
  assert.equal(p.model.style.transform, transformOf(FRONT))
  assert.deepEqual(p.js.states, ["placed", "landed"])
  // The panel shows at once, so its title takes the focus.
  assert.deepEqual(p.focus, ["title"])
  p.click(p.closeLink)
  assert.deepEqual(p.js.patches, ["/inside?room=r2"])
  // The panel goes at once.
  assert.deepEqual(p.js.states, ["placed", "landed", "closing"])
})

test("an item that is not on the plan, or not in its view, comes from the middle", () => {
  // Three cases: no item on the plan, an item out of the view of the plan,
  // and a plan out of the page. In the last case, the page is down at the
  // list of the rooms.
  for (const options of [{plan: false}, {onPlan: false}, {top: -1000}]) {
    const p = page(options)
    p.time.tick(0)
    assert.equal(p.scale(), 0.2)
    p.time.tick(OUT)
    p.press("Escape")
    p.time.tick(BACK)
    assert.equal(p.scale(), 0.2)
    assert.deepEqual(p.js.patches, ["/inside?room=r2"])
  }
})

test("the focus does not go back to an element that went away", () => {
  const p = page()
  p.hook.previous = {isConnected: false, focus: () => p.focus.push("gone")}
  p.hook.destroyed()
  assert.notEqual(p.focus.at(-1), "gone")
})
