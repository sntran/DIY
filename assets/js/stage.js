// The hook Stage of an item in front of the person (DIYWeb.Stage). The
// server draws the model of the item from 12 cameras: the frames of a
// flipbook. The first camera is the camera of the house, and the last
// looks at the front of the item. This script puts the first frame on the
// item of the plan. Then it moves the model to its place on the stage. It
// shows the frames one after the other while the model moves. So the item
// comes out of the house and turns to the person. A close does the same in
// the other direction, and then closes the stage. The key Put it back, the
// Escape key, and a tap next to the panel close the stage.
//
// With less motion (prefers-reduced-motion), the model is at once at its
// place, and a close is at once. The stage is a modal dialog: the Tab key
// keeps the focus in it (the hook Sheet).

import {sheetHook} from "./sheet.js"

// The time of the flight out and of the flight back, in milliseconds.
export const OUT = 900
export const BACK = 650

// The numbers of a text attribute ("1 2 3").
export const numbers = (text) => (text ?? "").trim().split(/\s+/).filter(Boolean).map(Number)

// Fast at the start, slow at the end; and the other way.
export const easeOut = (t) => 1 - (1 - t) ** 3
export const easeIn = (t) => t ** 3

// The frame for a part of the flight (0 to 1).
export const frameAt = (part, count) => Math.min(count - 1, Math.max(0, Math.round(part * (count - 1))))

// The box of the drawing of an item on the plan: all its polygons but its
// shadow. Null when it does not show.
export function rectOf(group) {
  if (!group) return null
  const rects = [...group.querySelectorAll("polygon:not(.p-shadow)")]
    .map((p) => p.getBoundingClientRect())
    .filter((r) => r.width > 0 || r.height > 0)
  if (rects.length === 0) return null
  const left = Math.min(...rects.map((r) => r.left))
  const top = Math.min(...rects.map((r) => r.top))
  const right = Math.max(...rects.map((r) => r.right))
  const bottom = Math.max(...rects.map((r) => r.bottom))
  return {left, top, width: right - left, height: bottom - top}
}

// The pose of the model at the place of the item on the plan: a move and a
// scale of the model element. The box is the place of the element on the
// page, with no transform. The first frame has the drawing of the plan in
// its box start (in units of the view). The center of that box goes to the center of the rect. With
// no rect, the model starts small, at its own center.
export function restPose(box, view, start, rect) {
  const [vx, vy, vw, vh] = view
  const [sx, sy, sw, sh] = start
  if (!rect) return {x: box.width * 0.4, y: box.height * 0.4, s: 0.2}
  // The SVG fits the view in the box, at the middle (preserveAspectRatio).
  const k = Math.min(box.width / vw, box.height / vh)
  const ox = (box.width - k * vw) / 2
  const oy = (box.height - k * vh) / 2
  const s = Math.max(rect.width / (k * sw), rect.height / (k * sh))
  const cx = box.left + ox + k * (sx + sw / 2 - vx)
  const cy = box.top + oy + k * (sy + sh / 2 - vy)
  const rx = rect.left + rect.width / 2
  const ry = rect.top + rect.height / 2
  // With the origin of the transform at the top left of the box.
  return {x: rx - box.left - s * (cx - box.left), y: ry - box.top - s * (cy - box.top), s}
}

export const FRONT = {x: 0, y: 0, s: 1}

// The sizes of the panel on the stage, in px for a font of 16 px. The
// least width and height let a person read it. A larger font makes them
// larger. The panel stays EDGE px from the sides of the page.
export const MIN_W = 260
export const MIN_H = 150
export const MAX_W = 440
export const EDGE = 12

// The places of the model and of its panel on the stage (an area of the
// page). The region is the place of the panel on the last frame. It has
// three corners: at the top left, at the top right and at the bottom left.
// They are in units of the view. The whole model fits in the area when the
// panel is then large enough to read. Else the model comes nearer. The
// panel is not wider or higher than the page. The middle of the panel is
// at the middle of the width, and at 45% of the height. When a side of the
// panel is then out of the page, the panel moves into the page.
export function placement(view, region, area, rem = 16) {
  const [vx, vy, vw, vh] = view
  const [ax, ay, bx, by, cx, cy] = region
  const ru = Math.hypot(bx - ax, by - ay)
  const rv = Math.hypot(cx - ax, cy - ay)
  const font = rem / 16
  const fit = Math.min((area.width * 0.9) / vw, (area.height * 0.75) / vh)
  const most = Math.min(Math.min(area.width - 2 * EDGE, MAX_W * font) / ru, (area.height - 2 * EDGE) / rv)
  const k = Math.min(Math.max(fit, (MIN_W * font) / ru, (MIN_H * font) / rv), most)
  // The middle of the panel, and the half of its box on the page.
  const [mx, my] = [(bx + cx) / 2, (by + cy) / 2]
  const hx = Math.max(Math.abs(ax - mx), Math.abs(bx - mx)) * k
  const hy = Math.max(Math.abs(ay - my), Math.abs(by - my)) * k
  const px = Math.max(EDGE + hx, Math.min(area.width / 2, area.width - EDGE - hx))
  const py = Math.max(EDGE + hy, Math.min(area.height * 0.45, area.height - EDGE - hy))
  const left = px - (mx - vx) * k
  const top = py - (my - vy) * k
  return {
    model: {left, top, width: vw * k, height: vh * k},
    panel: {
      width: ru * k,
      height: rv * k,
      // The panel goes along the two sides of the region.
      matrix: [(bx - ax) / ru, (by - ay) / ru, (cx - ax) / rv, (cy - ay) / rv, left + (ax - vx) * k, top + (ay - vy) * k],
    },
  }
}

