// The API of EcoFlow for developers (developer.ecoflow.com), for the
// direct link to EcoFlow (maker_link.js). The design tells it, with its
// sources ("The direct link to EcoFlow"). The page calls EcoFlow
// directly: its answers have CORS headers for each site. So the keys of
// the person never go to the server of the app.
//
// Each request has a signature: HMAC-SHA256 with the secret key
// (signText()). A poll reads the list of the devices, then the state of
// each station of a known family, all at the same time (cloud.stations()).
// A control sets one part of a station (cloud.control()).

// The hosts of the regions of EcoFlow for the API for developers, as the
// options of EcoFlow Cloud (config_flow.py).
export const HOSTS = {americas: "https://api-a.ecoflow.com", europe: "https://api-e.ecoflow.com"}
export const LIST = "/iot-open/sign/device/list"
export const QUOTA = "/iot-open/sign/device/quota/all"
export const SET = "/iot-open/sign/device/quota"
// The highest power of a station, in W, as in home_assistant.js.
export const MAX_POWER = 1_000_000
// The most devices that the app reads from one account.
export const MAX_DEVICES = 100
// The codes of EcoFlow for keys that it refuses. The code 8513 is
// "accessKey is invalid", also for a key of a different region. The code
// 8521 is "signature is wrong", for a wrong secret key or a wrong time.
// The design tells the sources. The code 8524 ("invalid parameter") comes
// with no keys, and also for a command that EcoFlow does not accept. The
// app always sends the keys, so 8524 is a failure.
export const KEY_ERRORS = ["8513", "8521"]
// The parts of a station.
export const PARTS = ["battery", "input", "output", "ac", "dc"]
// A serial number that the page can read (as DIY.Pecron.id?/1).
const SN = /^[A-Za-z0-9_-]{1,64}$/

// A value of a switch: on or off.
const ON_OFF = (on, off) => (value) => (value === on ? "on" : value === off ? "off" : null)

// The families of stations. The key of a family is the product name of
// the device in the list, with no case, no spaces and no signs. Each
// family has the keys of its parts in the state of the station, and the
// commands of its switches. A part can have more keys: the AC outlets of
// a DELTA Pro 3 are of 120 V and of 240 V. The DC part is the 12 V outlets
// only.
export const FAMILIES = {
  deltapro: {
    battery: "ems.lcdShowSoc", input: "pd.wattsInSum", output: "pd.wattsOutSum",
    switches: {ac: ["inv.cfgAcEnabled"], dc: ["mppt.carState"]},
    state: ON_OFF(1, 0),
    commands: {
      ac: (sn, on) => [{sn, params: {cmdSet: 32, id: 66, enabled: on ? 1 : 0}}],
      dc: (sn, on) => [{sn, params: {cmdSet: 32, id: 81, enabled: on ? 1 : 0}}],
    },
  },
  deltapro3: {
    battery: "cmsBattSoc", input: "powInSumW", output: "powOutSumW",
    switches: {ac: ["flowInfoAcHvOut", "flowInfoAcLvOut"], dc: ["flowInfo12v"]},
    state: ON_OFF(2, 0),
    commands: {
      ac: (sn, on) => [deltaPro3(sn, {cfgHvAcOutOpen: on}), deltaPro3(sn, {cfgLvAcOutOpen: on})],
      dc: (sn, on) => [deltaPro3(sn, {cfgDc12vOutOpen: on})],
    },
  },
  deltaproultra: {
    battery: "hs_yj751_pd_appshow_addr.soc", input: "hs_yj751_pd_appshow_addr.wattsInSum",
    output: "hs_yj751_pd_appshow_addr.wattsOutSum", switches: {}, state: ON_OFF(1, 0), commands: {},
  },
}

function deltaPro3(sn, params) {
  return {sn, cmdId: 17, dirDest: 1, dirSrc: 1, cmdFunc: 254, dest: 2, needAck: true, params}
}

// The family of a product name, or null.
export function family(productName) {
  const key = typeof productName === "string" ? productName.toLowerCase().replace(/[^a-z0-9]/g, "") : ""
  return Object.hasOwn(FAMILIES, key) ? key : null
}

// The parameters as one level: a key in a key is "a.b", and an item of a
// list is "a[0]".
export function flatten(value, prefix = "", into = {}) {
  for (const [key, item] of Object.entries(value)) {
    const name = Array.isArray(value) ? `${prefix}[${key}]` : prefix ? `${prefix}.${key}` : key
    if (item !== null && typeof item === "object") flatten(item, name, into)
    else into[name] = item
  }
  return into
}

// The text that the secret key signs: the parameters in the order of
// their keys, then the access key, the nonce and the time.
export function signText(params, accessKey, nonce, timestamp) {
  const flat = flatten(params ?? {})
  const sorted = Object.keys(flat).sort().map((key) => `${key}=${flat[key]}`)
  return [...sorted, `accessKey=${accessKey}`, `nonce=${nonce}`, `timestamp=${timestamp}`].join("&")
}

