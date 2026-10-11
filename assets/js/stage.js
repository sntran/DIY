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
// The panel of the item is next to the model on a wide page, and under it
// on a narrow page (the CSS). The model goes in the rest of the page. The
// tags on the model show where a number is on the real item. A tap on a
// tag goes to its number in the panel. "Show me where" in the panel shows
// the tag. The LED screen of a hub goes on the top of its model.
//
// With less motion (prefers-reduced-motion), the model is at once at its
// place, and a close is at once. The stage is a modal dialog: the Tab key
// keeps the focus in it (the hook Sheet).

import {sheetHook} from "./sheet.js"

// The time of the flight out and of the flight back, in milliseconds.
export const OUT = 900
export const BACK = 650
// The time of the ring of "Show me where" (three rings of 0.7 s in the CSS).
export const PING = 2100

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

// The width of the screen of a hub on the stage, in px for a font of
// 16 px: large enough to read. A larger font makes it larger. A screen
// that is less wide than SCREEN_MIN is too small to read on the model.
export const SCREEN_W = 300
export const SCREEN_MIN = 220

// The area of the model on the stage: the page with no panel. On a wide
// page the panel is at the right, and on a narrow page at the bottom. The
// boxes are in px, from the top left of the page.
export function areaOf(page, panel) {
  if (panel.left > page.width / 3) return {left: 24, top: 24, width: panel.left - 56, height: page.height - 48}
  return {left: 16, top: 16, width: page.width - 32, height: panel.top - 40}
}

// The place of the model in its area: the whole model, at the middle. With
// a screen (a hub), the model comes near: its screen (the region, three
// corners in units of the view) is SCREEN_W px wide. On a small area, the
// screen is as wide or as high as the area, less 24 px.
// The box has k, the px of a unit of the view.
export function placement(view, region, area, {screen = false, rem = 16} = {}) {
  const [vx, vy, vw, vh] = view
  if (screen) {
    const [ax, ay, bx, by, cx, cy] = region
    const wide = Math.hypot(bx - ax, by - ay)
    const high = Math.hypot(cx - ax, cy - ay)
    const k = Math.min(SCREEN_W * rem / 16 / wide, (area.width - 24) / wide, (area.height - 24) / high)
    const [mx, my] = [(bx + cx) / 2, (by + cy) / 2]
    return {
      left: area.left + area.width / 2 - (mx - vx) * k, top: area.top + area.height / 2 - (my - vy) * k,
      width: vw * k, height: vh * k, k,
    }
  }
  const k = Math.min((area.width * 0.92) / vw, (area.height * 0.94) / vh)
  return {
    left: area.left + (area.width - vw * k) / 2, top: area.top + (area.height - vh * k) / 2,
    width: vw * k, height: vh * k, k,
  }
}

// A point of the view (a tag) on the page, in the box of the model.
export const pointAt = (box, view, [x, y]) => [box.left + (x - view[0]) * box.k, box.top + (y - view[1]) * box.k]

// The screen of a hub on the region of the model: its size, and its CSS
// matrix. The matrix puts the screen along the two sides of the region, so
// it follows the slant of the top.
export function screenOf(box, view, region) {
  const [[ax, ay], [bx, by], [cx, cy]] = [0, 2, 4].map((i) => pointAt(box, view, region.slice(i, i + 2)))
  const width = Math.hypot(bx - ax, by - ay)
  const height = Math.hypot(cx - ax, cy - ay)
  return {width, height, matrix: [(bx - ax) / width, (by - ay) / width, (cx - ax) / height, (cy - ay) / height, ax, ay]}
}

