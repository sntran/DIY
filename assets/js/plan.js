// The hook Plan of the plan of the house at scale (DIYWeb.Cutaway). The
// person moves the items and the rooms with a pointer (a finger or a
// mouse). Two fingers, Ctrl and the mouse wheel, or the buttons zoom. A
// drag on an empty place moves the picture. When the picture shows all the
// house, a finger that moves up or down scrolls the page, and the page
// glides when the finger lifts. A tap on an item opens it. A tap on a
// room, on a wall or on the edge of a slab chooses the room. The room then
// has handles on its walls, and the view zooms in to it. In the list of the rooms (for a keyboard and a screen reader), the
// arrow keys move an item or a room.
//
// The server draws the SVG. This script only moves parts of it while the
// pointer moves, and then sends the change: the server then draws it again.
//
// The math. A point of the plan is x, y in inches, on the surface of a
// room. It goes to the SVG with the axes of the camera (data-axes: the SVG
// vectors of one inch along x, along y and up, DIYWeb.Camera.axes/1). It
// also uses the origin of the surface (data-origin, the SVG point of 0, 0).
// The formula:
//   sx = ox + ax x + bx y + cx z
//   sy = oy + ay x + by y + cy z
// A floor is flat (z = 0). A roof (data-rise) has a ridge along x, at the
// middle of its depth. On a roof, z is 0 at the eaves and the rise at the
// ridge.

// The numbers of a text attribute ("1 2 3").
export const numbers = (text) => text.trim().split(/\s+/).map(Number)

// The surface of a room element: its origin, its plan and its rise.
export function surfaceOf(el) {
  const rise = el.getAttribute("data-rise")
  return {
    origin: numbers(el.getAttribute("data-origin")),
    plan: numbers(el.getAttribute("data-plan")),
    rise: rise ? Number(rise) : 0,
  }
}

// The height of a surface over a point of the plan (y in inches).
export function heightAt(surface, y) {
  if (!surface.rise) return 0
  const [, py, , d] = surface.plan
  const half = d / 2
  return surface.rise * (1 - Math.abs(y - (py + half)) / half)
}

// The SVG point of a point of the plan on a surface.
export function forward(point, surface, axes) {
  const [ax, ay, bx, by, cx, cy] = axes
  const [ox, oy] = surface.origin
  const z = heightAt(surface, point.y)
  return {x: ox + ax * point.x + bx * point.y + cx * z, y: oy + ay * point.x + by * point.y + cy * z}
}

// The x, y of a move on the SVG (u, v). The SVG vectors of one inch are a
// (along x) and b (along y). It solves u = ax x + bx y, v = ay x + by y.
function solve(u, v, [ax, ay], [bx, by]) {
  const det = ax * by - bx * ay
  return {x: (u * by - bx * v) / det, y: (ax * v - ay * u) / det}
}

// The point of the plan on a surface under an SVG point.
export function inverse(svg, surface, axes) {
  const [ax, ay, bx, by, cx, cy] = axes
  const [ox, oy] = surface.origin
  const [u, v] = [svg.x - ox, svg.y - oy]
  if (!surface.rise) return solve(u, v, [ax, ay], [bx, by])

  // On a roof, z goes with y: z = z0 + m y on each slope. So a slope is a
  // plane with the vector b + m c along y, from the point z0 c. The front
  // slope goes from the ridge to the front; else the point is on the back
  // slope.
  const [, py, , d] = surface.plan
  const ridge = py + d / 2
  const m = surface.rise / (d / 2)
  const slope = (z0, k) => solve(u - cx * z0, v - cy * z0, [ax, ay], [bx + k * cx, by + k * cy])
  const front = slope(surface.rise + m * ridge, -m)
  return front.y >= ridge ? front : slope(surface.rise - m * ridge, m)
}

// True when the point of the plan under an SVG point is on a surface.
export function onSurface(svg, surface, axes) {
  const p = inverse(svg, surface, axes)
  const [x, y, w, d] = surface.plan
  return p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + d
}