// HMAC-SHA256 of a text, in hex (WebCrypto).
export async function hmac(subtle, secret, text) {
  const encoder = new TextEncoder()
  const key = await subtle.importKey("raw", encoder.encode(secret), {name: "HMAC", hash: "SHA-256"}, false, ["sign"])
  const signature = new Uint8Array(await subtle.sign("HMAC", key, encoder.encode(text)))
  return [...signature].map((byte) => byte.toString(16).padStart(2, "0")).join("")
}

// The parts of a station from its state: the numbers in their ranges,
// and the switches. A part that the state does not have is null.
export function stationParts(name, quota) {
  const kind = FAMILIES[name]
  const number = (key, max) => {
    const value = quota[key]
    return typeof value === "number" && value >= 0 && value <= max ? value : null
  }
  const parts = {battery: number(kind.battery, 100), input: number(kind.input, MAX_POWER), output: number(kind.output, MAX_POWER)}
  for (const part of ["ac", "dc"]) {
    const states = (kind.switches[part] ?? []).map((key) => kind.state(quota[key]))
    parts[part] = states.includes("on") ? "on" : states.includes("off") ? "off" : null
  }
  return parts
}

// The cloud of EcoFlow for one account. deps: fetch, subtle (WebCrypto),
// nonce() and now() (the time in ms). keys: {region, accessKey, secretKey}.
// Each call gives {ok: true, body} or {ok: false, error}, as the relay of
// Pecron: "token" (EcoFlow refuses the keys), "unreachable" (no answer),
// or "failed".
export function ecoflowCloud(deps, keys) {
  // A region that is not in HOSTS sends no request: the keys go to no
  // other host.
  const host = Object.hasOwn(HOSTS, keys?.region) ? HOSTS[keys.region] : null
  const call = async (method, path, params, signal) => {
    if (!host) return {ok: false, error: "failed"}
    const nonce = deps.nonce()
    const timestamp = String(deps.now())
    const sign = await hmac(deps.subtle, keys.secretKey, signText(params, keys.accessKey, nonce, timestamp))
    const query = method === "GET" && params ? "?" + new URLSearchParams(params) : ""
    const response = await deps.fetch(host + path + query, {
      method,
      headers: {
        accessKey: keys.accessKey, nonce, timestamp, sign,
        ...(method === "PUT" ? {"content-type": "application/json;charset=UTF-8"} : {}),
      },
      body: method === "PUT" ? JSON.stringify(params) : undefined,
      credentials: "omit",
      cache: "no-store",
      signal,
    }).catch(() => null)
    if (!response) return {ok: false, error: signal?.aborted ? "timeout" : "unreachable"}
    const json = await response.json().catch(() => null)
    if (!response.ok || json?.code === undefined) return {ok: false, error: "failed"}
    // EcoFlow refuses the keys (KEY_ERRORS). A different code (for example
    // 1006, a device that the API does not allow) is a failure.
    if (KEY_ERRORS.includes(String(json.code))) return {ok: false, error: "token"}
    return String(json.code) === "0" ? {ok: true, body: json.data} : {ok: false, error: "failed"}
  }

  return {
    // The stations of the account: the devices of a known family, with
    // their parts. The calls of the states go at the same time, so one
    // wait covers a poll of many stations. When EcoFlow does not give the
    // state of a station, the station keeps its parts of the last poll
    // (last), and it is not online.
    async stations(signal, last = null) {
      const list = await call("GET", LIST, null, signal)
      if (!list.ok) return list
      if (!Array.isArray(list.body)) return {ok: false, error: "failed"}
      const devices = list.body.slice(0, MAX_DEVICES)
        .filter((device) => typeof device?.sn === "string" && SN.test(device.sn) && family(device.productName))
      const quotas = await Promise.all(devices.map((device) => call("GET", QUOTA, {sn: device.sn}, signal)))
      if (quotas.some((quota) => quota.error === "token")) return {ok: false, error: "token"}
      const stations = devices.map((device, index) => {
        const quota = quotas[index]
        const read = quota.ok && quota.body !== null && typeof quota.body === "object"
        const before = Array.isArray(last) ? last.find((station) => station?.id === device.sn) : null
        const parts = read ? stationParts(family(device.productName), quota.body)
          : Object.fromEntries(PARTS.map((part) => [part, before?.model === device.productName ? before[part] ?? null : null]))
        return {
          id: device.sn, name: typeof device.deviceName === "string" ? device.deviceName : null,
          model: device.productName, online: device.online === 1 && read, ...parts,
        }
      })
      return {ok: true, body: {stations}}
    },

    // Turns a part of a station on or off: one command for each key of
    // the part. A family with no command for the part fails.
    async control(sn, name, part, on, signal) {
      const commands = FAMILIES[name]?.commands[part]
      if (!commands) return {ok: false, error: "failed"}
      for (const body of commands(sn, on)) {
        const answer = await call("PUT", SET, body, signal)
        if (!answer.ok) return answer
      }
      return {ok: true, body: null}
    },
  }
}
