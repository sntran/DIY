// The tests of assets/js/usage.js: the usage files of a smart meter.
import {test} from "node:test"
import assert from "node:assert/strict"
import fc from "fast-check"
import {UsageError, MONTHS, fields, parseDate, readUsage, localTime, usageHook} from "../../assets/js/usage.js"

const UNREADABLE = "The app cannot read this file. Use the 15-minute CSV of Smart Meter Texas, or a Green Button file (XML or CSV)."
const EMPTY = /no electric usage/

const pad = (n) => String(n).padStart(2, "0")
const rows = (usage) => usage.months.map((m) => [m.month, m.kwh, m.export, m.days])

// A CSV of Smart Meter Texas: one row for each interval of 15 minutes.
function smt(lines) {
  const head = "ESIID,USAGE_DATE,REVISION_DATE,USAGE_START_TIME,USAGE_END_TIME,USAGE_KWH,ESTIMATED_ACTUAL,CONSUMPTION_SURPLUSGENERATION"
  return [head, ...lines.map(({date, hour = 0, minute = 0, kwh, kind = "Consumption"}) =>
    `"1044372000000000",${date},10/01/2025 06:32:13,${pad(hour)}:${pad(minute)},${pad(hour)}:${pad(minute + 15)},${kwh},A,${kind}`)].join("\r\n")
}

// The tags of a ReadingType (ESPI). A tag with null is not in the file.
function typeTags({uom = 72, power = 0, direction = 1, commodity = 1, kind = 12, accumulation = 4, length = 3600} = {}) {
  const tags = {accumulationBehaviour: accumulation, commodity, flowDirection: direction, intervalLength: length, kind, powerOfTenMultiplier: power, uom}
  return Object.entries(tags)
    .filter(([, value]) => value !== null)
    .map(([name, value]) => `<espi:${name}>${value}</espi:${name}>`)
    .join("")
}

// One IntervalReading. A duration with null, or a value with undefined, is
// not in the file.
const interval = ({start, value, duration = 3600}) =>
  "<espi:IntervalReading><espi:timePeriod>" +
  (duration === null ? "" : `<espi:duration>${duration}</espi:duration>`) +
  `<espi:start>${start}</espi:start></espi:timePeriod>` +
  (value === undefined ? "" : `<espi:value>${value}</espi:value>`) +
  "</espi:IntervalReading>"

// A Green Button XML (ESPI) as the utilities give it: an Atom feed with the
// LocalTimeParameters, and for each MeterReading an entry with a link to its
// ReadingType, an entry of the ReadingType, and the entries of its
// IntervalBlocks (each with a link up to the MeterReading, and the interval
// of the full block).
//
// A meter is {type, blocks, related, up}: related false gives no link to the
// ReadingType, up "none" or "empty" gives a block with no up link, or with no
// href in it.
function feed(meters, {tz = -21600, dst = 3600} = {}) {
  const site = "https://utility.example/DataCustodian/espi/1_1/resource"
  const point = `${site}/Subscription/5/UsagePoint/1`
  const entries = [
    `<entry><content><espi:LocalTimeParameters><espi:dstOffset>${dst}</espi:dstOffset><espi:tzOffset>${tz}</espi:tzOffset></espi:LocalTimeParameters></content></entry>`,
  ]
  meters.forEach(({type = {}, blocks = [], related = true, up}, i) => {
    const reading = `${point}/MeterReading/0${i + 1}`
    const readingType = `${site}/ReadingType/0${i + 1}`
    entries.push(
      `<entry><link rel="self" href="${reading}"/><link rel="up" href="${point}/MeterReading"/>` +
      `<link rel="related" href="${reading}/IntervalBlock"/>` +
      (related ? `<link rel="related" href="${readingType}"/>` : "") +
      "<content><espi:MeterReading/></content></entry>",
    )
    entries.push(
      `<entry><link rel="self" href="${readingType}"/><link rel="up" href="${site}/ReadingType"/>` +
      `<content><espi:ReadingType>${typeTags(type)}</espi:ReadingType></content></entry>`,
    )
    blocks.forEach((block, j) => {
      const link = up === "none" ? "" : up === "empty" ? '<link rel="up"/>' : `<link rel="up" href="${reading}/IntervalBlock"/>`
      entries.push(
        `<entry><link href="${site}"/><link rel="self" href="${reading}/IntervalBlock/${j + 1}"/>${link}` +
        `<content><espi:IntervalBlock xmlns:espi="http://naesb.org/espi"><espi:interval><espi:duration>86400</espi:duration><espi:start>${block.length ? block[0].start : 0}</espi:start></espi:interval>${block.map(interval).join("")}</espi:IntervalBlock></content></entry>`,
      )
    })
  })
  return `<?xml version="1.0" encoding="UTF-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom" xmlns:espi="http://naesb.org/espi">\n${entries.join("\n")}\n</feed>`
}

