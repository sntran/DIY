// The direct link to the cloud of the maker of a power station, for a
// person with no Home Assistant. The design tells it ("The direct link to
// a maker"). The token or the keys of the person stay on the device
// (IndexedDB). A page cannot call the cloud of Pecron: each call goes
// through the relay of the app (DIYWeb.RelayController), and the relay
// keeps no token. The page calls the cloud of EcoFlow directly
// (ecoflow.js): the keys never go to the server of the app.
//
// The hook reads the stations of the account (a poll) at the start, and
// then each POLL_WAIT while the page shows. A switch of the page sends a
// control of the AC or DC outlets of a station. Six rules come from the
// TLA+ model specs/MakerLink.tla:
// - The generation: a new token or a disconnect starts a new generation.
//   An answer of an old generation changes nothing.
// - One poll at a time: a timer while a poll waits does nothing. The next
//   timer polls.
// - A poll after a control: the end of a control starts a poll. While a
//   poll waits, it marks a poll "again" for the end of that poll.
// - The timeout: the wait for an answer, also for its body, ends after
//   ANSWER_WAIT. The hook never waits for ever (the property Live).
// - The end after the poll: the end of a control with no error goes to
//   the LiveView after the answer of the next poll (EndNew). Until then,
//   the switch waits: it does not show the state from before the control.
//   An end with an error goes at once.
// - The wait for the station (EcoFlow): a station of EcoFlow can apply a
//   command after its answer. The end of a control with no error waits
//   APPLY_WAIT, and then goes with the next poll.
//
// The hook tells the LiveView (DIYWeb.MakerLink): "maker:status" (the
// state of the link), "maker:stations" (the stations of the account) and
// "maker:control_done" (the end of a control).

import {ecoflowCloud, family, HOSTS} from "./ecoflow.js"

// The wait for a station of EcoFlow to apply a command. The client
// TarasKhust/ecoflow-api-mqtt waits 3 seconds before it reads the state
// again.
export const APPLY_WAIT = 3_000
// The makers. Pecron: the path of the relay, and the start of a token of
// its portal ("phk_"). EcoFlow: its cloud for the page (ecoflow.js), with
// the region and the two keys of the person, and the wait for a station.
export const MAKERS = {
  pecron: {relay: "/relay/pecron", prefix: "phk_"},
  ecoflow: {cloud: ecoflowCloud, settle: APPLY_WAIT},
}
// The wait between two polls, and the longest wait for an answer.
export const POLL_WAIT = 30_000
export const ANSWER_WAIT = 20_000
// The database of the tokens, and the channel of the news of the tabs.
export const DB = "diy-makers"
export const STORE = "tokens"
export const CHANNEL = "diy.makers"
// The longest token.
export const MAX_TOKEN = 512

// A key: printable characters with no space.
const validKey = (key) => typeof key === "string" && key.length <= MAX_TOKEN && /^[\x21-\x7e]+$/.test(key)

// True for a token of a maker. A token of Pecron has its start, then more
// characters. The keys of EcoFlow are a region of HOSTS, an access key
// and a secret key.
export function validToken(maker, token) {
  if (MAKERS[maker].cloud) {
    return token !== null && typeof token === "object" && Object.hasOwn(HOSTS, token.region) &&
      validKey(token.accessKey) && validKey(token.secretKey)
  }
  return validKey(token) && token.startsWith(MAKERS[maker].prefix) && token.length > MAKERS[maker].prefix.length
}

// The value of the form of a card, with no spaces at the two ends.
const cleaned = (value) => typeof value === "string" ? value.trim()
  : value !== null && typeof value === "object"
    ? {region: value.region, accessKey: value.accessKey?.trim(), secretKey: value.secretKey?.trim()}
    : null

// Two tokens are the same: the store gives a new object for each read.
const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null)

export class MakerLink {
  // deps: the maker, the store of the tokens, fetch, and push (to the
  // LiveView). Also notify (the news for the other tabs), visible (the
  // page shows), and the timers. For EcoFlow, also subtle (WebCrypto),
  // nonce() and now().
  constructor(deps) {
    Object.assign(this, deps)
    this.relay = MAKERS[this.maker].relay
    this.cloud = MAKERS[this.maker].cloud
    this.settle = MAKERS[this.maker].settle ?? 0
    this.token = null
    this.generation = 0
    this.busy = false
    this.again = false
    this.waiting = false
    this.timer = null
    this.state = "loading"
    this.error = null
    this.stations = null
    this.stopped = false
    this.ends = []
    // The calls that wait for an answer, and the region of the last keys.
    this.calls = new Set()
    this.region = null
  }

