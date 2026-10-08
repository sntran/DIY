// Reads a usage file of a smart meter on the device. The file never goes to
// the server: the hook UsageFile reads it in the browser, and sends only the
// sums of each month to the LiveView (docs/design.md, "Real usage").
//
// The files:
//
// - Smart Meter Texas: the CSV of "Energy Data 15 Min Interval" (or of the
//   daily reads), with the columns USAGE_DATE, USAGE_KWH and
//   CONSUMPTION_SURPLUSGENERATION.
// - Green Button: the XML (ESPI) of "Download My Data", or its CSV with a
//   type, a date, the usage and its units.
// - A CSV with a date and the kWh (and the kWh to the grid, if it has them).
//
// The result has, for each month (YYYY-MM): the kWh from the grid, the kWh
// to the grid (surplus generation), and the days with data.

export class UsageError extends Error {}

// The last months that the result keeps.
export const MONTHS = 24

const UNREADABLE = "The app cannot read this file. Use the 15-minute CSV of Smart Meter Texas, or a Green Button file (XML or CSV)."
const EMPTY = "The file has no electric usage that the app can read. A file of gas, or of the demand (kW), has no kWh."

// The fields of one line of CSV. A field can be in quotes, with "" for a
// quote in it.
export function fields(line) {
  const out = []
  let field = ""
  let quoted = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (quoted) {
      if (c === '"' && line[i + 1] === '"') {
        field += '"'
        i++
      } else if (c === '"') {
        quoted = false
      } else {
        field += c
      }
    } else if (c === '"') {
      quoted = true
    } else if (c === ",") {
      out.push(field.trim())
      field = ""
    } else {
      field += c
    }
  }
  out.push(field.trim())
  return out
}

// A date as [year, month, day]: MM/DD/YYYY or YYYY-MM-DD, and a real date
// (no February 30). No text (a short row) gives null.
export function parseDate(text) {
  let m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(text)
  if (m) return valid(+m[3], +m[1], +m[2])
  m = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(text)
  if (m) return valid(+m[1], +m[2], +m[3])
  return null
}

function valid(year, month, day) {
  const date = new Date(Date.UTC(year, month - 1, day))
  if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null
  return [year, month, day]
}

// The sums of the months.
function collector() {
  const months = new Map()
  return {
    add([year, month, day], kwh, toGrid) {
      if (!Number.isFinite(kwh)) return
      const key = `${year}-${String(month).padStart(2, "0")}`
      let m = months.get(key)
      if (!m) {
        m = {month: key, kwh: 0, export: 0, days: new Set()}
        months.set(key, m)
      }
      m.days.add(day)
      // A net reading under zero is power to the grid.
      if (toGrid || kwh < 0) m.export += Math.abs(kwh)
      else m.kwh += kwh
    },

    result(source) {
      const list = [...months.values()]
        .sort((a, b) => (a.month < b.month ? -1 : 1))
        .slice(-MONTHS)
      if (list.length === 0) throw new UsageError(EMPTY)
      return {
        source,
        months: list.map((m) => ({month: m.month, kwh: round(m.kwh), export: round(m.export), days: m.days.size})),
      }
    },
  }
}

const round = (n) => Math.round(n * 1000) / 1000

// Reads the text of a usage file.
export function readUsage(text) {
  if (typeof text !== "string") throw new UsageError(UNREADABLE)
  // trimStart also takes away the byte order mark of a file.
  const start = text.trimStart()
  if (start.startsWith("<")) return readXml(start)
  return readCsv(start)
}

// A word of gas: a file of gas has no kWh.
const GAS = /\b(gas|therms?|ccf|mcf)\b/i

