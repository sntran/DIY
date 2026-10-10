// The tests of assets/js/stage.js: the math of the flight, and the hook
// with a fake page and a fake clock.
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {
  OUT, BACK, FRONT, MIN_W, MAX_W, EDGE, numbers, easeOut, easeIn, frameAt, rectOf, restPose, placement, between,
  transformOf, fly, inside, cssString, nextTab, browserParts, pageParts, stageHook,
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
  }
  const parts = browserParts(win)
  assert.equal(parts.now(), 42)
  parts.frame("f")
  assert.deepEqual(calls, ["f"])
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

test("the place of the model and of its panel on the stage", () => {
  // A view of 100 by 50 units, and a panel of 40 by 20 units at its middle,
  // with no slant.
  const view = [-50, -25, 100, 50]
  const region = [-20, -10, 20, -10, -20, 10]
  // A wide area: the whole model fits, and the panel is large enough.
  const wide = placement(view, region, {width: 1000, height: 800})
  close(wide.model.width, 900)
  close(wide.panel.width, 360)
  close(wide.panel.height, 180)
  assert.deepEqual(wide.panel.matrix.slice(0, 4), [1, 0, 0, 1])
  // The middle of the panel is at the middle of the width, at 45% of the
  // height.
  close(wide.panel.matrix[4] + wide.panel.width / 2, 500)
  close(wide.panel.matrix[5] + wide.panel.height / 2, 360)
  close(wide.model.left + wide.model.width / 2, 500)

  // A phone: the model comes nearer, so that the panel is large enough to
  // read. Then the model is wider than the page.
  const phone = placement(view, [-5, -10, 5, -10, -5, 10], {width: 390, height: 844})
  close(phone.panel.width, MIN_W)
  assert.ok(phone.model.width > 390)
  // A desktop: the panel is not wider than the most.
  const desk = placement(view, [-40, -20, 40, -20, -40, 20], {width: 2000, height: 2000})
  close(desk.panel.width, MAX_W)

  // A short page (a zoom of 400%): the panel is not higher than the page,
  // and it is on the page. The model is then nearer than for the least
  // width of the panel.
  const short = placement(view, [-10, -20, 10, -20, -10, 20], {width: 320, height: 256})
  close(short.panel.height, 256 - 2 * EDGE)
  close(short.panel.matrix[5], EDGE)
  assert.ok(short.panel.width < MIN_W)
  // A large font makes a larger panel.
  const font = placement(view, [-5, -10, 5, -10, -5, 10], {width: 390, height: 844}, 20)
  close(font.panel.width, MIN_W * 1.25)

  // A slant: the panel goes along the sides of the region.
  const slant = placement(view, [0, 0, 30, 3, 1, 20], {width: 800, height: 600})
  const [a, b, c, d] = slant.panel.matrix
  close(Math.hypot(a, b), 1)
  close(Math.hypot(c, d), 1)
  close(b / a, 0.1)
})

