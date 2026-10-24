// The browser test of the house builder: a person builds a house in
// Chromium, on the server of the tests (test/diy_web/browser_test.exs).
// The script checks each step, and runs axe-core (WCAG 2.2 A and AA, and
// the best practices of axe) on each screen, in the light and the dark
// mode, on a phone (390 pixels) and on a desk (1280 pixels). It exits with
// 1 at the first fault.
//
//   node test/browser/house.mjs http://localhost:4002
//
// PLAYWRIGHT is the module of Playwright (default: "playwright-core"), and
// CHROMIUM the path of a Chromium.

import { readFileSync } from "node:fs"
import { createRequire } from "node:module"
import assert from "node:assert/strict"
import { fakeHomeAssistant } from "./fake_ha.mjs"
import { fakeEcoFlow } from "./fake_ecoflow.mjs"

const require = createRequire(import.meta.url)
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright-core")
const axe = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8")
const tags = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa", "best-practice"]
const site = process.argv[2] ?? "http://localhost:4002"
// The server of the tests has a stub of the cloud of Pecron
// (DIY.Stubs.pecron/0). On the Worker, there is no stub: the walk does not
// connect Pecron there.
const stubs = process.env.DIY_STUBS === "1"

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM })
let faults = 0

// A fake Home Assistant on this computer (test/browser/fake_ha.mjs), with
// a floor, three areas and devices. Two devices are in the living room,
// and one is on the patio. The sun is a service, not a device of the
// house. The ceiling lights are on. The energy settings have the meter
// of the house: 25 kWh each day of the last 40 days. They also have the
// ceiling lights: 12 kWh last month, and 4 kWh this month. A power station
// of Pecron is on the patio, with the integration of Pecron.
const device = (id, name, area_id, entity, extra = {}) => ({
  device: { id, name, name_by_user: null, area_id, entry_type: null, disabled_by: null, model: null, ...extra },
  entity: { entity_id: entity, device_id: id, area_id: null, entity_category: null, hidden_by: null, disabled_by: null },
})
const day = 86_400_000
const today = Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), new Date().getUTCDate())
const thisMonth = Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), 1)
const lastMonth = Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth() - 1, 1)
const twoMonthsAgo = Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth() - 2, 1)
const energySensor = {
  entity_id: "sensor.ceiling_energy", device_id: "lights", area_id: null, entity_category: null, hidden_by: null,
  disabled_by: null,
}
// An entity of the station: the code of its part is at the end of its
// unique id.
const pecron = (entity_id, code) => ({
  entity_id, device_id: "station", area_id: null, entity_category: null, hidden_by: null, disabled_by: null,
  platform: "pecron", unique_id: `01J:station:${code}`,
})
const station = [
  pecron("sensor.station_battery", "battery_percentage"),
  pecron("sensor.station_out", "total_output_power"),
  pecron("switch.station_ac", "ac_switch_hm"),
  pecron("switch.station_dc", "dc_switch_hm"),
  pecron("binary_sensor.station_online", "online"),
]
const devices = [
  device("lights", "Ceiling Lights", "living_room", "light.ceiling"),
  device("tv", "Living Room TV", "living_room", "media_player.tv"),
  device("fan", "Patio fan", "patio", "fan.patio"),
  device("sun", "Sun", null, "sensor.sun", { entry_type: "service" }),
]
const homeAssistant = await fakeHomeAssistant({
  floors: [{ floor_id: "ground", name: "Ground floor", level: 0 }],
  areas: [
    { area_id: "living_room", name: "Living Room", floor_id: "ground" },
    { area_id: "patio", name: "Patio", floor_id: null },
    { area_id: "guest_suite", name: "Guest Suite", floor_id: null },
  ],
  devices: [
    ...devices.map((one) => one.device),
    device("station", "Backup battery", "patio", "", { model: "E3800LFP" }).device,
  ],
  entities: [...devices.map((one) => one.entity), energySensor, ...station],
  states: {
    "light.ceiling": "on", "media_player.tv": "playing", "sensor.station_battery": "64",
    "sensor.station_out": "350", "switch.station_ac": "on", "switch.station_dc": "off",
    "binary_sensor.station_online": "on",
  },
  attributes: {
    "sensor.station_battery": { unit_of_measurement: "%" }, "sensor.station_out": { unit_of_measurement: "W" },
  },
  prefs: {
    energy_sources: [{ type: "grid", stat_energy_from: "sensor.grid_in", stat_energy_to: null }],
    device_consumption: [{ stat_consumption: "sensor.ceiling_energy", name: "Ceiling Lights" }],
  },
  statistics: {
    "sensor.grid_in": {
      day: Array.from({ length: 40 }, (_, i) => ({ start: today - (40 - i) * day, end: today - (39 - i) * day, change: 25 })),
    },
    "sensor.ceiling_energy": {
      // The first month of a sensor does not count: it can be a part of a
      // month.
      month: [
        { start: twoMonthsAgo, end: lastMonth, change: 11 },
        { start: lastMonth, end: thisMonth, change: 12 },
        { start: thisMonth, end: today, change: 4 },
      ],
    },
  },
})

// axe on the page as it is now. First the animations and the transitions
// that end must end: a panel that fades in has a low contrast until then.
// The loops of the items that run never end, so they do not count.
async function check(page, name) {
  await page.waitForFunction(() =>
    document.getAnimations().every((a) => a.playState !== "running" || a.effect?.getTiming().iterations === Infinity))
  await page.evaluate(axe)
  const { violations } = await page.evaluate((tags) => window.axe.run(document, { runOnly: tags }), tags)
  for (const violation of violations) {
    faults++
    console.log(`${name}: ${violation.id} (${violation.impact}): ${violation.help}`)
    for (const node of violation.nodes) console.log(`  ${node.target.join(" ")}`)
  }
}

// Follows a link of the list of the rooms. The list is for a keyboard and
// a screen reader: it shows when it has the focus. So the test uses the
// keyboard, as a person with a keyboard does.
async function follow(page, selector) {
  await page.focus(selector)
  await page.keyboard.press("Enter")
}

// The id of an item of the plan by its name, and of a room by its name.
const itemId = (page, name) =>
  page.evaluate((name) => [...document.querySelectorAll("g[data-item]")]
    .find((g) => g.querySelector("title").textContent === name).getAttribute("data-item"), name)
const roomId = (page, name) =>
  page.evaluate((name) => [...document.querySelectorAll('li[id^="room-"]')]
    .find((li) => li.querySelector("h3").textContent.trim().startsWith(name)).id.slice(5), name)

// A drag with the mouse, in steps.
async function drag(page, from, dx, dy) {
  await page.mouse.move(from.x, from.y)
  await page.mouse.down()
  for (let i = 1; i <= 8; i++) await page.mouse.move(from.x + (dx * i) / 8, from.y + (dy * i) / 8)
  await page.mouse.up()
}

const center = (box) => ({ x: box.x + box.width / 2, y: box.y + box.height / 2 })

// A CSV of Smart Meter Texas: 15-minute reads from July 2024 to June
// 2025, with more use in the hot and the cold months.
function meterFile() {
  const lines = ["ESIID,USAGE_DATE,REVISION_DATE,USAGE_START_TIME,USAGE_END_TIME,USAGE_KWH,ESTIMATED_ACTUAL,CONSUMPTION_SURPLUSGENERATION"]
  for (let i = 0; i < 12; i++) {
    const year = 2024 + Math.floor((6 + i) / 12)
    const month = ((6 + i) % 12) + 1
    const days = new Date(Date.UTC(year, month, 0)).getUTCDate()
    const kwh = 0.3 + (month >= 6 && month <= 9 ? 0.4 : month <= 2 || month === 12 ? 0.2 : 0)
    for (let day = 1; day <= days; day++) {
      const date = `${String(month).padStart(2, "0")}/${String(day).padStart(2, "0")}/${year}`
      for (let q = 0; q < 96; q++) {
        const time = `${String(Math.floor(q / 4)).padStart(2, "0")}:${String((q % 4) * 15).padStart(2, "0")}`
        lines.push(`"1044372000000000",${date},${date},${time},${time},${kwh.toFixed(3)},A,Consumption`)
      }
    }
  }
  return Buffer.from(lines.join("\r\n"))
}

// The math of a hint of the lesson, as a person does it: "1,586 kWh ×
// 13.7¢ ÷ 100", or "$4.06 + 1,586 kWh × 6.8673¢ ÷ 100".
function calc(text) {
  const expression = text
    .replace(/,/g, "")
    .replace(/×/g, "*")
    .replace(/÷/g, "/")
    .replace(/\.(?!\d)/g, "")
    .replace(/[^0-9.+*/ ]/g, "")
  return Function(`return (${expression})`)()
}

const money = (number) => number.toFixed(2)

