// The tests of assets/js/usage.js: the usage files of a smart meter.
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {
  UsageError, MONTHS, fields, parseDate, parseHour, readUsage, localTime, usageHook,
} from "../../assets/js/usage.js"

const pad = (n) => String(n).padStart(2, "0")

// A CSV of Smart Meter Texas: one row for each interval of 15 minutes.
function smt(rows) {
  const head = "ESIID,USAGE_DATE,REVISION_DATE,USAGE_START_TIME,USAGE_END_TIME,USAGE_KWH,ESTIMATED_ACTUAL,CONSUMPTION_SURPLUSGENERATION"
  return [head, ...rows.map(({date, hour, minute = 0, kwh, kind = "Consumption"}) =>
    `"1044372000000000",${date},10/01/2025 06:32:13,${pad(hour)}:${pad(minute)},${pad(hour)}:${pad(minute + 15)},${kwh},A,${kind}`)].join("\r\n")
}

// A Green Button XML (ESPI) with readings of one hour.
function espi(readings, {power = 0, uom = 72, direction = 1, tz = -21600, dst = 3600} = {}) {
  const items = readings.map(({start, value, duration = 3600}) =>
    `<espi:IntervalReading><espi:timePeriod><espi:duration>${duration}</espi:duration><espi:start>${start}</espi:start></espi:timePeriod><espi:value>${value}</espi:value></espi:IntervalReading>`)
  return `<?xml version="1.0"?><feed><entry><content><espi:LocalTimeParameters><espi:dstOffset>${dst}</espi:dstOffset><espi:tzOffset>${tz}</espi:tzOffset></espi:LocalTimeParameters></content></entry>
<entry><content><espi:ReadingType><espi:flowDirection>${direction}</espi:flowDirection><espi:powerOfTenMultiplier>${power}</espi:powerOfTenMultiplier><espi:uom>${uom}</espi:uom></espi:ReadingType></content></entry>
<entry><content><espi:IntervalBlock>${items.join("")}</espi:IntervalBlock></content></entry></feed>`
}

test("fields reads quotes, quotes in quotes, and spaces", () => {
  assert.deepEqual(fields('a, "b,c" ,"d ""e"""'), ["a", "b,c", 'd "e"'])
  assert.deepEqual(fields(""), [""])
})

test("dates and hours", () => {
  assert.deepEqual(parseDate("07/04/2025"), [2025, 7, 4])
  assert.deepEqual(parseDate("2025-07-04"), [2025, 7, 4])
  assert.deepEqual(parseDate("2025-07-04 00:00"), [2025, 7, 4])
  assert.equal(parseDate("13/04/2025"), null)
  assert.equal(parseDate("07/32/2025"), null)
  assert.equal(parseDate("July 4"), null)
  assert.equal(parseDate(undefined), null)
  assert.equal(parseHour("00:00"), 0)
  assert.equal(parseHour("23:45"), 23)
  assert.equal(parseHour("1:15 PM"), 13)
  assert.equal(parseHour("12:00 AM"), 0)
  assert.equal(parseHour("12:00 pm"), 12)
  assert.equal(parseHour("07:30:00"), 7)
  assert.equal(parseHour(""), 0)
  assert.equal(parseHour("25:00"), null)
  assert.equal(parseHour("noon"), null)
})

test("a CSV of Smart Meter Texas gives the months, the days and the hours", () => {
  const text = smt([
    {date: "07/01/2025", hour: 0, kwh: 0.25},
    {date: "07/01/2025", hour: 0, minute: 15, kwh: 0.25},
    {date: "07/01/2025", hour: 15, kwh: 1.5},
    {date: "07/02/2025", hour: 15, kwh: 0.5},
    {date: "07/02/2025", hour: 13, kwh: 2, kind: "Surplus Generation"},
    {date: "08/01/2025", hour: 9, kwh: 1},
  ])
  const usage = readUsage("﻿" + text)
  assert.equal(usage.source, "smt")
  assert.equal(usage.months.length, 2)
  const july = usage.months[0]
  assert.deepEqual({month: july.month, kwh: july.kwh, export: july.export, days: july.days},
    {month: "2025-07", kwh: 2.5, export: 2, days: 2})
  assert.equal(july.hours[0], 0.25)
  assert.equal(july.hours[15], 1)
  assert.equal(july.hours.length, 24)
  assert.equal(usage.months[1].month, "2025-08")
})

test("a CSV of daily reads gives no hours", () => {
  const text = "ESIID,USAGE_DATE,REVISION_DATE,START_READING,END_READING,USAGE_KWH\n" +
    "1,09/01/2025,x,100,130,30\n1,09/02/2025,x,130,155,25\n"
  const usage = readUsage(text)
  assert.deepEqual(usage.months, [{month: "2025-09", kwh: 55, export: 0, days: 2, hours: null}])
})

