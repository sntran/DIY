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

const require = createRequire(import.meta.url)
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright-core")
const axe = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8")
const tags = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa", "best-practice"]
const site = process.argv[2] ?? "http://localhost:4002"

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM })
let faults = 0

// A fake Home Assistant on this computer (test/browser/fake_ha.mjs).
const homeAssistant = await fakeHomeAssistant()

// axe on the page as it is now.
async function check(page, name) {
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
  await page.waitForSelector("#item-sheet:has-text('Camper van')")
  await page.click("#open-van")
  await page.waitForSelector("#van-weight")
  assert.match(await page.textContent("#weight-total"), /of 8,900 lb/)
  await check(page, `${name} van`)

  // The list of the zones is for a keyboard, as the list of the rooms.
  await follow(page, 'a[id^="add-"][aria-label="Add an item to Galley"]')
  await page.waitForSelector("#add-sheet")
  await check(page, `${name} van add`)
  await page.click("#add-van_fridge")
  await page.waitForSelector("#item-sheet:has-text('12 V fridge')")
  await check(page, `${name} van item`)
  await page.click("#item-sheet .btn-ghost[aria-label=Close]")
  await page.waitForSelector("#item-sheet", { state: "detached" })
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
  await page.waitForSelector("#item-sheet:has-text('Insulation')")
  await page.click("#item-sheet .btn-ghost[aria-label=Close]")
  await page.waitForSelector("#item-sheet", { state: "detached" })
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
  await page.waitForSelector("#house-picture svg.cutaway-outside .p-chip-text:has-text('Grid')")
  assert.equal(
    await page.$eval("#house-picture .p-flow", (path) => getComputedStyle(path).animationIterationCount),
    "5",
  )

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
  await page.waitForSelector("#item-sheet")
  await check(page, `${name} item`)
  await page.click("#turn-item")

  // The sheet keeps the focus, and the Escape key closes it. The focus goes
  // back to the item.
  const inSheet = () => page.evaluate(() => document.querySelector("#item-sheet").contains(document.activeElement))
  for (let i = 0; i < 30; i++) {
    await page.keyboard.press(i % 3 === 0 ? "Shift+Tab" : "Tab")
    assert.ok(await inSheet(), `${name}: the focus stays in the sheet`)
  }
  await page.keyboard.press("Escape")
  await page.waitForSelector("#item-sheet", { state: "detached" })
  assert.match(await page.evaluate(() => document.activeElement.textContent), /Fridge/)
  await follow(page, fridge)
  await page.waitForSelector("#item-sheet")
  await page.fill("#item-form input[name='item[kwh_year]']", "700")
  await page.waitForFunction(() => document.querySelector("#item-math")?.textContent.includes("700 kWh"))
  await page.click("#item-sheet .btn-ghost[aria-label=Close]")
  await page.waitForSelector("#item-sheet", { state: "detached" })

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
  await page.waitForSelector("#item-sheet")
  await page.waitForSelector("#plan-svg[data-dim=f2]")
  await page.click("#item-sheet .btn-ghost[aria-label=Close]")
  await page.waitForSelector("#item-sheet", { state: "detached" })

  await follow(page, 'a[id^="add-"][aria-label="Add an item to Kitchen"]')
  await page.waitForSelector("#add-sheet")
  await check(page, `${name} add`)
  await page.click("#add-freezer")
  await page.waitForSelector("#item-sheet:has-text('Freezer')")
  await page.click("#item-sheet .btn-ghost[aria-label=Close]")
  await page.waitForSelector("#item-sheet", { state: "detached" })

  await page.click("nav >> text=Bill")
  await page.waitForSelector("#months")
  await check(page, `${name} math`)

  await page.click("nav >> text=Settings")
  await page.waitForSelector("#settings")
  await check(page, `${name} settings`)
  await page.fill("#settings-price input[name=price]", "12.5")
  await page.click("#settings-price button")
  await page.waitForSelector("text=the price that you gave")

  await page.waitForSelector("#device-status:has-text('Saved on this device')")

  // Home Assistant: the sign-in on its page, the socket, and the
  // disconnect. The code of the sign-in does not stay in the address.
  await page.fill("#ha-form input[name=url]", homeAssistant.url + "/")
  await page.click("#ha-form button")
  await page.waitForSelector("#ha-status:has-text('Connected to Fake house (Home Assistant 2026.10.0)')")
  assert.equal(new URL(page.url()).search, "")
  await check(page, `${name} Home Assistant`)
  const revoked = homeAssistant.revoked.length
  await page.click("#ha-disconnect")
  await page.waitForSelector("#ha-status:has-text('Not connected.')")
  // The hook does not wait for the revoke: wait for it here.
  for (let i = 0; i < 50 && homeAssistant.revoked.length === revoked; i++) {
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  assert.equal(homeAssistant.revoked.length, revoked + 1)
  assert.equal(homeAssistant.sessions.size, 0)
  return page
}

for (const colorScheme of ["light", "dark"]) {
  for (const width of [390, 1280]) {
    const name = `${colorScheme}, ${width} px`
    const context = await browser.newContext({ colorScheme, viewport: { width, height: 900 } })
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
    await page.waitForSelector("#item-sheet:has-text('Pool pump')")

    // A reconnect after the network goes down: the page restores the build.
    await context.setOffline(true)
    await page.waitForTimeout(1500)
    await context.setOffline(false)
    await page.waitForSelector(".phx-connected")
    // The new LiveView restores the build: the pool pump is there.
    await page.waitForSelector("#item-sheet:has-text('Pool pump')")
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.waitForSelector("#item-sheet", { state: "detached" })
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
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.waitForSelector("#item-sheet", { state: "detached" })
    await page.click("nav >> text=Bill")
    await page.waitForSelector("#real-months")
    await page.waitForSelector("#fit")
    assert.match(await page.textContent("#inside-count"), /of 12 real months/)
    await check(page, `${name} real usage`)
    await page.click("nav >> text=House")
    assert.match(await page.textContent("#real-average"), /\$\d+/)

    // The power: a station in the laundry runs the fridge, and the person
    // plans panels on the roof.
    await page.click("nav >> text=Rooms")
    await page.waitForSelector("#inside")
    await follow(page, 'a[id^="add-"][aria-label="Add an item to Laundry"]')
    await page.click("#add-power_station")
    await page.waitForSelector("#item-sheet:has-text('Power station')")
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.waitForSelector("#item-sheet", { state: "detached" })
    await follow(page, 'a[id^="item-"]:has-text("Fridge")')
    await page.check("#flags-form input[name=backup][type=checkbox]")
    await page.waitForSelector("#flags-form input[name=backup]:checked")
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    // The text of the list changes before the sheet closes: so the test
    // waits for the two.
    await page.waitForSelector("#item-sheet", { state: "detached" })
    await page.waitForSelector('a[id^="item-"]:has-text("on the station")', { state: "attached" })
    await follow(page, 'a[id^="add-"][aria-label="Add an item to Roof"]')
    await page.click("#add-solar_panels")
    await page.waitForSelector("#item-sheet:has-text('Solar panels')")
    await page.check("#flags-form input[name=planned][type=checkbox]")
    await page.waitForSelector('#item-sheet:has-text("Solar panels")')
    await page.waitForSelector("#flags-form input[name=planned]:checked")
    await check(page, `${name} planned item`)
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.waitForSelector("#item-sheet", { state: "detached" })
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
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.waitForSelector("#item-sheet", { state: "detached" })
    await page.click("nav >> text=Power")
    await page.waitForSelector("#today-overload")
    await check(page, `${name} power with an overload`)

    await lesson(page, name)
    await van(page, name)

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