// The readings of one day, from 00:00 in Texas in summer.
function day(value, hours = 24, start = Date.UTC(2025, 6, 1, 5) / 1000) {
  return Array.from({length: hours}, (_, h) => ({start: start + h * 3600, value}))
}

test("fields reads quotes, quotes in quotes, and spaces", () => {
  assert.deepEqual(fields('a, "b,c" ,"d ""e"""'), ["a", "b,c", 'd "e"'])
  assert.deepEqual(fields(""), [""])
})

test("only real dates", () => {
  assert.deepEqual(parseDate("07/04/2025"), [2025, 7, 4])
  assert.deepEqual(parseDate("7/4/2025"), [2025, 7, 4])
  assert.deepEqual(parseDate("2025-07-04"), [2025, 7, 4])
  assert.deepEqual(parseDate("2025-07-04 00:00"), [2025, 7, 4])
  assert.deepEqual(parseDate("02/29/2024"), [2024, 2, 29])
  for (const text of ["13/04/2025", "07/32/2025", "02/30/2025", "02/29/2025", "00/10/2025", "2025-13-01", "2025-04-31", "2025-04-00", "July 4", "", undefined]) {
    assert.equal(parseDate(text), null, String(text))
  }
})

test("a CSV of Smart Meter Texas gives the months, with the surplus generation", () => {
  const text = smt([
    {date: "08/01/2025", hour: 9, kwh: 1},
    {date: "07/01/2025", kwh: 0.25},
    {date: "07/01/2025", minute: 15, kwh: 0.25},
    {date: "07/01/2025", hour: 15, kwh: 1.5},
    {date: "07/02/2025", hour: 15, kwh: 0.5},
    {date: "07/02/2025", hour: 13, kwh: 2, kind: "Surplus Generation"},
    {date: "06/30/2025", hour: 13, kwh: 1},
    // Not a real date: the app does not count it.
    {date: "02/30/2025", kwh: 9},
  ]) + "\r\n\r\n\"1044372000000000\",07/03/2025\r\n"
  // The byte order mark of the file.
  const usage = readUsage("﻿" + text)
  assert.equal(usage.source, "smt")
  assert.deepEqual(rows(usage), [["2025-06", 1, 0, 1], ["2025-07", 2.5, 2, 2], ["2025-08", 1, 0, 1]])
})

test("a CSV of the daily readings of Smart Meter Texas", () => {
  const text = "ESIID,USAGE_DATE,REVISION_DATE,START_READING,END_READING,USAGE_KWH\n" +
    "1,09/01/2025,x,100,130,30\n1,09/02/2025,x,130,155,25\n"
  assert.deepEqual(readUsage(text), {source: "smt", months: [{month: "2025-09", kwh: 55, export: 0, days: 2}]})
})

test("a CSV of Green Button, with lines before the header, Wh, gas and short rows", () => {
  const text = [
    "Name,JANE DOE", "Address,1 MAIN ST", "",
    "TYPE,DATE,START TIME,END TIME,USAGE,UNITS,COST,NOTES",
    "Electric usage,2025-01-05,1:00 PM,1:59 PM,1500,Wh,$0.20,",
    "Electric usage,2025-01-05,12:00 AM,12:59 AM,0.5,kWh,$0.07,",
    "Natural gas usage,2025-01-05,,,3,therms,$4.00,",
    "Natural gas usage,2025-01-05,,,3,kWh,$4.00,",
    "Electric usage,2025-01-06,1:00 PM,1:59 PM,4,kW,,",
    "Electric usage,2025-01-07",
    "Electric usage,someday,1:00 PM,1:59 PM,1,kWh,,",
    "Electric usage,2025-01-08,2:00 PM,2:59 PM,-1,kWh,,",
    "Electric usage,2025-01-09,2:00 PM,2:59 PM,,kWh,,",
  ].join("\n")
  const usage = readUsage(text)
  assert.equal(usage.source, "green_button")
  assert.deepEqual(rows(usage), [["2025-01", 2, 1, 2]])
})

