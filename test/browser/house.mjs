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
  await check(page, `${name} doors`)
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
  assert.match(await page.textContent("#market"), /Oncor/)
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

  await page.click('a[id^="item-"]:has-text("Fridge")')
  await page.waitForSelector("#item-sheet")
  await check(page, `${name} item`)
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

    await context.close()
  }
}

await browser.close()
if (faults > 0) {
  console.log(`${faults} faults.`)
  process.exit(1)
}
console.log("ok")