// A test user with no background does the plan lesson: the worked example,
// an EFL with the help of the hints, a second plan with fewer hints, and the
// worksheet with the two plans.
async function lesson(page, name) {
  await page.click("nav >> text=Plans")
  await page.waitForSelector("#example")
  await check(page, `${name} lesson example`)
  await page.click("#example >> text=Next: your data")
  await page.waitForSelector("#with-help")

  // The EFL of a plan, read in the browser: an encrypted EFL too.
  await page.setInputFiles("#efl-file", "test/fixtures/efl/discount-saver-18.pdf")
  await page.waitForSelector("#efl-result:has-text('discount-saver-18')")
  assert.equal(await page.locator("#efl-check td .hero-check").count(), 3)
  await page.setInputFiles("#efl-file", "test/fixtures/efl/txu-smart-1000-select-12.pdf")
  await page.waitForSelector("#efl-result:has-text('txu-smart-1000-select-12')")
  assert.equal(await page.locator("#efl-check td .hero-check").count(), 3)
  // Each number links to its page of the PDF.
  await page.waitForFunction(() =>
    [...document.querySelectorAll("#efl-result a[data-efl-page]")].every((a) => a.href.startsWith("blob:")),
  )
  await check(page, `${name} EFL`)
  await page.fill("#efl-add input[name=name]", "Plan with a credit")
  await page.click("#efl-add button")
  await page.waitForSelector("#lesson-plan")

  // Each part of the bill of the month with the most use, with the hints.
  const kwh = await page.$eval("#exercise p.font-semibold", (el) => +el.textContent.match(/([\d,]+) kWh/)[1].replace(/,/g, ""))
  const month = await page.$eval("#exercise p.font-semibold", (el) => el.textContent.match(/bill of (\w+)/)[1])
  const hint = (part) => page.$eval(`label:has(#answer-${part}) span.text-xs`, (el) => el.textContent)
  const energy = calc(await hint("energy"))
  const base = calc(await hint("base"))
  const tdu = calc(await hint("tdu"))
  let credits = 0
  for (const line of await page.$$eval("#plan-numbers li", (els) => els.map((el) => el.textContent))) {
    const credit = line.match(/Credit: \$([\d.]+) for ([\d,]+) kWh or more( in (.*))?\./)
    if (credit && kwh >= +credit[2].replace(/,/g, "") && (!credit[4] || credit[4].includes(month))) credits += +credit[1]
  }
  await page.fill("#answer-energy", money(energy))
  await page.fill("#answer-base", money(base))
  await page.fill("#answer-tdu", money(tdu))
  await page.fill("#answer-credits", money(credits))
  await page.fill("#answer-total", money(energy + base + tdu - credits))
  await page.click("#exercise button")
  await page.waitForSelector("#exercise-done")
  await check(page, `${name} exercise`)
  await page.click("#exercise-done >> text=Next: fewer hints")

  // A second plan from its numbers (a plan from a broker), and its bill.
  await page.waitForSelector("#plan-form")
  await page.fill("#plan-form input[name='plan[name]']", "Broker plan")
  await page.fill("#plan-form input[name='plan[base]']", "4.95")
  await page.fill("#plan-form input[name='plan[energy]']", "9.5")
  await page.click("#plan-form button")
  await page.waitForSelector("#fewer-hints #exercise")
  const second = await page.$eval("#exercise p.font-semibold", (el) => +el.textContent.match(/([\d,]+) kWh/)[1].replace(/,/g, ""))
  await page.fill("#answer-total", money(4.95 + second * 9.5 / 100 + 4.06 + second * 6.8673 / 100))
  await page.click("#exercise button[type=submit], #exercise button:not([type])")
  await page.waitForSelector("#exercise-done")
  await page.click("#exercise-done >> text=Next: on your own")

  // The worksheet: the two plans, in the order of the user.
  await page.waitForSelector("#worksheet-table")
  const heads = await page.$$eval("#worksheet-table thead th", (els) => els.map((el) => el.textContent.trim()))
  assert.deepEqual(heads, ["Month", "kWh", "Plan with a credit", "Broker plan"])
  await check(page, `${name} worksheet`)
}

// The van: the person adds a camper van in the driveway, fills its zones,
// and takes the power station of the house in it.
async function van(page, name) {
  await page.click("nav >> text=Rooms")
  await page.waitForSelector("#inside")
  await follow(page, 'a[id^="add-"][aria-label="Add an item to Driveway"]')
  await page.click("#add-camper_van")
  await page.waitForSelector("#item-stage:has-text('Camper van')")
  await page.click("#open-van")
  await page.waitForSelector("#van-weight")
  assert.match(await page.textContent("#weight-total"), /of 8,900 lb/)
  await check(page, `${name} van`)

  // The list of the zones is for a keyboard, as the list of the rooms.
  await follow(page, 'a[id^="add-"][aria-label="Add an item to Galley"]')
  await page.waitForSelector("#add-sheet")
  await check(page, `${name} van add`)
  // A new item of the van comes forward with the same panel as an item of
  // the house. Its first part has its weight and its energy.
  await page.click("#add-van_fridge")
  await page.waitForSelector("#item-stage:has-text('12 V fridge') [data-stage=landed]")
  await page.waitForSelector("#part-cost:has-text('Wh in a day of July')")
  await check(page, `${name} van item`)
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })
  await page.waitForSelector("#van-notes:has-text('no power station')")

  // The van cut open: the person zooms to its floor, and drags the fridge.
  await page.click('div[id^="van-plan-"] button[data-focus=floor]')
  const vanFridge = `g[data-item="${await itemId(page, "12 V fridge")}"]`
  const vanFridgeAt = await page.getAttribute(vanFridge, "data-at")
  await page.locator(vanFridge).scrollIntoViewIfNeeded()
  await drag(page, center(await page.locator(vanFridge).boundingBox()), 8, 6)
  await page.waitForFunction(([s, at]) => document.querySelector(s).getAttribute("data-at") !== at, [vanFridge, vanFridgeAt])
    .catch(() => assert.fail(`${name}: the fridge moves in the van with a drag`))
  await check(page, `${name} van plan`)

  // A tap on the cab chooses it: the seats and the dash let the tap
  // through. The cab is fixed.
  const zoneId = (zone) =>
    page.evaluate((zone) => [...document.querySelectorAll('#van-list li[id^="zone-"]')]
      .find((li) => li.querySelector("h3").textContent.trim().startsWith(zone)).id.slice(5), zone)
  const cab = `polygon[data-room="${await zoneId("Cab")}"]`
  await page.locator(cab).scrollIntoViewIfNeeded()
  await page.mouse.click(...Object.values(center(await page.locator(cab).boundingBox())))
  await page.waitForSelector("#zone-bar:has-text('It stays where it is')")
  await check(page, `${name} van zone`)

  // The bed: its bar and its sheet.
  await follow(page, `#choose-${await zoneId("Bed")}`)
  await page.waitForSelector("#zone-bar:has-text('Bed')")
  await page.click("#bar-change")
  await page.waitForSelector("#zone-sheet")
  await check(page, `${name} van zone sheet`)
  await page.keyboard.press("Escape")
  await page.waitForSelector("#zone-sheet", { state: "detached" })

  // The shell has no place on the plan: a tap adds insulation to it.
  await page.click("#shell-add")
  await page.waitForSelector("#add-sheet")
  await page.click("#add-insulation")
  await page.waitForSelector("#item-stage:has-text('Insulation') [data-stage=landed]")
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })
  await page.waitForSelector('#van-shell a[id^="shell-item-"]')

  await page.click('#van-stations button:has-text("Take it in this van")')
  await page.waitForSelector("#van-stations:has-text('in this van')")
  await page.waitForSelector("#van-months")
  await page.waitForSelector("#van-power:has-text('Off the grid')")
  await check(page, `${name} van with the station`)

  // The house shows the station as away, and the bill of the house stays.
  await page.click("nav >> text=Rooms")
  await page.waitForSelector('[id^="away-"]:has-text("in the van now")', { state: "attached" })
  // The bar has no part Van: the list of the rooms opens the van (with the
  // keyboard).
  const bar = page.locator("nav[aria-label='The parts of your build']")
  assert.equal(await bar.getByText("Van", { exact: true }).count(), 0, `${name}: the bar has no part Van`)
  await page.focus('[id^="away-"]')
  await page.keyboard.press("Enter")
  await page.waitForSelector("#van-stations")
  await page.click('#van-stations button:has-text("Bring it home")')
  await page.waitForSelector("#van-stations:has-text('at home')")
}

// A pool in the yard: an item, with water on the plan and on the house.
// The sheet Add of the yard finds the pool and the hot tub with a search.
// The search in the kitchen tells where a central AC goes.
async function pool(page, name) {
  await page.click("nav >> text=Rooms")
  await page.waitForSelector("#inside")
  await follow(page, 'a[id^="add-"][aria-label="Add an item to Backyard"]')
  await page.waitForSelector("#add-sheet")
  await page.fill("#add-search input[name=q]", "spa")
  await page.waitForSelector("#add-sheet #add-pool")
  await page.waitForSelector("#add-fridge", { state: "detached" })
  await check(page, `${name} search`)
  await page.click("#add-pool")
  await page.waitForSelector("#item-stage:has-text('Pool')")
  await check(page, `${name} pool`)
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })
  await page.waitForSelector("#plan-svg polygon.p-water", { state: "attached" })

  await follow(page, 'a[id^="add-"][aria-label="Add an item to Backyard"]')
  await page.waitForSelector("#add-sheet")
  await page.fill("#add-search input[name=q]", "hot tub")
  await page.click("#add-hot_tub")
  await page.waitForSelector("#item-stage:has-text('Hot tub')")
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })

  // The person drags the dryer onto the washer: it goes on the washer
  // (data-on).
  await page.click("button[data-focus=ground]")
  const [washerId, dryerId] = [await itemId(page, "Clothes washer"), await itemId(page, "Clothes dryer")]
  const dryer = `g[data-item="${dryerId}"]`
  const washer = center(await page.locator(`g[data-item="${washerId}"]`).boundingBox())
  const from = center(await page.locator(dryer).boundingBox())
  await drag(page, from, washer.x - from.x, washer.y - from.y)
  await page.waitForSelector(`${dryer}[data-on="${washerId}"]`, { state: "attached" })
    .catch(() => assert.fail(`${name}: the dryer goes on the washer with a drag`))
  await check(page, `${name} dryer on the washer`)

  await follow(page, 'a[id^="add-"][aria-label="Add an item to Kitchen"]')
  await page.waitForSelector("#add-sheet")
  await page.fill("#add-search input[name=q]", "heat pump")
  await page.waitForSelector("#elsewhere-ac:has-text('a room outside or the roof')")
  await page.fill("#add-search input[name=q]", "Tesla")
  await page.waitForSelector("#add-ev")
  await page.waitForSelector("#add-elsewhere", { state: "detached" })
  await page.click("#add-sheet a[data-close]")
  await page.waitForSelector("#add-sheet", { state: "detached" })

  await page.click("nav >> text=House")
  await page.waitForSelector("#house-picture .p-water", { state: "attached" })
}

