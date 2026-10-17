// The tests of assets/js/ecoflow.js. They check the signature of a
// request, the stations of an account and their parts, and the controls.
// A fake EcoFlow checks each signature.
import {test} from "node:test"
import assert from "node:assert/strict"
import {createHmac} from "node:crypto"
import fc from "fast-check"
import {
  HOSTS, LIST, QUOTA, SET, MAX_POWER, MAX_DEVICES, KEY_ERRORS, FAMILIES, family, flatten, signText, hmac,
  stationParts, ecoflowCloud,
} from "../../assets/js/ecoflow.js"

const subtle = globalThis.crypto.subtle
const KEYS = {region: "americas", accessKey: "AK1", secretKey: "SK1"}

test("the hosts, the paths and the limits", () => {
  assert.deepEqual(HOSTS, {americas: "https://api-a.ecoflow.com", europe: "https://api-e.ecoflow.com"})
  assert.equal(LIST, "/iot-open/sign/device/list")
  assert.equal(QUOTA, "/iot-open/sign/device/quota/all")
  assert.equal(SET, "/iot-open/sign/device/quota")
  assert.equal(MAX_POWER, 1_000_000)
  assert.equal(MAX_DEVICES, 100)
  assert.deepEqual(KEY_ERRORS, ["8513", "8521", "8524"])
})

test("the parameters become one level, and the text of the signature has their order", () => {
  assert.deepEqual(flatten({sn: "S", params: {cmdSet: 32, id: 66, list: [1, {a: 2}]}, on: true}), {
    sn: "S", "params.cmdSet": 32, "params.id": 66, "params.list[0]": 1, "params.list[1].a": 2, on: true,
  })
  assert.deepEqual(flatten({}), {})
  // The body of a control of a DELTA Pro 3, as the clients of EcoFlow sign
  // it. First come the keys in order, then the keys of the account.
  const body = {sn: "MR51", cmdId: 17, dirDest: 1, dirSrc: 1, cmdFunc: 254, dest: 2, needAck: true, params: {cfgHvAcOutOpen: false}}
  assert.equal(signText(body, "AK", "77", "1700000000000"),
    "cmdFunc=254&cmdId=17&dest=2&dirDest=1&dirSrc=1&needAck=true&params.cfgHvAcOutOpen=false&sn=MR51" +
    "&accessKey=AK&nonce=77&timestamp=1700000000000")
  assert.equal(signText(null, "AK", "1", "2"), "accessKey=AK&nonce=1&timestamp=2")
  assert.equal(signText({sn: "S1"}, "AK", "1", "2"), "sn=S1&accessKey=AK&nonce=1&timestamp=2")
})