test("a CSV of gas only has no electric usage", () => {
  const text = "TYPE,DATE,START TIME,END TIME,USAGE,UNITS,COST\nNatural gas usage,2025-01-05,,,3,therms,$4.00\n"
  assert.throws(() => readUsage(text), EMPTY)
  assert.throws(() => readUsage("Date,Usage (therms)\n2025-01-05,3\n"), EMPTY)
  assert.throws(() => readUsage("Date,Usage (CCF)\n2025-01-05,3\n"), EMPTY)
})

test("a CSV with the kWh from the grid and to the grid", () => {
  const usage = readUsage("Date,Import (kWh),Export (kWh)\n2025-04-01,10,3\n2025-04-02,5,\n2025-05-01,1,0.5\n")
  assert.equal(usage.source, "csv")
  assert.deepEqual(rows(usage), [["2025-04", 15, 3, 2], ["2025-05", 1, 0.5, 1]])

  const delivered = readUsage("Date,Delivered,Received\n2025-04-01,10,3\n")
  assert.deepEqual(rows(delivered), [["2025-04", 10, 3, 1]])
})

test("a CSV of the net kWh: a number under zero is power to the grid", () => {
  const usage = readUsage("Date,Net kWh\n2025-04-01,6\n2025-04-02,-4\n")
  assert.deepEqual(rows(usage), [["2025-04", 6, 4, 2]])
})

test("a CSV with a direction for each row", () => {
  const usage = readUsage("Date,Value,Direction\n2025-03-01,2,Delivered\n2025-03-01,0.5,Received\n")
  assert.equal(usage.source, "csv")
  assert.deepEqual(rows(usage), [["2025-03", 2, 0.5, 1]])
})

test("a CSV with a column Value, units and type, short rows, and numbers with commas", () => {
  const usage = readUsage("Date,Value,Units,Type\n2025-03-01,2,kWh,Delivered\n2025-03-02\n2025-03-03,1,kWh\n")
  assert.equal(usage.source, "green_button")
  assert.deepEqual(rows(usage), [["2025-03", 3, 0, 2]])

  assert.deepEqual(rows(readUsage('Date,Usage (kWh)\n2025-03-01,"1,200.5"\n')), [["2025-03", 1200.5, 0, 1]])
  assert.deepEqual(rows(readUsage("Date/Time,kWh\n2025-03-01 00:15,0.5\n2025-03-01 00:30,0.25\n")), [["2025-03", 0.75, 0, 1]])
})

test("the CSV files that the app cannot read", () => {
  for (const text of [null, 7, "hello", "a,b\n1,2", "USAGE,X\n1,2", "END DATE,KWH\n2025-03-01,2", "DATE,EXPORT_KWH\n2025-03-01,2"]) {
    assert.throws(() => readUsage(text), (error) => error instanceof UsageError && error.message === UNREADABLE, String(text))
  }
  for (const text of ["Date,Value\n", "DATE,USAGE\nx,y", "DATE,USAGE\n2025-03-01,"]) {
    assert.throws(() => readUsage(text), EMPTY, text)
  }
})

test("a Green Button XML in Wh, with the time of the place and daylight time", () => {
  // 2025-07-01 05:00 UTC is 00:00 in Texas (UTC-6, and 1 hour of daylight
  // time). With no daylight time, it is 23:00 on June 30.
  const july = Date.UTC(2025, 6, 1, 5) / 1000
  // 2025-01-15 06:00 UTC is 00:00 in Texas (no daylight time in January).
  const january = Date.UTC(2025, 0, 15, 6) / 1000
  const blocks = [[{start: july, value: 1500}, {start: july + 3600, value: 500}], [{start: january - 3600, value: 1000}, {start: january, value: 2000}]]
  const usage = readUsage(feed([{blocks}]))
  assert.equal(usage.source, "green_button")
  assert.deepEqual(rows(usage), [["2025-01", 3, 0, 2], ["2025-07", 2, 0, 1]])
  assert.deepEqual(rows(readUsage(feed([{blocks}], {dst: 0}))), [["2025-01", 3, 0, 2], ["2025-06", 1.5, 0, 1], ["2025-07", 0.5, 0, 1]])
})