function readCsv(text) {
  const lines = text.split(/\r?\n/)
  const at = lines.findIndex((line) => {
    const head = fields(line).map((f) => f.toUpperCase())
    return head.some((f) => f.includes("DATE")) && head.some((f) => /USAGE|KWH|VALUE|IMPORT|DELIVERED/.test(f))
  })
  if (at < 0) throw new UsageError(UNREADABLE)

  const head = fields(lines[at]).map((f) => f.toUpperCase())
  // The first column that passes one of the tests, in the order of the tests.
  const find = (...tests) => {
    for (const t of tests) {
      const at = head.findIndex(t)
      if (at >= 0) return at
    }
    return -1
  }
  const toGridColumn = (f) => /EXPORT|RECEIVED|GENERATION|SURPLUS/.test(f) && !/CONSUMPTION_SURPLUS/.test(f)
  const date = find((f) => f === "USAGE_DATE" || f === "DATE", (f) => f.startsWith("DATE"))
  const usage = find(
    (f) => f === "USAGE_KWH" || f === "KWH",
    (f) => /IMPORT|DELIVERED/.test(f) && !toGridColumn(f),
    (f) => /USAGE|KWH/.test(f) && !/DATE|TIME/.test(f) && !toGridColumn(f),
    (f) => f === "VALUE",
  )
  const toGrid = find((f) => toGridColumn(f) && /KWH|EXPORT|RECEIVED/.test(f))
  const kind = find((f) => f === "CONSUMPTION_SURPLUSGENERATION" || f === "TYPE" || f === "DIRECTION")
  const units = find((f) => f === "UNITS" || f === "UNIT")
  if (date < 0 || usage < 0) throw new UsageError(UNREADABLE)

  const sums = collector()
  for (const line of lines.slice(at + 1)) {
    if (!line.trim()) continue
    const row = fields(line)
    const day = parseDate(row[date])
    if (!day) continue
    // A row of gas, or with units that are not kWh or Wh, has no kWh.
    const unit = units < 0 ? "KWH" : (row[units] || "").toUpperCase()
    if (kind >= 0 && GAS.test(row[kind] || "")) continue
    if (unit !== "KWH" && unit !== "WH") continue
    const scale = unit === "WH" ? 1 / 1000 : 1
    const number = (at) => parseFloat((row[at] || "").replace(/,/g, "")) * scale
    const surplus = kind >= 0 && /SURPLUS|GENERATION|RECEIVED|EXPORT/i.test(row[kind] || "")
    sums.add(day, number(usage), surplus)
    if (toGrid >= 0) sums.add(day, number(toGrid), true)
  }
  const source = head.includes("ESIID") ? "smt" : head.includes("TYPE") && units >= 0 ? "green_button" : "csv"
  return sums.result(source)
}

// The local time of a time in UTC seconds, with the offset of the file and
// the daylight time of the US (from the second Sunday of March to the first
// Sunday of November, at 2:00).
export function localTime(seconds, offset, dst) {
  const standard = new Date((seconds + offset) * 1000)
  const year = standard.getUTCFullYear()
  const begin = Date.UTC(year, 2, sunday(year, 2, 2), 2)
  const end = Date.UTC(year, 10, sunday(year, 10, 1), 1)
  const t = standard.getTime()
  return dst && t >= begin && t < end ? new Date(t + dst * 1000) : standard
}

// The day of the nth Sunday of a month (month from 0).
function sunday(year, month, nth) {
  const first = new Date(Date.UTC(year, month, 1)).getUTCDay()
  return 1 + ((7 - first) % 7) + (nth - 1) * 7
}

function tag(text, name) {
  const m = new RegExp(`<(?:\\w+:)?${name}>\\s*(-?\\d+)\\s*</(?:\\w+:)?${name}>`).exec(text)
  return m ? +m[1] : null
}

// The links of an entry of an Atom feed: {rel, href}.
function links(entry) {
  return [...entry.matchAll(/<(?:\w+:)?link\b([^>]*)>/g)].map(([, attributes]) => ({
    rel: (/\brel="([^"]*)"/.exec(attributes) || [])[1],
    href: (/\bhref="([^"]*)"/.exec(attributes) || [])[1] || "",
  }))
}

// The kind of the content of an entry.
function kindOf(entry) {
  const m = /<(?:\w+:)?(ReadingType|MeterReading|IntervalBlock)[\s/>]/.exec(entry)
  return m && m[1]
}

// A ReadingType (ESPI): the app reads only electric energy in Wh (uom 72),
// from the grid (flow 1), to the grid (19) or net (4).
function readingType(text) {
  return {
    uom: tag(text, "uom"),
    power: tag(text, "powerOfTenMultiplier") ?? 0,
    direction: tag(text, "flowDirection") ?? 1,
    commodity: tag(text, "commodity"),
    kind: tag(text, "kind"),
    length: tag(text, "intervalLength"),
  }
}

