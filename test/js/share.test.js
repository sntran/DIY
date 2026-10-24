// The tests of assets/js/share.js: the share of the link of a house.
import {test} from "node:test"
import assert from "node:assert/strict"
import {shareHook, share} from "../../assets/js/share.js"

// A button of the share, with its document and its window.
function button(navigator) {
  const status = {textContent: ""}
  const listeners = {}
  const attrs = {
    "data-path": "/s/1abc",
    "data-title": "A house",
    "data-copied": "The link is in the clipboard.",
    "data-failed": "Copy the link from the box.",
    "data-status": "share-status",
  }
  const el = {
    getAttribute: (name) => attrs[name],
    addEventListener: (event, fn) => (listeners[event] = fn),
    ownerDocument: {
      getElementById: (id) => (id === "share-status" ? status : null),
      defaultView: {location: {origin: "https://diy.example"}, navigator},
    },
  }
  return {el, status, listeners}
}

test("a phone opens its share sheet with the full link", async () => {
  const shared = []
  const {el, status} = button({share: async (data) => shared.push(data)})
  assert.equal(await share(el), "shared")
  assert.deepEqual(shared, [{title: "A house", url: "https://diy.example/s/1abc"}])
  assert.equal(status.textContent, "")
})

test("a person who closes the share sheet gets no message", async () => {
  const abort = Object.assign(new Error("closed"), {name: "AbortError"})
  const {el, status} = button({share: async () => Promise.reject(abort)})
  assert.equal(await share(el), "closed")
  assert.equal(status.textContent, "")
})

test("with no share sheet, the link goes into the clipboard", async () => {
  const copied = []
  const {el, status} = button({clipboard: {writeText: async (text) => copied.push(text)}})
  assert.equal(await share(el), "copied")
  assert.deepEqual(copied, ["https://diy.example/s/1abc"])
  assert.equal(status.textContent, "The link is in the clipboard.")
})

test("a share sheet that fails gives the clipboard", async () => {
  const copied = []
  const {el} = button({
    share: async () => Promise.reject(new Error("not allowed")),
    clipboard: {writeText: async (text) => copied.push(text)},
  })
  assert.equal(await share(el), "copied")
  assert.deepEqual(copied, ["https://diy.example/s/1abc"])
})

test("a share sheet that fails with no reason gives the clipboard", async () => {
  const copied = []
  const {el} = button({
    share: async () => Promise.reject(undefined),
    clipboard: {writeText: async (text) => copied.push(text)},
  })
  assert.equal(await share(el), "copied")
  assert.equal(copied.length, 1)
})

test("with no clipboard, the status tells the person to copy the link", async () => {
  const {el, status} = button({})
  assert.equal(await share(el), "failed")
  assert.equal(status.textContent, "Copy the link from the box.")
})

test("the hook shares at a click", async () => {
  const copied = []
  const {el, listeners} = button({clipboard: {writeText: async (text) => copied.push(text)}})
  const hook = Object.assign({el}, shareHook)
  hook.mounted()
  await listeners.click()
  assert.deepEqual(copied, ["https://diy.example/s/1abc"])
})
