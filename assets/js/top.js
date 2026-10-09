// The hook Top: a new page starts at its top. All the pages are one
// LiveView, and a patch keeps the scroll of the page before it. The
// element has data-page (the page and its step). When it changes, the
// window goes to the top.
export const topHook = {
  mounted() {
    this.page = this.el.getAttribute("data-page")
  },

  updated() {
    const page = this.el.getAttribute("data-page")
    if (page !== this.page) this.el.ownerDocument.defaultView.scrollTo(0, 0)
    this.page = page
  },
}