// A pose between two poses: a at 0, b at 1.
export const between = (a, b, t) => ({x: a.x * (1 - t) + b.x * t, y: a.y * (1 - t) + b.y * t, s: a.s * (1 - t) + b.s * t})

export const transformOf = ({x, y, s}) => `translate(${x}px, ${y}px) scale(${s})`

// A flight: each step of the clock shows the frame and the pose of its
// part of the time. It calls done at the end. It stops when it is not
// alive (a different flight started, or the stage went away).
export function fly({from, to, first, last, count, time, ease, now, frame, show, done, alive = () => true}) {
  const start = now()
  const step = () => {
    if (!alive()) return
    const t = Math.min(1, (now() - start) / time)
    const part = ease(t)
    show(frameAt(first / (count - 1) + (last - first) / (count - 1) * part, count), between(from, to, part))
    if (t < 1) frame(step)
    else done()
  }
  step()
}

// The center of a rect is in a box.
export const inside = (rect, box) => {
  const [x, y] = [rect.left + rect.width / 2, rect.top + rect.height / 2]
  return x >= box.left && x <= box.left + box.width && y >= box.top && y <= box.top + box.height
}

// A text in a CSS string ("..."): its quotes and its backslashes have an
// escape, so an id cannot end the selector.
export const cssString = (text) => JSON.stringify(String(text)).slice(1, -1)

// The next tab for an arrow key, Home or End, or null for a different key.
export function nextTab(tabs, current, key) {
  const i = tabs.indexOf(current)
  const moves = {ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1}
  if (!(key in moves)) return null
  return tabs[(moves[key] + tabs.length) % tabs.length]
}

// The parts of the browser for the hook (for the tests, fakes).
export const browserParts = (win) => ({
  now: () => win.performance.now(),
  frame: (f) => win.requestAnimationFrame(f),
  reduce: () => Boolean(win.matchMedia?.("(prefers-reduced-motion: reduce)").matches),
  // The size of the font of the page, in px.
  rem: () => Number.parseFloat(win.getComputedStyle(win.document.documentElement).fontSize) || 16,
})

// The parts of the browser of the page of an element.
export const pageParts = (el) => browserParts(el.ownerDocument.defaultView)