  // Reads the token of the store, and starts the link.
  async start() {
    const generation = this.generation
    const token = await this.read()
    if (generation === this.generation) this.use(token)
  }

  // The token of the store. A value that is not a token (for example of a
  // different version of the app) is no token: it goes to no host.
  async read() {
    try {
      const token = await this.store.get(this.maker)
      return validToken(this.maker, token) ? token : null
    } catch {
      return null
    }
  }

  // A new generation, with a token or with none (a disconnect). The calls
  // of the old generation stop, and the page forgets its stations. A
  // stopped link (a page that goes) does nothing.
  use(token) {
    if (this.stopped) return
    this.generation += 1
    this.stopCalls()
    this.token = token
    if (token?.region) this.region = token.region
    this.busy = false
    this.again = false
    this.waiting = false
    this.ends = []
    this.clearTimer(this.timer)
    this.timer = null
    this.stations = null
    this.push("maker:stations", {maker: this.maker, stations: null})
    if (token) {
      this.status("connecting")
      this.poll()
    } else {
      this.status("none")
    }
  }

  status(state, error = null) {
    this.state = state
    this.error = error
    this.push("maker:status", this.statusPayload())
  }

  // The state of the link. For EcoFlow, it also has the region of the last
  // keys (not a key), so that the form shows it again.
  statusPayload() {
    const payload = {maker: this.maker, state: this.state, error: this.error}
    return this.cloud ? {...payload, region: this.region} : payload
  }

  // The key Connect, with the token or the keys of the form. The fields
  // go empty.
  async connect(value) {
    const token = cleaned(value)
    if (!validToken(this.maker, token)) return this.status(this.token ? this.state : "none", "format")
    try {
      await this.store.put(this.maker, token)
    } catch {
      return this.status(this.token ? this.state : "none", "storage")
    }
    this.use(token)
    this.notify()
  }

  async disconnect() {
    try {
      await this.store.delete(this.maker)
    } catch {
      // The token stays in the store, but this tab forgets it.
    }
    this.use(null)
    this.notify()
  }

  // A different tab changed the token.
  async news() {
    const token = await this.read()
    if (!same(token, this.token)) this.use(token)
  }

  // Reads the stations, one poll at a time. The next poll comes after
  // POLL_WAIT, when the page shows. A refused token stops the polls.
  async poll() {
    if (!this.token || this.busy) return
    this.clearTimer(this.timer)
    this.timer = null
    this.busy = true
    const generation = this.generation
    // The ends of the controls before this poll go after its answer. When
    // the poll fails, they go too, and the page tells that it has no link.
    const ends = this.ends
    this.ends = []
    const answer = this.cloud
      ? await this.direct((cloud, signal) => cloud.stations(signal, this.stations))
      : await this.call("GET", "/stations")
    if (generation !== this.generation) return
    if (answer.ok && Array.isArray(answer.body?.stations)) {
      this.stations = answer.body.stations
      this.push("maker:stations", {maker: this.maker, stations: this.stations})
      this.status("connected")
    } else {
      this.status(answer.error === "token" ? "refused" : "offline", answer.error ?? "failed")
    }
    ends.forEach((end) => this.push("maker:control_done", end))
    this.busy = false
    if (this.again) {
      this.again = false
      return this.poll()
    }
    if (this.state !== "refused") this.timer = this.setTimer(() => this.tick(), POLL_WAIT)
  }

  // The timer: a poll when the page shows. Else the poll waits for the
  // page (shown()).
  tick() {
    this.timer = null
    if (this.visible()) this.poll()
    else this.waiting = true
  }

  shown() {
    if (!this.waiting) return
    this.waiting = false
    this.poll()
  }

