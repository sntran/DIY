// Writes the lines of each test EFL (test/fixtures/efl/NAME.pdf) to
// NAME.json, with the reader of the page (assets/js/efl.js). The tests of
// DIY.EFL read these lines, and test/js/efl.test.js checks that the reader
// gives the same lines. Run it after a change of the reader:
//
//   node scripts/efl_lines.mjs
import {readFileSync, readdirSync, writeFileSync} from "node:fs"
import {readLines} from "../assets/js/efl.js"

const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs")
const dir = new URL("../test/fixtures/efl/", import.meta.url)

for (const file of readdirSync(dir).filter((f) => f.endsWith(".pdf")).sort()) {
  const data = new Uint8Array(readFileSync(new URL(file, dir)))
  const lines = await readLines(pdfjs, data)
  writeFileSync(new URL(file.replace(/\.pdf$/, ".json"), dir), JSON.stringify(lines, null, 1) + "\n")
  console.log(`${file}: ${lines.length} lines`)
}
