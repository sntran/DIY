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

const require = createRequire(import.meta.url)
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright-core")
const axe = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8")
const tags = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa", "best-practice"]
const site = process.argv[2] ?? "http://localhost:4002"

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM })
let faults = 0

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

// True when an element is at the center of its row (a room), or at the top
// of #levels (a level): the snap of the swipe.
function snapped([selector, axis]) {
  const el = document.querySelector(selector)
  const box = el.getBoundingClientRect()
  const parent = el.parentElement.getBoundingClientRect()
  return axis === "x"
    ? Math.abs(box.left + box.width / 2 - (parent.left + parent.width / 2)) < 2
    : Math.abs(box.top - document.querySelector("#levels").getBoundingClientRect().top) < 2
}

// Waits until #levels and its rows do not scroll for 15 frames: the end of
// a smooth scroll and of its snap. A step before that end can lose to it.
async function still(page) {
  await page.evaluate(() => new Promise((resolve) => {
    const levels = document.querySelector("#levels")
    const rows = [...levels.querySelectorAll(".snap-x")]
    const now = () => [levels.scrollTop, ...rows.map((row) => row.scrollLeft)].join()
    let last = now()
    let frames = 0
    const tick = () => {
      const next = now()
      if (next !== last) {
        last = next
        frames = 0
      } else if (++frames >= 15) {
        return resolve()
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  }))
}

// The place of #levels and of the hash, for the message of a fault.
async function where(page) {
  return page.evaluate(() => `scrollTop ${document.querySelector("#levels").scrollTop}, hash "${location.hash}"`)
}

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
  assert.equal(await page.locator("#efl-check td:has-text('✓')").count(), 3)
  await page.setInputFiles("#efl-file", "test/fixtures/efl/txu-smart-1000-select-12.pdf")
  await page.waitForSelector("#efl-result:has-text('txu-smart-1000-select-12')")
  assert.equal(await page.locator("#efl-check td:has-text('✓')").count(), 3)
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
  await page.click("#start-preset")

  await page.waitForSelector("#bill-average")
  assert.match(await page.textContent("#bill-average"), /\$\d+/)
  // The market comes from Power to Choose after the bill: on the Worker,
  // from the real service, so it can take some seconds.
  await page.waitForSelector("#market:has-text('Oncor')", { timeout: 30000 })
  await check(page, `${name} front`)

  await page.click("#go-in")
  await page.waitForSelector("#inside")

  // The rooms start at the first floor, and stay there after a change.
  // (Before axe: axe scrolls the containers of the page.)
  await page.waitForFunction(() => document.querySelector("#levels").scrollTop > 0, null, { timeout: 3000 })
    .catch(() => assert.fail("the rooms start at the first floor"))
  const start = await page.$eval("#levels", (el) => el.scrollTop)
  await page.click("#swipe-hint button")
  await page.waitForSelector("#swipe-hint", { state: "detached" })
  assert.equal(await page.$eval("#levels", (el) => el.scrollTop), start, "the rooms stay at the first floor")
  await check(page, `${name} rooms`)

  // A swipe to the left goes to the next room: the row snaps to it. (A
  // swipe that is shorter than half of a room snaps back.)
  await still(page)
  const rooms = await page.$$eval("#level-f1 article[id^=room-]", (els) => els.map((el) => `#${el.id}`))
  const first = await page.$eval(rooms[0], (el) => el.getBoundingClientRect())
  await page.mouse.move(first.x + first.width / 2, first.y + first.height / 2)
  await page.mouse.wheel(300, 0)
  await page.waitForFunction(snapped, [rooms[1], "x"], { timeout: 5000 })
    .catch(async () => assert.fail(`${name}: a swipe to the left snaps to the next room (${await where(page)})`))
  await still(page)

  // A swipe up goes to the level below: #levels snaps to it.
  await page.mouse.wheel(0, 600)
  await page.waitForFunction(snapped, ["#level-outside", "y"], { timeout: 5000 })
    .catch(async () => assert.fail(`${name}: a swipe up snaps to the level below (${await where(page)})`))
  await still(page)

  // The links do the same for a keyboard.
  await page.focus('#level-outside a[aria-label="The level above"]')
  await page.keyboard.press("Enter")
  await page.waitForFunction(snapped, ["#level-f1", "y"], { timeout: 5000 })
    .catch(async () => assert.fail(`${name}: the link goes to the level above (${await where(page)})`))
  await still(page)

  await page.click('a[id^="item-"]:has-text("Fridge")')
  await page.waitForSelector("#item-sheet")
  await check(page, `${name} item`)

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
  await page.click('a[id^="item-"]:has-text("Fridge")')
  await page.waitForSelector("#item-sheet")
  await page.fill("#item-form input[name='item[kwh_year]']", "700")
  await page.waitForFunction(() => document.querySelector("#item-math")?.textContent.includes("700 kWh"))
  await page.click("#item-sheet .btn-ghost[aria-label=Close]")
  await page.waitForSelector("#item-sheet", { state: "detached" })

  await page.click('a[id^="add-"][aria-label="Add an item to Kitchen"]')
  await page.waitForSelector("#add-sheet")
  await check(page, `${name} add`)
  await page.click("#add-freezer")
  await page.waitForSelector("#item-sheet:has-text('Freezer')")
  await page.click("#item-sheet .btn-ghost[aria-label=Close]")

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
    await other.waitForSelector('a[id^="item-"]')
    const before = await other.$$eval('a[id^="item-"]', (items) => items.length)
    await page.click('a[aria-label="Add an item to Backyard"]')
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
    await page.click('a[aria-label="Add an item to Laundry"]')
    await page.click("#add-power_station")
    await page.waitForSelector("#item-sheet:has-text('Power station')")
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.waitForSelector("#item-sheet", { state: "detached" })
    await page.click('a[id^="item-"]:has-text("Fridge")')
    await page.check("#flags-form input[name=backup][type=checkbox]")
    await page.waitForSelector("#flags-form input[name=backup]:checked")
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.waitForSelector('a[id^="item-"]:has-text("On the station")')
    await page.click('a[aria-label="Add an item to Roof"]')
    await page.click("#add-solar_panels")
    await page.waitForSelector("#item-sheet:has-text('Solar panels')")
    await page.check("#flags-form input[name=planned][type=checkbox]")
    await page.waitForSelector('#item-sheet:has-text("Solar panels")')
    await page.waitForSelector("#flags-form input[name=planned]:checked")
    await check(page, `${name} planned item`)
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.waitForSelector('a[id^="item-"]:has-text("Plan")')

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

    // A station that is too small for its items: the warning.
    await page.click("nav >> text=Rooms")
    await page.click('a[id^="item-"]:has-text("Power station")')
    await page.fill("#item-form input[name='item[output_w]']", "100")
    await page.press("#item-form input[name='item[output_w]']", "Tab")
    await page.waitForFunction(() => document.querySelector("#item-form input[name='item[output_w]']").value === "100")
    await page.click("#item-sheet .btn-ghost[aria-label=Close]")
    await page.click("nav >> text=Power")
    await page.waitForSelector("#today-overload")
    await check(page, `${name} power with an overload`)

    await lesson(page, name)

    await context.close()
  }
}

await browser.close()
if (faults > 0) {
  console.log(`${faults} faults.`)
  process.exit(1)
}
console.log("ok")
