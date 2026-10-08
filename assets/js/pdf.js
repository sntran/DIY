// pdf.js for the reader of an EFL (assets/js/efl.js), in its own file: the
// page loads it only when the person opens an EFL. pdf.js runs in the page
// (no worker), so that it needs no second file. The legacy build has the
// functions that an older browser does not have (Chromium 141 has no
// Map.prototype.getOrInsertComputed): the modern build could not read
// some EFLs there. The tests and scripts/efl_lines.mjs use the same build.
import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs"
import * as worker from "pdfjs-dist/legacy/build/pdf.worker.mjs"

globalThis.pdfjsWorker = worker
window.DIYPdf = pdfjs