async function connected(page) {
  await page.waitForSelector(".phx-connected")
}

// The steps of a new user, with a check of axe on each screen.
async function build(context, name) {
  const page = await context.newPage()
  page.on("pageerror", (error) => { faults++; console.log(`${name}: page error: ${error.message}`) })
  await page.goto(site + "/")
  await connected(page)

  await page.waitForSelector("#door-my-house")
  // The bar at the top while a page loads: axe checks it too. (On a slow
  // computer, it shows at each load.)
  await page.evaluate(() => window.dispatchEvent(new Event("phx:page-loading-start")))
  await page.waitForSelector("body > canvas", { state: "attached" })
  await check(page, `${name} doors`)
  await page.evaluate(() => window.dispatchEvent(new Event("phx:page-loading-stop")))

  // The languages: the first screen in Spanish and in Vietnamese, with the
  // checks of axe. Then the walk goes on in English.
  for (const [lang, title] of [["es", "Encuentre su próximo pequeño paso"], ["vi", "Tìm bước nhỏ tiếp theo của bạn"]]) {
    await page.click(`#language-${lang}`)
    await page.waitForSelector(`html[lang=${lang}] h1:has-text('${title}')`)
    await page.waitForSelector(`#language-${lang}[aria-current=true]`)
    await connected(page)
    await check(page, `${name} doors (${lang})`)
  }
  await page.click("#language-en")
  await page.waitForSelector("html[lang=en] h1:has-text('Find your next small step')")
  await connected(page)
  await page.click("#door-my-house")

  await page.waitForSelector("#zip-form")
  await check(page, `${name} ZIP code`)
  await page.fill("#zip", "123")
  await page.click("#zip-form button[type=submit]")
  await page.waitForSelector("#zip-error")
  await page.fill("#zip", "75070")
  await page.click("#zip-form button[type=submit]")

  await page.waitForSelector("#preset-form")
  await check(page, `${name} preset`)
  await page.click("label[for=size-medium]")
  await page.click("label[for=age-2000s]")
  await page.click("label[for=floors-2]")
  await page.click("label[for=heat-gas]")
  // The chosen buttons: their words must stay clear.
  await check(page, `${name} preset chosen`)
  await page.click("#start-preset")

  await page.waitForSelector("#bill-average")
  assert.match(await page.textContent("#bill-average"), /\$\d+/)
  // The market comes from Power to Choose after the bill: on the Worker,
  // from the real service, so it can take some seconds.
  await page.waitForSelector("#market:has-text('Oncor')", { timeout: 30000 })
  await check(page, `${name} front`)

  // The house from the outside, in the look of the plan: the pole of the
  // grid and its wire. The power flows in the wire 5 times, then it stops.
  // With less motion, it does not move.
  await page.waitForSelector("#house-picture svg.cutaway-outside .p-chip-text:has-text('Grid')")
  const flow = await page.$eval("#house-picture .p-flow", (path) => {
    const style = getComputedStyle(path)
    return { name: style.animationName, count: style.animationIterationCount }
  })
  if (await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)) {
    assert.equal(flow.name, "none")
  } else {
    assert.equal(flow.count, "5")
  }

  // The chart of the bill: a click on a month gives its dollars in the
  // line over the chart. The keyboard on the next month does it too.
  const names = ["January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December"]
  const first = new Date().getUTCMonth() === 0 ? 2 : 1
  await page.click(`#chart-${first}`)
  await page.waitForSelector(`#chart-${first}[aria-pressed=true]`)
  assert.match(await page.textContent("#bill-month"), new RegExp(`${names[first - 1]}: \\$`))
  await page.focus(`#chart-${first + 1}`)
  await page.keyboard.press("Enter")
  await page.waitForSelector(`#chart-${first + 1}[aria-pressed=true]`)
  assert.match(await page.textContent("#bill-month"), new RegExp(`${names[first]}: \\$`))
  await check(page, `${name} front, a month of the chart`)

  // The sky at the house (docs/design.md, "The sky at the house"). The
  // stubs of the server give a clear day; the Worker asks Open-Meteo. A
  // choice of a night with rain changes the picture. Its colors follow the
  // scene, not the theme of the page: by day, the sky is light also in the
  // dark theme.
  const skyFill = () => page.$eval("#house-picture .p-sky", (el) => getComputedStyle(el).fill)
  const paneFill = () => page.$eval("#house-picture .p-pane", (el) => getComputedStyle(el).fill)
  if (process.env.DIY_STUBS) {
    await page.waitForSelector("#sky-form option[value=now]:has-text('Now (Day)')", { state: "attached" })
    await page.waitForSelector("#sky-form-now:has-text('Now at the house: 59 °F, day, sun.')")
  }
  await page.selectOption("#sky-form select[name=time]", "night")
  await page.selectOption("#sky-form select[name=weather]", "rain")
  await page.waitForSelector("#house-picture svg[data-scene=night][data-weather=rain]")
  assert.equal(await skyFill(), "rgb(16, 27, 51)")
  assert.equal(await paneFill(), "rgb(242, 196, 107)")
  await check(page, `${name} night with rain`)
  await page.selectOption("#sky-form select[name=time]", "day")
  await page.selectOption("#sky-form select[name=weather]", "sun")
  await page.waitForSelector("#house-picture svg[data-scene=day][data-weather=sun]")
  assert.equal(await skyFill(), "rgb(217, 235, 248)")
  assert.equal(await paneFill(), "rgb(185, 220, 245)")
  await page.selectOption("#sky-form select[name=time]", "now")
  await page.selectOption("#sky-form select[name=weather]", "now")
  await page.waitForSelector("#sky-form option[value=now][selected]", { state: "attached" })

  // The share of the house (docs/design.md, "A shared house"): the sheet,
  // the picture of its preview, the box of the ZIP code, and the button.
  // Chromium on Linux has no share sheet, so the link goes into the
  // clipboard.
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: site })
  await page.click("#share-open")
  await page.waitForSelector("#share-sheet li:has-text('ZIP code 75070')")
  await page.waitForFunction(() => {
    const img = document.querySelector("#share-sheet img")
    return img.complete && img.naturalWidth === 1200 && img.naturalHeight === 630
  }, null, { timeout: 30000 })
  await check(page, `${name} share`)
  // A picture of a sunset with snow: the link and its picture change.
  const before = await page.inputValue("#share-link")
  await page.selectOption("#share-sky select[name=time]", "sunset")
  await page.selectOption("#share-sky select[name=weather]", "snow")
  await page.waitForFunction((before) => document.querySelector("#share-link").value !== before, before)
  await page.waitForFunction(() => {
    const img = document.querySelector("#share-sheet img")
    return img.complete && img.naturalWidth === 1200 && img.getAttribute("src").endsWith("/picture.png")
  }, null, { timeout: 30000 })
  await page.selectOption("#share-sky select[name=time]", "now")
  await page.selectOption("#share-sky select[name=weather]", "now")
  await page.waitForFunction((before) => document.querySelector("#share-link").value === before, before)
  await page.click("#share-zip input[type=checkbox]")
  await page.waitForFunction(() => !document.querySelector("#share-sheet").textContent.includes("ZIP code 75070"))
  await page.click("#share-zip input[type=checkbox]")
  await page.waitForSelector("#share-sheet li:has-text('ZIP code 75070')")
  const link = await page.inputValue("#share-link")
  assert.match(link, new RegExp(`^${site}/s/1[A-Za-z0-9_-]+$`))
  await page.click("#share-button")
  await page.waitForSelector("#share-status:has-text('The link is in the clipboard.')")
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), link)
  await page.click("#share-sheet [data-close]")
  await page.waitForSelector("#share-sheet", { state: "detached" })

  // The page of the link in a new tab, as a neighbor sees it. It has the
  // tags and the picture of the preview. The button asks first, because
  // this device has a house.
  const shared = await context.newPage()
  shared.on("pageerror", (error) => { faults++; console.log(`${name} shared: page error: ${error.message}`) })
  await shared.goto(link)
  await connected(shared)
  await shared.waitForSelector("#shared h1:has-text('A shared house')")
  const image = await shared.getAttribute('meta[property="og:image"]', "content")
  assert.equal(image, `${link}/picture.png`)
  const start = Date.now()
  const picture = await shared.request.get(image)
  console.log(`${name}: the picture of the link took ${Date.now() - start} ms`)
  assert.equal(picture.status(), 200)
  assert.equal(picture.headers()["content-type"], "image/png")
  await check(shared, `${name} shared house`)
  await shared.waitForSelector("#adopt:not([disabled])")
  await shared.click("#adopt")
  await shared.waitForSelector("#adopt-confirm")
  await check(shared, `${name} shared house, the question`)
  await shared.click("#adopt-cancel")
  await shared.waitForSelector("#adopt-confirm", { state: "detached" })
  await shared.close()

  await page.click("#go-in")
  await page.waitForSelector("#plan-svg")
  await page.click("#plan-hint button")
  await page.waitForSelector("#plan-hint", { state: "detached" })
  await check(page, `${name} rooms`)

  // The plan at scale: the person zooms to the first floor. A drag of the
  // AC, held at its top: its top is over the house, but its space stays
  // in the yard. So it moves in the yard, with no message.
  await page.click("button[data-focus=ground]")
  const ac = `g[data-item="${await itemId(page, "Central AC")}"]`
  const [acAt, acIn] = [await page.getAttribute(ac, "data-at"), await page.getAttribute(ac, "data-in")]
  const acBox = await page.locator(ac).boundingBox()
  await drag(page, { x: acBox.x + acBox.width / 2, y: acBox.y + 3 }, 10, 6)
  await page.waitForFunction(([s, at]) => document.querySelector(s).getAttribute("data-at") !== at, [ac, acAt])
    .catch(() => assert.fail(`${name}: the AC moves with a drag at its top`))
  assert.equal(await page.getAttribute(ac, "data-in"), acIn, `${name}: the AC stays in the yard`)
  assert.equal(await page.locator("#flash-error").count(), 0, `${name}: no message after the drag`)

  // The person zooms in, and drags the TV from the back wall to the middle
  // of the living room.
  await page.click("button[data-zoom=in]")
  const tv = `g[data-item="${await itemId(page, "TV")}"]`
  const tvAt = await page.getAttribute(tv, "data-at")
  await drag(page, center(await page.locator(tv).boundingBox()), -24, 40)
  await page.waitForFunction(([s, at]) => document.querySelector(s).getAttribute("data-at") !== at, [tv, tvAt])
    .catch(() => assert.fail(`${name}: the TV moves with a drag`))

  // A tap on the kitchen chooses it. The handle of its left wall moves the
  // wall.
  const kitchen = `polygon[data-room="${await roomId(page, "Kitchen")}"]`
  await page.mouse.click(...Object.values(center(await page.locator(kitchen).boundingBox())))
  await page.waitForSelector("#room-bar:has-text('Kitchen')")
  await check(page, `${name} room`)
  // The arrows of the bar go to the next room and back. The outline of
  // the new room is on the plan on the screen.
  await page.click("#room-next")
  await page.waitForSelector("#room-bar:has-text('Living room')")
  await page.waitForTimeout(300)
  const [screen, line] = [await page.locator("#plan-svg").boundingBox(), await page.locator("[data-outline]").boundingBox()]
  assert.ok(line.x >= screen.x - 1 && line.y >= screen.y - 1 && line.x + line.width <= screen.x + screen.width + 1 &&
    line.y + line.height <= screen.y + screen.height + 1, `${name}: the next room is on the screen`)
  await page.click("#room-before")
  await page.waitForSelector("#room-bar:has-text('Kitchen')")
  const plan = await page.getAttribute(kitchen, "data-plan")
  await drag(page, center(await page.locator('circle[data-handle="x0"]').boundingBox()), -26, -15)
  await page.waitForFunction(([s, p]) => document.querySelector(s).getAttribute("data-plan") !== p, [kitchen, plan])
    .catch(() => assert.fail(`${name}: the left wall of the kitchen moves with its handle`))
  // The living room is next to the kitchen. So the button that moves the
  // kitchen to it cannot move, but it keeps the focus, and the page says
  // why.
  await page.focus("#move-room-right")
  await page.keyboard.press("Enter")
  await page.waitForSelector("#flash-error")
  assert.equal(await page.evaluate(() => document.activeElement.id), "move-room-right",
    `${name}: the move button keeps the focus`)
  await page.click("#room-bar a[aria-label=Close]")
  await page.waitForSelector("#room-bar", { state: "detached" })

  // The list of the rooms: the arrow keys move the fridge, and a screen
  // reader hears where it is.
  const fridge = 'a[id^="item-"]:has-text("Fridge")'
  await page.focus(fridge)
  await page.keyboard.press("ArrowRight")
  await page.waitForSelector("#plan-status:has-text('Fridge:')", { state: "attached" })
  await check(page, `${name} list`)

  await page.keyboard.press("Enter")
  await page.waitForSelector("#item-stage [data-stage=landed]")
  await check(page, `${name} item`)
  // The panel scrolls to its place, its size and its turn. The width has
  // − and +, as a number of the item.
  await page.locator("#item-place").scrollIntoViewIfNeeded()
  await check(page, `${name} item place`)
  const width = Number(await page.inputValue("#size-w"))
  await page.click("#size-w-field button[phx-value-by='1']")
  await page.waitForFunction((w) => Number(document.querySelector("#size-w").value) > w, width)
  await page.waitForSelector("#item-said:has-text('Width:')", { state: "attached" })
  await page.click("#turn-item")

  // The stage keeps the focus, and the Escape key puts the item back. The
  // focus goes back to the item.
  const inSheet = () => page.evaluate(() => document.querySelector("#item-stage").contains(document.activeElement))
  for (let i = 0; i < 30; i++) {
    await page.keyboard.press(i % 3 === 0 ? "Shift+Tab" : "Tab")
    assert.ok(await inSheet(), `${name}: the focus stays on the stage`)
  }
  await page.keyboard.press("Escape")
  await page.waitForSelector("#item-stage", { state: "detached" })
  assert.match(await page.evaluate(() => document.activeElement.textContent), /Fridge/)
  await follow(page, fridge)
  await page.waitForSelector("#item-stage")
  await page.fill("#item-form input[name='item[kwh_year]']", "700")
  await page.waitForFunction(() => document.querySelector("#item-year")?.textContent.includes("700 kWh"))
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })

  // A tap on the fridge on the plan: it comes out of the house and turns to
  // the person. The frames of the flipbook change, and its panel shows.
  // With less motion, the fridge is at once in front.
  // The list of the rooms shows while it has the focus: first the focus
  // goes away, as with a tap on the page.
  await page.evaluate(() => document.activeElement?.blur())
  const fridgeId = await itemId(page, "Fridge")
  const spot = await page.locator(`#plan-item-${fridgeId}`).boundingBox()
  await page.mouse.click(spot.x + spot.width / 2, spot.y + spot.height / 2)
  await page.waitForSelector(`#item-stage-${fridgeId}`)
  if (!(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches))) {
    const shown = new Set()
    for (let i = 0; i < 15; i++) {
      shown.add(await page.evaluate(() =>
        [...document.querySelectorAll(".stage-frame")].findIndex((frame) => !frame.hasAttribute("hidden"))))
      await page.waitForTimeout(50)
    }
    assert.ok(shown.size > 3, `${name}: the frames change in the flight (${[...shown]})`)
  }
  await page.waitForSelector("#item-stage [data-stage=landed]")
  assert.equal(await page.evaluate(() =>
    [...document.querySelectorAll(".stage-frame")].findIndex((frame) => !frame.hasAttribute("hidden"))), 11)
  // The title of the panel takes the focus. A tap on the tag of the
  // EnergyGuide label goes to its number. A tap on + gives the next round
  // number: a patch, which keeps the state of the stage, and the panel
  // stays on the page.
  assert.equal(await page.evaluate(() => document.activeElement?.id), "item-stage-title")
  // Shift+Tab from the title goes to the last control of the dialog, and
  // up. The focus stays in the dialog, and the head of the panel does not
  // cover the control with the focus (WCAG 2.4.11).
  for (let i = 0; i < 8; i++) {
    await page.keyboard.press("Shift+Tab")
    const focus = await page.evaluate(() => {
      const el = document.activeElement
      const head = document.querySelector(".stage-head").getBoundingClientRect()
      const box = el.getBoundingClientRect()
      const under = el.closest(".stage-scroll") && !el.closest(".stage-head") ? box.top < head.bottom - 1 : false
      return { inside: Boolean(el.closest("#item-stage")), under, name: el.id || el.textContent.trim() }
    })
    assert.ok(focus.inside, `${name}: the focus stays in the dialog (${focus.name})`)
    assert.ok(!focus.under, `${name}: the head covers ${focus.name}`)
  }
  await page.click("#item-stage-spot-kwh_year")
  await page.waitForFunction(() => document.activeElement?.id === "param-kwh_year")
  await page.click("#param-kwh_year-field button[phx-value-by='1']")
  await page.waitForSelector("#item-year:has-text('750 kWh')")
  const placed = await page.evaluate(() => {
    const stage = document.querySelector("#item-stage [data-stage]")
    const box = stage.querySelector(".stage-panel").getBoundingClientRect()
    return { state: stage.dataset.stage, top: box.top, bottom: box.bottom, height: innerHeight }
  })
  assert.equal(placed.state, "landed")
  assert.ok(placed.top >= 0 && placed.bottom <= placed.height, `${name}: the panel is on the page (${JSON.stringify(placed)})`)
  await page.keyboard.press("Escape")
  await page.waitForSelector("#item-stage", { state: "detached" })

  // The list chooses a bedroom on floor 2: floor 2 comes, and floor 1
  // hides.
  await follow(page, `#choose-${await roomId(page, "Bedroom 1")}`)
  await page.waitForSelector("#room-bar:has-text('Bedroom 1')")
  await page.waitForSelector("#plan-svg[data-dim=f2]")
  await page.waitForSelector("button[data-focus=f2][aria-pressed=true]")
  await check(page, `${name} a room on floor 2`)
  await page.click("#room-bar a[aria-label=Close]")
  await page.waitForSelector("#room-bar", { state: "detached" })
  // The list opens the computer on floor 2 while floor 1 shows: floor 2
  // comes.
  await page.click("button[data-focus=ground]")
  await page.waitForSelector("#plan-svg[data-dim=ground]")
  await follow(page, 'a[id^="item-"]:has-text("Computer")')
  await page.waitForSelector("#item-stage")
  await page.waitForSelector("#plan-svg[data-dim=f2]")
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })

  await follow(page, 'a[id^="add-"][aria-label="Add an item to Kitchen"]')
  await page.waitForSelector("#add-sheet")
  await check(page, `${name} add`)
  await page.click("#add-freezer")
  await page.waitForSelector("#item-stage:has-text('Freezer')")
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })

  // A Home Assistant hub in the living room. Its screen opens the sign-in
  // in a new tab. The first tab stays on the hub. The light of the hub on
  // the plan shows the link.
  await follow(page, 'a[id^="add-"][aria-label="Add an item to Living room"]')
  await page.click("#add-home_assistant")
  await page.waitForSelector("#item-stage:has-text('Home Assistant hub') #ha-form")
  const hub = new URL(page.url()).searchParams.get("item")
  // The field of the address on the screen of the hub is wide enough to
  // read, on a phone and on a wide page. The whole screen is on the page.
  await page.waitForSelector("#item-stage [data-stage=landed]")
  const field = await page.$eval("#ha-url", (el) => el.getBoundingClientRect().width)
  assert.ok(field > 200, `the field of the address is ${field} px wide`)
  const led = await page.$eval("#item-stage-screen", (el) => {
    const box = el.getBoundingClientRect()
    return box.top >= 0 && box.left >= 0 && box.bottom <= innerHeight && box.right <= innerWidth
  })
  assert.ok(led, "the screen of the hub is on the page")
  await page.fill("#ha-form input[name=url]", homeAssistant.url + "/")
  const opened = page.context().waitForEvent("page")
  await page.click("#ha-form button")
  const tab = await opened
  const closed = new Promise((resolve) => tab.once("close", resolve))
  const visited = []
  tab.on("framenavigated", (frame) => { if (frame === tab.mainFrame()) visited.push(new URL(frame.url())) })
  await tab.waitForSelector("#log-in")
  // While the sign-in is in the new tab, the screen of the hub tells it,
  // and the panel can stop it.
  await page.waitForSelector("#ha-screen-state:has-text('Sign in to Home Assistant on the new tab.')")
  await page.waitForSelector("#ha-disconnect:has-text('Stop the sign-in')")
  await check(page, `${name} sign-in waits`)
  // The person signs in. The tab comes back to the sign-in page of the app
  // with the code. It keeps the tokens, tells the first tab, and closes.
  await tab.click("#log-in")
  await closed
  const back = visited.find((url) => url.pathname === "/ha/sign-in" && url.searchParams.has("code"))
  assert.ok(back, "the tab comes back to the sign-in page of the app")
  await page.waitForSelector("#item-stage #ha-status:has-text('Connected to Fake house (Home Assistant 2026.10.0)')")
  assert.equal(new URL(page.url()).search, `?item=${hub}`)
  await page.waitForSelector("#inside[data-ha=connected]")
  // The light on the pill of the hub is green. The test waits for it: a
  // patch of the page can come at the same time.
  await page.waitForFunction(
    (selector) => {
      const light = document.querySelector(selector)
      return light && getComputedStyle(light).fill === "rgb(34, 197, 94)"
    },
    `g.p-hub-label[data-item="${hub}"] .i-ha-light`,
  )
  await page.waitForSelector("#item-stage [data-stage=landed]")
  await check(page, `${name} Home Assistant`)

  // The match of the rooms, from the sheet of the hub. The living room is in
  // both. Patio and Guest Suite are only in Home Assistant: the app suggests
  // a place for each. Home Assistant adds the other rooms, with a new floor
  // for floor 2. (The first run adds them. The next runs find them.)
  await follow(page, "#ha-match")
  await page.waitForSelector("#ha-rooms-sheet #ha-rooms")
  await page.waitForSelector("#ha-both li:has-text('Living room')")
  assert.equal(await page.inputValue("select[name='ha[patio]']"), "outside outdoor")
  assert.equal(await page.inputValue("select[name='ha[guest_suite]']"), "f1 indoor")
  await check(page, `${name} match`)
  const newAreas = !homeAssistant.registry.areas.some((area) => area.name === "Kitchen")
  await page.click("#ha-rooms button")
  await page.waitForSelector(newAreas ? "#ha-sync:has-text('Home Assistant added')" : "#ha-sync")
  await page.waitForSelector("#ha-app h3:has-text('(0)')")
  await page.waitForSelector("#ha-ha h3:has-text('(0)')")
  await page.waitForSelector("#ha-both li:has-text('Guest Suite')")
  const area = (name) => homeAssistant.registry.areas.find((one) => one.name === name)
  const upstairs = homeAssistant.registry.floors.find((one) => one.level === 1)
  assert.equal(area("Kitchen").floor_id, "ground")
  assert.equal(area("Bedroom 1").floor_id, upstairs.floor_id)
  assert.equal(area("Garage").floor_id, null)
  assert.equal(homeAssistant.registry.areas.length, new Set(homeAssistant.registry.areas.map((one) => one.name)).size)

  // The ghosts of the devices. The ceiling lights and the TV are in the
  // living room. The fan and the station are on the patio (a room after
  // the match). One comes in with the keyboard (the list of the rooms).
  // One comes in with a tap on the plan.
  await page.goto(`${site}/inside`)
  await connected(page)
  await page.waitForSelector("#ha-ghosts:has-text('4 devices of Home Assistant are not in the house yet.')")
  assert.equal(await page.locator("#plan-svg g.p-ghost").count(), 4)
  // A ghost is pale and blue, with a dashed edge: not the colors of an
  // item. Its edge has a contrast of 3:1 at least on the floors.
  const look = await page.$eval("#plan-svg g.p-ghost polygon:not(.p-shadow)", (polygon) => {
    const style = getComputedStyle(polygon)
    return { stroke: style.stroke, dash: style.strokeDasharray }
  })
  assert.ok(["rgb(11, 51, 117)", "rgb(187, 222, 251)"].includes(look.stroke), `the edge of a ghost is ${look.stroke}`)
  assert.equal(look.dash, "3px, 2px")
  // On a hidden layer, the pill of a ghost takes no tap.
  const hidden = await page.evaluate(() => {
    const svg = document.getElementById("plan-svg")
    const pill = document.querySelector("#plan-ground .p-ghost-label text")
    const box = pill.getBoundingClientRect()
    const point = [box.x + box.width / 2, box.y + box.height / 2]
    const before = document.elementFromPoint(...point)?.closest("[data-ghost]") != null
    svg.setAttribute("data-dim", "f2")
    const after = document.elementFromPoint(...point)?.closest("[data-ghost]") != null
    svg.removeAttribute("data-dim")
    return { before, after }
  })
  assert.deepEqual(hidden, { before: true, after: false })
  await check(page, `${name} ghosts`)
  // Each run of the walk starts with the lights on.
  homeAssistant.set("light.ceiling", "on")
  await follow(page, "#plan-list button:has-text('Add Ceiling Lights from Home Assistant')")
  await page.waitForSelector("#item-stage #ha-device:has-text('This is Ceiling Lights in Home Assistant.')")
  await page.waitForSelector("#item-stage [data-stage=landed]")
  // The lights are on: the switch, the words, and the plan tell it.
  await page.waitForSelector("#ha-switch[role=switch][aria-checked=true]")
  await page.waitForSelector("#ha-power-state:has-text('It is on.')")
  await page.waitForSelector("#plan-svg g.p-item[data-ha=on]")
  await check(page, `${name} ghost item`)
  // The switch turns the lights off in Home Assistant.
  await page.click("#ha-switch")
  await page.waitForSelector("#ha-switch[aria-checked=false]")
  await page.waitForSelector("#ha-power-state:has-text('It is off.')")
  await page.waitForSelector("#plan-svg g.p-item[data-ha=off]")
  await page.waitForSelector("#item-stage .stage[data-ha=off]")
  assert.deepEqual(homeAssistant.calls.at(-1), { domain: "light", service: "turn_off", ids: ["light.ceiling"] })
  // A person turns them on in Home Assistant: the page follows.
  homeAssistant.set("light.ceiling", "on")
  await page.waitForSelector("#ha-switch[aria-checked=true]")
  // The keyboard: the switch keeps the focus.
  await page.focus("#ha-switch")
  await page.keyboard.press("Space")
  await page.waitForSelector("#ha-switch[aria-checked=false][aria-disabled=false]")
  assert.equal(await page.evaluate(() => document.activeElement?.id), "ha-switch")
  await check(page, `${name} switch`)
  // The energy that Home Assistant measured for the lights, next to the
  // estimate of the same months. This month is not over: it does not count.
  await page.waitForSelector("#ha-energy:has-text('Home Assistant measured 12 kWh in 1 month')")
  await page.waitForSelector("#ha-energy:has-text('The estimate for the same months')")
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })
  await page.waitForSelector('#plan-svg g.p-ghost[data-ghost="lights"]', { state: "detached" })
  // The largest face of the ghost of the TV, for a tap.
  const face = await page.evaluate(() => {
    const boxes = [...document.querySelectorAll('#plan-svg g.p-ghost[data-ghost="tv"] polygon')]
      .map((polygon) => polygon.getBoundingClientRect())
    const box = boxes.reduce((a, b) => (b.width * b.height > a.width * a.height ? b : a))
    return { x: box.x + box.width / 2, y: box.y + box.height / 2 }
  })
  await page.mouse.click(face.x, face.y)
  // The house has a TV of the preset: the panel tells that it can be the
  // same TV.
  await page.waitForSelector("#item-stage #ha-twin")
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })
  // The station of Pecron comes with its model, its numbers and its
  // outlets. Each run of the walk starts with the AC outlets on.
  homeAssistant.set("switch.station_ac", "on")
  await follow(page, "#plan-list button:has-text('Add Backup battery from Home Assistant')")
  await page.waitForSelector("#item-stage #item-stage-title:has-text('Pecron E3800LFP')")
  await page.waitForSelector("#item-stage [data-stage=landed]")
  await page.waitForSelector("#ha-battery:has-text('64%')")
  await page.waitForSelector("#ha-output:has-text('350 W')")
  await page.waitForSelector("#ha-input:has-text('Not known')")
  await page.waitForSelector("#ha-switch-ac[role=switch][aria-checked=true]")
  await page.waitForSelector("#ha-dc-state:has-text('It is off.')")
  assert.equal(await page.locator("#ha-switch").count(), 0)
  await check(page, `${name} station`)
  // The keyboard turns the AC outlets off: one call for their switch, and
  // the switch keeps the focus.
  await page.focus("#ha-switch-ac")
  await page.keyboard.press("Space")
  await page.waitForSelector("#ha-switch-ac[aria-checked=false][aria-disabled=false]")
  assert.equal(await page.evaluate(() => document.activeElement?.id), "ha-switch-ac")
  assert.deepEqual(homeAssistant.calls.at(-1), { domain: "switch", service: "turn_off", ids: ["switch.station_ac"] })
  // The battery changes in Home Assistant: the page follows.
  homeAssistant.set("sensor.station_battery", "63")
  await page.waitForSelector("#ha-battery:has-text('63%')")
  homeAssistant.set("sensor.station_battery", "64")
  // The station goes offline: the panel tells that the numbers are its
  // last numbers, and its switches do not work. The switch keeps the
  // focus.
  assert.equal(await page.locator("#ha-station-link").count(), 0)
  await page.focus("#ha-switch-ac")
  homeAssistant.set("binary_sensor.station_online", "off")
  await page.waitForSelector("#ha-station-link:has-text('These are its last numbers.')")
  await page.waitForSelector("#ha-switch-ac[aria-disabled=true]")
  await page.waitForSelector("#ha-ac-state:has-text('The last state was off.')")
  assert.equal(await page.evaluate(() => document.activeElement?.id), "ha-switch-ac")
  await check(page, `${name} station with no link`)
  await page.focus("#ha-switch-ac")
  homeAssistant.set("binary_sensor.station_online", "on")
  await page.waitForSelector("#ha-station-link", { state: "detached" })
  assert.equal(await page.evaluate(() => document.activeElement?.id), "ha-switch-ac")
  // The person disables the switch of the DC outlets in Home Assistant,
  // and Home Assistant restarts. The station has no DC switch now: only
  // the name of the part and its status.
  const dc = homeAssistant.registry.entities.find((entity) => entity.entity_id === "switch.station_dc")
  dc.disabled_by = "user"
  homeAssistant.disconnect()
  await page.waitForSelector("#ha-ac-state:has-text('The app has no link to Home Assistant now.')")
  homeAssistant.connect()
  await page.waitForSelector("#ha-switch-dc", { state: "detached" })
  await page.waitForSelector("#ha-dc-state:has-text('The app has no switch for it.')")
  await page.waitForSelector("#ha-ac-state:has-text('It is off.')")
  // The link to Home Assistant closes while the AC switch has the focus.
  // The DC outlets get no switch, and the AC switch keeps the focus. When
  // the link comes back, it keeps the focus again.
  await page.focus("#ha-switch-ac")
  homeAssistant.disconnect()
  await page.waitForSelector("#ha-ac-state:has-text('The app has no link to Home Assistant now.')")
  await page.waitForSelector("#ha-switch-ac[aria-disabled=true]")
  assert.equal(await page.locator("#ha-switch-dc").count(), 0)
  assert.equal(await page.locator("#ha-dc-state:has-text('The app has no switch for it.')").count(), 1)
  assert.equal(await page.evaluate(() => document.activeElement?.id), "ha-switch-ac")
  await check(page, `${name} station with no link to Home Assistant`)
  await page.focus("#ha-switch-ac")
  homeAssistant.connect()
  await page.waitForSelector("#ha-ac-state:has-text('It is off.')")
  await page.waitForSelector("#ha-switch-ac[aria-disabled=false]")
  assert.equal(await page.locator("#ha-switch-dc").count(), 0)
  assert.equal(await page.evaluate(() => document.activeElement?.id), "ha-switch-ac")
  dc.disabled_by = null
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })
  await page.waitForSelector("#ha-ghosts:has-text('1 device of Home Assistant is not in the house yet.')")

  // The meter of Home Assistant: the front of the house offers it. The
  // house gets a smart meter, and its real months.
  await page.goto(`${site}/`)
  await connected(page)
  await page.waitForSelector("#real:has-text('of usage from your meter')")
  await check(page, `${name} meter of Home Assistant`)
  await page.click("#use-ha-meter")
  await page.waitForSelector("#real-average")
  await page.goto(`${site}/estimate`)
  await connected(page)
  await page.waitForSelector("#real-months")
  // The person removes the meter: its real months go too. The walk later
  // adds a meter with a file.
  await page.goto(`${site}/inside`)
  await connected(page)
  await follow(page, '#plan-list a[id^="item-"]:has-text("Smart meter")')
  await page.waitForSelector("#item-stage #usage-months:has-text('Home Assistant')")
  await page.click("#ask-remove")
  await page.click("#delete-item")
  await page.waitForSelector("#item-stage", { state: "detached" })

  await page.goto(`${site}/inside?item=${hub}`)
  await connected(page)
  await page.waitForSelector("#item-stage #ha-status:has-text('Connected to Fake house')")

  const revoked = homeAssistant.revoked.length
  await page.click("#ha-disconnect")
  await page.waitForSelector("#ha-status:has-text('Not connected.')")
  await page.waitForSelector("#inside[data-ha=none]")
  // The hook does not wait for the revoke: wait for it here.
  for (let i = 0; i < 50 && homeAssistant.revoked.length === revoked; i++) {
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  assert.equal(homeAssistant.revoked.length, revoked + 1)
  assert.equal(homeAssistant.sessions.size, 0)
  await page.click("#item-stage .stage-back")
  await page.waitForSelector("#item-stage", { state: "detached" })
  // After the disconnect, no ghost.
  assert.equal(await page.locator("#plan-svg [data-ghost]").count(), 0)

  // The sign-in page that no tab of the app opened, for example from a link
  // of a different site. It does not leave the app, and tells the error.
  const lone = await page.context().newPage()
  const outside = []
  lone.on("request", (request) => { if (!request.url().startsWith(site)) outside.push(request.url()) })
  await lone.goto(`${site}/ha/sign-in?${new URLSearchParams({ url: homeAssistant.url, id: "x1" })}`)
  await lone.waitForSelector("#ha-error:has-text('Only the key Connect of the app can start a sign-in.')")
  await lone.waitForSelector("#ha-close")
  assert.equal(new URL(lone.url()).origin, new URL(site).origin)
  assert.deepEqual(outside, [])
  await check(lone, `${name} sign-in page`)
  await lone.close()

  await page.click("nav >> text=Bill")
  await page.waitForSelector("#months")
  await check(page, `${name} math`)

  await page.click("nav >> text=Settings")
  await page.waitForSelector("#settings")
  await check(page, `${name} settings`)

  // The direct link to Pecron, with no Home Assistant: the token stays on
  // the device, and the field goes empty. The cloud of Pecron is the stub
  // of the tests (DIY.Stubs.pecron/0).
  await page.waitForSelector("#pecron-status:has-text('Not connected.')")
  await page.fill("#pecron-form input[name=token]", "abc")
  await page.click("#pecron-form button")
  await page.waitForSelector("#pecron-error:has-text('A token of Pecron starts with phk_.')")
  if (stubs) {
    await page.fill("#pecron-form input[name=token]", "phk_walk")
    await page.click("#pecron-form button")
    await page.waitForSelector("#pecron-status:has-text('Connected to Pecron: 1 station.')")
    // The form goes: the status of the card has the focus.
    assert.equal(await page.evaluate(() => document.activeElement?.id), "pecron-status")
  }
  await check(page, `${name} Pecron`)

  // The direct link to EcoFlow: the page calls the cloud of EcoFlow (the
  // fake of the test, a route of the browser). Keys of the wrong form give
  // an error. The fields of the keys go empty.
  await page.waitForSelector("#ecoflow-status:has-text('Not connected.')")
  await page.fill("#ecoflow-form input[name=access_key]", "walk-access")
  await page.click("#ecoflow-form button")
  await page.waitForSelector("#ecoflow-error:has-text('Put the access key and the secret key')")
  // The keys are not keys of Europe: EcoFlow refuses them. The form comes
  // again with the region of the keys.
  await page.selectOption("#ecoflow-form select[name=region]", "europe")
  await page.fill("#ecoflow-form input[name=access_key]", "walk-access")
  await page.fill("#ecoflow-form input[name=secret_key]", "walk-secret")
  await page.click("#ecoflow-form button")
  await page.waitForSelector("#ecoflow-status:has-text('EcoFlow does not accept the keys.')")
  assert.equal(await page.inputValue("#ecoflow-form select[name=region]"), "europe")
  await page.selectOption("#ecoflow-form select[name=region]", "americas")
  await page.fill("#ecoflow-form input[name=access_key]", "walk-access")
  await page.fill("#ecoflow-form input[name=secret_key]", "walk-secret")
  await page.click("#ecoflow-form button")
  await page.waitForSelector("#ecoflow-status:has-text('Connected to EcoFlow: 1 station.')")
  await check(page, `${name} EcoFlow`)
  await page.fill("#settings-price input[name=price]", "12.5")
  await page.click("#settings-price button")
  await page.waitForSelector("text=the price that you gave")

  await page.waitForSelector("#device-status:has-text('Saved on this device')")

  // Settings has the card too, with a link to the hub.
  await page.waitForSelector("#ha-hub:has-text('Your hub is in Living room')")
  return page
}