// The screen of a hub on the page. On a small area (a zoom of 400 %), the
// screen on the model is too small to read. Then it covers the whole area,
// with no slant: the person sees the screen from very near.
export function screenAt(box, view, region, area, rem = 16) {
  const screen = screenOf(box, view, region)
  if (screen.width >= Math.min(SCREEN_MIN * rem / 16, area.width - 24) - 0.5) return screen
  return {width: area.width, height: area.height, matrix: [1, 0, 0, 1, area.left, area.top]}
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

// The parts of the browser for the hook (for the tests, fakes).
export const browserParts = (win) => ({
  now: () => win.performance.now(),
  frame: (f) => win.requestAnimationFrame(f),
  reduce: () => Boolean(win.matchMedia?.("(prefers-reduced-motion: reduce)").matches),
  wait: (f, ms) => win.setTimeout(f, ms),
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
      this.screen = this.el.querySelector(".stage-screen")
      this.spots = [...this.el.querySelectorAll("[data-spot]")]
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
      this.state("placed")
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

    // A new look of the item, for example a busbar with more positions: the
    // LiveView sends new frames (with a new id). The frame of the old pose
    // shows. The model keeps its place.
    updated() {
      const frames = [...this.model.querySelectorAll(".stage-frame")]
      if (frames[0] === this.frames[0]) return
      this.frames = frames
      this.show(this.index, this.pose)
    },

    // The flight out, from the item on the plan to the stage.
    start() {
      this.model.style.visibility = ""
      if (this.closing) return
      this.rest = this.restPose(this.planRect())
      const id = ++this.flight
      // The panel shows when the model lands: then its title takes the
      // focus, so a screen reader reads the name of the item.
      const landed = () => {
        this.state("landed")
        this.el.querySelector(".stage-title")?.focus({preventScroll: true})
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

    // The state of the stage (the CSS has a rule for each): "placed",
    // "landed" or "closing". It is the attribute data-stage. The LiveView
    // sets the attribute at once, so the panel shows before its key takes the
    // focus. A patch keeps it. (A class of the LiveView changes only at the
    // next frame, and a patch keeps it only when the element did not have it.)
    state(name) {
      this.js().setAttribute(this.el, "data-stage", name)
    },

    // The model, its tags and its screen on the stage, for the size of the
    // page and of its font. The panel has its place from the CSS: the
    // offsets do not change in its slide.
    place() {
      const page = {width: this.el.clientWidth, height: this.el.clientHeight}
      const panel = {
        left: this.panel.offsetLeft, top: this.panel.offsetTop,
        width: this.panel.offsetWidth, height: this.panel.offsetHeight,
      }
      const view = numbers(this.model.dataset.view)
      const region = numbers(this.el.dataset.region)
      const area = areaOf(page, panel)
      const rem = this.parts.rem()
      const box = placement(view, region, area, {screen: Boolean(this.screen), rem})
      Object.assign(this.model.style, {
        left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px`,
      })
      for (const spot of this.spots) {
        const [x, y] = pointAt(box, view, numbers(spot.dataset.at))
        Object.assign(spot.style, {left: `${x}px`, top: `${y}px`})
      }
      if (this.screen) {
        const {width, height, matrix} = screenAt(box, view, region, area, rem)
        Object.assign(this.screen.style, {
          width: `${width}px`, height: `${height}px`, transform: `matrix(${matrix.join(", ")})`,
        })
      }
      // The notch of a panel at the right points at the middle of the model.
      const middle = box.top + box.height / 2 - panel.top
      this.panel.style.setProperty("--notch", `${Math.max(24, Math.min(panel.height - 48, middle))}px`)
    },

    // A tap on a tag: its number in the panel, with the focus.
    goTo(key) {
      const field = this.el.ownerDocument.getElementById(`param-${key}-field`)
      if (!field) return
      field.scrollIntoView({block: "center", behavior: this.parts.reduce() ? "auto" : "smooth"})
      field.classList.add("stage-flash")
      this.parts.wait(() => field.classList.remove("stage-flash"), 900)
      field.querySelector("input:not([type=hidden]), select")?.focus({preventScroll: true})
    },

    // "Show me where": a ring on the tag of a number, or on the screen of a
    // hub, three times. With less motion, the ring does not move. It goes
    // after PING ms. The screen also takes the focus.
    ping(key) {
      const target = key === "screen" ? this.screen : this.spots.find((spot) => spot.dataset.spot === key)
      if (!target) return
      target.classList.remove("stage-ping")
      void target.offsetWidth
      target.classList.add("stage-ping")
      // A new ring of the same target starts its time again.
      const ping = (target.stagePing ?? 0) + 1
      target.stagePing = ping
      this.parts.wait(() => target.stagePing === ping && target.classList.remove("stage-ping"), PING)
      if (key === "screen") target.querySelector("input:not([type=hidden])")?.focus({preventScroll: true})
    },

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
      if (event.key === "Escape") {
        event.preventDefault()
        this.back(this.el.querySelector("[data-close]").getAttribute("href"))
      } else if (event.key === "Tab") {
        sheetHook.trap.call(this, event)
      }
    },

    // A close link: the item flies back first. A tag, or a "Show me where".
    click(event) {
      const link = event.target.closest("[data-close]")
      if (link) {
        event.preventDefault()
        event.stopPropagation()
        return this.back(link.getAttribute("href"))
      }
      const spot = event.target.closest("[data-spot]")
      if (spot) return this.goTo(spot.dataset.spot)
      const show = event.target.closest("[data-show]")
      if (show) this.ping(show.dataset.show)
    },

    // The flight back, from where the model is now (also in the flight
    // out), to the item on the plan. Then the close.
    back(href) {
      if (this.closing) return
      this.closing = true
      const id = ++this.flight
      const close = () => this.js().patch(href)
      this.state("closing")
      if (this.parts.reduce()) return close()
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
