// The hook Plan of the plan of the house at scale (DIYWeb.Cutaway). The
// person moves the items and the rooms with a pointer (a finger or a
// mouse). Two fingers, the wheel or the buttons zoom. A drag on an empty
// place moves the picture. A tap on an item opens it, and a tap on a room
// chooses it: the room then has handles on its walls. In the list of the
// rooms (for a keyboard and a screen reader), the arrow keys move an item
// or a room.
//
// The server draws the SVG. This script only moves parts of it while the
// pointer moves, and then sends the change: the server then draws it again.
//
// The math. A point of the plan is x, y in inches, on the surface of a
// room. It goes to the SVG with the units of one inch (data-k: kx, ky, kz).
// It also uses the origin of the surface (data-origin: the SVG point of
// 0, 0):
//   sx = ox + kx (x - y)
//   sy = oy + ky (x + y) - kz z
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
export function forward(point, surface, k) {
  const [kx, ky, kz] = k
  const [ox, oy] = surface.origin
  const z = heightAt(surface, point.y)
  return {x: ox + kx * (point.x - point.y), y: oy + ky * (point.x + point.y) - kz * z}
}

// The point of the plan on a surface under an SVG point.
export function inverse(svg, surface, k) {
  const [kx, ky, kz] = k
  const [ox, oy] = surface.origin
  const a = (svg.x - ox) / kx
  const b = (svg.y - oy) / ky
  if (!surface.rise) return {x: (a + b) / 2, y: (b - a) / 2}

  // On a roof: the front slope (from the ridge to the front), else the
  // back slope. q is the part of z in the SVG y.
  const [, py, , d] = surface.plan
  const ridge = py + d / 2
  const m = surface.rise / (d / 2)
  const q = kz / ky
  const front = (b + q * (surface.rise + m * ridge) - a) / (2 + q * m)
  const y = front >= ridge ? front : (b + q * (surface.rise - m * ridge) - a) / (2 - q * m)
  return {x: a + y, y}
}

// True when the point of the plan under an SVG point is on a surface.
export function onSurface(svg, surface, k) {
  const p = inverse(svg, surface, k)
  const [x, y, w, d] = surface.plan
  return p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + d
}

// The SVG units of one pixel of the screen. The view fills the SVG on the
// side that limits it, and keeps its shape.
export function unitsOf(view, width, height) {
  return Math.max(view.w / (width || 1), view.h / (height || 1))
}

// A move on the SVG as a move on a flat plan, in inches.
export function delta(dsx, dsy, k) {
  const [kx, ky] = k
  const a = dsx / kx
  const b = dsy / ky
  return {dx: (a + b) / 2, dy: (b - a) / 2}
}

