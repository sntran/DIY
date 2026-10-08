// Reads a usage file of a smart meter on the device. The file never goes to
// the server: the hook UsageFile reads it in the browser, and sends only the
// sums of each month to the LiveView (docs/design.md, "Real usage").
//
// The files:
//
// - Smart Meter Texas: the CSV of "Energy Data 15 Min Interval" (or of the
//   daily reads), with the columns USAGE_DATE, USAGE_START_TIME, USAGE_KWH
//   and CONSUMPTION_SURPLUSGENERATION.
// - Green Button: the XML (ESPI) of "Download My Data", or a CSV with a
//   date, a start time and the usage.
//
// The result has, for each month (YYYY-MM): the kWh from the grid, the kWh
// to the grid (surplus generation), the days with data, and the mean kWh
// of each hour of the day (24 numbers, or null for daily data).

export class UsageError extends Error {}

// The last months that the result keeps.
export const MONTHS = 24

const UNREADABLE = "The app cannot read this file. Use the 15-minute CSV of Smart Meter Texas, or a Green Button file."
const EMPTY = "The file has no usage that the app can read."

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

// A date as [year, month, day]: MM/DD/YYYY or YYYY-MM-DD. No text (a short
// row) gives null.
export function parseDate(text) {
  let m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(text)
  if (m) return valid(+m[3], +m[1], +m[2])
  m = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(text)
  if (m) return valid(+m[1], +m[2], +m[3])
  return null
}

function valid(year, month, day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  return [year, month, day]
}

// The hour of a time: HH:MM (24 hours), or H:MM AM/PM. Empty: hour 0.
export function parseHour(text) {
  if (!text) return 0
  const m = /^(\d{1,2}):(\d{2})(?::\d{2})?\s*(AM|PM)?$/i.exec(text.trim())
  if (!m) return null
  let hour = +m[1]
  const half = m[3] && m[3].toUpperCase()
  if (half === "PM" && hour < 12) hour += 12
  if (half === "AM" && hour === 12) hour = 0
  return hour >= 0 && hour <= 23 ? hour : null
}

// The sums of the months.
function collector() {
  const months = new Map()
  return {
    add([year, month, day], hour, kwh, toGrid) {
      if (!Number.isFinite(kwh) || kwh < 0) return
      const key = `${year}-${String(month).padStart(2, "0")}`
      let m = months.get(key)
      if (!m) {
        m = {month: key, kwh: 0, export: 0, days: new Set(), hours: new Array(24).fill(0), hourly: true}
        months.set(key, m)
      }
      m.days.add(day)
      if (toGrid) {
        m.export += kwh
      } else {
        m.kwh += kwh
        if (hour === null) m.hourly = false
        else m.hours[hour] += kwh
      }
    },

    result(source) {
      const list = [...months.values()]
        .sort((a, b) => (a.month < b.month ? -1 : 1))
        .slice(-MONTHS)
      if (list.length === 0) throw new UsageError(EMPTY)
      return {
        source,
        months: list.map((m) => ({
          month: m.month,
          kwh: round(m.kwh),
          export: round(m.export),
          days: m.days.size,
          hours: m.hourly ? m.hours.map((h) => round(h / m.days.size)) : null,
        })),
      }
    },
  }
}

const round = (n) => Math.round(n * 1000) / 1000

// Reads the text of a usage file.
export function readUsage(text) {
  if (typeof text !== "string") throw new UsageError(UNREADABLE)
  const start = text.replace(/^﻿/, "").trimStart()
  if (start.startsWith("<")) return readXml(start)
  return readCsv(start)
}

function readCsv(text) {
  const lines = text.split(/\r?\n/)
  const at = lines.findIndex((line) => {
    const head = fields(line).map((f) => f.toUpperCase())
    return head.some((f) => f.includes("DATE")) && head.some((f) => /USAGE|KWH|VALUE/.test(f))
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
  const date = find((f) => f === "USAGE_DATE" || f === "DATE", (f) => f.startsWith("DATE"))
  const time = find((f) => ["USAGE_START_TIME", "START TIME", "START_TIME", "TIME"].includes(f))
  const usage = find(
    (f) => f === "USAGE_KWH" || f === "KWH",
    (f) => /USAGE|KWH/.test(f) && !/DATE|TIME/.test(f),
    (f) => f === "VALUE",
  )
  const kind = find((f) => f === "CONSUMPTION_SURPLUSGENERATION" || f === "TYPE" || f === "DIRECTION")
  const units = find((f) => f === "UNITS" || f === "UNIT")
  const source = head.includes("ESIID") ? "smt" : "green_button"
  if (date < 0 || usage < 0) throw new UsageError(UNREADABLE)

  const sums = collector()
  for (const line of lines.slice(at + 1)) {
    if (!line.trim()) continue
    const row = fields(line)
    const day = parseDate(row[date])
    if (!day) continue
    const hour = time < 0 ? null : parseHour(row[time])
    if (time >= 0 && hour === null) continue
    let kwh = parseFloat((row[usage] || "").replace(/,/g, ""))
    const unit = units < 0 ? "" : (row[units] || "").toUpperCase()
    if (unit === "WH") kwh /= 1000
    const toGrid = kind >= 0 && /SURPLUS|GENERATION|RECEIVED|EXPORT/i.test(row[kind] || "")
    sums.add(day, hour, kwh, toGrid)
  }
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

function readXml(text) {
  if (!/IntervalReading/.test(text)) throw new UsageError(UNREADABLE)
  const power = tag(text, "powerOfTenMultiplier") ?? 0
  const uom = tag(text, "uom") ?? 72
  const direction = tag(text, "flowDirection") ?? 1
  const offset = tag(text, "tzOffset") ?? 0
  const dst = tag(text, "dstOffset") ?? 0
  // uom 72 is Wh, and 169 is kWh (ESPI).
  const toKwh = Math.pow(10, power) / (uom === 169 ? 1 : 1000)

  const sums = collector()
  const readings = text.match(/<(?:\w+:)?IntervalReading>[\s\S]*?<\/(?:\w+:)?IntervalReading>/g) || []
  for (const reading of readings) {
    const start = tag(reading, "start")
    const duration = tag(reading, "duration")
    const value = tag(reading, "value")
    if (start === null || value === null) continue
    const local = localTime(start, offset, dst)
    const day = [local.getUTCFullYear(), local.getUTCMonth() + 1, local.getUTCDate()]
    const hour = duration !== null && duration <= 3600 ? local.getUTCHours() : null
    sums.add(day, hour, value * toKwh, direction === 19)
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
    return file.text().then(
      (text) => {
        try {
          this.pushEvent("usage", readUsage(text))
        } catch (error) {
          this.pushEvent("usage_error", {error: error.message})
        }
        this.el.value = ""
      },
      () => this.pushEvent("usage_error", {error: UNREADABLE}),
    )
  },
}
