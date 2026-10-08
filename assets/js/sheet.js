// The hook Sheet of a sheet over the page (a modal dialog). The Escape key
// closes the sheet, and the Tab key keeps the focus in the sheet. When the
// sheet closes, the focus goes back to the element that had it before, if
// that element is still on the page.

// The elements that can have the focus.
export const FOCUSABLE =
  "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), summary, [tabindex]"

export const sheetHook = {
  mounted() {
    const doc = this.el.ownerDocument
    this.previous = doc.activeElement
    this.onKey = (event) => this.key(event)
    doc.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    this.el.ownerDocument.removeEventListener("keydown", this.onKey)
    if (this.previous && this.previous.isConnected) this.previous.focus()
  },

  key(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.el.querySelector("[data-close]").click()
    } else if (event.key === "Tab") {
      this.trap(event)
    }
  },

  // The first and the last element that can have the focus: Tab after the
  // last goes to the first, and Shift+Tab before the first to the last.
  trap(event) {
    const list = [...this.el.querySelectorAll(FOCUSABLE)].filter(
      (el) => el.tabIndex >= 0 && el.getClientRects().length > 0,
    )
    if (list.length === 0) return
    const first = list[0]
    const last = list[list.length - 1]
    const active = this.el.ownerDocument.activeElement
    const outside = !this.el.contains(active)
    if (event.shiftKey && (active === first || outside)) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && (active === last || outside)) {
      event.preventDefault()
      first.focus()
    }
  },
}