test("the signature is HMAC-SHA256 in hex, as node:crypto gives it", async () => {
  assert.equal(await hmac(subtle, "key", "The quick brown fox jumps over the lazy dog"),
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
  await fc.assert(fc.asyncProperty(fc.string({minLength: 1}), fc.string(), async (secret, text) => {
    assert.equal(await hmac(subtle, secret, text), createHmac("sha256", secret).update(text).digest("hex"))
  }), {numRuns: 100})
})

test("the order of the keys does not change the text", () => {
  const key = fc.stringMatching(/^[a-zA-Z][a-zA-Z0-9]{0,6}$/)
  // The values have no "&" and no "=", so that the test can split the text.
  const text = fc.stringMatching(/^[a-zA-Z0-9 ._-]*$/)
  fc.assert(fc.property(fc.dictionary(key, fc.oneof(fc.integer(), fc.boolean(), text)), (params) => {
    const reversed = Object.fromEntries(Object.entries(params).reverse())
    const text = signText(params, "A", "N", "T")
    assert.equal(signText(reversed, "A", "N", "T"), text)
    const keys = text.split("&").slice(0, -3).map((pair) => pair.split("=")[0])
    assert.deepEqual(keys, [...keys].sort())
  }))
})

test("the family of a product name", () => {
  assert.deepEqual(Object.keys(FAMILIES), ["deltapro", "deltapro3", "deltaproultra"])
  assert.equal(family("DELTA Pro"), "deltapro")
  assert.equal(family("Delta Pro 3"), "deltapro3")
  assert.equal(family("DELTA_PRO_3"), "deltapro3")
  assert.equal(family("DELTA Pro Ultra"), "deltaproultra")
  for (const other of ["DELTA Pro Ultra X", "DELTA 2", "Smart Plug", "constructor", "", null, 5]) {
    assert.equal(family(other), null)
  }
})

test("the parts of each family from the state of a station", () => {
  assert.deepEqual(stationParts("deltapro", {
    "ems.lcdShowSoc": 82, "pd.wattsInSum": 640, "pd.wattsOutSum": 350, "inv.cfgAcEnabled": 1, "mppt.carState": 0,
  }), {battery: 82, input: 640, output: 350, ac: "on", dc: "off"})
  // The AC outlets of a DELTA Pro 3 are on when one of them is on: 2 is
  // on, and 0 is off.
  assert.deepEqual(stationParts("deltapro3", {
    cmsBattSoc: 57.5, powInSumW: 0, powOutSumW: 2310, flowInfoAcHvOut: 0, flowInfoAcLvOut: 2, flowInfo12v: 0,
  }), {battery: 57.5, input: 0, output: 2310, ac: "on", dc: "off"})
  assert.equal(stationParts("deltapro3", {flowInfoAcHvOut: 0, flowInfoAcLvOut: 0}).ac, "off")
  // The public API has no switch of a DELTA Pro Ultra.
  assert.deepEqual(stationParts("deltaproultra", {
    "hs_yj751_pd_appshow_addr.soc": 40, "hs_yj751_pd_appshow_addr.wattsInSum": 10,
    "hs_yj751_pd_appshow_addr.wattsOutSum": 20,
  }), {battery: 40, input: 10, output: 20, ac: null, dc: null})
  // A number out of its range, or that is not a number, and a switch with
  // a value that the app does not know: null.
  assert.deepEqual(stationParts("deltapro", {
    "ems.lcdShowSoc": 101, "pd.wattsInSum": -1, "pd.wattsOutSum": "350", "inv.cfgAcEnabled": 2,
  }), {battery: null, input: null, output: null, ac: null, dc: null})
  assert.deepEqual(stationParts("deltapro", {"ems.lcdShowSoc": 100, "pd.wattsOutSum": MAX_POWER, "pd.wattsInSum": MAX_POWER + 1}),
    {battery: 100, input: null, output: MAX_POWER, ac: null, dc: null})
})

test("each part is null or in its range, for any state", () => {
  const value = fc.oneof(fc.integer({min: -10, max: 110}), fc.integer({min: 999_990, max: 1_000_010}), fc.double(),
    fc.constantFrom(0, 1, 2, "1", true, null))
  fc.assert(fc.property(fc.constantFrom(...Object.keys(FAMILIES)), fc.dictionary(
    fc.constantFrom(...Object.values(FAMILIES).flatMap((kind) => [kind.battery, kind.input, kind.output, ...Object.values(kind.switches).flat()])),
    value,
  ), (name, quota) => {
    const parts = stationParts(name, quota)
    assert.ok(parts.battery === null || (parts.battery >= 0 && parts.battery <= 100))
    for (const part of ["input", "output"]) assert.ok(parts[part] === null || (parts[part] >= 0 && parts[part] <= MAX_POWER))
    for (const part of ["ac", "dc"]) assert.ok([null, "on", "off"].includes(parts[part]))
  }))
})

// A fake EcoFlow: it checks the signature of each request with the secret
// key, and answers with the list and the states of the account.
function fakeEcoflow({devices = [], quotas = {}, answer = null, secret = "SK1"} = {}) {
  const ecoflow = {requests: [], commands: []}
  ecoflow.fetch = async (url, options) => {
    const parsed = new URL(url)
    const params = options.method === "PUT" ? JSON.parse(options.body) : Object.fromEntries(parsed.searchParams)
    const {accessKey, nonce, timestamp, sign} = options.headers
    const expected = createHmac("sha256", secret)
      .update(signText(Object.keys(params).length ? params : null, accessKey, nonce, timestamp)).digest("hex")
    ecoflow.requests.push({method: options.method, path: parsed.pathname, params, options})
    const custom = answer?.(options.method, parsed.pathname, params)
    if (custom !== undefined) return custom
    const json = (body) => ({ok: true, json: async () => body})
    if (sign !== expected) return json({code: "8521", message: "signature is wrong"})
    if (parsed.pathname === LIST) return json({code: "0", message: "Success", data: devices})
    if (parsed.pathname === QUOTA) {
      return params.sn in quotas ? json({code: "0", data: quotas[params.sn]}) : json({code: "1006", message: "not allowed"})
    }
    ecoflow.commands.push(params)
    return json({code: "0", message: "Success", data: null})
  }
  return ecoflow
}

const deps = (ecoflow) => {
  let nonce = 100
  return {fetch: ecoflow.fetch, subtle, nonce: () => String(nonce++), now: () => 1_700_000_000_000}
}

const DEVICES = [
  {sn: "DCABZ1", deviceName: "Garage", productName: "DELTA Pro", online: 1},
  {sn: "MR51Z2", deviceName: "Shed", productName: "Delta Pro 3", online: 1},
  {sn: "Y711Z3", productName: "DELTA Pro Ultra", online: 0},
  {sn: "HW51Z4", deviceName: "Plug", productName: "Smart Plug", online: 1},
  {sn: 5, productName: "DELTA Pro"},
  null,
]
const QUOTAS = {
  DCABZ1: {"ems.lcdShowSoc": 82, "pd.wattsInSum": 640, "pd.wattsOutSum": 350, "inv.cfgAcEnabled": 1, "mppt.carState": 0},
  MR51Z2: {cmsBattSoc: 57, powInSumW: 0, powOutSumW: 2310, flowInfoAcHvOut: 2, flowInfoAcLvOut: 2, flowInfo12v: 2},
}

test("the stations of the account: the devices of a known family, with their parts", async () => {
  const ecoflow = fakeEcoflow({devices: DEVICES, quotas: QUOTAS})
  const cloud = ecoflowCloud(deps(ecoflow), KEYS)
  const answer = await cloud.stations()
  assert.deepEqual(answer, {ok: true, body: {stations: [
    {id: "DCABZ1", name: "Garage", model: "DELTA Pro", online: true, battery: 82, input: 640, output: 350, ac: "on", dc: "off"},
    {id: "MR51Z2", name: "Shed", model: "Delta Pro 3", online: true, battery: 57, input: 0, output: 2310, ac: "on", dc: "on"},
    // EcoFlow does not give the state of this one: its parts are not
    // known, and it is not online.
    {id: "Y711Z3", name: null, model: "DELTA Pro Ultra", online: false, battery: null, input: null, output: null, ac: null, dc: null},
  ]}})
  // A GET signs its query. The keys go only in the headers, with no
  // cookie and no cache.
  assert.deepEqual(ecoflow.requests.map(({method, path, params}) => [method, path, params]), [
    ["GET", LIST, {}], ["GET", QUOTA, {sn: "DCABZ1"}], ["GET", QUOTA, {sn: "MR51Z2"}], ["GET", QUOTA, {sn: "Y711Z3"}],
  ])
  const first = ecoflow.requests[0].options
  assert.deepEqual(first.headers, {accessKey: "AK1", nonce: "100", timestamp: "1700000000000", sign: first.headers.sign})
  assert.equal(first.credentials, "omit")
  assert.equal(first.cache, "no-store")
  assert.equal(first.body, undefined)

  // The region of Europe.
  const europe = fakeEcoflow()
  await ecoflowCloud(deps(europe), {...KEYS, region: "europe"}).stations()
  assert.equal(europe.requests.length, 1)
})

test("the account has at most MAX_DEVICES devices that the app reads", async () => {
  const devices = Array.from({length: MAX_DEVICES + 5}, (_, i) => ({sn: `DCABZ${i}`, productName: "DELTA Pro", online: 1}))
  const ecoflow = fakeEcoflow({devices})
  const answer = await ecoflowCloud(deps(ecoflow), KEYS).stations()
  assert.equal(answer.body.stations.length, MAX_DEVICES)
})

test("the errors: refused keys, no answer, a timeout, and an answer that the app cannot read", async () => {
  const stations = (options, keys = KEYS) => ecoflowCloud(deps(fakeEcoflow({devices: DEVICES, quotas: QUOTAS, ...options})), keys).stations()
  // A wrong secret key: EcoFlow refuses the signature.
  assert.deepEqual(await stations({secret: "other"}), {ok: false, error: "token"})
  for (const code of KEY_ERRORS) {
    const json = {ok: true, json: async () => ({code, message: "no"})}
    assert.deepEqual(await stations({answer: () => json}), {ok: false, error: "token"})
    // A refused key in the state of a station.
    assert.deepEqual(await stations({answer: (_m, path) => (path === QUOTA ? json : undefined)}), {ok: false, error: "token"})
  }
  // A number as the code is a code too.
  assert.deepEqual(await stations({answer: () => ({ok: true, json: async () => ({code: 8513})})}), {ok: false, error: "token"})
  // A different code, an HTTP error, a body that is not JSON, a body with
  // no code, and a list that is not a list.
  const fail = (body, ok = true) => ({ok, json: async () => body})
  assert.deepEqual(await stations({answer: () => fail({code: "1006"})}), {ok: false, error: "failed"})
  assert.deepEqual(await stations({answer: () => fail({code: "0"}, false)}), {ok: false, error: "failed"})
  assert.deepEqual(await stations({answer: () => ({ok: true, json: async () => { throw new Error("html") }})}), {ok: false, error: "failed"})
  assert.deepEqual(await stations({answer: () => fail(null)}), {ok: false, error: "failed"})
  assert.deepEqual(await stations({answer: () => fail({code: "0", data: {list: []}})}), {ok: false, error: "failed"})
  // A state that is not an object: the parts are not known.
  const odd = await stations({answer: (_m, path) => (path === QUOTA ? fail({code: "0", data: "none"}) : undefined)})
  assert.equal(odd.body.stations[0].battery, null)
  // No answer, and a timeout.
  const down = {...deps(fakeEcoflow()), fetch: async () => { throw new TypeError("network") }}
  assert.deepEqual(await ecoflowCloud(down, KEYS).stations(), {ok: false, error: "unreachable"})
  const abort = new AbortController()
  abort.abort()
  assert.deepEqual(await ecoflowCloud(down, KEYS).stations(abort.signal), {ok: false, error: "timeout"})
})

test("a control sends one command for each key of the part", async () => {
  const ecoflow = fakeEcoflow({devices: DEVICES, quotas: QUOTAS})
  const cloud = ecoflowCloud(deps(ecoflow), KEYS)
  // The AC outlets of 120 V and of 240 V of a DELTA Pro 3.
  assert.deepEqual(await cloud.control("MR51Z2", "deltapro3", "ac", false), {ok: true, body: null})
  const dp3 = {sn: "MR51Z2", cmdId: 17, dirDest: 1, dirSrc: 1, cmdFunc: 254, dest: 2, needAck: true}
  assert.deepEqual(ecoflow.commands, [{...dp3, params: {cfgHvAcOutOpen: false}}, {...dp3, params: {cfgLvAcOutOpen: false}}])
  const put = ecoflow.requests.at(-1)
  assert.equal(put.method, "PUT")
  assert.equal(put.path, SET)
  assert.equal(put.options.headers["content-type"], "application/json;charset=UTF-8")
  ecoflow.commands = []
  await cloud.control("MR51Z2", "deltapro3", "dc", true)
  assert.deepEqual(ecoflow.commands, [{...dp3, params: {cfgDc12vOutOpen: true}}])
  // The AC outlets and the 12 V outlets of a DELTA Pro.
  ecoflow.commands = []
  await cloud.control("DCABZ1", "deltapro", "ac", true)
  await cloud.control("DCABZ1", "deltapro", "dc", false)
  assert.deepEqual(ecoflow.commands, [
    {sn: "DCABZ1", params: {cmdSet: 32, id: 66, enabled: 1}}, {sn: "DCABZ1", params: {cmdSet: 32, id: 81, enabled: 0}},
  ])
  ecoflow.commands = []
  await cloud.control("DCABZ1", "deltapro", "ac", false)
  await cloud.control("DCABZ1", "deltapro", "dc", true)
  assert.deepEqual(ecoflow.commands, [
    {sn: "DCABZ1", params: {cmdSet: 32, id: 66, enabled: 0}}, {sn: "DCABZ1", params: {cmdSet: 32, id: 81, enabled: 1}},
  ])
  // A part with no command, and a family that the app does not know.
  ecoflow.commands = []
  assert.deepEqual(await cloud.control("Y711Z3", "deltaproultra", "ac", true), {ok: false, error: "failed"})
  assert.deepEqual(await cloud.control("X", "other", "ac", true), {ok: false, error: "failed"})
  assert.deepEqual(await cloud.control("DCABZ1", "deltapro", "battery", true), {ok: false, error: "failed"})
  assert.deepEqual(ecoflow.commands, [])
  // The first command fails: the second does not go.
  const refused = fakeEcoflow({answer: (method) => (method === "PUT" ? {ok: true, json: async () => ({code: "8521"})} : undefined)})
  assert.deepEqual(await ecoflowCloud(deps(refused), KEYS).control("MR51Z2", "deltapro3", "ac", true), {ok: false, error: "token"})
  assert.equal(refused.requests.length, 1)
})
