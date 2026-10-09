// The tests of assets/js/top.js: a new page starts at its top.
import {test} from "node:test"
import assert from "node:assert/strict"
import {topHook} from "../../assets/js/top.js"

test("a new page goes to the top; the same page keeps its scroll", () => {
  const scrolls = []
  const attrs = {"data-page": "front::"}
  const el = {
    getAttribute: (name) => attrs[name],
    ownerDocument: {defaultView: {scrollTo: (x, y) => scrolls.push([x, y])}},
  }
  const hook = Object.assign({el}, topHook)
  hook.mounted()
  hook.updated()
  assert.deepEqual(scrolls, [])
  attrs["data-page"] = "inside::"
  hook.updated()
  assert.deepEqual(scrolls, [[0, 0]])
  hook.updated()
  assert.deepEqual(scrolls, [[0, 0]])
})