test("a Green Button XML of solar: a MeterReading from the grid, and one to the grid", () => {
  const usage = readUsage(feed([
    {type: {direction: 1}, blocks: [day(1500)]},
    // In tenths of a Wh: the multiplier is 10^-1.
    {type: {direction: 19, power: -1}, blocks: [day(5000, 8)]},
  ]))
  assert.deepEqual(rows(usage), [["2025-07", 36, 4, 1]])
})

test("a Green Button XML with hourly, daily and summary readings counts the days once", () => {
  const usage = readUsage(feed([
    {type: {length: 3600}, blocks: [day(500)]},
    {type: {length: 86400}, blocks: [[{start: Date.UTC(2025, 6, 1, 5) / 1000, value: 12000, duration: 86400}]]},
    // The demand, in W.
    {type: {uom: 38, kind: 8}, blocks: [day(9000)]},
    // No length in the ReadingType: the length of the readings.
    {type: {length: null}, blocks: [[{start: Date.UTC(2025, 6, 1, 5) / 1000, value: 12000, duration: 86400}]]},
  ]))
  assert.deepEqual(rows(usage), [["2025-07", 12, 0, 1]])

  // No length in the ReadingType: the length of one reading, not the
  // interval of the full block.
  const noLength = readUsage(feed([
    {type: {length: null}, blocks: [day(500)]},
    {type: {length: null}, blocks: [[{start: Date.UTC(2025, 6, 1, 5) / 1000, value: 12000, duration: 86400}]]},
  ]))
  assert.deepEqual(rows(noLength), [["2025-07", 12, 0, 1]])

  // No length in the ReadingType, and none in the readings.
  const unknown = readUsage(feed([{type: {length: null}, blocks: [[{start: Date.UTC(2025, 6, 1, 5) / 1000, value: 2000, duration: null}], []]}]))
  assert.deepEqual(rows(unknown), [["2025-07", 2, 0, 1]])
})

test("a Green Button XML of net readings, and a reading with no value", () => {
  const start = Date.UTC(2025, 4, 10, 12) / 1000
  const usage = readUsage(feed([{
    type: {direction: 4, commodity: null, kind: null},
    blocks: [[{start, value: 1000}, {start: start + 3600, value: -3000}, {start: start + 7200}], []],
  }]))
  assert.deepEqual(rows(usage), [["2025-05", 1, 3, 1]])
})

test("a ReadingType with no multiplier and no flow: Wh from the grid", () => {
  const start = Date.UTC(2025, 4, 10, 12) / 1000
  const usage = readUsage(feed([{type: {power: null, direction: null, accumulation: null}, blocks: [[{start, value: 1000}]]}]))
  assert.deepEqual(rows(usage), [["2025-05", 1, 0, 1]])
})

test("a Green Button XML with the net, and the flows from and to the grid: the net does not count", () => {
  const usage = readUsage(feed([
    {type: {direction: 1}, blocks: [day(1500)]},
    {type: {direction: 19}, blocks: [day(500, 8)]},
    {type: {direction: 4}, blocks: [day(1000)]},
  ]))
  assert.deepEqual(rows(usage), [["2025-07", 36, 4, 1]])
})

test("a meter that changes from daily to hourly readings loses no day, and two meters add up", () => {
  const june = Date.UTC(2025, 5, 30, 5) / 1000
  const usage = readUsage(feed([
    {type: {length: 86400}, blocks: [[{start: june, value: 20000, duration: 86400}, {start: june + 86400, value: 99000, duration: 86400}]]},
    {type: {length: 3600}, blocks: [day(500)]},
    {type: {length: 3600}, blocks: [day(250)]},
  ]))
  assert.deepEqual(rows(usage), [["2025-06", 20, 0, 1], ["2025-07", 18, 0, 1]])
})

