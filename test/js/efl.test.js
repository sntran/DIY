// The tests of assets/js/efl.js. The test EFLs and their lines are in
// test/fixtures/efl (scripts/efl_lines.mjs).
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync, readdirSync} from "node:fs"
import fc from "fast-check"
import {clean, group, readLines, loadPdf, eflHook, MAX_LINES, MAX_PAGES} from "../../assets/js/efl.js"

const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs")
const dir = new URL("../fixtures/efl/", import.meta.url)
const item = (str, x, y, width = 10) => ({str, transform: [1, 0, 0, 1, x, y], width})

test("the items of a page make its lines, from the top to the bottom", () => {
  const lines = group(
    [
      item("Energy Charge", 50, 600, 60),
      item("7.5¢", 300, 601),
      item("", 10, 500),
      item("  ", 10, 500),
      item("Base", 50, 700, 20),
      item("Charge", 72, 699),
      item("$5", 81, 699),
      item("tail", 40, 400),
      {str: "no width", transform: [1, 0, 0, 1, 90, 400]},
    ],
    2,
  )
  assert.deepEqual(lines, [
    {page: 2, text: "Base Charge$5"},
    {page: 2, text: "Energy Charge  7.5¢"},
    {page: 2, text: "tail  no width"},
  ])
})

test("clean drops control characters and the Private Use Area", () => {
  assert.equal(clean("nerg Charge\u0000­"), "nerg Charge")
})

// Random items at random places: the lines keep each letter of the items,
// and have no empty line.
test("the lines of a page keep each letter of its items", () => {
  const text = fc.oneof(fc.string({maxLength: 12}), fc.constantFrom("\u0000", "\ue000x", "  ", "13.7000\u00a2", "\t$9.95 "))
  const anyItem = fc.record({
    str: text,
    x: fc.integer({min: 0, max: 600}),
    y: fc.integer({min: 0, max: 800}),
    width: fc.integer({min: 0, max: 100}),
  })
  const letters = (s) => s.replace(/\s/g, "")
  fc.assert(fc.property(fc.array(anyItem, {maxLength: 40}), fc.integer({min: 1, max: 3}), (items, page) => {
    const lines = group(items.map((i) => item(i.str, i.x, i.y, i.width)), page)
    assert.equal(lines.map((l) => letters(l.text)).join("").length, items.map((i) => letters(clean(i.str))).join("").length)
    for (const line of lines) {
      assert.equal(line.page, page)
      assert.ok(line.text.length > 0 && line.text === line.text.trim())
    }
  }))
})

test("the reader gives the lines of each test EFL", async () => {
  const files = readdirSync(dir).filter((f) => f.endsWith(".pdf"))
  assert.equal(files.length, 12)
  for (const file of files) {
    const lines = await readLines(pdfjs, new Uint8Array(readFileSync(new URL(file, dir))))
    const expected = JSON.parse(readFileSync(new URL(file.replace(".pdf", ".json"), dir)))
    assert.deepEqual(lines, expected, file)
  }
  assert.equal(MAX_PAGES, 3)
})

test("the reader reads at most 3 pages", async () => {
  const pages = []
  const doc = {numPages: 5, getPage: (n) => (pages.push(n), {getTextContent: async () => ({items: [item(`page ${n}`, 0, 0)]})})}
  let destroyed = false
  const fake = {getDocument: () => ({promise: Promise.resolve(doc), destroy: async () => (destroyed = true)})}
  const lines = await readLines(fake, new Uint8Array())
  assert.deepEqual(pages, [1, 2, 3])
  assert.equal(lines.length, 3)
  assert.ok(destroyed)
})

// A document with a head that runs the scripts that it gets.
function fakeDocument(behavior) {
  const win = {}
  const scripts = []
  const doc = {
    defaultView: win,
    createElement: () => ({}),
    head: {
      appendChild(script) {
        scripts.push(script.src)
        queueMicrotask(() => {
          if (behavior === "fail") return script.onerror()
          win.DIYPdf = {name: "pdf.js"}
          script.onload()
        })
      },
    },
    querySelectorAll: () => [],
  }
  return {doc, win, scripts}
}

test("pdf.js loads one time, and again after a failure", async () => {
  const failing = fakeDocument("fail")
  await assert.rejects(loadPdf(failing.doc, "/pdf.js"))
  const {doc, scripts} = fakeDocument("ok")
  const [a, b] = await Promise.all([loadPdf(doc, "/pdf.js"), loadPdf(doc, "/pdf.js")])
  assert.equal(a.name, "pdf.js")
  assert.equal(a, b)
  assert.deepEqual(scripts, ["/pdf.js"])
  // The page has pdf.js now.
  assert.equal(await loadPdf(doc, "/pdf.js"), a)
})

function hook(file, behavior = "ok") {
  const {doc, win} = fakeDocument(behavior)
  win.DIYPdf = behavior === "ok" ? pdfjs : undefined
  const links = [{dataset: {eflPage: "2"}}]
  doc.querySelectorAll = (selector) => (assert.equal(selector, "a[data-efl-page]"), links)
  const events = []
  let listener = null
  const el = {
    ownerDocument: doc,
    dataset: {pdf: "/assets/js/pdf.js"},
    files: file ? [file] : [],
    value: "efl.pdf",
    addEventListener: (type, fun) => (assert.equal(type, "change"), (listener = fun)),
  }
  const h = Object.assign({el, pushEvent: (name, payload) => events.push([name, payload])}, eflHook)
  h.mounted()
  return {h, el, events, links, change: () => listener()}
}

test("the hook reads the file in the browser, and links the numbers to the PDF", async () => {
  const urls = []
  const revoked = []
  globalThis.URL.createObjectURL = () => (urls.push(`blob:${urls.length}`), urls.at(-1))
  globalThis.URL.revokeObjectURL = (url) => revoked.push(url)

  const data = readFileSync(new URL("txu-smart-1000-select-12.pdf", dir))
  const file = {name: "efl.pdf", arrayBuffer: async () => data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)}
  const {h, el, events, links} = hook(file)

  h.updated()
  assert.equal(links[0].href, undefined)
  await h.read()
  assert.equal(events[0][0], "efl")
  assert.equal(events[0][1].name, "efl.pdf")
  assert.equal(events[0][1].lines[0].text, "Electricity Facts Label (EFL)")
  assert.ok(events[0][1].lines.length <= MAX_LINES)
  assert.equal(el.value, "")
  h.updated()
  assert.equal(links[0].href, "blob:0#page=2")

  // A second file: the first URL goes away.
  await h.read()
  assert.deepEqual(revoked, ["blob:0"])
  h.destroyed()
  assert.deepEqual(revoked, ["blob:0", "blob:1"])
})

test("the hook sends an error for a file that is not a PDF, and nothing with no file", async () => {
  const file = {name: "x.pdf", arrayBuffer: async () => new TextEncoder().encode("not a PDF").buffer}
  const {h, events, change} = hook(file)
  await change()
  assert.deepEqual(events, [["efl_error", {}]])

  const none = hook(null)
  await none.h.read()
  assert.deepEqual(none.events, [])
  none.h.destroyed()
})