  // Turns the AC or DC outlets of a station on or off. A poll reads the new
  // state, and the end goes to the LiveView with it. For EcoFlow, that poll
  // starts APPLY_WAIT after the answer. The maker can refuse the token for a
  // control ("denied"), and the token can still read. On the portal of
  // Pecron, the person can turn off the controls (the option "Allow HA to
  // send control commands"). So the poll tells if the maker refuses the
  // token.
  async control(device, part, on) {
    const generation = this.generation
    if (!this.token) return this.push("maker:control_done", {maker: this.maker, device, part, error: "failed"})
    const name = family(this.stations?.find((station) => station.id === device)?.model)
    const answer = this.cloud
      ? await this.direct((cloud, signal) => cloud.control(device, name, part, on, signal))
      : await this.call("POST", `/command/${encodeURIComponent(device)}`, {part, on})
    if (generation !== this.generation) return
    const error = answer.ok ? null : answer.error === "token" ? "denied" : answer.error
    const end = {maker: this.maker, device, part, error}
    if (error) {
      this.push("maker:control_done", end)
      this.after(null)
    } else if (this.settle) {
      this.setTimer(() => { if (generation === this.generation) this.after(end) }, this.settle)
    } else {
      this.after(end)
    }
  }

  // After a control: its end (with no error) waits for the next poll. A
  // poll starts, or a poll "again" while a poll waits.
  after(end) {
    if (end) this.ends.push(end)
    if (this.busy) this.again = true
    else this.poll()
  }

  // The wait for the answer of a call (run). It ends after ANSWER_WAIT, or
  // when a new generation starts: the signal then stops the call, also the
  // body of its answer. Then the answer is the error "timeout".
  async wait(run) {
    const abort = new AbortController()
    const timer = this.setTimer(() => abort.abort(), ANSWER_WAIT)
    this.calls.add(abort)
    const answer = await run(abort.signal)
    this.clearTimer(timer)
    this.calls.delete(abort)
    return abort.signal.aborted ? {ok: false, error: "timeout"} : answer
  }

  stopCalls() {
    this.calls.forEach((abort) => abort.abort())
    this.calls.clear()
  }

  // A call of the relay, with the token. It gives {ok, body} or {ok: false,
  // error}. The errors: "token" (the maker refuses the token), "unreachable"
  // (no answer of the maker), "offline" (no answer of the relay), "timeout"
  // and "failed".
  call(method, path, body = null) {
    return this.wait(async (signal) => {
      const response = await this.fetch(this.relay + path, {
        method,
        headers: {authorization: `Bearer ${this.token}`, ...(body ? {"content-type": "application/json"} : {})},
        body: body ? JSON.stringify(body) : undefined,
        credentials: "omit",
        cache: "no-store",
        signal,
      }).catch(() => null)
      const json = response ? await response.json().catch(() => null) : null
      if (!response) return {ok: false, error: "offline"}
      if (response.ok) return {ok: true, body: json}
      return {ok: false, error: ["token", "unreachable"].includes(json?.error) ? json.error : "failed"}
    })
  }

  // A call of the cloud of the maker (EcoFlow), from the page, with the
  // keys. It has the same wait as a call of the relay, and the same
  // answers. With no WebCrypto (a page with no https), the page cannot
  // sign a request ("crypto"). A call that throws an error is "failed".
  direct(run) {
    if (!this.subtle) return Promise.resolve({ok: false, error: "crypto"})
    const cloud = this.cloud({fetch: this.fetch, subtle: this.subtle, nonce: this.nonce, now: this.now}, this.token)
    return this.wait((signal) => run(cloud, signal).catch(() => ({ok: false, error: "failed"})))
  }

  // A new LiveView (after a reconnect) gets the state and the stations.
  report() {
    this.push("maker:status", this.statusPayload())
    this.push("maker:stations", {maker: this.maker, stations: this.stations})
  }

  stop() {
    this.stopped = true
    this.generation += 1
    this.stopCalls()
    this.clearTimer(this.timer)
    this.timer = null
  }
}

