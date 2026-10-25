// Writes priv/picture/styles.json: the style of each class of the
// picture of a house (the classes p-* and i-* of app.css). The picture
// of a shared house uses it (DIYWeb.Picture, docs/design.md, "The preview
// of a link"). resvg reads no CSS variables and no color-mix(). Thus
// Chromium gives the values. For each class, the file has the properties
// that are not the same as on a shape with no class. The page has the
// light theme. The file has the styles of each scene of the house
// (data-scene: day, sunset and night). For each scene, "SCENE-snow" has
// the classes that are different in snow (data-weather="snow"), with all
// their properties. "SCENE-inside" has the classes that are different in
// the house cut open (no class cutaway-outside), with all their
// properties. The picture does not move: the page has reduced motion, so
// the styles are those after the loops.
//
//   MIX_ENV=test mix.com assets.build
//   CHROMIUM=/path/to/chrome node scripts/picture-styles.mjs
//
// With --check, the script writes nothing. It fails when the file is not
// the same as the styles of app.css. The browser test runs it so.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { chromium } from "playwright-core"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const css = readFileSync(join(root, "priv/static/assets/css/app.css"), "utf8")
const out = join(root, "priv/picture/styles.json")

// The classes of the picture, in the order of app.css.
const classes = [...new Set(css.match(/\.[pi]-[a-z0-9-]+/g).map((c) => c.slice(1)))].sort()

// The properties that resvg reads, for each kind of element.
const shape = [
  "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity",
  "stroke-linejoin", "stroke-linecap", "stroke-dasharray", "stroke-dashoffset",
  "opacity", "display", "visibility", "paint-order", "vector-effect",
]
const stop = ["stop-color", "stop-opacity"]
const text = ["font-size", "font-weight", "text-anchor", "dominant-baseline", "letter-spacing"]

export async function styles() {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM })
  try {
    const page = await browser.newPage({ colorScheme: "light", reducedMotion: "reduce" })
    const result = {}
    for (const scene of ["day", "sunset", "night"]) {
      const base = await read(page, scene, "sun", true)
      result[scene] = base
      result[`${scene}-snow`] = changes(base, await read(page, scene, "snow", true))
      result[`${scene}-inside`] = changes(base, await read(page, scene, "sun", false))
    }
    return result
  } finally {
    await browser.close()
  }
}

// The classes of b that are not the same as in a, with all their
// properties.
function changes(a, b) {
  const changed = {}
  for (const cls of new Set([...Object.keys(a), ...Object.keys(b)])) {
    if (JSON.stringify(a[cls]) !== JSON.stringify(b[cls])) changed[cls] = b[cls] ?? {}
  }
  return changed
}

// The styles of the classes in a scene, with a weather, for the house
// from the outside or cut open.
async function read(page, scene, weather, outside) {
  const view = outside ? "cutaway cutaway-house cutaway-outside" : "cutaway cutaway-house"
  await page.setContent(
    `<!doctype html><html data-theme="light"><head><style>${css}</style></head><body>
    <svg class="${view}" data-scene="${scene}" data-weather="${weather}" id="svg"><defs><linearGradient id="g"></linearGradient></defs></svg>
    </body></html>`,
  )
  return await page.evaluate(({ classes, shape, stop, text }) => {
    const ns = "http://www.w3.org/2000/svg"
    const svg = document.getElementById("svg")
    const gradient = document.getElementById("g")
    const read = (tag, parent, names, cls) => {
      const bare = document.createElementNS(ns, tag)
      const el = document.createElementNS(ns, tag)
      el.setAttribute("class", cls)
      parent.append(bare, el)
      const a = getComputedStyle(bare)
      const b = getComputedStyle(el)
      const props = {}
      for (const name of names) {
        const v = b.getPropertyValue(name)
        if (v !== a.getPropertyValue(name)) props[name] = v.replace(/url\("?#([^")]+)"?\)/g, "url(#$1)")
      }
      bare.remove()
      el.remove()
      return props
    }
    // A color as rgb() or rgba(): resvg reads no oklab(). A canvas gives
    // the color in sRGB.
    const canvas = document.createElement("canvas").getContext("2d", { willReadFrequently: true })
    const rgb = (value) => {
      if (value === "none" || value.startsWith("url(")) return value
      canvas.clearRect(0, 0, 1, 1)
      canvas.fillStyle = value
      canvas.fillRect(0, 0, 1, 1)
      const [r, g, b, a] = canvas.getImageData(0, 0, 1, 1).data
      return a === 255 ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${Math.round((a / 255) * 100) / 100})`
    }
    const result = {}
    for (const cls of classes) {
      const props = {
        ...read("polygon", svg, shape, cls),
        ...read("stop", gradient, stop, cls),
        ...read("text", svg, text, cls),
      }
      for (const name of ["fill", "stroke", "stop-color"]) {
        if (name in props) props[name] = rgb(props[name])
      }
      if (Object.keys(props).length > 0) result[cls] = props
    }
    return result
  }, { classes, shape, stop, text })
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const json = JSON.stringify(await styles(), null, 1) + "\n"
  if (process.argv.includes("--check")) {
    if (readFileSync(out, "utf8") !== json) {
      console.error("priv/picture/styles.json is not the same as app.css: run scripts/picture-styles.mjs.")
      process.exit(1)
    }
  } else {
    mkdirSync(dirname(out), { recursive: true })
    writeFileSync(out, json)
  }
}