// The SVG units of one pixel of the screen. The view fills the SVG on the
// side that limits it, and keeps its shape.
export function unitsOf(view, width, height) {
  return Math.max(view.w / (width || 1), view.h / (height || 1))
}

// A move on the SVG as a move on a flat plan, in inches.
export function delta(dsx, dsy, axes) {
  const [ax, ay, bx, by] = axes
  const {x, y} = solve(dsx, dsy, [ax, ay], [bx, by])
  return {dx: x, dy: y}
}

// The plan of a room after a move of one of its walls. x0 and x1 are the
// walls at the small x and at the large x. y0 and y1 are the walls at the
// small y and at the large y. In the house, x0 is the left wall and y0 the
// back wall.
export function resize(plan, edge, dx, dy) {
  const [x, y, w, d] = plan
  switch (edge) {
    case "x0":
      return [x + dx, y, w - dx, d]
    case "x1":
      return [x, y, w + dx, d]
    case "y0":
      return [x, y + dy, w, d - dy]
    default:
      return [x, y, w, d + dy]
  }
}

// The SVG points of the corners of a plan on a flat surface.
export function outline(plan, origin, axes) {
  const [x, y, w, d] = plan
  const surface = {origin, plan, rise: 0}
  return [
    [x, y],
    [x + w, y],
    [x + w, y + d],
    [x, y + d],
  ]
    .map(([px, py]) => forward({x: px, y: py}, surface, axes))
    .map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`)
    .join(" ")
}

// A view (a box of the SVG) after a zoom by a factor around a point. The
// view stays from 1/12 of the box of the house to 2 times it.
export function zoom(view, factor, px, py, fit) {
  const w = Math.min(Math.max(view.w / factor, fit.w / 12), fit.w * 2)
  const f = view.w / w
  return {x: px - (px - view.x) / f, y: py - (py - view.y) / f, w, h: view.h / f}
}

// The move of an arrow key, in inches: 6, or 24 with Shift. The key moves
// the item as it points on the screen. The arrows of the camera are
// data-arrows (rx ry dx dy, DIYWeb.Camera.arrows/1). They are the steps of
// the plan for a move to the right, and for a move down the screen.
export function arrow(key, shift, arrows) {
  const step = shift ? 24 : 6
  const [rx, ry, dx, dy] = arrows
  const moves = {
    ArrowRight: [rx, ry],
    ArrowLeft: [-rx, -ry],
    ArrowDown: [dx, dy],
    ArrowUp: [-dx, -dy],
  }
  // (+ 0 makes a -0 a 0.)
  return moves[key] ? {dx: moves[key][0] * step + 0, dy: moves[key][1] * step + 0} : null
}

// True when two boxes ({x, y, width, height}) overlap, or are nearer than
// a gap.
export function overlaps(a, b, gap = 0) {
  return (
    a.x < b.x + b.width + gap &&
    b.x < a.x + a.width + gap &&
    a.y < b.y + b.height + gap &&
    b.y < a.y + a.height + gap
  )
}

// The view that shows a box of the SVG on a screen with a shape (w / h).
// The box has a margin, and it is at the middle. The view is at least
// `least` wide.
export function frame(box, shape, margin = 1.15, least = 0) {
  let w = box.w * margin
  let h = box.h * margin
  if (w / h < shape) w = h * shape
  else h = w / shape
  if (w < least) [w, h] = [least, least / shape]
  return {x: box.x + box.w / 2 - w / 2, y: box.y + box.h / 2 - h / 2, w, h}
}

// The view that shows a room: a third of the box of the house at least,
// so that the person sees where the room is. A view that shows it in more
// detail stays: a tap does not zoom out.
export function focus(view, box, shape, fit) {
  const next = frame(box, shape, 1.15, fit.w / 3)
  return next.w >= view.w ? view : next
}

// A view that keeps the house (the box fit) on the screen. A view smaller
// than the house stays in it; a view larger than the house keeps all of
// it. So a drag does not move the house off the screen.
export function clamp(view, fit) {
  const axis = (start, size, from, length) => {
    const [low, high] = [from, from + length - size].sort((a, b) => a - b)
    return Math.min(Math.max(start, low), high)
  }
  return {...view, x: axis(view.x, view.w, fit.x, fit.w), y: axis(view.y, view.h, fit.y, fit.h)}
}

// The id of the layer of an element of the plan.
const layerOf = (el) => el.closest("[data-box]").getAttribute("id").replace("plan-", "")
// A room or an item, and its layer, as a text; or null.
const placeOf = (el) => (el ? `${el.getAttribute("data-room") || el.getAttribute("data-item")} ${layerOf(el)}` : null)

// The view as the text of a viewBox.
const box = (view) => [view.x, view.y, view.w, view.h].map((n) => n.toFixed(2)).join(" ")
const parseView = (text) => {
  const [x, y, w, h] = numbers(text)
  return {x, y, w, h}
}

// A move of the pointer of more than this (in pixels) is a drag, not a tap.
const SLOP = 5
// A handle is 24 pixels wide. Handles that are nearer than 1.5 handles
// on the screen would hide their room: then they do not show.
const HANDLE = 24
// The view stays for each plan (the house, and each van) in the tab.
const KEY = "plan-view:"
// A page that a finger scrolls keeps its speed after the finger lifts, and
// slows down. It keeps this part of its speed for each 16 ms. It stops
// under 0.02 pixels for each ms. A finger that stops for more than 50 ms
// before it lifts gives no glide. A frame counts at most 50 ms: after a
// pause of the page, the glide does not jump.
const FRICTION = 0.95
const STOP = 0.02
const STILL = 50
const FRAME = 50
// The speed of the finger: this part of the speed of the last move, and
// the rest of the speed of the moves before it.
const LAST = 0.8
// The events that stop a glide, on all the page.
const HALT = ["pointerdown", "wheel", "keydown"]

export const planHook = {
  mounted() {
    this.svg = this.el.querySelector("svg")
    this.axes = numbers(this.svg.getAttribute("data-axes"))
    this.arrows = numbers(this.svg.getAttribute("data-arrows"))
    this.pointers = new Map()
    this.drag = null
    const saved = this.saved()
    // The view of the person comes back with its layer. With no view, the
    // page starts on its first layer (the house: floor 1): the layer fills
    // the screen, and the other layers hide.
    const layer = saved ? this.stored(":layer") : this.svg.getAttribute("data-start")
    const first = layer ? this.layerView(layer) : null
    if (first) this.dim(layer)
    this.show(saved || first || this.fit())
    this.chosen = null
    this.opened = null
    this.reveal()

    this.listeners = {
      pointerdown: (e) => this.down(e),
      pointermove: (e) => this.move(e),
      pointerup: (e) => this.up(e),
      pointercancel: (e) => this.cancel(e),
      wheel: (e) => this.wheel(e),
    }
    for (const [type, fun] of Object.entries(this.listeners))
      this.svg.addEventListener(type, fun, {passive: false})
    this.onClick = (e) => this.click(e)
    this.onKey = (e) => this.key(e)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    this.stopGlide()
    this.window().clearTimeout(this.hintTimer)
    for (const [type, fun] of Object.entries(this.listeners)) this.svg.removeEventListener(type, fun)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKey)
  },

  // The box of all the layers, or of the layer that shows when the others
  // hide. The view stays in it. The server changes it when a room moves or
  // comes: so the script reads it each time.
  fit() {
    const dimmed = this.dimmed()
    const layer = this.oneLayer() && dimmed && this.svg.querySelector(`#plan-${dimmed}`)
    return parseView(layer ? layer.getAttribute("data-box") : this.svg.getAttribute("data-fit"))
  },

  units(view) {
    return unitsOf(view, this.svg.clientWidth, this.svg.clientHeight)
  },

  // The shape of the SVG on the screen (w / h). A page with no size yet
  // has a square.
  shape() {
    return (this.svg.clientWidth || 1) / (this.svg.clientHeight || 1)
  },

  window() {
    return this.el.ownerDocument.defaultView
  },

  // True when the view shows all the house: all its width and all its
  // height.
  whole() {
    const fit = this.fit()
    return this.view.w >= fit.w - 1e-6 && this.view.h >= fit.h - 1e-6
  },

  // The house shows one layer at a time (data-start): the tab of a layer,
  // or a room on a layer, makes the other layers hide. In the van, all the
  // layers show, and the tab of a layer makes the other layers pale.
  oneLayer() {
    return this.svg.getAttribute("data-start") !== null
  },

  // The view that the person had on this page before (a zoom), if any.
  saved() {
    const text = this.stored("")
    return text ? parseView(text) : null
  },

  // A value that stays for this plan in the tab (the view, and its layer),
  // or null.
  stored(name) {
    try {
      return this.window().sessionStorage.getItem(KEY + this.el.id + name)
    } catch (_error) {
      return null
    }
  },

  // A page with no storage keeps the view only while it is open.
  store(name, value) {
    try {
      const storage = this.window().sessionStorage
      if (value === null) storage.removeItem(KEY + this.el.id + name)
      else storage.setItem(KEY + this.el.id + name, value)
    } catch (_error) {
      // Nothing to do.
    }
  },

  // The server draws the SVG again: its labels and its handles show again.
  // The layer that stands out stops when it is not there now. A room that
  // the person chooses shows.
  updated() {
    const dimmed = this.dimmed()
    this.dim(dimmed && this.svg.querySelector(`#plan-${dimmed}`) ? dimmed : null)
    this.declutter()
    this.handles()
    this.reveal()
  },

  // A room that the person chooses, or an item with an open sheet, shows
  // (also from the list or a sheet). When it is on a layer that hides, the
  // view zooms in to the room, or its layer shows. Only a new choice, or a
  // move to a different layer, moves the view.
  reveal() {
    const outline = this.svg.querySelector("[data-outline]")
    const room = outline && this.surface(outline.getAttribute("data-outline"))
    const open = this.svg.getAttribute("data-open")
    const item = open && this.svg.querySelector(`[data-item="${open}"]`)
    const [chosen, opened] = [placeOf(room), placeOf(item)]
    if (chosen !== this.chosen && room && this.hidden(room)) this.zoomTo(room)
    else if (opened !== this.opened && item && this.hidden(item)) this.showLayer(layerOf(item))
    this.chosen = chosen
    this.opened = opened
  },

  // True when an element is on a layer that hides (the house).
  hidden(el) {
    const dimmed = this.dimmed()
    return this.oneLayer() && dimmed !== null && layerOf(el) !== dimmed
  },

  // Shows a view: the viewBox, and the size of the labels and the handles
  // on the screen (the same at each zoom). The house stays on the screen.
  show(view) {
    view = clamp(view, this.fit())
    this.view = view
    this.svg.setAttribute("viewBox", box(view))
    const units = this.units(view)
    this.svg.style.setProperty("--p-label", `${(12 * units).toFixed(3)}px`)
    // A handle is 24 pixels wide: the smallest target of WCAG 2.2 (2.5.8).
    this.svg.style.setProperty("--p-handle", `${((HANDLE / 2) * units).toFixed(3)}px`)
    // After a zoom, the labels have a new size on the SVG.
    if (units !== this.labelUnits) {
      this.labelUnits = units
      this.declutter()
    }
    this.handles()
    this.store("", box(view))
  },

  // Where two labels overlap, or are nearer than 4 pixels, the label of
  // the larger room shows (data-rank). The other one hides until a zoom in.
  declutter() {
    const labels = [...this.svg.querySelectorAll("[data-rank]")].sort(
      (a, b) => Number(b.getAttribute("data-rank")) - Number(a.getAttribute("data-rank")),
    )
    const shown = []
    for (const label of labels) {
      label.style.visibility = ""
      const box = label.getBBox()
      if (shown.some((other) => overlaps(other, box, 4 * this.labelUnits))) label.style.visibility = "hidden"
      else shown.push(box)
    }
  },

  // The handles of the chosen room show when they are far enough apart on
  // the screen.
  handles() {
    const handles = [...this.svg.querySelectorAll("[data-handle]")]
    const points = handles.map((h) => [Number(h.getAttribute("cx")), Number(h.getAttribute("cy"))])
    let near = Infinity
    for (const [i, [x, y]] of points.entries())
      for (const [u, v] of points.slice(i + 1)) near = Math.min(near, Math.hypot(u - x, v - y))
    const hide = near / this.units(this.view) < 1.5 * HANDLE
    for (const handle of handles) handle.style.visibility = hide ? "hidden" : ""
  },

  // The SVG point of a point of the screen.
  point(clientX, clientY) {
    const m = this.svg.getScreenCTM()
    return {x: (clientX - m.e) / m.a, y: (clientY - m.f) / m.d}
  },

  // The surface of a room under a point of the screen (not the dragged
  // element), or null.
  roomAt(clientX, clientY) {
    const els = this.el.ownerDocument.elementsFromPoint(clientX, clientY)
    return els.find((el) => el.getAttribute && el.getAttribute("data-room")) || null
  },

  surface(id) {
    return this.svg.querySelector(`[data-room="${id}"]`)
  },

  // The surface of the room of a wall, or of the edge of a slab, or null.
  roomOf(el) {
    const part = el.closest("[data-of]")
    return part ? this.surface(part.getAttribute("data-of")) : null
  },

  down(e) {
    // A finger that stops a glide does not tap: as on a page that the
    // browser scrolls.
    const halted = Boolean(this.gliding) || this.halted === e
    this.halted = null
    this.stopGlide()
    this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
    this.svg.setPointerCapture(e.pointerId)
    if (this.pointers.size === 2) {
      this.reset()
      const [p, q] = [...this.pointers.values()]
      this.drag = {kind: "pinch", span: Math.hypot(p.x - q.x, p.y - q.y), view: this.view}
      return
    }
    if (this.pointers.size > 2) return
    const target = e.target
    const handle = target.closest("[data-handle]")
    const item = target.closest("[data-item]")
    const room = target.closest("[data-room]") || this.roomOf(target)
    const chosen = this.svg.querySelector("[data-outline]")
    let kind = "pan"
    let el = null
    if (handle) [kind, el] = ["handle", handle]
    else if (item) [kind, el] = ["item", item]
    else if (room && chosen && room.getAttribute("data-room") === chosen.getAttribute("data-outline"))
      [kind, el] = ["room", room]
    // A finger on a view of all the house scrolls the page up or down.
    const scroll = kind === "pan" && e.pointerType === "touch" && this.whole()
    this.drag = {kind, el, room, x: e.clientX, y: e.clientY, last: e.clientY, scroll, view: this.view, moved: false, t: e.timeStamp, v: 0, halted}
  },

  move(e) {
    if (!this.pointers.has(e.pointerId)) return
    this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
    const drag = this.drag
    if (!drag) return
    if (drag.kind === "pinch") return this.pinch(drag)
    const dx = e.clientX - drag.x
    const dy = e.clientY - drag.y
    if (!drag.moved && Math.hypot(dx, dy) < SLOP) return
    drag.moved = true
    const start = this.point(drag.x, drag.y)
    const now = this.point(e.clientX, e.clientY)
    const sdx = now.x - start.x
    const sdy = now.y - start.y

    if (drag.scroll) {
      this.window().scrollBy(0, drag.last - e.clientY)
      // The speed of the finger, in pixels for each ms, with the speed of
      // the moves before it.
      const dt = e.timeStamp - drag.t
      if (dt > 0) drag.v = LAST * ((drag.last - e.clientY) / dt) + (1 - LAST) * drag.v
      drag.t = e.timeStamp
      drag.last = e.clientY
    } else if (drag.kind === "pan") {
      // The view moves with the pointer: the start point stays under it.
      const units = this.units(drag.view)
      this.show({...drag.view, x: drag.view.x - dx * units, y: drag.view.y - dy * units})
    } else if (drag.kind === "handle") {
      this.preview(drag.el, sdx, sdy)
    } else {
      for (const el of this.moving(drag)) {
        el.setAttribute("transform", `translate(${sdx.toFixed(2)} ${sdy.toFixed(2)})`)
        el.classList.add("p-dragging")
      }
    }
    drag.sdx = sdx
    drag.sdy = sdy
  },

  // The elements that move with a drag: an item; or a room with its items
  // and its outline.
  moving(drag) {
    if (drag.kind === "item") return [drag.el]
    const id = drag.el.getAttribute("data-room")
    return [
      drag.el.parentNode,
      ...this.svg.querySelectorAll(`[data-in="${id}"]`),
      this.svg.querySelector("#plan-selection"),
    ].filter(Boolean)
  },

  // The outline of a room while a handle moves.
  preview(handle, sdx, sdy) {
    const outlineEl = this.svg.querySelector("[data-outline]")
    const plan = numbers(outlineEl.getAttribute("data-plan"))
    const origin = numbers(outlineEl.getAttribute("data-origin"))
    const {dx, dy} = delta(sdx, sdy, this.axes)
    const edge = handle.getAttribute("data-handle")
    outlineEl.setAttribute("points", outline(resize(plan, edge, dx, dy), origin, this.axes))
    handle.setAttribute("transform", `translate(${sdx.toFixed(2)} ${sdy.toFixed(2)})`)
  },

  pinch(drag) {
    const [p, q] = [...this.pointers.values()]
    const span = Math.hypot(p.x - q.x, p.y - q.y)
    const mid = this.point((p.x + q.x) / 2, (p.y + q.y) / 2)
    this.show(zoom(this.view, span / drag.span, mid.x, mid.y, this.fit()))
    drag.span = span
  },

  up(e) {
    if (!this.pointers.delete(e.pointerId)) return
    const drag = this.drag
    // A pinch ends when fewer than two fingers stay.
    if (drag && drag.kind === "pinch" && this.pointers.size >= 2) return
    this.drag = null
    if (!drag || drag.kind === "pinch") return
    if (!drag.moved) return drag.halted ? undefined : this.tap(drag)
    if (drag.scroll && e.timeStamp - drag.t <= STILL) return this.glide(drag.v)
    if (drag.kind === "item") this.dropItem(drag, e)
    else if (drag.kind === "room") this.send("move_room", {id: drag.el.getAttribute("data-room"), ...this.inches(drag)}, drag)
    else if (drag.kind === "handle")
      this.send(
        "size_room",
        {
          id: drag.el.getAttribute("data-room-id"),
          edge: drag.el.getAttribute("data-handle"),
          ...this.inches(drag),
        },
        drag,
      )
  },

  cancel(e) {
    this.pointers.delete(e.pointerId)
    this.reset()
  },

  // The page keeps the speed of the finger, and slows down, as a page that
  // the browser scrolls. Each frame scrolls the page by the exact distance
  // of the time since the frame before it. So the glide is the same at
  // each rate of frames. A touch, the wheel or a key on the page stops it,
  // and also a page that goes out of view.
  glide(v) {
    if (Math.abs(v) < STOP) return
    const win = this.window()
    const token = {}
    this.gliding = token
    this.onHalt = (e) => {
      // The same event comes to the plan after the window: so the plan
      // knows that this press stopped the glide.
      if (e.type === "pointerdown") this.halted = e
      this.stopGlide()
    }
    for (const type of HALT) win.addEventListener(type, this.onHalt, {capture: true, passive: true})
    this.el.ownerDocument.addEventListener("visibilitychange", this.onHalt)
    const k = Math.log(FRICTION) / 16
    let last = null
    const frame = (t) => {
      if (this.gliding !== token) return
      if (last !== null) {
        const dt = Math.min(t - last, FRAME)
        const left = Math.exp(k * dt)
        win.scrollBy(0, (v * (left - 1)) / k)
        v *= left
      }
      last = t
      if (Math.abs(v) < STOP) this.stopGlide()
      else win.requestAnimationFrame(frame)
    }
    win.requestAnimationFrame(frame)
  },

  stopGlide() {
    if (!this.gliding) return
    this.gliding = null
    const win = this.window()
    for (const type of HALT) win.removeEventListener(type, this.onHalt, {capture: true})
    this.el.ownerDocument.removeEventListener("visibilitychange", this.onHalt)
  },

  // A drag that stops: the moved elements go back. The server draws them
  // at their new place.
  reset() {
    const drag = this.drag
    this.drag = null
    if (!drag || drag.kind === "pinch" || drag.kind === "pan") return
    this.restore(drag)
  },

  restore(drag) {
    const els = drag.kind === "handle" ? [drag.el] : this.moving(drag)
    for (const el of els) {
      el.removeAttribute("transform")
      el.classList.remove("p-dragging")
    }
    if (drag.kind === "handle") {
      const outlineEl = this.svg.querySelector("[data-outline]")
      const plan = numbers(outlineEl.getAttribute("data-plan"))
      const origin = numbers(outlineEl.getAttribute("data-origin"))
      outlineEl.setAttribute("points", outline(plan, origin, this.axes))
    }
  },

  inches(drag) {
    const {dx, dy} = delta(drag.sdx, drag.sdy, this.axes)
    return {dx: Math.round(dx) + 0, dy: Math.round(dy) + 0}
  },

  // A tap: an item opens; a room is chosen, and the view zooms in to it;
  // the empty place clears the choice.
  tap(drag) {
    if (drag.kind === "handle") return
    if (drag.kind === "item") return this.pushEvent("open_item", {id: drag.el.getAttribute("data-item")})
    const id = drag.room ? drag.room.getAttribute("data-room") : ""
    if (drag.room) this.zoomTo(drag.room)
    this.pushEvent("select_room", {id})
  },

  // The view zooms in to a room: all the surfaces of its floor (a roof has
  // three), its items, its walls and its slab. The other layers hide.
  zoomTo(room) {
    const layer = layerOf(room)
    const dimmed = this.dimmed()
    if (this.oneLayer()) this.dim(layer)
    else if (dimmed && dimmed !== layer) this.dim(null)
    const id = room.getAttribute("data-room")
    const parts = this.svg.querySelectorAll(`[data-room="${id}"], [data-in="${id}"], [data-of="${id}"]`)
    const boxes = [...parts].map((el) => el.getBBox())
    const x = Math.min(...boxes.map((b) => b.x))
    const y = Math.min(...boxes.map((b) => b.y))
    const w = Math.max(...boxes.map((b) => b.x + b.width)) - x
    const h = Math.max(...boxes.map((b) => b.y + b.height)) - y
    this.show(focus(this.view, {x, y, w, h}, this.shape(), this.fit()))
  },

  // One layer stands out (the tab of a layer): the other layers hide (the
  // house) or are pale (the van). The SVG keeps the attribute when the
  // server draws it again. The tab of the layer is pressed.
  dim(id) {
    if (id) this.svg.setAttribute("data-dim", id)
    else this.svg.removeAttribute("data-dim")
    this.store(":layer", id || null)
    for (const tab of this.el.querySelectorAll("[data-focus]"))
      tab.setAttribute("aria-pressed", String(tab.getAttribute("data-focus") === id))
  },

  // The view fills the screen with a layer, and the other layers hide.
  showLayer(id) {
    this.dim(id)
    this.show(this.layerView(id))
  },

  // The view that fills the screen with a layer, or null with no layer.
  // The house fills the screen (its slabs and its walls): the yards can go
  // past the edge.
  layerView(id) {
    const layer = this.svg.querySelector(`#plan-${id}`)
    if (!layer) return null
    const shell = [...layer.querySelectorAll("[data-of]")].map((el) => el.getBBox())
    if (shell.length === 0) {
      const [x, y, w, h] = numbers(layer.getAttribute("data-box"))
      return frame({x, y, w, h}, this.shape(), 1.05)
    }
    const x = Math.min(...shell.map((b) => b.x))
    const y = Math.min(...shell.map((b) => b.y))
    const w = Math.max(...shell.map((b) => b.x + b.width)) - x
    const h = Math.max(...shell.map((b) => b.y + b.height)) - y
    return frame({x, y, w, h}, this.shape(), 1.08)
  },

  // The layer that stands out, or null.
  dimmed() {
    return this.svg.getAttribute("data-dim")
  },

  // An item that the person drops: the center of its space on the floor
  // moves with the pointer. It goes to the room whose surface has that
  // center. The script tries its own room first. Then it tries the rooms of
  // the layer under the pointer, and then the rooms of its own layer. The
  // pointer is on the body of the item, above its space: so the pointer
  // does not choose the room. With no such room, the item goes to the room
  // under the pointer (else to its own room).
  dropItem(drag, e) {
    const own = this.surface(drag.el.getAttribute("data-in"))
    const [cx, cy] = numbers(drag.el.getAttribute("data-at"))
    const start = forward({x: cx, y: cy}, surfaceOf(own), this.axes)
    const point = {x: start.x + drag.sdx, y: start.y + drag.sdy}
    const under = this.roomAt(e.clientX, e.clientY)
    const layers = [under && under.closest("[data-box]"), own.closest("[data-box]")]
    const rooms = layers.filter(Boolean).flatMap((layer) => [...layer.querySelectorAll("[data-room]")])
    const target = [own, ...rooms].find((el) => onSurface(point, surfaceOf(el), this.axes)) || under || own
    const center = inverse(point, surfaceOf(target), this.axes)
    this.send(
      "place_item",
      {
        id: drag.el.getAttribute("data-item"),
        room: target.getAttribute("data-room"),
        x: Math.round(center.x),
        y: Math.round(center.y),
      },
      drag,
    )
  },

  // Sends a change. When the server replies, the moved elements go back:
  // the new picture of the server is then on the page.
  send(event, payload, drag) {
    this.pushEvent(event, payload, () => this.restore(drag))
  },

  // The mouse wheel scrolls the page. Ctrl (or Command) and the wheel zoom.
  // A pinch on a touchpad also comes as a wheel with Ctrl.
  wheel(e) {
    if (!e.ctrlKey && !e.metaKey) return this.hint()
    e.preventDefault()
    const p = this.point(e.clientX, e.clientY)
    this.show(zoom(this.view, Math.exp(-e.deltaY * 0.0015), p.x, p.y, this.fit()))
  },

  // After the wheel with no Ctrl, a note on the picture tells how to zoom,
  // for 1.5 seconds.
  hint() {
    const hint = this.el.querySelector("[data-hint]")
    if (!hint) return
    hint.classList.remove("opacity-0")
    this.window().clearTimeout(this.hintTimer)
    this.hintTimer = this.window().setTimeout(() => hint.classList.add("opacity-0"), 1500)
  },

  // The buttons: zoom in, zoom out, all the house, and one layer. The tab
  // of a layer fills the screen with the layer, and the other layers hide.
  click(e) {
    const button = e.target.closest("[data-zoom], [data-focus]")
    if (!button) return
    const zoomTo = button.getAttribute("data-zoom")
    const v = this.view
    if (zoomTo === "fit") {
      this.dim(null)
      return this.show(this.fit())
    }
    if (zoomTo) {
      const factor = zoomTo === "in" ? 1.5 : 1 / 1.5
      return this.show(zoom(v, factor, v.x + v.w / 2, v.y + v.h / 2, this.fit()))
    }
    this.showLayer(button.getAttribute("data-focus"))
    // A chosen room on a layer that hides is not chosen now.
    const outline = this.svg.querySelector("[data-outline]")
    const room = outline && this.surface(outline.getAttribute("data-outline"))
    if (room && this.hidden(room)) this.pushEvent("select_room", {id: ""})
  },

  // The arrow keys on an item or a room of the list.
  key(e) {
    const el = e.target.closest ? e.target.closest("[data-nudge], [data-nudge-room]") : null
    const move = arrow(e.key, e.shiftKey, this.arrows)
    if (!el || !move) return
    e.preventDefault()
    const item = el.getAttribute("data-nudge")
    const room = el.getAttribute("data-nudge-room")
    if (item) this.pushEvent("nudge_item", {id: item, ...move})
    else this.pushEvent("nudge_room", {id: room, ...move})
    // The item or the room that moves shows: its layer comes.
    const target = item ? this.svg.querySelector(`[data-item="${item}"]`) : this.surface(room)
    if (target && this.hidden(target)) this.showLayer(layerOf(target))
  },
}