test("a CSV of Green Button, with lines before the header, units and AM/PM", () => {
  const text = [
    "Name,JANE DOE", "Address,1 MAIN ST", "",
    "TYPE,DATE,START TIME,END TIME,USAGE,UNITS,COST,NOTES",
    "Electric usage,2025-01-05,1:00 PM,1:59 PM,1500,Wh,$0.20,",
    "Electric usage,2025-01-05,12:00 AM,12:59 AM,0.5,kWh,$0.07,",
    "Electric usage,2025-01-06,bad,1:59 PM,1,kWh,,",
    "Electric usage,someday,1:00 PM,1:59 PM,1,kWh,,",
    "Electric usage,2025-01-06,2:00 PM,2:59 PM,-1,kWh,,",
    "Electric usage,2025-01-06,2:00 PM,2:59 PM,,kWh,,",
  ].join("\n")
  const usage = readUsage(text)
  assert.equal(usage.source, "green_button")
  assert.deepEqual(usage.months.map((m) => [m.month, m.kwh, m.days]), [["2025-01", 2, 1]])
  assert.equal(usage.months[0].hours[13], 1.5)
  assert.equal(usage.months[0].hours[0], 0.5)
})

test("a CSV with no time column gives no hours, and the numbers can have commas", () => {
  const usage = readUsage('Date,Usage (kWh)\n2025-03-01,"1,200.5"\n')
  assert.deepEqual(usage.months, [{month: "2025-03", kwh: 1200.5, export: 0, days: 1, hours: null}])
})

test("a Green Button XML in Wh, with the time of the place and daylight time", () => {
  // 2025-07-01 05:00 UTC is 00:00 in Texas (UTC-6 + 1 hour of daylight time).
  const july = Date.UTC(2025, 6, 1, 5) / 1000
  // 2025-01-15 06:00 UTC is 00:00 in Texas (no daylight time).
  const january = Date.UTC(2025, 0, 15, 6) / 1000
  const text = espi([
    {start: july, value: 1500},
    {start: july + 3600, value: 500},
    {start: january, value: 2000},
    {start: january, value: 100, duration: 86400},
  ])
  const usage = readUsage(text)
  assert.equal(usage.source, "green_button")
  const [jan, jul] = usage.months
  assert.equal(jul.month, "2025-07")
  assert.equal(jul.kwh, 2)
  assert.equal(jul.hours[0], 1.5)
  assert.equal(jul.hours[1], 0.5)
  assert.equal(jan.kwh, 2.1)
  // A daily reading gives no hours for its month.
  assert.equal(jan.hours, null)
})

test("a Green Button XML in kWh, with a multiplier, or to the grid", () => {
  const start = Date.UTC(2025, 4, 10, 12) / 1000
  assert.equal(readUsage(espi([{start, value: 25}], {power: -1, uom: 169})).months[0].kwh, 2.5)
  const out = readUsage(espi([{start, value: 25}], {direction: 19}).replace("</feed>",
    `<espi:IntervalReading><espi:timePeriod><espi:duration>3600</espi:duration><espi:start>${start}</espi:start></espi:timePeriod><espi:value>1000</espi:value></espi:IntervalReading></feed>`))
  assert.deepEqual([out.months[0].kwh, out.months[0].export], [0, 1.025])
})

test("a Green Button XML with the defaults, and a reading with no value", () => {
  const start = Date.UTC(2025, 4, 10, 12) / 1000
  const text = `<feed><IntervalReading><timePeriod><duration>900</duration><start>${start}</start></timePeriod><value>2000</value></IntervalReading>
<IntervalReading><timePeriod><start>${start}</start></timePeriod></IntervalReading></feed>`
  const usage = readUsage(text)
  assert.equal(usage.months[0].kwh, 2)
  assert.equal(usage.months[0].hours[12], 2)
})

test("a CSV with a column Value, short rows, and a header with no date column", () => {
  const usage = readUsage("Date,Value,Units,Type\n2025-03-01,2,kWh,Delivered\n2025-03-02\n2025-03-03,1\n")
  assert.deepEqual(usage.months.map((m) => [m.month, m.kwh, m.days]), [["2025-03", 3, 2]])
  assert.throws(() => readUsage("END DATE,KWH\n2025-03-01,2"), /cannot read/)
  assert.throws(() => readUsage("<feed><IntervalReading>"), /no usage/)
})