function electric(type) {
  return type.uom === 72 && [null, 0, 1, 2].includes(type.commodity) &&
    [null, 12].includes(type.kind) && [1, 4, 19].includes(type.direction)
}

// The path of a MeterReading from the link of one of its IntervalBlocks:
// ".../MeterReading/01/IntervalBlock/01" or ".../MeterReading/01/IntervalBlock".
const meterReading = (href) => href.replace(/\/IntervalBlock(\/[^/]*)?$/, "")

function readXml(text) {
  if (!/IntervalReading/.test(text)) throw new UsageError(UNREADABLE)
  const offset = tag(text, "tzOffset") ?? 0
  const dst = tag(text, "dstOffset") ?? 0
  const entries = text.match(/<(?:\w+:)?entry[\s>][\s\S]*?<\/(?:\w+:)?entry>/g) || []

  // The ReadingTypes, the ReadingType of each MeterReading, and the
  // IntervalBlocks with their MeterReading.
  const types = new Map()
  const readingTypes = new Map()
  const blocks = []
  for (const entry of entries) {
    const all = links(entry)
    const self = (all.find((l) => l.rel === "self") || {href: ""}).href
    switch (kindOf(entry)) {
      case "ReadingType":
        types.set(self, readingType(entry))
        break
      case "MeterReading": {
        const related = all.find((l) => l.rel === "related" && /ReadingType/.test(l.href))
        if (related) readingTypes.set(self, related.href)
        break
      }
      case "IntervalBlock": {
        const up = all.find((l) => l.rel === "up") || {href: self}
        blocks.push({meterReading: meterReading(up.href || self), text: entry})
        break
      }
    }
  }
  // A file with no feed: one ReadingType for its blocks.
  if (entries.length === 0) {
    const all = text.match(/<(?:\w+:)?ReadingType[\s>][\s\S]*?<\/(?:\w+:)?ReadingType>/g) || []
    if (all.length === 1) types.set("", readingType(all[0]))
    blocks.push({meterReading: "", text})
  }
  const only = types.size === 1 ? [...types.values()][0] : null
  const typeOf = (block) => types.get(readingTypes.get(block.meterReading)) || only

  // The blocks of electric energy. For each direction, the finest readings:
  // a file with hourly and daily readings of the same days counts them
  // once.
  const found = blocks.map((block) => ({block, type: typeOf(block)})).filter(({type}) => type && electric(type))
  if (found.length === 0) throw new UsageError(EMPTY)
  const finest = new Map()
  for (const {type, block} of found) {
    const length = type.length ?? tag(block.text, "duration") ?? Infinity
    if (!finest.has(type.direction) || length < finest.get(type.direction)) finest.set(type.direction, length)
  }

  const sums = collector()
  for (const {block, type} of found) {
    const length = type.length ?? tag(block.text, "duration") ?? Infinity
    if (length !== finest.get(type.direction)) continue
    const toKwh = Math.pow(10, type.power) / 1000
    for (const reading of block.text.match(/<(?:\w+:)?IntervalReading>[\s\S]*?<\/(?:\w+:)?IntervalReading>/g) || []) {
      const start = tag(reading, "start")
      const value = tag(reading, "value")
      if (start === null || value === null) continue
      const local = localTime(start, offset, dst)
      const day = [local.getUTCFullYear(), local.getUTCMonth() + 1, local.getUTCDate()]
      sums.add(day, value * toKwh, type.direction === 19)
    }
  }
  return sums.result("green_button")
}

// The LiveView hook of the input of a usage file. It reads the file in the
// browser, and sends only the result.
export const usageHook = {
  mounted() {
    this.el.addEventListener("change", () => this.read())
  },

  read() {
    const file = this.el.files && this.el.files[0]
    if (!file) return Promise.resolve()
    return file
      .text()
      .then(
        (text) => {
          try {
            this.pushEvent("usage", readUsage(text))
          } catch (error) {
            this.pushEvent("usage_error", {error: error.message})
          }
        },
        () => this.pushEvent("usage_error", {error: UNREADABLE}),
      )
      .finally(() => {
        this.el.value = ""
      })
  },
}
