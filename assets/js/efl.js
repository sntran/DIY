// Reads the text of an EFL (an Electricity Facts Label, a PDF) on the
// device, with pdf.js. The result is the lines of each page, from the top
// to the bottom: the server finds the numbers of the plan in them
// (DIY.EFL), and shows the line of each number.

// The pages that the reader reads: an EFL has one or two pages.
export const MAX_PAGES = 3

// Two parts of a line are on the same row when their bottoms are this
// close (in points).
const ROW = 3

// The lines of the items of the text of one page. An item is a part of the
// text with its place: transform[4] is x, transform[5] is y (from the
// bottom), and width.
export function group(items, page) {
  const rows = []
  for (const item of items) {
    if (!item.str || !item.str.trim()) continue
    const x = item.transform[4]
    const y = item.transform[5]
    let row = rows.find((r) => Math.abs(r.y - y) <= ROW)
    if (!row) {
      row = {y, parts: []}
      rows.push(row)
    }
    row.parts.push({x, end: x + (item.width || 0), str: clean(item.str)})
  }
  rows.sort((a, b) => b.y - a.y)
  return rows.map((row) => {
    row.parts.sort((a, b) => a.x - b.x)
    let text = ""
    let end = null
    for (const part of row.parts) {
      if (end !== null && part.x - end > 1) text += part.x - end > 12 ? "  " : " "
      text += part.str
      end = part.end
    }
    return {page, text: text.replace(/\s+/g, (s) => (s.length > 1 ? "  " : " ")).trim()}
  })
}

// The text with no control characters and no characters of the Private
// Use Area: a font with no Unicode map gives them for its letters.
export function clean(text) {
  return text.replace(/[\u0000-\u001f\u007f-\u009f\u00ad\u200b-\u200f\ufeff\ue000-\uf8ff]/g, "")
}

// The lines of the pages of a PDF (its bytes), with pdf.js.
export async function readLines(pdfjs, data) {
  const task = pdfjs.getDocument({data, isEvalSupported: false, disableFontFace: true})
  const doc = await task.promise
  const lines = []
  for (let page = 1; page <= Math.min(doc.numPages, MAX_PAGES); page++) {
    const content = await (await doc.getPage(page)).getTextContent()
    lines.push(...group(content.items, page))
  }
  await task.destroy()
  return lines
}

// Loads the file of pdf.js (assets/js/pdf.js) one time, when the person
// opens the first EFL: the other pages do not need it.
let loading = null

export function loadPdf(doc, src) {
  const win = doc.defaultView
  if (win.DIYPdf) return Promise.resolve(win.DIYPdf)
  if (!loading) {
    loading = new Promise((resolve, reject) => {
      const script = doc.createElement("script")
      script.src = src
      script.onload = () => resolve(win.DIYPdf)
      script.onerror = () => {
        loading = null
        reject(new Error("pdf.js"))
      }
      doc.head.appendChild(script)
    })
  }
  return loading
}

// The most lines that the hook sends: an EFL has near 60.
export const MAX_LINES = 2000

// The LiveView hook of the input of an EFL file. It reads the PDF in the
// browser, and sends its lines. The links of the numbers
// (a[data-efl-page]) open the PDF at their page.
export const eflHook = {
  mounted() {
    this.el.addEventListener("change", () => this.read())
  },

  updated() {
    this.links()
  },

  destroyed() {
    if (this.url) URL.revokeObjectURL(this.url)
  },

  read() {
    const file = this.el.files && this.el.files[0]
    if (!file) return Promise.resolve()
    const doc = this.el.ownerDocument
    return Promise.all([loadPdf(doc, this.el.dataset.pdf), file.arrayBuffer()])
      .then(([pdfjs, buffer]) => readLines(pdfjs, new Uint8Array(buffer)))
      .then(
        (lines) => {
          if (this.url) URL.revokeObjectURL(this.url)
          this.url = URL.createObjectURL(file)
          this.pushEvent("efl", {name: file.name, lines: lines.slice(0, MAX_LINES)})
        },
        () => this.pushEvent("efl_error", {}),
      )
      .finally(() => {
        this.el.value = ""
      })
  },

  links() {
    if (!this.url) return
    for (const link of this.el.ownerDocument.querySelectorAll("a[data-efl-page]")) {
      link.href = `${this.url}#page=${link.dataset.eflPage}`
    }
  },
}
