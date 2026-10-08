// The tests of assets/js/scroll.js.
import {test} from "node:test"
import assert from "node:assert/strict"
import {scrollHook} from "../../assets/js/scroll.js"

const element = (start, found) => ({
  dataset: {start},
  scrollTop: 10,
  getBoundingClientRect: () => ({top: 100}),
  querySelector(selector) {
    assert.equal(selector, `#${start}`)
    return found ? {getBoundingClientRect: () => ({top: 400})} : null
  },
})

test("the rooms start at the level of the data", () => {
  const el = element("level-f1", true)
  Object.assign({el}, scrollHook).mounted()
  assert.equal(el.scrollTop, 310)
})

test("a level that is not there changes nothing", () => {
  const el = element("level-f9", false)
  Object.assign({el}, scrollHook).mounted()
  assert.equal(el.scrollTop, 10)
})