test("the files that the app cannot read", () => {
  for (const text of [null, "hello", "a,b\n1,2", "<html></html>", "DATE,USAGE\nx,y", "<feed><IntervalReading></IntervalReading></feed>"]) {
    assert.throws(() => readUsage(text), UsageError)
  }
  assert.throws(() => readUsage("Date,Value\n"), /no usage/)
  assert.throws(() => readUsage("USAGE,X\n1,2"), /cannot read/)
})

test("the result keeps the last months", () => {
  const rows = []
  for (let year = 2022; year <= 2025; year++) {
    for (let month = 1; month <= 12; month++) rows.push({date: `${pad(month)}/01/${year}`, hour: 1, kwh: 1})
  }
  const usage = readUsage(smt(rows))
  assert.equal(usage.months.length, MONTHS)
  assert.equal(usage.months.at(-1).month, "2025-12")
  assert.equal(usage.months[0].month, "2024-01")
})

test("the daylight time of the US", () => {
  // 2025: from March 9 to November 2.
  const before = localTime(Date.UTC(2025, 2, 9, 7) / 1000, -21600, 3600)
  const after = localTime(Date.UTC(2025, 2, 9, 9) / 1000, -21600, 3600)
  assert.equal(before.getUTCHours(), 1)
  assert.equal(after.getUTCHours(), 4)
  const november = localTime(Date.UTC(2025, 10, 2, 8) / 1000, -21600, 3600)
  assert.equal(november.getUTCHours(), 2)
  assert.equal(localTime(Date.UTC(2025, 6, 1, 6) / 1000, -21600, 0).getUTCHours(), 0)
})

// Random readings of 15 minutes: the months of the result have the sums of
// the readings, and the hours of a month add up to its kWh.
test("the months have the sums of the readings", () => {
  const reading = fc.record({
    month: fc.integer({min: 1, max: 12}),
    day: fc.integer({min: 1, max: 28}),
    hour: fc.integer({min: 0, max: 23}),
    quarter: fc.constantFrom(0, 15, 30, 45),
    kwh: fc.integer({min: 0, max: 5000}).map((n) => n / 1000),
  })
  fc.assert(fc.property(fc.array(reading, {minLength: 1, maxLength: 60}), (readings) => {
    const rows = readings.map((r) => ({date: `${pad(r.month)}/${pad(r.day)}/2025`, hour: r.hour, minute: r.quarter, kwh: r.kwh}))
    const usage = readUsage(smt(rows))
    for (const m of usage.months) {
      const mine = readings.filter((r) => `2025-${pad(r.month)}` === m.month)
      const total = mine.reduce((sum, r) => sum + r.kwh, 0)
      assert.ok(Math.abs(m.kwh - total) < 0.01)
      assert.equal(m.days, new Set(mine.map((r) => r.day)).size)
      const hours = m.hours.reduce((sum, h) => sum + h, 0) * m.days
      assert.ok(Math.abs(hours - total) < 0.05)
    }
    assert.equal(usage.months.length, new Set(readings.map((r) => r.month)).size)
  }))
})

test("readUsage gives a result or a UsageError for any text", () => {
  fc.assert(fc.property(fc.string({maxLength: 300}), (text) => {
    try {
      const usage = readUsage(text)
      assert.ok(usage.months.length > 0)
    } catch (error) {
      assert.ok(error instanceof UsageError)
    }
  }))
})

// A fake input element and LiveView hook.
function input(file) {
  const listeners = {}
  return {
    files: file ? [file] : [],
    value: "file.csv",
    addEventListener(name, fn) { listeners[name] = fn },
    listeners,
  }
}

function hook(el) {
  const pushed = []
  return Object.assign({el, pushed, pushEvent(name, payload) { pushed.push([name, payload]) }}, usageHook)
}

test("the hook reads the file in the browser, and sends the months", async () => {
  const text = smt([{date: "07/01/2025", hour: 3, kwh: 1}])
  const h = hook(input({text: () => Promise.resolve(text)}))
  h.mounted()
  await h.el.listeners.change()
  await h.read()
  assert.equal(h.pushed[0][0], "usage")
  assert.equal(h.pushed[0][1].months[0].kwh, 1)
  assert.equal(h.el.value, "")
})

test("the hook sends the error of a file", async () => {
  const bad = hook(input({text: () => Promise.resolve("hello")}))
  await bad.read()
  assert.deepEqual(bad.pushed, [["usage_error", {error: "The app cannot read this file. Use the 15-minute CSV of Smart Meter Texas, or a Green Button file."}]])

  const broken = hook(input({text: () => Promise.reject(new Error("no"))}))
  await broken.read()
  assert.equal(broken.pushed[0][0], "usage_error")

  const none = hook(input(null))
  await none.read()
  assert.deepEqual(none.pushed, [])
  const missing = hook({...input(null), files: undefined})
  await missing.read()
  assert.deepEqual(missing.pushed, [])
})
