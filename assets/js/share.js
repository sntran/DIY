// The hook Share: the button that shares the link of a house
// (docs/design.md, "The share"). The element has these attributes:
// - data-path: the link;
// - data-title: the title of the link;
// - data-copied: the text when the link is in the clipboard;
// - data-failed: the text when no share works;
// - data-status: the id of the element of the status.
//
// On a phone, navigator.share opens the share sheet of the phone. Else the
// link goes into the clipboard. A person who closes the share sheet gets
// no message.
export const shareHook = {
  mounted() {
    this.el.addEventListener("click", () => share(this.el))
  },
}

export async function share(el) {
  const doc = el.ownerDocument
  const win = doc.defaultView
  const url = new URL(el.getAttribute("data-path"), win.location.origin).href
  const status = doc.getElementById(el.getAttribute("data-status"))
  const nav = win.navigator

  if (typeof nav.share === "function") {
    try {
      await nav.share({title: el.getAttribute("data-title"), url})
      return "shared"
    } catch (error) {
      if (error && error.name === "AbortError") return "closed"
    }
  }

  try {
    await nav.clipboard.writeText(url)
    status.textContent = el.getAttribute("data-copied")
    return "copied"
  } catch {
    status.textContent = el.getAttribute("data-failed")
    return "failed"
  }
}