// The first screens at 320 px in Spanish and in Vietnamese: the longer
// texts must not make the page wider than the screen (WCAG 1.4.10).
for (const [lang, zip] of [["es", "75070"], ["vi", "75070"]]) {
  const context = await browser.newContext({ viewport: { width: 320, height: 700 } })
  const page = await context.newPage()
  page.on("pageerror", (error) => { faults++; console.log(`320 px ${lang}: page error: ${error.message}`) })
  await page.goto(`${site}/language/${lang}?return=%2F`)
  await page.waitForSelector(`html[lang=${lang}] #door-planning`)
  await connected(page)
  await page.click("#door-planning")
  await page.fill("#zip", zip)
  await page.click("#zip-form button[type=submit]")
  await page.waitForSelector("#start-preset")
  const wide = await page.evaluate(() => document.documentElement.scrollWidth)
  assert.ok(wide <= 320, `320 px ${lang}: the page is ${wide} px wide`)
  await check(page, `320 px ${lang} preset`)
  await context.close()
}

// On a desktop, the person wants less motion: an item is at once on its
// stage. So the walk checks the flights and the way with less motion, and
// it is shorter.
for (const colorScheme of ["light", "dark"]) {
  for (const width of [390, 1280]) {
    const name = `${colorScheme}, ${width} px`
    const reducedMotion = width > 1000 ? "reduce" : "no-preference"
    const context = await browser.newContext({ colorScheme, reducedMotion, viewport: { width, height: 900 } })
    // The cloud of EcoFlow. The walk also records each request and each
    // message of the socket with a key of EcoFlow to the server of the
    // app. There must be none.
    const ecoflow = fakeEcoFlow()
    await context.route("https://api-a.ecoflow.com/**", ecoflow.route)
    // The cloud of Europe does not know the keys of the walk.
    await context.route("https://api-e.ecoflow.com/**", fakeEcoFlow({ accessKey: "walk-europe" }).route)
    const leaks = []
    const leaked = (text) => /walk-(access|secret)/.test(text ?? "")
    context.on("request", (request) => {
      if (request.url().startsWith(site) && [request.url(), request.postData(), JSON.stringify(request.headers())].some(leaked)) {
        leaks.push(request.url())
      }
    })
    context.on("page", (one) => one.on("websocket", (socket) => socket.on("framesent", ({ payload }) => {
      if (leaked(String(payload))) leaks.push(socket.url())
    })))
    const page = await build(context, name)

    // The build stays on the device: a reload shows it.
    await page.reload()
    await connected(page)
    await page.waitForSelector("#settings")
    assert.match(await page.inputValue("#settings-price input[name=price]"), /12.5/)

    // A second tab shows the build, and follows the changes of the first.
    const other = await context.newPage()
    await other.goto(site + "/inside")
    await connected(other)
    await other.waitForSelector("#inside")
    await page.goto(site + "/inside")
    await connected(page)
    await other.waitForSelector('a[id^="item-"]', { state: "attached" })
    const before = await other.$$eval('a[id^="item-"]', (items) => items.length)
    await follow(page, 'a[id^="add-"][aria-label="Add an item to Backyard"]')
    await page.click("#add-pool_pump")
    await other.waitForFunction((n) => document.querySelectorAll('a[id^="item-"]').length > n, before)
    await page.waitForSelector("#item-stage:has-text('Pool pump')")

    // A reconnect after the network goes down: the page restores the build.
    await context.setOffline(true)
    await page.waitForTimeout(1500)
    await context.setOffline(false)
    await page.waitForSelector(".phx-connected")
    // The new LiveView restores the build: the pool pump is there.
    await page.waitForSelector("#item-stage:has-text('Pool pump')")
    await page.click("#item-stage .stage-back")
    await page.waitForSelector("#item-stage", { state: "detached" })
    await page.click("nav >> text=House")
    await page.waitForSelector("#bill-average")

    // The real usage: the person adds the meter, and opens its file. The
    // file stays in the browser; the page gets the sums of the months.
    await page.click("#real >> text=Add the meter")
    await page.waitForSelector("#add-sheet")
    await page.click("#add-smart_meter")
    await page.waitForSelector("#usage-file")
    await check(page, `${name} meter`)
    await page.setInputFiles("#usage-file", { name: "IntervalMeterUsage.csv", mimeType: "text/csv", buffer: meterFile() })
    await page.waitForSelector("#usage-months:has-text('Smart Meter Texas: 12 months, from July 2024 to June 2025')")
    await page.click("#item-stage .stage-back")
    await page.waitForSelector("#item-stage", { state: "detached" })
    await page.click("nav >> text=Bill")
    await page.waitForSelector("#real-months")
    await page.waitForSelector("#fit")
    assert.match(await page.textContent("#inside-count"), /of 12 real months/)
    await check(page, `${name} real usage`)
    await page.click("nav >> text=House")
    assert.match(await page.textContent("#real-average"), /\$\d+/)

    // The station of Pecron from Home Assistant goes: the app uses Home
    // Assistant for it, so it has no direct link. The walk checks the
    // power with a station of its own.
    await page.click("nav >> text=Rooms")
    await page.waitForSelector("#inside")
    await follow(page, 'a[id^="item-"]:has-text("Pecron E3800LFP")')
    assert.equal(await page.locator("#maker-choices").count(), 0)
    await page.click("#ask-remove")
    await page.click("#delete-item")
    await page.waitForSelector("#item-stage", { state: "detached" })

    // A new station links to the DELTA Pro 3 of the account of EcoFlow: its
    // model, its numbers and its 12 V outlets. The keyboard turns its AC
    // outlets off: one command for 240 V and one for 120 V. The switch
    // waits for the station (3 seconds), then for the next poll. The keys
    // never go to the server of the app.
    await follow(page, 'a[id^="add-"][aria-label="Add an item to Laundry"]')
    await page.click("#add-power_station")
    await page.click("#maker-choices button:has-text('Garage EcoFlow (DELTA Pro 3)')")
    await page.waitForSelector("#item-stage #item-stage-title:has-text('EcoFlow DELTA Pro 3')")
    await page.waitForSelector("#ecoflow-battery:has-text('57%')")
    await page.waitForSelector("#ecoflow-output:has-text('2,310 W')")
    await page.waitForSelector("#ecoflow-dc-label:has-text('12 V outlets')")
    await page.waitForSelector("#ecoflow-switch-ac[aria-checked=true][aria-disabled=false]")
    await page.focus("#ecoflow-switch-ac")
    await page.keyboard.press("Space")
    await page.waitForSelector("#ecoflow-ac-state:has-text('EcoFlow turns it off.')")
    await page.waitForSelector("#ecoflow-switch-ac[aria-checked=false][aria-disabled=false]")
    assert.equal(await page.evaluate(() => document.activeElement?.id), "ecoflow-switch-ac")
    assert.deepEqual(ecoflow.calls.filter((call) => call.method === "PUT").map((call) => call.params.params),
      [{ cfgHvAcOutOpen: false }, { cfgLvAcOutOpen: false }])
    await check(page, `${name} EcoFlow station`)
    assert.deepEqual(leaks, [])
    // The item stays while the walk links a station of Pecron: so the
    // station of EcoFlow is not a choice there.
    await page.click("#item-stage .stage-back")
    await page.waitForSelector("#item-stage", { state: "detached" })

    // A new station links to the station of the account of Pecron: its
    // model, its numbers, and the keyboard turns its AC outlets. When the
    // relay does not answer, the switch keeps the focus.
    if (stubs) {
      await follow(page, 'a[id^="add-"][aria-label="Add an item to Laundry"]')
      await page.click("#add-power_station")
      await page.waitForSelector("#maker-choice-0:has-text('Backup battery (E3800LFP)')")
      // A long name of a station wraps at 320 px.
      assert.equal(await page.$eval("#maker-choice-0", (choice) => getComputedStyle(choice).whiteSpace), "normal")
      await page.click("#maker-choice-0")
      // The key goes away: the title of the part takes the focus.
      assert.equal(await page.evaluate(() => document.activeElement?.id), "part-maker-title")
      await page.waitForSelector("#item-stage #item-stage-title:has-text('Pecron E3800LFP')")
      // A long name of the station wraps in the notes of the part too.
      assert.equal(await page.$eval("#maker-notes", (notes) => getComputedStyle(notes).overflowWrap), "anywhere")
      await page.waitForSelector("#pecron-battery:has-text('82%')")
      await page.waitForSelector("#pecron-output:has-text('350 W')")
      const outlets = await page.getAttribute("#pecron-switch-ac", "aria-checked")
      await page.focus("#pecron-switch-ac")
      await page.keyboard.press("Space")
      await page.waitForSelector(`#pecron-switch-ac[aria-checked=${outlets === "true" ? "false" : "true"}][aria-disabled=false]`)
      assert.equal(await page.evaluate(() => document.activeElement?.id), "pecron-switch-ac")
      await check(page, `${name} Pecron station`)
      await page.route("**/relay/pecron/stations", (route) => route.abort())
      await page.keyboard.press("Space")
      await page.waitForSelector("#maker-notes #maker-offline")
      await page.waitForSelector("#pecron-switch-ac[aria-disabled=true]")
      assert.equal(await page.evaluate(() => document.activeElement?.id), "pecron-switch-ac")
      await check(page, `${name} Pecron station offline`)
      await page.unroute("**/relay/pecron/stations")
      // The page opens again with the panel of the station. Before the first
      // list, the key "Remove the link" has the focus. The list comes, and
      // the switches come above the key: the key keeps the focus.
      let release = null
      const held = new Promise((resolve) => { release = resolve })
      await page.route("**/relay/pecron/stations", async (route) => { await held; await route.continue() })
      await page.reload()
      await connected(page)
      await page.waitForSelector("#maker-unlink")
      assert.equal(await page.locator("#pecron-switch-ac").count(), 0)
      await page.focus("#maker-unlink")
      release()
      await page.waitForSelector("#pecron-switch-ac")
      assert.equal(await page.evaluate(() => document.activeElement?.id), "maker-unlink")
      await page.unroute("**/relay/pecron/stations")
      // The relay does not answer: the item has no choices. "Remove the
      // link" takes the part away, and the title of the panel takes the
      // focus.
      await page.route("**/relay/pecron/stations", (route) => route.abort())
      await page.focus("#pecron-switch-ac")
      await page.keyboard.press("Space")
      await page.waitForSelector("#maker-notes #maker-offline")
      await page.focus("#maker-unlink")
      await page.keyboard.press("Enter")
      await page.waitForSelector("#part-maker", { state: "detached" })
      await page.waitForFunction(() => document.activeElement?.id === "item-stage-title")
      await page.unroute("**/relay/pecron/stations")
      await page.click("#ask-remove")
      await page.click("#delete-item")
      await page.waitForSelector("#item-stage", { state: "detached" })
    }

    // The station of EcoFlow goes.
    await follow(page, 'a[id^="item-"]:has-text("EcoFlow DELTA Pro 3")')
    await page.click("#ask-remove")
    await page.click("#delete-item")
    await page.waitForSelector("#item-stage", { state: "detached" })

    // The power: a station in the laundry runs the fridge, and the person
    // plans panels on the roof.
    await page.click("nav >> text=Rooms")
    await page.waitForSelector("#inside")
    await follow(page, 'a[id^="add-"][aria-label="Add an item to Laundry"]')
    await page.click("#add-power_station")
    await page.waitForSelector("#item-stage:has-text('Power station')")
    await page.click("#item-stage .stage-back")
    await page.waitForSelector("#item-stage", { state: "detached" })

    // The wires: a busbar next to the station, and a wire from the station
    // on 48 V. The page tells the rules of the NEC, and a fault.
    await follow(page, 'a[id^="add-"][aria-label="Add an item to Laundry"]')
    await page.click("#add-dc_bus")
    await page.waitForSelector("#item-stage:has-text('DC busbar or distributor')")
    await page.click("#item-stage .stage-back")
    await page.waitForSelector("#item-stage", { state: "detached" })
    await follow(page, 'a[id^="item-"]:has-text("Power station")')
    await page.selectOption("#wire-to", { label: "DC busbar or distributor, in Laundry" })
    await page.click("#add-wire-button")
    await page.waitForSelector(".wire-advice:has-text('Wire: 8 AWG copper or larger')")
    await page.selectOption(".wire select[name='wire[system]']", "48")
    await page.waitForSelector(".wire-advice:has-text('58.4 V or more')")
    await page.selectOption(".wire select[name='wire[awg]']", "10")
    await page.waitForSelector(".wire-faults:has-text('The wire is too small')")
    await page.waitForSelector("#item-stage [data-stage=landed]")
    await check(page, `${name} wire`)
    // The current comes from the busbar, and then from the station again.
    // The choices keep their values: the second click works too.
    await page.click(".wire .stage-choice:has-text('DC busbar or distributor')")
    await page.waitForSelector(".wire-title:has-text('DC busbar or distributor to Power station')")
    await page.click(".wire .stage-choice:has-text('Power station')")
    await page.waitForSelector(".wire-title:has-text('Power station to DC busbar or distributor')")
    await page.waitForSelector(".wire .stage-choice:has-text('Power station') input:checked")
    await page.click("#item-stage .stage-back")
    await page.waitForSelector("#item-stage", { state: "detached" })
    await follow(page, 'a[id^="item-"]:has-text("Fridge")')
    await page.check("#flags-form input[name=backup][type=checkbox]")
    await page.waitForSelector("#flags-form input[name=backup]:checked")
    await page.click("#item-stage .stage-back")
    // The text of the list changes before the stage closes: so the test
    // waits for the two.
    await page.waitForSelector("#item-stage", { state: "detached" })
    await page.waitForSelector('a[id^="item-"]:has-text("on the station")', { state: "attached" })
    await follow(page, 'a[id^="add-"][aria-label="Add an item to Roof"]')
    await page.click("#add-solar_panels")
    await page.waitForSelector("#item-stage:has-text('Solar panels')")
    await page.check("#flags-form input[name=planned][type=checkbox]")
    await page.waitForSelector('#item-stage:has-text("Solar panels")')
    await page.waitForSelector("#flags-form input[name=planned]:checked")
    await page.waitForSelector("#item-stage [data-stage=landed]")
    await check(page, `${name} planned item`)
    await page.click("#item-stage .stage-back")
    await page.waitForSelector("#item-stage", { state: "detached" })
    await page.waitForSelector('a[id^="item-"]:has-text("a plan")', { state: "attached" })

    // The page Bill with a planned item: the house of today, and a note.
    await page.click("nav >> text=Bill")
    await page.waitForSelector("#planned-note")
    await page.waitForSelector("#items")

    await page.click("nav >> text=Power")
    await page.waitForSelector("#plan")
    await page.waitForSelector("#outage")
    assert.match(
      await page.textContent("#payback"),
      /The planned equipment (saves \$[\d,]+ in one year[:.] [Ii]t pays back in|saves no money|does not pay back: it costs)/,
    )
    await check(page, `${name} power`)
    await page.click("nav >> text=House")
    await page.waitForSelector("#whatif-card")
    await check(page, `${name} front with a plan`)
    // A tap on the house goes in.
    await page.click("#house-picture")
    await page.waitForSelector("#plan-svg")

    // A station that is too small for its items: the warning.
    await page.click("nav >> text=Rooms")
    await follow(page, 'a[id^="item-"]:has-text("Power station")')
    await page.fill("#item-form input[name='item[output_w]']", "100")
    await page.press("#item-form input[name='item[output_w]']", "Tab")
    await page.waitForFunction(() => document.querySelector("#item-form input[name='item[output_w]']").value === "100")
    await page.click("#item-stage .stage-back")
    await page.waitForSelector("#item-stage", { state: "detached" })
    await page.click("nav >> text=Power")
    await page.waitForSelector("#today-overload")
    await check(page, `${name} power with an overload`)

    await lesson(page, name)
    await van(page, name)
    await pool(page, name)

    await context.close()
  }
}

await browser.close()
homeAssistant.close()
if (faults > 0) {
  console.log(`${faults} faults.`)
  process.exit(1)
}
console.log("ok")
