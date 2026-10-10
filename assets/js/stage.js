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

// A pose between two poses: a at 0, b at 1.
export const between = (a, b, t) => ({x: a.x * (1 - t) + b.x * t, y: a.y * (1 - t) + b.y * t, s: a.s * (1 - t) + b.s * t})

export const transformOf = ({x, y, s}) => `translate(${x}px, ${y}px) scale(${s})`

// A flight: each step of the clock shows the frame and the pose of its
// part of the time. It calls done at the end.
export function fly({from, to, first, last, count, time, ease, now, frame, show, done}) {
  const start = now()
  const step = () => {
    const t = Math.min(1, (now() - start) / time)
    const part = ease(t)
    show(frameAt(first / (count - 1) + (last - first) / (count - 1) * part, count), between(from, to, part))
    if (t < 1) frame(step)
    else done()
  }
  step()
}

// The parts of the browser for the hook (for the tests, fakes).
export const browserParts = (win) => ({
  now: () => win.performance.now(),
  frame: (f) => win.requestAnimationFrame(f),
  reduce: () => Boolean(win.matchMedia?.("(prefers-reduced-motion: reduce)").matches),
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
      this.frames = [...this.model.querySelectorAll(".stage-frame")]
      this.closing = false
      this.onKey = (event) => this.key(event)
      this.onClick = (event) => this.click(event)
      doc.addEventListener("keydown", this.onKey)
      this.el.addEventListener("click", this.onClick)

      // The item on the plan does not show while it is on the stage.
      this.away = doc.createElement("style")
      this.away.textContent = `#plan-item-${this.el.dataset.item} { opacity: 0 }`
      const group = doc.getElementById(`plan-item-${this.el.dataset.item}`)
      this.rest = this.restPose(rectOf(group))
      doc.head.append(this.away)

      this.el.querySelector('[role="tab"][aria-selected="true"]')?.focus({preventScroll: true})
      if (this.parts.reduce()) return this.show(this.frames.length - 1, FRONT)
      fly({
        from: this.rest, to: FRONT, first: 0, last: this.frames.length - 1, count: this.frames.length,
        time: OUT, ease: easeOut, now: this.parts.now, frame: this.parts.frame,
        show: (i, pose) => this.show(i, pose), done: () => {},
      })
    },

    destroyed() {
      const doc = this.el.ownerDocument
      doc.removeEventListener("keydown", this.onKey)
      this.away.remove()
      if (this.previous?.isConnected) this.previous.focus()
    },

    restPose(rect) {
      this.model.style.transform = "none"
      const box = this.model.getBoundingClientRect()
      return restPose(box, numbers(this.model.dataset.view), numbers(this.el.dataset.start), rect)
    },

    show(index, pose) {
      this.frames.forEach((svg, i) => { svg.hidden = i !== index })
      this.model.style.transformOrigin = "0 0"
      this.model.style.transform = transformOf(pose)
    },

    key(event) {
      if (event.key === "Escape") {
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

    back(href) {
      if (this.closing) return
      this.closing = true
      const close = () => this.js().patch(href)
      if (this.parts.reduce()) return close()
      this.js().addClass(this.el, "stage-closing")
      // The plan can have a different place now (a zoom, or a move).
      const rect = rectOf(this.el.ownerDocument.getElementById(`plan-item-${this.el.dataset.item}`))
      const rest = rect ? this.restPose(rect) : this.rest
      fly({
        from: FRONT, to: rest, first: this.frames.length - 1, last: 0, count: this.frames.length,
        time: BACK, ease: easeIn, now: this.parts.now, frame: this.parts.frame,
        show: (i, pose) => this.show(i, pose), done: close,
      })
    },
  }
}
