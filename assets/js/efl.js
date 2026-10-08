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
    // An item with no letters (only spaces, or only characters that clean
    // takes away) makes no line.
    const str = clean(item.str || "")
    if (!str.trim()) continue
    const x = item.transform[4]
    const y = item.transform[5]
    let row = rows.find((r) => Math.abs(r.y - y) <= ROW)
    if (!row) {
      row = {y, parts: []}
      rows.push(row)
    }
    row.parts.push({x, end: x + (item.width || 0), str})
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

// The lines of the pages of a PDF (its bytes), with pdf.js. The task of
// pdf.js ends also after an error.
export async function readLines(pdfjs, data) {
  const task = pdfjs.getDocument({data, isEvalSupported: false, disableFontFace: true, verbosity: 0})
  try {
    const doc = await task.promise
    const lines = []
    for (let page = 1; page <= Math.min(doc.numPages, MAX_PAGES); page++) {
      const content = await (await doc.getPage(page)).getTextContent()
      lines.push(...group(content.items, page))
    }
    return lines
  } finally {
    await task.destroy()
  }
}

// Loads the file of pdf.js (assets/js/pdf.js) one time, when the person
// opens the first EFL: the other pages do not need it.
let loaded = null

export function loadPdf(doc, src) {
  const win = doc.defaultView
  if (win.DIYPdf) return Promise.resolve(win.DIYPdf)
  if (!loaded) {
    loaded = new Promise((resolve, reject) => {
      const script = doc.createElement("script")
      script.src = src
      const fail = () => {
        loaded = null
        reject(new Error("pdf.js"))
      }
      script.onload = () => (win.DIYPdf ? resolve(win.DIYPdf) : fail())
      script.onerror = fail
      doc.head.appendChild(script)
    })
  }
  return loaded
}

// The most lines that the hook sends (an EFL has near 60), the most bytes
// of their text (an EFL has near 6,000; DIY.EFL reads 64 KB at most), and
// the largest file that it reads.
export const MAX_LINES = 2000
export const MAX_BYTES = 65536
export const MAX_FILE = 20 * 1024 * 1024

// The lines of an EFL, in the limits: or null for a file that is not an
// EFL (a bill, for example). The text of a file that is not an EFL does not
// go to the server.
export function eflLines(lines) {
  if (!lines.some((line) => /average\s+price/i.test(line.text))) return null
  const kept = []
  let bytes = 0
  for (const line of lines.slice(0, MAX_LINES)) {
    bytes += new TextEncoder().encode(line.text).length
    if (bytes > MAX_BYTES) break
    kept.push(line)
  }
  return kept
}

// The URL of the PDF that the person opened last: the links of the
// numbers open it at their page.
let pdfUrl = null

// Sets the links of the numbers (a[data-efl-page]) in an element.
export function setLinks(root) {
  if (!pdfUrl) return
  for (const link of root.querySelectorAll("a[data-efl-page]")) {
    link.href = `${pdfUrl}#page=${link.dataset.eflPage}`
  }
}

// The LiveView hook of the input of an EFL file. It reads the PDF in the
// browser, and sends the lines of an EFL. The URL of the PDF has the type
// of a PDF, whatever the name of the file: a file "efl.html" does not open
// as a page of the app.
export const eflHook = {
  mounted() {
    this.el.addEventListener("change", () => this.read())
  },

  read() {
    const file = this.el.files && this.el.files[0]
    if (!file) return Promise.resolve()
    if (file.size > MAX_FILE) {
      this.pushEvent("efl_error", {})
      this.el.value = ""
      return Promise.resolve()
    }
    const doc = this.el.ownerDocument
    return Promise.all([loadPdf(doc, this.el.dataset.pdf), file.arrayBuffer()])
      .then(([pdfjs, buffer]) =>
        readLines(pdfjs, new Uint8Array(buffer.slice(0))).then((lines) => [lines, buffer]),
      )
      .then(
        ([lines, buffer]) => {
          const kept = eflLines(lines)
          if (!kept) return this.pushEvent("efl_error", {})
          if (pdfUrl) URL.revokeObjectURL(pdfUrl)
          pdfUrl = URL.createObjectURL(new Blob([buffer], {type: "application/pdf"}))
          // The same result from the server gets no update: the links of
          // the page get the new URL now.
          setLinks(this.el.ownerDocument)
          this.pushEvent("efl", {name: file.name, lines: kept})
        },
        () => this.pushEvent("efl_error", {}),
      )
      .finally(() => {
        this.el.value = ""
      })
  },
}

// The LiveView hook of the result of an EFL (#efl-result): it sets the
// links of the numbers each time the server changes the result.
export const eflLinksHook = {
  mounted() {
    setLinks(this.el)
  },

  updated() {
    setLinks(this.el)
  },
}