test("a rect in a box, a text in a CSS string, and the next tab", () => {
  const box = {left: 0, top: 0, width: 100, height: 100}
  assert.equal(inside({left: 40, top: 40, width: 10, height: 10}, box), true)
  assert.equal(inside({left: 140, top: 40, width: 10, height: 10}, box), false)
  assert.equal(inside({left: 40, top: -40, width: 10, height: 10}, box), false)
  assert.equal(cssString('i7"] { x } [a="'), 'i7\\"] { x } [a=\\"')
  const tabs = ["use", "numbers", "place", "remove"]
  assert.equal(nextTab(tabs, "use", "ArrowRight"), "numbers")
  assert.equal(nextTab(tabs, "use", "ArrowLeft"), "remove")
  assert.equal(nextTab(tabs, "remove", "ArrowRight"), "use")
  assert.equal(nextTab(tabs, "place", "Home"), "use")
  assert.equal(nextTab(tabs, "use", "End"), "remove")
  assert.equal(nextTab(tabs, "use", "Enter"), null)
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

// A fake page: a plan with the item, and the stage of the item. The plan
// can be up (top < 0) and out of the page. The classes of the LiveView
// change at the next frame, as with LiveView. A tab takes the focus only
// when the panel shows.
function page({reduce = false, plan = true, onPlan = true, start = "-5 -10 10 20", top = 0, rem = 16} = {}) {
  const time = clock()
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
  const panel = element()
  const classes = new Set()
  const tabs = ["use", "numbers", "place", "remove"].map((name) => {
    const tab = {
      name, getAttribute: () => "tab", closest: () => tab,
      focus: () => classes.has("stage-landed") && focus.push(name), click: () => focus.push(`click ${name}`),
    }
    return tab
  })
  const closeLink = {getAttribute: (name) => (assert.equal(name, "href"), "/inside?room=r2")}
  let clicked = null
  const js = {patches: [], classes: []}
  const el = {
    ownerDocument: doc,
    dataset: {item: "i7", start, region: "-20 -10 20 -10 -20 10"},
    addEventListener: (type, f) => { clicked = f },
    classList: {add: (cls) => classes.add(cls), remove: (cls) => classes.delete(cls)},
    getBoundingClientRect: () => rect(0, 0, 390, 844),
    querySelector(selector) {
      if (selector === ".stage-model") return model
      if (selector === ".stage-panel") return panel
      if (selector === '[role="tab"][aria-selected="true"]') return tabs[0]
      if (selector === "[data-close]") return closeLink
      throw new Error(selector)
    },
    querySelectorAll: (selector) => (selector === '[role="tab"]' ? tabs : []),
    contains: () => true,
  }
  const hook = Object.assign({el, js: () => ({
    patch: (href) => js.patches.push(href),
    addClass: (node, cls) => (js.classes.push(["+", cls]), time.frame(() => classes.add(cls))),
    removeClass: (node, cls) => (js.classes.push(["-", cls]), time.frame(() => classes.delete(cls))),
  })}, stageHook(() => ({now: time.now, frame: time.frame, reduce: () => reduce, rem: () => rem})))
  hook.mounted()
  const press = (key, target = null) => {
    let prevented = false
    listeners.get("keydown")({key, shiftKey: false, target, preventDefault: () => (prevented = true)})
    return prevented
  }
  const click = (target) => {
    const event = {
      target: {closest: (selector) => (assert.equal(selector, "[data-close]"), target)},
      prevented: false, stopped: false,
      preventDefault() { this.prevented = true },
      stopPropagation() { this.stopped = true },
    }
    clicked(event)
    return event
  }
  const visible = () => frames.findIndex((f) => !f.hasAttribute("hidden"))
  const scale = () => Number(model.style.transform.match(/scale\((.*)\)/)[1])
  return {hook, time, head, focus, frames, model, panel, js, classes, listeners, resize, press, click, closeLink, visible, scale, el, tabs}
}

test("the stage places the model and its panel, and flies the item out of the plan", () => {
  const p = page()
  assert.deepEqual(p.js.classes, [["+", "stage-placed"]])
  // The panel: 40 by 20 units at the middle of the view. It needs 150 px
  // of height: 7.5 px for each unit.
  assert.equal(p.panel.style.width, "300px")
  assert.equal(p.panel.style.height, "150px")
  assert.equal(p.panel.style["--pw"], "300px")
  assert.match(p.panel.style.transform, /^matrix\(1, 0, 0, 1, /)
  assert.equal(p.model.style.width, "750px")
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
  // The panel shows, and the key of its page takes the focus.
  assert.deepEqual(p.js.classes.at(-1), ["+", "stage-landed"])
  assert.deepEqual(p.focus, ["use"])

  // A new size of the page places them again.
  // A large page: the panel has its most width.
  p.el.getBoundingClientRect = () => rect(0, 0, 2000, 2000)
  p.resize.get("resize")()
  assert.equal(p.panel.style.width, `${MAX_W}px`)
})

test("a close flies the item back, and then closes the stage", () => {
  const p = page()
  p.time.tick(0)
  p.time.tick(OUT)
  const event = p.click(p.closeLink)
  assert.equal(event.prevented, true)
  assert.equal(event.stopped, true)
  assert.deepEqual(p.js.classes.slice(-2), [["-", "stage-landed"], ["+", "stage-closing"]])
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
  assert.equal(p.js.classes.some(([op, cls]) => op === "+" && cls === "stage-landed"), false)
})

test("a close before the flight out starts, and a stage that goes away before or in a flight", () => {
  for (const options of [{}, {plan: false}]) {
    const p = page(options)
    p.press("Escape")
    p.time.tick(0)
    // The flight out does not start after the close.
    assert.equal(p.js.classes.some(([op, cls]) => op === "+" && cls === "stage-landed"), false)
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
    assert.deepEqual(r.js.classes, [["+", "stage-placed"]])
    assert.equal(r.model.style.transform, undefined)
    assert.equal(r.visible(), 11)
  }
})

test("the arrow keys go from page to page; Escape and Tab", () => {
  const p = page()
  p.time.tick(0)
  p.time.tick(OUT)
  assert.equal(p.press("ArrowRight", p.tabs[0]), true)
  assert.deepEqual(p.focus.slice(-2), ["numbers", "click numbers"])
  p.press("End", p.tabs[0])
  assert.deepEqual(p.focus.slice(-2), ["remove", "click remove"])
  // A key that is not for the tabs, on a tab: no change of the page.
  assert.equal(p.press("a", p.tabs[0]), false)
  // The Tab key: the trap of the hook Sheet (no element: no change).
  assert.equal(p.press("Tab"), false)
  assert.equal(p.press("Escape", {}), true)
  // A click that is not on a close link does nothing.
  const event = p.click(null)
  assert.equal(event.prevented, false)
})

test("with less motion, the item is at once in front, and a close is at once", () => {
  const p = page({reduce: true})
  p.time.tick(0)
  assert.equal(p.visible(), 11)
  assert.equal(p.model.style.transform, transformOf(FRONT))
  assert.deepEqual(p.js.classes.at(-1), ["+", "stage-landed"])
  // The panel shows at once, so its key takes the focus.
  assert.deepEqual(p.focus, ["use"])
  p.click(p.closeLink)
  assert.deepEqual(p.js.patches, ["/inside?room=r2"])
  assert.equal(p.js.classes.some(([, cls]) => cls === "stage-closing"), false)
})

test("an item that is not on the plan, or not in its view, comes from the middle", () => {
  // No item on the plan; an item out of the view of the plan; a plan out of
  // the page (the page is down at the list of the rooms).
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