test("a Green Button XML with links in single quotes, or with no self links", () => {
  const meters = [{type: {direction: 1}, blocks: [day(1500)]}, {type: {direction: 19}, blocks: [day(500, 8)]}]
  assert.deepEqual(rows(readUsage(feed(meters).replace(/"/g, "'"))), [["2025-07", 36, 4, 1]])
  // With no self links, the app cannot find the ReadingType of a block.
  assert.throws(() => readUsage(feed(meters).replace(/<link rel="self" href="[^"]*"\/>/g, "")), EMPTY)
})

test("a Green Button XML of gas or of the demand has no electric usage", () => {
  const start = Date.UTC(2025, 4, 10, 12) / 1000
  // Natural gas (commodity 7), in therms (uom 169).
  assert.throws(() => readUsage(feed([{type: {commodity: 7, uom: 169}, blocks: [[{start, value: 3}]]}])), EMPTY)
  // Gas in Wh is still gas.
  assert.throws(() => readUsage(feed([{type: {commodity: 7}, blocks: [[{start, value: 3}]]}])), EMPTY)
  // The demand in W, and the energy of a different kind.
  assert.throws(() => readUsage(feed([{type: {uom: 38, kind: 8}, blocks: [[{start, value: 3}]]}])), EMPTY)
  assert.throws(() => readUsage(feed([{type: {kind: 3}, blocks: [[{start, value: 3}]]}])), EMPTY)
  // The totals of a register, not the change in each interval.
  assert.throws(() => readUsage(feed([{type: {accumulation: 1}, blocks: [[{start, value: 3}]]}])), EMPTY)
  // A flow that the app does not know.
  assert.throws(() => readUsage(feed([{type: {direction: 2}, blocks: [[{start, value: 3}]]}])), EMPTY)
})

test("the links of a feed: a block with no up link, and a MeterReading with no ReadingType", () => {
  const start = Date.UTC(2025, 4, 10, 12) / 1000
  // The link of the block itself gives its MeterReading.
  assert.deepEqual(rows(readUsage(feed([{blocks: [[{start, value: 1000}]], up: "none"}]))), [["2025-05", 1, 0, 1]])
  assert.deepEqual(rows(readUsage(feed([{blocks: [[{start, value: 1000}]], up: "empty"}]))), [["2025-05", 1, 0, 1]])
  // One ReadingType in the file: it is the type of all the blocks.
  assert.deepEqual(rows(readUsage(feed([{blocks: [[{start, value: 1000}]], related: false}]))), [["2025-05", 1, 0, 1]])
  // Two ReadingTypes: a block with no ReadingType does not count.
  const two = readUsage(feed([
    {blocks: [[{start, value: 1000}]], related: false},
    {type: {direction: 19}, blocks: [[{start, value: 500}]]},
  ]))
  assert.deepEqual(rows(two), [["2025-05", 0, 0.5, 1]])
})

test("a Green Button XML with no feed", () => {
  const start = Date.UTC(2025, 4, 10, 12) / 1000
  const block = `<IntervalBlock>${interval({start, value: 2000})}</IntervalBlock>`
  const type = (tags) => `<ReadingType>${typeTags(tags).replace(/espi:/g, "")}</ReadingType>`
  assert.deepEqual(rows(readUsage(`<UsagePoint>${type({})}${block}</UsagePoint>`)), [["2025-05", 2, 0, 1]])
  // No ReadingType, or two: the app does not know the units.
  assert.throws(() => readUsage(`<UsagePoint>${block}</UsagePoint>`), EMPTY)
  assert.throws(() => readUsage(`<UsagePoint>${type({})}${type({uom: 38})}${block}</UsagePoint>`), EMPTY)
})

test("the XML files that the app cannot read", () => {
  assert.throws(() => readUsage("<html></html>"), (error) => error.message === UNREADABLE)
  assert.throws(() => readUsage("<feed><IntervalReading></IntervalReading></feed>"), EMPTY)
  assert.throws(() => readUsage("<feed><entry><content><IntervalBlock><IntervalReading></IntervalReading></IntervalBlock></content></entry></feed>"), EMPTY)
})

test("the result keeps the last months", () => {
  const lines = []
  for (let year = 2022; year <= 2025; year++) {
    for (let month = 1; month <= 12; month++) lines.push({date: `${pad(month)}/01/${year}`, kwh: 1})
  }
  const usage = readUsage(smt(lines.reverse()))
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

// Random readings of 15 minutes, from the grid and to the grid: the months of
// the result have the sums of the readings, and the days with data.
test("the months have the sums of the readings", () => {
  const reading = fc.record({
    month: fc.integer({min: 1, max: 12}),
    day: fc.integer({min: 1, max: 28}),
    hour: fc.integer({min: 0, max: 23}),
    quarter: fc.constantFrom(0, 15, 30, 45),
    kwh: fc.integer({min: 0, max: 5000}).map((n) => n / 1000),
    surplus: fc.boolean(),
  })
  fc.assert(fc.property(fc.array(reading, {minLength: 1, maxLength: 60}), (readings) => {
    const lines = readings.map((r) => ({
      date: `${pad(r.month)}/${pad(r.day)}/2025`, hour: r.hour, minute: r.quarter, kwh: r.kwh,
      kind: r.surplus ? "Surplus Generation" : "Consumption",
    }))
    const usage = readUsage(smt(lines))
    for (const m of usage.months) {
      const mine = readings.filter((r) => `2025-${pad(r.month)}` === m.month)
      const sum = (list) => list.reduce((total, r) => total + r.kwh, 0)
      assert.ok(Math.abs(m.kwh - sum(mine.filter((r) => !r.surplus))) < 0.01)
      assert.ok(Math.abs(m.export - sum(mine.filter((r) => r.surplus))) < 0.01)
      assert.equal(m.days, new Set(mine.map((r) => r.day)).size)
    }
    assert.deepEqual(usage.months.map((m) => m.month), [...new Set(readings.map((r) => `2025-${pad(r.month)}`))].sort())
  }))
})

// A result has months in order, each once, with no number under zero and the
// days of one month.
function check(usage) {
  assert.ok(usage.months.length > 0 && usage.months.length <= MONTHS)
  const names = usage.months.map((m) => m.month)
  assert.deepEqual(names, [...new Set(names)].sort())
  for (const m of usage.months) {
    assert.match(m.month, /^\d{4}-(0[1-9]|1[0-2])$/)
    assert.ok(m.kwh >= 0 && m.export >= 0)
    assert.ok(m.days >= 1 && m.days <= 31)
  }
}

// A CSV with a header that the app knows, and random cells.
test("a CSV with random cells gives a good result or a UsageError", () => {
  const cell = fc.oneof(
    fc.string({maxLength: 12}),
    fc.constantFrom("2025-02-29", "2024-02-29", "13/01/2025", "01/31/2025", "kWh", "Wh", "therms", "Surplus", "Gas", "-1", "1e400", '"1,5"'),
    fc.double({noNaN: true}).map(String),
    fc.integer({min: 1, max: 12}).chain((month) => fc.integer({min: 1, max: 31}).map((d) => `${pad(month)}/${pad(d)}/2025`)),
  )
  const line = fc.array(cell, {maxLength: 6}).map((cells) => cells.join(","))
  fc.assert(fc.property(fc.array(line, {maxLength: 20}), (lines) => {
    const text = ["DATE,USAGE,UNITS,TYPE,EXPORT KWH", ...lines].join("\n")
    try {
      check(readUsage(text))
    } catch (error) {
      if (!(error instanceof UsageError)) throw error
    }
  }))
})

test("readUsage gives a result or a UsageError for any text", () => {
  fc.assert(fc.property(fc.string({maxLength: 300}), (text) => {
    try {
      check(readUsage(text))
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
  assert.deepEqual(h.pushed[0], ["usage", {source: "smt", months: [{month: "2025-07", kwh: 1, export: 0, days: 1}]}])
  assert.equal(h.el.value, "")
})

test("the hook sends the error of a file, and clears the input", async () => {
  const bad = hook(input({text: () => Promise.resolve("hello")}))
  await bad.read()
  assert.deepEqual(bad.pushed, [["usage_error", {error: UNREADABLE}]])
  assert.equal(bad.el.value, "")

  const broken = hook(input({text: () => Promise.reject(new Error("no"))}))
  await broken.read()
  assert.deepEqual(broken.pushed, [["usage_error", {error: UNREADABLE}]])
  assert.equal(broken.el.value, "")

  const none = hook(input(null))
  await none.read()
  assert.deepEqual(none.pushed, [])
  const missing = hook({...input(null), files: undefined})
  await missing.read()
  assert.deepEqual(missing.pushed, [])
})