export function stageHook(parts = pageParts) {
  return {
    mounted() {
      const doc = this.el.ownerDocument
      this.parts = parts(this.el)
      this.previous = doc.activeElement
      this.model = this.el.querySelector(".stage-model")
      this.panel = this.el.querySelector(".stage-panel")
      this.frames = [...this.model.querySelectorAll(".stage-frame")]
      this.flight = 0
      this.closing = false
      this.index = this.frames.length - 1
      this.pose = FRONT
      this.onKey = (event) => this.key(event)
      this.onClick = (event) => this.click(event)
      this.onResize = () => this.place()
      doc.addEventListener("keydown", this.onKey)
      doc.defaultView?.addEventListener("resize", this.onResize)
      this.el.addEventListener("click", this.onClick)
      this.mark("stage-placed")
      this.place()

      // The item on the plan does not show while it is on the stage.
      this.away = doc.createElement("style")
      this.away.textContent = `[id="${cssString(`plan-item-${this.el.dataset.item}`)}"] { opacity: 0 }`
      doc.head.append(this.away)

      // The hook Plan shows the layer of the item after this hook mounts: so
      // the flight starts at the next frame of the page.
      this.model.style.visibility = "hidden"
      this.parts.frame(() => this.start())
    },

    // The flight out, from the item on the plan to the stage.
    start() {
      this.model.style.visibility = ""
      if (this.closing) return
      this.rest = this.restPose(this.planRect())
      const id = ++this.flight
      // The panel shows when the model lands: then it takes the focus.
      const landed = () => {
        this.mark("stage-landed")
        this.el.querySelector('[role="tab"][aria-selected="true"]')?.focus({preventScroll: true})
      }
      if (this.parts.reduce()) {
        this.show(this.frames.length - 1, FRONT)
        return landed()
      }
      fly({
        from: this.rest, to: FRONT, first: 0, last: this.frames.length - 1, count: this.frames.length,
        time: OUT, ease: easeOut, now: this.parts.now, frame: this.parts.frame,
        show: (i, pose) => this.show(i, pose), done: landed, alive: () => id === this.flight,
      })
    },

    // The box of the item on the plan. The item must show in the plan, and
    // on the page. The stage is as large as the page.
    planRect() {
      const doc = this.el.ownerDocument
      const rect = rectOf(doc.getElementById(`plan-item-${this.el.dataset.item}`))
      const plan = doc.getElementById("plan-svg")?.getBoundingClientRect()
      return rect && plan && inside(rect, plan) && inside(rect, this.el.getBoundingClientRect()) ? rect : null
    },

    // A class on the stage, at once. The LiveView adds it too, so that a
    // patch keeps it. But the LiveView adds it only at the next frame of the
    // page, and the focus needs the panel before that.
    mark(add, remove = null) {
      if (remove) {
        this.el.classList.remove(remove)
        this.js().removeClass(this.el, remove)
      }
      this.el.classList.add(add)
      this.js().addClass(this.el, add)
    },

    // The model and its panel on the stage, for the size of the page and of
    // its font.
    place() {
      const area = this.el.getBoundingClientRect()
      const view = numbers(this.model.dataset.view)
      const {model, panel} = placement(view, numbers(this.el.dataset.region), area, this.parts.rem())
      Object.assign(this.model.style, {
        left: `${model.left}px`, top: `${model.top}px`, width: `${model.width}px`, height: `${model.height}px`,
      })
      Object.assign(this.panel.style, {
        width: `${panel.width}px`, height: `${panel.height}px`, transform: `matrix(${panel.matrix.join(", ")})`,
      })
      this.panel.style.setProperty("--pw", `${panel.width}px`)
    },

    // The stage is not on the page now: the flight stops, and a start that
    // waits for a frame does not start a flight (specs/Stage.tla).
    destroyed() {
      const doc = this.el.ownerDocument
      this.closing = true
      this.flight += 1
      doc.removeEventListener("keydown", this.onKey)
      doc.defaultView?.removeEventListener("resize", this.onResize)
      this.away.remove()
      if (this.previous?.isConnected) this.previous.focus()
    },

    restPose(rect) {
      const transform = this.model.style.transform
      this.model.style.transform = "none"
      const box = this.model.getBoundingClientRect()
      this.model.style.transform = transform
      return restPose(box, numbers(this.model.dataset.view), numbers(this.el.dataset.start), rect)
    },

    // A frame and a pose of the model. Only one frame shows: an SVG element
    // has no hidden property, so the attribute changes.
    show(index, pose) {
      this.index = index
      this.pose = pose
      this.frames.forEach((svg, i) => svg.toggleAttribute("hidden", i !== index))
      this.model.style.transformOrigin = "0 0"
      this.model.style.transform = transformOf(pose)
    },

    key(event) {
      const tab = event.target?.closest?.('[role="tab"]')
      const next = tab && nextTab([...this.el.querySelectorAll('[role="tab"]')], tab, event.key)
      if (next) {
        event.preventDefault()
        next.focus()
        next.click()
      } else if (event.key === "Escape") {
        event.preventDefault()
        this.back(this.el.querySelector("[data-close]").getAttribute("href"))
      } else if (event.key === "Tab") {
        sheetHook.trap.call(this, event)
      }
    },

    // A close link: the item flies back first.
    click(event) {
      const link = event.target.closest("[data-close]")
      if (!link) return
      event.preventDefault()
      event.stopPropagation()
      this.back(link.getAttribute("href"))
    },

    // The flight back, from where the model is now (also in the flight
    // out), to the item on the plan. Then the close.
    back(href) {
      if (this.closing) return
      this.closing = true
      const id = ++this.flight
      const close = () => this.js().patch(href)
      if (this.parts.reduce()) return close()
      this.mark("stage-closing", "stage-landed")
      // The plan can have a different place now (a zoom, or a move).
      const rect = this.planRect()
      const rest = rect ? this.restPose(rect) : (this.rest ?? this.restPose(null))
      fly({
        from: this.pose, to: rest, first: this.index, last: 0, count: this.frames.length,
        time: BACK, ease: easeIn, now: this.parts.now, frame: this.parts.frame,
        show: (i, pose) => this.show(i, pose), done: close, alive: () => id === this.flight,
      })
    },
  }
}
