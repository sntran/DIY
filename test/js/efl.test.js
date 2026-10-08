// The tests of assets/js/efl.js. The test EFLs and their lines are in
// test/fixtures/efl (scripts/efl_lines.mjs).
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync, readdirSync} from "node:fs"
import fc from "fast-check"
import {
  clean, group, readLines, loadPdf, eflLines, eflHook, eflLinksHook, MAX_LINES, MAX_PAGES, MAX_BYTES, MAX_FILE,
} from "../../assets/js/efl.js"

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
  assert.equal(files.length, 13)
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
          if (behavior === "ok") win.DIYPdf = {name: "pdf.js"}
          script.onload()
        })
      },
    },
    links: [],
    querySelectorAll(selector) {
      assert.equal(selector, "a[data-efl-page]")
      return this.links
    },
  }
  return {doc, win, scripts}
}

test("pdf.js loads one time, and again after a failure", async () => {
  const broken = fakeDocument("fail")
  await assert.rejects(loadPdf(broken.doc, "/pdf.js"))
  // A script that loads, but gives no pdf.js.
  const empty = fakeDocument("empty")
  await assert.rejects(loadPdf(empty.doc, "/pdf.js"))
  const {doc, scripts} = fakeDocument("ok")
  const [a, b] = await Promise.all([loadPdf(doc, "/pdf.js"), loadPdf(doc, "/pdf.js")])
  assert.equal(a.name, "pdf.js")
  assert.equal(a, b)
  assert.deepEqual(scripts, ["/pdf.js"])
  // The page has pdf.js now.
  assert.equal(await loadPdf(doc, "/pdf.js"), a)
})

test("the file of pdf.js gives pdf.js to the page, with its worker in the page", async () => {
  globalThis.window = {}
  await import("../../assets/js/pdf.js")
  assert.equal(typeof globalThis.window.DIYPdf.getDocument, "function")
  assert.ok(globalThis.pdfjsWorker)
  delete globalThis.window
})

test("the lines of an EFL: only a file with average prices, in the limits", () => {
  assert.equal(eflLines([{page: 1, text: "A bill: account 123"}]), null)
  const lines = [{page: 1, text: "Average Price per kWh 12.0¢ 11.0¢ 10.5¢"}]
  assert.deepEqual(eflLines(lines), lines)
  const many = Array.from({length: MAX_LINES + 5}, () => ({page: 1, text: "Average price"}))
  assert.equal(eflLines(many).length, MAX_LINES)
  const long = Array.from({length: 40}, () => ({page: 1, text: "average price " + "x".repeat(2000)}))
  const kept = eflLines(long)
  assert.ok(kept.reduce((sum, line) => sum + line.text.length, 0) <= MAX_BYTES)
  assert.equal(kept.length, 32)
})

test("the reader ends the task of pdf.js after an error", async () => {
  let destroyed = false
  const fake = {getDocument: () => ({promise: Promise.reject(new Error("bad")), destroy: async () => (destroyed = true)})}
  await assert.rejects(readLines(fake, new Uint8Array()))
  assert.ok(destroyed)
})

// A fake pdf.js that gives the lines of one page.
function fakePdf(texts) {
  const doc = {numPages: 1, getPage: async () => ({getTextContent: async () => ({items: texts.map((t, i) => item(t, 0, 700 - i * 20))})})}
  return {getDocument: () => ({promise: Promise.resolve(doc), destroy: async () => {}})}
}

function hook(file, pdf = pdfjs) {
  const {doc, win} = fakeDocument("ok")
  win.DIYPdf = pdf
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
  return {h, el, events, change: () => listener()}
}

// An element with links of the numbers, for the hook EflLinks.
function result() {
  const links = [{dataset: {eflPage: "2"}}]
  const el = {querySelectorAll: (selector) => (assert.equal(selector, "a[data-efl-page]"), links)}
  return {links, h: Object.assign({el}, eflLinksHook)}
}

const pdfFile = (name) => {
  const data = readFileSync(new URL(name, dir))
  return {name: "efl.html", size: data.byteLength, arrayBuffer: async () => data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)}
}

test("the hook reads the file in the browser, and the result links the numbers to the PDF", async () => {
  const urls = []
  const blobs = []
  const revoked = []
  globalThis.URL.createObjectURL = (blob) => (blobs.push(blob), urls.push(`blob:${urls.length}`), urls.at(-1))
  globalThis.URL.revokeObjectURL = (url) => revoked.push(url)

  // No PDF yet: the links stay with no href.
  const before = result()
  before.h.mounted()
  assert.equal(before.links[0].href, undefined)

  const {h, el, events} = hook(pdfFile("txu-smart-1000-select-12.pdf"))
  await h.read()
  assert.equal(events[0][0], "efl")
  assert.equal(events[0][1].name, "efl.html")
  assert.equal(events[0][1].lines[0].text, "Electricity Facts Label (EFL)")
  assert.equal(el.value, "")
  // The URL has the type of a PDF, also for a file with the name of a page.
  assert.equal(blobs[0].type, "application/pdf")

  // The result of the server: the hook sets the links, and again after a
  // change of the result.
  const after = result()
  after.h.mounted()
  assert.equal(after.links[0].href, "blob:0#page=2")
  after.links[0].href = undefined
  after.h.updated()
  assert.equal(after.links[0].href, "blob:0#page=2")

  // The same file again: the result of the server does not change, so the
  // hook sets the links of the page itself.
  h.el.ownerDocument.links = after.links
  await h.read()
  assert.deepEqual(revoked, ["blob:0"])
  assert.equal(after.links[0].href, "blob:1#page=2")
})

test("an encrypted EFL: the reader gives its lines", async () => {
  const {h, events} = hook(pdfFile("discount-saver-18.pdf"))
  await h.read()
  assert.equal(events[0][0], "efl")
  assert.ok(events[0][1].lines.some((line) => /average/i.test(line.text)))
})

test("the hook sends an error for a file that is not an EFL, too large, or not a PDF", async () => {
  // A PDF with no average prices (a bill): its text does not go to the server.
  const bill = {name: "bill.pdf", size: 10, arrayBuffer: async () => new ArrayBuffer(8)}
  const notEfl = hook(bill, fakePdf(["Your bill", "Account 123"]))
  await notEfl.h.read()
  assert.deepEqual(notEfl.events, [["efl_error", {}]])

  const large = hook({name: "big.pdf", size: MAX_FILE + 1, arrayBuffer: async () => assert.fail("read")})
  await large.h.read()
  assert.deepEqual(large.events, [["efl_error", {}]])
  assert.equal(large.el.value, "")

  const file = {name: "x.pdf", size: 9, arrayBuffer: async () => new TextEncoder().encode("not a PDF").buffer}
  const {events, change} = hook(file)
  await change()
  assert.deepEqual(events, [["efl_error", {}]])

  const none = hook(null)
  await none.h.read()
  assert.deepEqual(none.events, [])
})
