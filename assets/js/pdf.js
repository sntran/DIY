// pdf.js for the reader of an EFL (assets/js/efl.js), in its own file: the
// page loads it only when the person opens an EFL. pdf.js runs in the page
// (no worker), so that it needs no second file.
import * as pdfjs from "pdfjs-dist/build/pdf.mjs"
import * as worker from "pdfjs-dist/build/pdf.worker.mjs"

globalThis.pdfjsWorker = worker
window.DIYPdf = pdfjs