// The store of the tokens in IndexedDB: one token for each maker.
export function tokenStore(factory) {
  let connection = null
  const connect = () => {
    if (!connection) {
      connection = new Promise((resolve, reject) => {
        const request = factory.open(DB, 1)
        request.onupgradeneeded = () => request.result.createObjectStore(STORE)
        request.onsuccess = () => {
          request.result.onclose = () => { connection = null }
          resolve(request.result)
        }
        request.onerror = () => reject(request.error)
      })
      connection.catch(() => { connection = null })
    }
    return connection
  }
  const run = (mode, act) => connect().then((db) => new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode)
    const request = act(tx.objectStore(STORE))
    tx.oncomplete = () => resolve(request.result ?? null)
    tx.onabort = () => reject(tx.error)
  }))
  return {
    get: (maker) => run("readonly", (store) => store.get(maker)),
    put: (maker, token) => run("readwrite", (store) => store.put(token, maker)),
    delete: (maker) => run("readwrite", (store) => store.delete(maker)),
    // Closes the connection, when the page goes.
    close: () => {
      const open = connection
      connection = null
      open?.then((db) => db.close(), () => {})
    },
  }
}

// The hook of the page: one link for each maker. The key Connect of a card
// sends the DOM event "maker:connect" (JS.dispatch/1) with its form: the
// token goes to the hook, not to the LiveView.
export function makerLinkHook(deps) {
  return {
    mounted() {
      const parts = deps()
      this.parts = parts
      const push = (event, payload) => this.pushEvent(event, payload, () => {})
      this.links = Object.fromEntries(Object.keys(MAKERS).map((maker) =>
        [maker, new MakerLink({...parts, maker, push, notify: () => parts.notify(maker)})]))
      const link = (maker) => this.links[maker]
      this.handleEvent("maker:disconnect", ({maker}) => link(maker)?.disconnect())
      this.handleEvent("maker:control", ({maker, device, part, on}) => {
        if (["ac", "dc"].includes(part) && typeof device === "string") link(maker)?.control(device, part, on === true)
      })
      this.unlisten = parts.listen({
        connect: (maker, token) => link(maker)?.connect(token),
        news: (maker) => link(maker)?.news(),
        shown: () => Object.values(this.links).forEach((one) => one.shown()),
      })
      Object.values(this.links).forEach((one) => one.start())
    },
    reconnected() { Object.values(this.links).forEach((one) => one.report()) },
    destroyed() {
      this.unlisten()
      Object.values(this.links).forEach((one) => one.stop())
      this.parts.close()
    },
  }
}

// The parts of the browser for the hook.
export function makerParts(window) {
  const channel = typeof window.BroadcastChannel === "function" ? new window.BroadcastChannel(CHANNEL) : null
  const store = tokenStore(window.indexedDB)
  return {
    store,
    // The page goes: the channel and the database close.
    close: () => {
      channel?.close()
      store.close()
    },
    fetch: (...args) => window.fetch(...args),
    subtle: window.crypto?.subtle,
    // The nonce of a request of EcoFlow: 6 random digits, as
    // TarasKhust/ecoflow-api-mqtt sends.
    nonce: () => String(100_000 + (window.crypto.getRandomValues(new Uint32Array(1))[0] % 900_000)),
    now: () => Date.now(),
    notify: (maker) => channel?.postMessage(maker),
    visible: () => window.document.visibilityState !== "hidden",
    setTimer: (f, ms) => window.setTimeout(f, ms),
    clearTimer: (id) => window.clearTimeout(id),
    // The key Connect (with the form of its card), the news of the other
    // tabs, and the page that shows again.
    listen: ({connect, news, shown}) => {
      // The form of Pecron has a token. The form of EcoFlow has the region
      // and the two keys.
      const onConnect = (event) => {
        const field = (name) => event.target.elements.namedItem(name)
        const value = field("token") ? field("token").value
          : {region: field("region")?.value, accessKey: field("access_key")?.value, secretKey: field("secret_key")?.value}
        connect(event.target.dataset.maker, value)
        for (const name of ["token", "access_key", "secret_key"]) if (field(name)) field(name).value = ""
      }
      const onShown = () => { if (window.document.visibilityState !== "hidden") shown() }
      if (channel) channel.onmessage = (event) => news(event.data)
      window.addEventListener("maker:connect", onConnect)
      window.document.addEventListener("visibilitychange", onShown)
      return () => {
        if (channel) channel.onmessage = null
        window.removeEventListener("maker:connect", onConnect)
        window.document.removeEventListener("visibilitychange", onShown)
      }
    },
  }
}