// The plan of a room after a move of one of its walls. x0 and y0 are the
// walls at the back, and x1 and y1 are the walls at the front.
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
export function outline(plan, origin, k) {
  const [x, y, w, d] = plan
  const surface = {origin, plan, rise: 0}
  return [
    [x, y],
    [x + w, y],
    [x + w, y + d],
    [x, y + d],
  ]
    .map(([px, py]) => forward({x: px, y: py}, surface, k))
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

// The move of an arrow key, in inches: 6, or 24 with Shift. Right and left
// go along x, down and up along y.
export function arrow(key, shift) {
  const step = shift ? 24 : 6
  const moves = {
    ArrowRight: [step, 0],
    ArrowLeft: [-step, 0],
    ArrowDown: [0, step],
    ArrowUp: [0, -step],
  }
  return moves[key] ? {dx: moves[key][0], dy: moves[key][1]} : null
}

// The view as the text of a viewBox.
const box = (view) => [view.x, view.y, view.w, view.h].map((n) => n.toFixed(2)).join(" ")
const parseView = (text) => {
  const [x, y, w, h] = numbers(text)
  return {x, y, w, h}
}

// A move of the pointer of more than this (in pixels) is a drag, not a tap.
const SLOP = 5
// The view stays for each plan (the house, and each van) in the tab.
const KEY = "plan-view:"

export const planHook = {
  mounted() {
    this.svg = this.el.querySelector("svg")
    this.k = numbers(this.svg.getAttribute("data-k"))
    this.pointers = new Map()
    this.drag = null
    const saved = this.saved()
    this.show(saved || this.fit())

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
    for (const [type, fun] of Object.entries(this.listeners)) this.svg.removeEventListener(type, fun)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKey)
  },

  // The box of all the layers. The server changes it when a room moves or
  // comes: so the script reads it each time.
  fit() {
    return parseView(this.svg.getAttribute("data-fit"))
  },

  units(view) {
    return unitsOf(view, this.svg.clientWidth, this.svg.clientHeight)
  },

  // The view that the person had on this page before (a zoom), if any.
  saved() {
    try {
      const text = this.el.ownerDocument.defaultView.sessionStorage.getItem(KEY + this.el.id)
      return text ? parseView(text) : null
    } catch (_error) {
      return null
    }
  },

  // Shows a view: the viewBox, and the size of the labels and the handles
  // on the screen (the same at each zoom).
  show(view) {
    this.view = view
    this.svg.setAttribute("viewBox", box(view))
    const units = this.units(view)
    this.svg.style.setProperty("--p-label", `${(12 * units).toFixed(3)}px`)
    // A handle is 24 pixels wide: the smallest target of WCAG 2.2 (2.5.8).
    this.svg.style.setProperty("--p-handle", `${(12 * units).toFixed(3)}px`)
    try {
      this.el.ownerDocument.defaultView.sessionStorage.setItem(KEY + this.el.id, box(view))
    } catch (_error) {
      // A page with no storage keeps the view only while it is open.
    }
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

  down(e) {
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
    const room = target.closest("[data-room]")
    const chosen = this.svg.querySelector("[data-outline]")
    let kind = "pan"
    let el = null
    if (handle) [kind, el] = ["handle", handle]
    else if (item) [kind, el] = ["item", item]
    else if (room && chosen && room.getAttribute("data-room") === chosen.getAttribute("data-outline"))
      [kind, el] = ["room", room]
    this.drag = {kind, el, room, x: e.clientX, y: e.clientY, view: this.view, moved: false}
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

    if (drag.kind === "pan") {
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
    const {dx, dy} = delta(sdx, sdy, this.k)
    const edge = handle.getAttribute("data-handle")
    outlineEl.setAttribute("points", outline(resize(plan, edge, dx, dy), origin, this.k))
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
    if (!drag.moved) return this.tap(drag)
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
      outlineEl.setAttribute("points", outline(plan, origin, this.k))
    }
  },

  inches(drag) {
    const {dx, dy} = delta(drag.sdx, drag.sdy, this.k)
    return {dx: Math.round(dx), dy: Math.round(dy)}
  },

  // A tap: an item opens; a room is chosen; the empty place clears the
  // choice.
  tap(drag) {
    if (drag.kind === "handle") return
    if (drag.kind === "item") return this.pushEvent("open_item", {id: drag.el.getAttribute("data-item")})
    const id = drag.room ? drag.room.getAttribute("data-room") : ""
    this.pushEvent("select_room", {id})
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
    const start = forward({x: cx, y: cy}, surfaceOf(own), this.k)
    const point = {x: start.x + drag.sdx, y: start.y + drag.sdy}
    const under = this.roomAt(e.clientX, e.clientY)
    const layers = [under && under.closest("[data-box]"), own.closest("[data-box]")]
    const rooms = layers.filter(Boolean).flatMap((layer) => [...layer.querySelectorAll("[data-room]")])
    const target = [own, ...rooms].find((el) => onSurface(point, surfaceOf(el), this.k)) || under || own
    const center = inverse(point, surfaceOf(target), this.k)
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

  wheel(e) {
    e.preventDefault()
    const p = this.point(e.clientX, e.clientY)
    this.show(zoom(this.view, Math.exp(-e.deltaY * 0.0015), p.x, p.y, this.fit()))
  },

  // The buttons: zoom in, zoom out, all the house, and one layer.
  click(e) {
    const button = e.target.closest("[data-zoom], [data-focus]")
    if (!button) return
    const zoomTo = button.getAttribute("data-zoom")
    const v = this.view
    if (zoomTo === "fit") return this.show(this.fit())
    if (zoomTo) {
      const factor = zoomTo === "in" ? 1.5 : 1 / 1.5
      return this.show(zoom(v, factor, v.x + v.w / 2, v.y + v.h / 2, this.fit()))
    }
    const layer = this.svg.querySelector(`#plan-${button.getAttribute("data-focus")}`)
    const [x, y, w, h] = numbers(layer.getAttribute("data-box"))
    this.show({x: x - w * 0.05, y: y - h * 0.05, w: w * 1.1, h: h * 1.1})
  },

  // The arrow keys on an item or a room of the list.
  key(e) {
    const el = e.target.closest ? e.target.closest("[data-nudge], [data-nudge-room]") : null
    const move = arrow(e.key, e.shiftKey)
    if (!el || !move) return
    e.preventDefault()
    const item = el.getAttribute("data-nudge")
    if (item) this.pushEvent("nudge_item", {id: item, ...move})
    else this.pushEvent("nudge_room", {id: el.getAttribute("data-nudge-room"), ...move})
  },
}
