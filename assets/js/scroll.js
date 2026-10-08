// The hook ScrollStart of the rooms (#levels). At the mount, the rooms show
// the level of the front door (the first floor), not the roof: the element
// names that level in data-start. The swipes are CSS scroll snap, with no
// script.
//
// Caution: an element that a patch moves loses the place of its scroll.
// So no element before #levels in its parent comes and goes.
export const scrollHook = {
  mounted() {
    const start = this.el.querySelector(`#${this.el.dataset.start}`)
    if (start) {
      const top = start.getBoundingClientRect().top - this.el.getBoundingClientRect().top
      this.el.scrollTop += top
    }
  },
}
