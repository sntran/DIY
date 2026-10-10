// The tests of assets/js/stage.js: the math of the flight, and the hook
// with a fake page and a fake clock.
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {
  OUT, BACK, FRONT, numbers, easeOut, easeIn, frameAt, rectOf, restPose, between, transformOf, fly,
  browserParts, pageParts, stageHook,
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

// A fake clock: frame() keeps the step, and tick() moves the time.
function clock() {
  let t = 0
  let next = null
  return {
    now: () => t,
    frame: (f) => { next = f },
    tick(ms) {
      t += ms
      const f = next
      next = null
      f?.()
    },
    waiting: () => next !== null,
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
  }
  const parts = browserParts(win)
  assert.equal(parts.now(), 42)
  parts.frame("f")
  assert.deepEqual(calls, ["f"])
  assert.equal(parts.reduce(), true)
  assert.equal(browserParts({...win, matchMedia: undefined}).reduce(), false)
  assert.equal(pageParts({ownerDocument: {defaultView: win}}).now(), 42)
  assert.equal(typeof stageHook().mounted, "function")
})

// A fake page: a plan with the item, and the stage of the item.
function page({reduce = false, plan = true, start = "-5 -10 10 20"} = {}) {
  const time = clock()
  const listeners = new Map()
  const head = []
  const focus = []
  const doc = {
    activeElement: null,
    head: {append: (el) => head.push(el)},
    addEventListener: (type, f) => listeners.set(type, f),
    removeEventListener: (type, f) => listeners.get(type) === f && listeners.delete(type),
    createElement: (tag) => ({tag, textContent: "", remove() { head.splice(head.indexOf(this), 1) }}),
    getElementById: (id) => (plan && id === "plan-item-i7"
      ? {querySelectorAll: () => [polygon(rect(100, 500, 6, 12))]}
      : null),
  }
  const before = {isConnected: true, focus: () => focus.push("before")}
  doc.activeElement = before
  const frames = Array.from({length: 12}, () => ({hidden: true}))
  const model = {
    dataset: {view: "-50 -50 100 100"},
    style: {},
    querySelectorAll: (selector) => (assert.equal(selector, ".stage-frame"), frames),
    getBoundingClientRect: () => rect(20, 40, 300, 300),
  }
  const tab = {focus: (opts) => focus.push(["tab", opts])}
  const closeLink = {getAttribute: (name) => (assert.equal(name, "href"), "/inside?room=r2")}
  let clicked = null
  const js = {patches: [], classes: []}
  const el = {
    ownerDocument: doc,
    dataset: {item: "i7", start},
    addEventListener: (type, f) => { clicked = f },
    querySelector(selector) {
      if (selector === ".stage-model") return model
      if (selector === '[role="tab"][aria-selected="true"]') return tab
      if (selector === "[data-close]") return closeLink
      throw new Error(selector)
    },
    querySelectorAll: () => [],
    contains: () => true,
  }
  const hook = Object.assign({el, js: () => ({patch: (href) => js.patches.push(href), addClass: (node, cls) => js.classes.push([node, cls])})},
    stageHook(() => ({now: time.now, frame: time.frame, reduce: () => reduce})))
  hook.mounted()
  const press = (key) => {
    let prevented = false
    listeners.get("keydown")({key, shiftKey: false, preventDefault: () => (prevented = true)})
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
  const visible = () => frames.findIndex((f) => !f.hidden)
  return {hook, time, head, focus, frames, model, js, listeners, press, click, closeLink, visible, el}
}

test("the stage flies the item out of the plan, and the item of the plan does not show", () => {
  const p = page()
  assert.equal(p.head.length, 1)
  assert.equal(p.head[0].textContent, "#plan-item-i7 { opacity: 0 }")
  assert.deepEqual(p.focus, [["tab", {preventScroll: true}]])
  assert.equal(p.visible(), 0)
  assert.equal(p.model.style.transformOrigin, "0 0")
  // At the start, the first frame is on the item of the plan. The item is
  // 6 px wide, and the start box is 10 units of 3 px.
  close(Number(p.model.style.transform.match(/scale\((.*)\)/)[1]), 0.2)
  p.time.tick(OUT / 2)
  assert.ok(p.visible() > 0 && p.visible() < 11)
  p.time.tick(OUT)
  assert.equal(p.visible(), 11)
  assert.equal(p.model.style.transform, transformOf(FRONT))
})

test("a close flies the item back, and then closes the stage", () => {
  const p = page()
  p.time.tick(OUT)
  const event = p.click(p.closeLink)
  assert.equal(event.prevented, true)
  assert.equal(event.stopped, true)
  assert.deepEqual(p.js.classes, [[p.el, "stage-closing"]])
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
  assert.equal(p.focus.at(-1), "before")
})

test("the Escape key closes, and the Tab key keeps the focus in the stage", () => {
  const p = page()
  assert.equal(p.press("Escape"), true)
  p.time.tick(BACK)
  assert.deepEqual(p.js.patches, ["/inside?room=r2"])
  // The Tab key: the trap of the hook Sheet (no element: no change).
  assert.equal(p.press("Tab"), false)
  assert.equal(p.press("a"), false)
  // A click that is not on a close link does nothing.
  const event = p.click(null)
  assert.equal(event.prevented, false)
})

test("with less motion, the item is at once in front, and a close is at once", () => {
  const p = page({reduce: true})
  assert.equal(p.visible(), 11)
  assert.equal(p.model.style.transform, transformOf(FRONT))
  assert.equal(p.time.waiting(), false)
  p.click(p.closeLink)
  assert.deepEqual(p.js.patches, ["/inside?room=r2"])
  assert.deepEqual(p.js.classes, [])
})

test("an item that is not on the plan comes from the middle, and goes back there", () => {
  const p = page({plan: false})
  assert.equal(p.model.style.transform, "translate(120px, 120px) scale(0.2)")
  p.time.tick(OUT)
  p.press("Escape")
  p.time.tick(BACK)
  assert.equal(p.model.style.transform, "translate(120px, 120px) scale(0.2)")
  assert.deepEqual(p.js.patches, ["/inside?room=r2"])
})

test("the focus does not go back to an element that went away", () => {
  const p = page()
  p.hook.previous = {isConnected: false, focus: () => p.focus.push("gone")}
  p.hook.destroyed()
  assert.notEqual(p.focus.at(-1), "gone")
})
