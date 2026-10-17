// The sign-in to Home Assistant on the device, and the socket of the page
// to Home Assistant (docs/design.md, "Home Assistant", and the TLA+ model
// specs/HomeAssistant.tla).
//
// - The person gives the address of Home Assistant, on the screen of a hub
//   or in Settings. The key Connect opens the sign-in page of the app
//   (SIGN_IN) in a new tab. The tab opens in the tap: a browser blocks a
//   tab that a page opens later.
// - The new tab (SignIn) starts only when a tab of the app opened it: a link
//   of a different site cannot start a sign-in. It makes a random state and
//   a PKCE challenge, and keeps them in its sessionStorage. It goes to the
//   sign-in page of Home Assistant. Home Assistant sends it back with a
//   code. The new tab gets the tokens for the code, and keeps them in
//   IndexedDB, for all the tabs. The server of the app never sees them. Then
//   the new tab tells its end to the first tab, and closes.
// - The hook of each page (Link) reads the store, and opens a WebSocket to
//   Home Assistant with the access token. When a socket signs in, the hook
//   first gets a new access token if the old one ends in 60 seconds or
//   less. A socket that signed in stays open after the end of its access
//   token.
// - A disconnect clears the store, and revokes the session on Home
//   Assistant. A BroadcastChannel tells the other tabs to read the store.
//
// Three rules come from the model:
// - The generation: a disconnect adds one to the generation in the store.
//   A sign-in keeps its session only when the generation is the same as at
//   its start. Else it revokes its new session.
// - The compare and set: a refresh writes its access token only when the
//   store still has the same refresh token.
// - The owner: a refused refresh ends only the socket of its own session.
//
// The ghosts of the devices read the devices, the entities and the areas of
// Home Assistant (devices(), and DIY.HomeAssistant.ghosts/4).
//
// The hook watches the states of the lights, the switches and the fans
// (watchStates()), and turns them on and off (control()). It also watches
// the parts of the power stations of Pecron and EcoFlow (stationList()).
// These are the battery, the power in and out, the AC and DC switches,
// and the link of the station. It turns one switch of a station on or off
// at a time. Four rules come from the TLA+ model
// specs/HomeAssistantStates.tla:
// - The socket: the hook takes the messages of its open socket only.
// - The watch: the hook takes the events of its watch only.
// - The old states: a new watch and a closed socket clear the states.
// - The end: a new watch ends the old watch.
//
// The match of the rooms reads the floors and the areas of Home Assistant.
// It adds the areas of the rooms that the person chose
// (DIYWeb.HomeAssistant.rooms_sheet, and the TLA+ model specs/RoomSync.tla).
// Home Assistant refuses a second area with the same name. Then the hook
// uses the area that has the name: a different tab, or a person in Home
// Assistant, added it first. It uses a floor of the same name only when
// the floor has the same level.

export const DB = "diy-ha"
export const STORE = "session"
export const KEY = "session"
export const GENERATION = "generation"
export const CHANNEL = "diy.ha"
export const PENDING = "diy.ha.pending"
// The sign-in page of the app (DIYWeb.SignInLive), and the name of its tab.
// Home Assistant sends the tab back to this page.
export const SIGN_IN = "/ha/sign-in"
export const TAB = "diy-ha-sign-in"
// The time between two checks of the tab of a sign-in.
export const TAB_CHECK = 1_000
// A socket that signs in gets a new access token when the old one ends in
// 60 seconds or less.
export const EARLY = 60_000
// The wait after a change of a registry of Home Assistant before the hook
// reads the devices again: one read for many changes.
export const REGISTRY_WAIT = 1_000
// The domains of the entities that the app turns on and off.
export const CONTROLS = ["fan", "light", "switch"]
// The parts of a power station, and the domains of their entities. The
// parts are its battery (%), its power in and out (W), and the switches
// of its AC and DC outlets. The last part is its link: does Home
// Assistant get its numbers now (stationStates())?
export const STATION_PARTS = {
  battery: ["sensor"], input: ["sensor"], output: ["sensor"], ac: ["switch"], dc: ["switch"],
  link: ["binary_sensor", "sensor"],
}
// The parts of a station that the app turns on and off.
export const STATION_SWITCHES = ["ac", "dc"]
// The highest power of a station, in W. A power is from 0 W to MAX_POWER.
// A power in kW becomes W. A power or a battery in a different unit is not
// known.
export const MAX_POWER = 1_000_000
const WATTS = new Map([["W", 1], ["kW", 1000]])
// The states of the link of a station. A number of its link is also a
// link: the battery of EcoFlow BLE is its link.
const LINKED = ["on", "online"]
const UNLINKED = ["off", "offline", "assume_offline", "unavailable"]
// The integrations of Home Assistant that give a power station. For each
// part, the unique id of its entity (the form of the integration). The
// maker is the start of the keys of its models in DIY.Catalog. A model
// that is not a station (others) does not count.
const ecoflowCloud = (keys) => new RegExp(`^ecoflow-.+-(${keys.join("|")})$`)
export const STATION_SOURCES = [
  // The integration of Pecron, from the portal of Pecron (app.pecron.com):
  // the API of Pecron for Home Assistant. "entry:device:code". It is the
  // first way of the app (docs/design.md, "The integration for Pecron").
  // Its entities stay available when the station is not online. Its
  // binary sensor "online" tells the link. A WB12200 (a battery with no
  // inverter) is not a station, as for pecron-monitor.
  {
    maker: "pecron",
    platform: "pecron",
    others: /wb/i,
    parts: {
      battery: /:battery_percentage$/, input: /:total_input_power$/, output: /:total_output_power$/,
      ac: /:ac_switch_hm$/, dc: /:dc_switch_hm$/, link: /:online$/,
    },
  },
  // pecron-monitor (attractify-logan/pecron-monitor), through MQTT: the
  // station by Bluetooth or by the LAN, with no cloud, else by the cloud.
  // "pecron_key_name". It does not tell the link. A WB12200 (a battery
  // with no inverter) has "WB" in its name, as in pecron-monitor.
  {
    maker: "pecron",
    platform: "mqtt",
    others: /wb/i,
    parts: {
      battery: /^pecron_[0-9a-f]+_battery$/i, input: /^pecron_[0-9a-f]+_total_input$/i,
      output: /^pecron_[0-9a-f]+_total_output$/i, ac: /^pecron_[0-9a-f]+_ac$/i, dc: /^pecron_[0-9a-f]+_dc$/i,
    },
  },
  // EcoFlow Cloud (tolwi/hassio-ecoflow-cloud): "ecoflow-sn-key", with "-"
  // for "." and "_" in the key. Each family of stations has its keys. The
  // DC part is the 12 V outlets only. Its sensor "status" tells the link
  // ("status.scheduled" for a DELTA Pro Ultra or a DELTA 3 Max Plus of the
  // public API).
  // A Wave (an air conditioner) and a Glacier (a fridge) are not stations.
  {
    maker: "ecoflow",
    platform: "ecoflow_cloud",
    others: /^(wave|glacier)/i,
    parts: {
      battery: ecoflowCloud([
        "ems-lcdShowSoc", "bms-emsStatus-lcdShowSoc", "cms-batt-soc", "cmsBattSoc", "pd-soc",
        "hs-yj751-pd-appshow-addr-soc",
      ]),
      input: ecoflowCloud(["pd-wattsInSum", "pow-in-sum-w", "powInSumW", "hs-yj751-pd-appshow-addr-wattsInSum"]),
      output: ecoflowCloud(["pd-wattsOutSum", "pow-out-sum-w", "powOutSumW", "hs-yj751-pd-appshow-addr-wattsOutSum"]),
      ac: ecoflowCloud([
        "inv-cfgAcEnabled", "mppt-cfgAcEnabled", "cfg-ac-out-open", "cfg-hv-ac-out-open", "cfg-lv-ac-out-open",
        "cfgHvAcOutOpen", "cfgLvAcOutOpen", "flowInfoAcOut", "flowInfoAc2Out",
      ]),
      dc: ecoflowCloud([
        "mppt-carState", "pd-carState", "pd-carSwitch", "cfg-dc12v-out-open", "cfg-dc-12v-out-open",
        "cfgDc12vOutOpen", "flowInfo12v",
      ]),
      link: /^ecoflow-(api-)?[a-z0-9]+-status(-scheduled)?$/i,
    },
  },
  // EcoFlow BLE (rabits/ha-ef-ble): the station by Bluetooth. "ef_sn_key".
  // A Wave (an air conditioner) has a battery too. The DC part is the 12 V
  // outlet only. An entity is unavailable with no Bluetooth link: so the
  // battery tells the link.
  {
    maker: "ecoflow",
    platform: "ef_ble",
    others: /^wave/i,
    parts: {
      battery: /^ef_[a-z0-9]+_battery_level$/i, input: /^ef_[a-z0-9]+_input_power$/i,
      output: /^ef_[a-z0-9]+_output_power$/i, ac: /^ef_[a-z0-9]+_(ac_ports|ac_ports_2|ac_lv_port|ac_hv_port)$/i,
      dc: /^ef_[a-z0-9]+_dc_12v_port$/i, link: /^ef_[a-z0-9]+_battery_level$/i,
    },
  },
]
// The wait after a change of a state before the hook sends the states to
// the LiveView: one message for many changes.
export const STATE_WAIT = 150
// The longest wait for the end of a control. After it, the hook stops the
// wait: Home Assistant does not answer now.
export const CONTROL_WAIT = 10_000
// The energy data that the hook reads. The meter of the house: each day of
// the last 24 months. Each device: each month of the last 13 months. Also
// the most devices with energy that the hook reads.
export const METER_MONTHS = 24
export const DEVICE_MONTHS = 13
export const MAX_ENERGY_DEVICES = 200
// The first and the longest wait before the hook opens the socket again.
export const FIRST_WAIT = 1_000
export const MAX_WAIT = 60_000
// The id of the first command on a socket: get_config. The other commands
// get the next ids.
const CONFIG = 1

// The address of Home Assistant in a text of the person: its origin and
// its path with no "/" at the end. Else null.
export function address(text) {
  let url
  try {
    url = new URL(String(text).trim())
  } catch {
    return null
  }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null
  return (url.origin + url.pathname).replace(/\/+$/, "")
}

// An HTTPS page cannot open an http address: the browser blocks it.
export const blocked = (protocol, url) => protocol === "https:" && url.startsWith("http:")

export const socketUrl = (url) => url.replace(/^http/, "ws") + "/api/websocket"

// The name of a floor or of an area for a match: no case and no spaces.
// Home Assistant does the same (normalize_name). It uses a case fold, so
// "ß" is "ss". DIY.HomeAssistant.key/1 is the same.
export const key = (name) => name.toUpperCase().toLowerCase().replaceAll(" ", "")

// An error of a command on the socket: the code and the message of Home
// Assistant, or "offline" when the socket is not there.
export class CommandError extends Error {
  constructor(code, message) {
    super(message)
    this.code = code
  }
}

const offline = () => new CommandError("offline", "Home Assistant does not answer")

// The client of the app for Home Assistant: the address of the app.
export const clientOf = (location) => location.origin + "/"

// The sign-in page of the app in a new tab, with the address of Home
// Assistant and the id of the sign-in.
export const signInPage = (url, id) => SIGN_IN + "?" + new URLSearchParams({url, id})

// The id of a sign-in in a text, or null.
export const signInId = (text) => typeof text === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(text) ? text : null

const base64url = (bytes) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

export const randomText = (crypto, size = 16) => base64url(crypto.getRandomValues(new Uint8Array(size)))

// A PKCE pair (RFC 7636, S256): the verifier stays on the device, and the
// sign-in page gets the challenge.
export async function pkce(crypto) {
  const verifier = randomText(crypto, 48)
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))
  return {verifier, challenge: base64url(new Uint8Array(digest))}
}

// The sign-in page of Home Assistant for this app. Home Assistant accepts a
// way back on the host of the client: the sign-in page of the app.
export function authorizeUrl(url, {client, state, challenge}) {
  const query = new URLSearchParams({
    response_type: "code",
    client_id: client,
    redirect_uri: client.replace(/\/$/, "") + SIGN_IN,
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  })
  return `${url}/auth/authorize?${query}`
}

const post = (fetch, url, path, fields, options = {}) =>
  fetch(url + path, {method: "POST", body: new URLSearchParams(fields), ...options})

// Ends a session on Home Assistant. The hook does not wait for it. The
// request continues when the tab closes (keepalive).
const revoke = (fetch, session) => {
  post(fetch, session.url, "/auth/revoke", {token: session.refresh}, {keepalive: true}).catch(() => {})
}

// Opens the database of the sign-in.
export function open(factory) {
  return new Promise((resolve, reject) => {
    const request = factory.open(DB, 1)
    request.onupgradeneeded = () => request.result.createObjectStore(STORE)
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

// The store of the session in IndexedDB, with the generation: the count of
// the disconnects. Each operation is one transaction. notify() runs in the
// transaction of a write or a clear. The store opens the database again
// when the browser closed it (the person removed the data of the site).
export function sessionStore(factory, notify) {
  let connection = null

  const connect = () => {
    if (!connection) {
      connection = open(factory).then((db) => {
        db.onclose = () => { connection = null }
        db.onversionchange = () => {
          db.close()
          connection = null
        }
        return db
      })
      connection.catch(() => { connection = null })
    }
    return connection
  }

  // Reads the session and the generation, and gives them to
  // change(store, session, generation) in the same transaction. The result
  // of change is the result of the operation.
  const run = (mode, change) => connect().then((db) => new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode)
    const store = tx.objectStore(STORE)
    let session = null
    let result = null
    store.get(KEY).onsuccess = (event) => { session = event.target.result ?? null }
    store.get(GENERATION).onsuccess = (event) => { result = change(store, session, event.target.result ?? 0) }
    tx.oncomplete = () => resolve(result)
    tx.onabort = () => reject(tx.error)
  }))

  return {
    read: () => run("readonly", (_store, session) => session),
    generation: () => run("readonly", (_store, _session, generation) => generation),
    // Writes the session of a sign-in that started in this generation, and
    // gives {kept: true, old}. After a disconnect (a different generation),
    // it writes nothing, and gives {kept: false}.
    write: (session, generation) => run("readwrite", (store, old, now) => {
      if (generation !== now) return {kept: false, old: null}
      store.put(session, KEY)
      notify()
      return {kept: true, old}
    }),
    // Writes new fields of the session with this refresh token. False when
    // the store has a different session (the compare and set).
    update: (refresh, fields) => run("readwrite", (store, session) => {
      if (!session || session.refresh !== refresh) return false
      store.put({...session, ...fields}, KEY)
      return true
    }),
    // Clears the session with this refresh token (Home Assistant ended it),
    // and gives it.
    clear: (refresh) => run("readwrite", (store, session) => {
      if (!session || session.refresh !== refresh) return null
      store.delete(KEY)
      notify()
      return session
    }),
    // The disconnect: a new generation, and no session. It gives the old
    // session.
    disconnect: () => run("readwrite", (store, session, generation) => {
      store.put(generation + 1, GENERATION)
      if (!session) return null
      store.delete(KEY)
      notify()
      return session
    }),
  }
}

// The link of one tab to Home Assistant. It sends its state to the
// LiveView with push("ha:status", state): {state, url, name, version,
// error}. The states are none, signing_in, connecting, connected, offline
// and signed_out.
export class Link {
  constructor(deps) {
    Object.assign(this, deps)
    this.epoch = 0
    this.session = null
    this.socket = null
    this.retry = null
    this.tab = null
    this.watcher = null
    this.commands = new Map()
    this.events = new Map()
    this.watching = false
    this.reread = null
    this.controls = new Map()
    this.stations = new Map()
    this.stationsSent = false
    this.units = new Map()
    this.states = new Map()
    this.statesOf = null
    this.watched = null
    this.statesReady = false
    this.statesTimer = null
    this.next = CONFIG + 1
    this.wait = FIRST_WAIT
    this.invalids = 0
    this.version = null
    this.timeZone = null
    this.state = {state: "none", url: null, name: null, version: null, error: null}
  }

  show(state, {url = this.session?.url ?? null, name = null, version = null, error = null} = {}) {
    this.state = {state, url, name, version, error}
    this.report()
  }

  report() { this.push("ha:status", this.state) }

  // The start of the page: the stored session.
  start() {
    this.unlisten = this.listen((message) => this.news(message), () => this.again(), (text) => this.connect(text))
    return this.load(this.epoch)
  }

  // The hook goes away (LiveView mounts the page again): no more news, no
  // more tries, and no socket. The tab of a sign-in stays open: its session
  // comes to the new hook.
  stop() {
    this.epoch += 1
    this.forget()
    this.close()
    this.session = null
    this.unlisten()
  }

  // A message of a different tab: the store changed, or a sign-in ended.
  news(message) {
    if (message?.ended !== undefined) return this.ended(message)
    return this.load(this.epoch)
  }

  // Reads the store, and uses its session (the news of a different tab).
  async load(epoch, error = null) {
    let session
    try {
      session = await this.store.read()
    } catch {
      return this.show("none", {error: "storage"})
    }
    if (epoch !== this.epoch) return
    if (this.socket && session?.refresh === this.session?.refresh) return
    this.close()
    this.session = session
    // With no session, the tab of a sign-in can still give one.
    if (!session) return this.tab ? this.show("signing_in", {url: this.tab.url}) : this.show("none", {error})
    this.open(epoch)
  }

  // The person asks to connect: the sign-in page of the app opens in a new
  // tab. The field keeps a bad address, so the person can correct it.
  connect(text) {
    const url = address(text)
    if (!url) return this.show("none", {error: "url", url: typeof text === "string" ? text : null})
    if (blocked(this.location.protocol, url)) return this.show("none", {error: "blocked", url})
    const id = randomText(this.crypto)
    const tab = this.openTab(signInPage(url, id))
    if (!tab) return this.show("none", {error: "tab", url})
    this.forget()
    this.tab = {window: tab, id, url}
    this.show("signing_in", {url})
    this.watch()
  }

  // Checks the tab of the sign-in. When it closed with no end, the page
  // reads the store: the sign-in can be done.
  watch() {
    this.watcher = this.setTimer(() => {
      this.watcher = null
      if (!this.tab.window.closed) return this.watch()
      this.tab = null
      this.load(this.epoch, "closed")
    }, TAB_CHECK)
  }

  // The tab of a sign-in tells its end: an error, or null. Only the tab
  // that opened it waits for it.
  ended({ended, error}) {
    if (ended !== this.tab?.id) return
    this.forget()
    return this.load(this.epoch, error ?? null)
  }

  forget() {
    if (this.watcher) this.clearTimer(this.watcher)
    this.watcher = null
    this.tab = null
  }

  // The person asks to disconnect, or to stop a sign-in. A sign-in in a
  // different tab that started before it keeps nothing (the generation).
  // The browser closes the tab of a sign-in only when the tab shows a page
  // of the app: the tab has no opener.
  async disconnect() {
    this.epoch += 1
    const epoch = this.epoch
    this.tab?.window.close()
    this.forget()
    this.close()
    this.session = null
    let old = null
    try {
      old = await this.store.disconnect()
    } catch {
      old = null
    }
    if (old) revoke(this.fetch, old)
    if (epoch === this.epoch) this.show("none")
  }

  open(epoch) {
    this.show("connecting")
    const socket = new this.WebSocket(socketUrl(this.session.url))
    this.socket = socket
    socket.onmessage = (event) => this.message(socket, epoch, JSON.parse(event.data))
    socket.onclose = () => this.closed(socket, epoch)
  }

  close() {
    if (this.retry) this.clearTimer(this.retry)
    this.retry = null
    const socket = this.socket
    this.socket = null
    this.drop()
    socket?.close()
  }

  // The socket is gone: the commands on it get no answer, and its
  // subscriptions end.
  drop() {
    for (const {reject} of this.commands.values()) reject(offline())
    this.commands.clear()
    this.events.clear()
    this.watching = false
    if (this.reread) this.clearTimer(this.reread)
    this.reread = null
    this.statesOf = null
    this.forgetStates()
    this.next = CONFIG + 1
  }

  // Sends a command on the socket, and gives its result. Only a socket
  // that is connected takes commands.
  command(type, fields = {}) {
    if (!this.socket || this.state.state !== "connected") return Promise.reject(offline())
    const id = this.next++
    this.socket.send(JSON.stringify({...fields, id, type}))
    return new Promise((resolve, reject) => this.commands.set(id, {resolve, reject}))
  }

  // Starts a subscription on the socket: onEvent gets each of its events.
  // It gives the id of the subscription, and the result of the command
  // (done).
  subscribe(type, fields, onEvent) {
    const id = this.next
    const done = this.command(type, fields)
    this.events.set(id, onEvent)
    return {
      id,
      done: done.catch((error) => {
        this.events.delete(id)
        throw error
      }),
    }
  }

  // Ends a subscription: its late events change nothing.
  unsubscribe(id) {
    this.events.delete(id)
    this.command("unsubscribe_events", {subscription: id}).catch(() => {})
  }

  async message(socket, epoch, message) {
    if (socket !== this.socket) return
    if (message.type === "event") return this.events.get(message.id)?.(message.event)
    if (message.type === "auth_required") {
      const access = await this.access(epoch)
      if (access && socket === this.socket) socket.send(JSON.stringify({type: "auth", access_token: access}))
    } else if (message.type === "auth_ok") {
      this.invalids = 0
      this.version = message.ha_version
      socket.send(JSON.stringify({id: CONFIG, type: "get_config"}))
    } else if (message.type === "auth_invalid") {
      this.invalid(epoch)
    } else if (message.type === "result" && message.id === CONFIG && message.success) {
      this.wait = FIRST_WAIT
      // The months of the energy data are in the time zone of Home
      // Assistant.
      this.timeZone = message.result.time_zone ?? null
      this.show("connected", {name: message.result.location_name, version: this.version})
    } else if (message.type === "result" && this.commands.has(message.id)) {
      const {resolve, reject} = this.commands.get(message.id)
      this.commands.delete(message.id)
      if (message.success) resolve(message.result)
      else reject(new CommandError(message.error?.code, message.error?.message ?? "error"))
    }
  }

  // Home Assistant refused the access token. The first time, get a new one
  // and try again. The second time, the session ended.
  invalid(epoch) {
    this.invalids += 1
    if (this.invalids > 1) {
      // The session of the socket is the session of the tab: end the
      // socket now, so that its close does not show "offline".
      this.close()
      return this.signedOut(this.session, epoch)
    }
    this.session = {...this.session, expires: 0}
    this.close()
    this.open(epoch)
  }

  // The socket closed, and the hook did not close it: try again later.
  closed(socket, epoch) {
    if (socket !== this.socket) return
    this.socket = null
    this.drop()
    this.show("offline")
    this.retry = this.setTimer(() => {
      this.retry = null
      if (epoch === this.epoch && this.session && !this.socket) this.open(epoch)
    }, this.wait)
    this.wait = Math.min(this.wait * 2, MAX_WAIT)
  }

  // The device is online again: try now.
  again() {
    if (!this.session || this.socket) return
    this.close()
    this.wait = FIRST_WAIT
    this.open(this.epoch)
  }

  // The access token, with a new one when the old one ends soon.
  access(epoch) {
    return this.session.expires - this.now() > EARLY ? this.session.access : this.refresh(epoch)
  }

  async refresh(epoch) {
    const session = this.session
    let answer
    try {
      answer = await post(this.fetch, session.url, "/auth/token", {
        grant_type: "refresh_token", refresh_token: session.refresh, client_id: session.client,
      })
    } catch {
      return null
    }
    if (epoch !== this.epoch) return null
    let fields, written
    try {
      const tokens = await answer.json()
      // Only invalid_grant means that the session ended. A 403 can pass:
      // for example, a user that Home Assistant allows only at home.
      if (answer.status === 400 && tokens.error === "invalid_grant") return this.signedOut(session, epoch)
      if (!answer.ok) return null
      fields = {access: tokens.access_token, expires: this.now() + tokens.expires_in * 1000}
      written = await this.store.update(session.refresh, fields)
    } catch {
      // A bad answer, or a store that fails: the socket closes, and the
      // hook tries again later.
      return null
    }
    if (!written) {
      // A different tab changed the store.
      this.load(this.epoch)
      return null
    }
    if (epoch !== this.epoch) return null
    this.session = {...session, ...fields}
    return fields.access
  }

  // Home Assistant ended the session (for example, the person removed it
  // in Home Assistant). The tab clears the store and ends its socket only
  // when they still have that session: a different tab can have a new one.
  async signedOut(session, epoch) {
    try {
      await this.store.clear(session.refresh)
    } catch {
      // The store keeps it: the next start finds the same end.
    }
    if (epoch !== this.epoch || this.session?.refresh !== session.refresh) return null
    this.close()
    this.session = null
    this.show("signed_out", {url: session.url, error: "signed_out"})
    return null
  }

  // Sends the floors and the areas of Home Assistant to the LiveView
  // (ha:rooms), and tells if the user is an admin. With no socket, it
  // sends {error: "offline"}. When Home Assistant refuses a command (for
  // example, a version with no floors), it sends {error: "failed"}.
  async rooms() {
    try {
      const [floors, areas, user] = await Promise.all([
        this.command("config/floor_registry/list"),
        this.command("config/area_registry/list"),
        this.command("auth/current_user"),
      ])
      this.push("ha:rooms", {
        floors: floors.map((floor) => ({id: floor.floor_id, name: floor.name, level: floor.level ?? null})),
        areas: areas.map((area) => ({id: area.area_id, name: area.name, floor: area.floor_id ?? null})),
        admin: user.is_admin === true,
      })
    } catch (error) {
      this.push("ha:rooms", {error: error.code === "offline" ? "offline" : "failed"})
    }
  }

  // Sends the devices and the areas of Home Assistant to the LiveView
  // (ha:devices): only the parts that the ghosts need (deviceList). With
  // no socket, it sends {error: "offline"}. When Home Assistant refuses a
  // command, it sends {error: "failed"}.
  // The first read also starts to watch the registries of the devices, of
  // the entities and of the areas. After a change, the hook reads the
  // devices again (REGISTRY_WAIT). Each read also watches the states of
  // the entities that the app turns on and off (watchStates).
  async devices() {
    try {
      const [devices, entities, areas] = await Promise.all([
        this.command("config/device_registry/list"),
        this.command("config/entity_registry/list"),
        this.command("config/area_registry/list"),
      ])
      const stations = stationList(devices, entities)
      const list = deviceList(devices, entities, stations)
      this.push("ha:devices", {
        devices: list,
        areas: areas.map((area) => ({id: area.area_id, name: area.name, floor: area.floor_id ?? null})),
      })
      // A station has its own parts: its switches are not a switch of the
      // whole device.
      this.stations = new Map(list.filter((device) => device.station).map((device) => [device.id, stations.get(device.id).parts]))
      this.controls = controlList(list.filter((device) => !device.station), entities)
      this.watchRegistries()
      this.watchStates()
    } catch (error) {
      this.push("ha:devices", {error: error.code === "offline" ? "offline" : "failed"})
    }
  }

  // A watch that Home Assistant refuses (or a socket that closes) is not
  // a watch: the next read tries again. When Home Assistant refuses one of
  // the three subscriptions, the hook ends the others.
  async watchRegistries() {
    if (this.watching) return
    this.watching = true
    const changed = () => {
      if (this.reread) return
      this.reread = this.setTimer(() => {
        this.reread = null
        this.devices()
      }, REGISTRY_WAIT)
    }
    const subscriptions = ["device_registry_updated", "entity_registry_updated", "area_registry_updated"]
      .map((event) => this.subscribe("subscribe_events", {event_type: event}, changed))
    try {
      await Promise.all(subscriptions.map(({done}) => done))
    } catch {
      this.watching = false
      for (const {id, done} of subscriptions) done.then(() => this.unsubscribe(id), () => {})
    }
  }

  // Watches the states of the entities that the app turns on and off
  // (subscribe_entities). Home Assistant sends all their states first,
  // then each change. When the entities change, the hook ends the old
  // watch and starts a new one. When they do not change, the hook sends
  // the states that it has again: a new LiveView has none.
  async watchStates() {
    // The key does not change with the order of the registry. Each device
    // has a different id.
    const sorted = (map) => [...map].sort(([a], [b]) => (a < b ? -1 : 1))
    const key = JSON.stringify([sorted(this.controls), sorted(this.stations)])
    if (key === this.watched) {
      if (this.statesReady) this.sendStates()
      return
    }
    this.endStates()
    this.watched = key
    // The battery of EcoFlow BLE is also its link: one id for each entity.
    const ids = [...new Set([...this.controls.values(), ...[...this.stations.values()].flatMap(Object.values)].flat())].sort()
    // A watch with no entity gets the states of all the entities. So with
    // no entity, the hook starts no watch.
    if (ids.length === 0) return this.sendStates()
    const {id, done} = this.subscribe("subscribe_entities", {entity_ids: ids}, (event) => this.stateEvent(event))
    this.statesOf = id
    try {
      await done
    } catch {
      // A refused watch is no watch: the next read tries again.
      if (this.statesOf === id) {
        this.statesOf = null
        this.watched = null
      }
    }
  }

  // Ends the watch of the states. Its late events change nothing.
  endStates() {
    if (this.statesOf !== null) this.unsubscribe(this.statesOf)
    this.statesOf = null
    this.forgetStates()
  }

  forgetStates() {
    this.states = new Map()
    this.units = new Map()
    this.watched = null
    this.statesReady = false
    if (this.statesTimer) this.clearTimer(this.statesTimer)
    this.statesTimer = null
  }

  // An event of the watch: "a" adds states, "c" changes them, and "r"
  // removes entities. The hook also keeps the unit of each entity (the
  // attribute unit_of_measurement): "+" gives a new unit, and "-" removes
  // it. A change of the other attributes only sends nothing. The first
  // event sends the states, also with no state.
  stateEvent(event) {
    let changed = !this.statesReady
    const put = (id, state) => {
      if (this.states.get(id) !== state) changed = true
      this.states.set(id, state)
    }
    const unit = (id, value) => {
      if (this.units.get(id) === value) return
      changed = true
      if (typeof value === "string") this.units.set(id, value)
      else this.units.delete(id)
    }
    for (const [id, state] of Object.entries(event.a ?? {})) {
      put(id, state.s)
      unit(id, state.a?.unit_of_measurement)
    }
    for (const [id, change] of Object.entries(event.c ?? {})) {
      if (change["+"] && "s" in change["+"]) put(id, change["+"].s)
      if (change["+"]?.a && "unit_of_measurement" in change["+"].a) unit(id, change["+"].a.unit_of_measurement)
      if (change["-"]?.a?.includes?.("unit_of_measurement")) unit(id, undefined)
    }
    for (const id of event.r ?? []) {
      changed = this.states.delete(id) || changed
      this.units.delete(id)
    }
    this.statesReady = true
    if (!changed || this.statesTimer) return
    this.statesTimer = this.setTimer(() => {
      this.statesTimer = null
      this.sendStates()
    }, STATE_WAIT)
  }

  // Sends the state of each device to the LiveView (ha:states), and the
  // state of each station (ha:stations). With no station, the hook sends
  // the stations only one time, to clear them.
  sendStates() {
    this.push("ha:states", {states: deviceStates(this.controls, this.states)})
    if (this.stations.size === 0 && !this.stationsSent) return
    this.push("ha:stations", {stations: stationStates(this.stations, this.states, this.units)})
    this.stationsSent = this.stations.size > 0
  }

  // Sends the states that wait for the timer now.
  flushStates() {
    if (!this.statesTimer) return
    this.clearTimer(this.statesTimer)
    this.statesTimer = null
    this.sendStates()
  }

  // Turns the entities of a device on or off (call_service), for the
  // switch of its item. Or it turns the entities of a part of a station on
  // or off (part: "ac" or "dc"). It tells the end to the LiveView
  // (ha:control_done, with the part or null): with no error, or with
  // "offline" or "failed". With
  // no end after CONTROL_WAIT, it tells "timeout": Home Assistant can still
  // do the control later, and the watch then tells it. The new state comes
  // with the watch of the states, and Home Assistant sends it before the
  // end. So the hook sends the states before the end. Then the LiveView
  // never shows the old state after the end.
  async control(device, on, part = null) {
    let ended = false
    const end = (error) => {
      if (ended) return
      ended = true
      this.clearTimer(timer)
      this.flushStates()
      this.push("ha:control_done", {device, part, error})
    }
    const timer = this.setTimer(() => end("timeout"), CONTROL_WAIT)
    try {
      const ids = part === null ? this.controls.get(device) : this.stations.get(device)?.[part]
      if (!ids) throw new CommandError("unknown", "The app does not turn this device on or off")
      const domains = new Map()
      for (const id of ids) domains.set(domainOf(id), [...(domains.get(domainOf(id)) ?? []), id])
      await Promise.all([...domains].map(([domain, entityIds]) =>
        this.command("call_service", {domain, service: on ? "turn_on" : "turn_off", target: {entity_id: entityIds}})))
      end(null)
    } catch (error) {
      end(error.code === "offline" ? "offline" : "failed")
    }
  }

  // Sends the energy data of Home Assistant to the LiveView (ha:energy):
  // the meter of the house (meterMonths) and the energy of each device
  // (deviceEnergy). The energy settings of Home Assistant name their
  // sensors (energy/get_prefs), and its statistics give their kWh
  // (recorder/statistics_during_period). With no energy settings, the
  // meter is null and the list of the devices is empty. With no socket, it
  // sends {error: "offline"}. When Home Assistant refuses a command, it
  // sends {error: "failed"}.
  async energy() {
    try {
      const [prefs, entities] = await Promise.all([
        this.command("energy/get_prefs").catch((error) => {
          if (error.code === "not_found") return null
          throw error
        }),
        this.command("config/entity_registry/list"),
      ])
      const {from, to, devices} = energySources(prefs, entities)
      const zone = zoneOf(this.timeZone)
      const now = this.now()
      const read = (ids, months, period) => ids.length === 0 ? Promise.resolve({}) :
        this.command("recorder/statistics_during_period", {
          start_time: new Date(monthStart(now, months)).toISOString(),
          statistic_ids: ids,
          period,
          types: ["change"],
          units: {energy: "kWh"},
        })
      const [meter, used] = await Promise.all([
        read([...from, ...to], METER_MONTHS, "day"),
        read(devices.map((device) => device.statistic), DEVICE_MONTHS + 1, "month"),
      ])
      const months = meterMonths(meter, from, to, zone)
      this.push("ha:energy", {
        meter: months.length > 0 ? {source: "home_assistant", months} : null,
        devices: deviceEnergy(devices, used, entities, zone, monthOf(now, zone)),
        month: monthOf(now, zone),
      })
    } catch (error) {
      this.push("ha:energy", {error: error.code === "offline" ? "offline" : "failed"})
    }
  }

  // Adds an area for each room: [{room, name, level, floor}]. The level is
  // the level of the floor in Home Assistant (null: no floor), and floor is
  // the name of a new floor. It sends the areas of the rooms, and the rooms
  // that it did not add, to the LiveView (ha:areas_added).
  async addAreas(rooms) {
    const links = []
    const errors = []
    let floors = null
    for (const {room, name, level, floor} of rooms) {
      try {
        floors ??= await this.command("config/floor_registry/list")
        let at = level === null ? null : floors.find((one) => one.level === level)
        if (level !== null && !at) {
          at = await this.add("config/floor_registry", {name: floor, level}, (one) => one.level === level)
            .catch((error) => {
              if (error.code !== "invalid_info") throw error
              throw new CommandError(error.code, `Home Assistant has a floor ${floor} at a different level`)
            })
          floors.push(at)
        }
        const area = await this.add("config/area_registry", at ? {name, floor_id: at.floor_id} : {name})
        links.push({room, area: area.area_id})
      } catch (error) {
        errors.push({room, message: error.message})
      }
    }
    this.push("ha:areas_added", {links, errors})
  }

  // Adds a floor or an area. When Home Assistant already has one with the
  // same name, it gives that one, if it fits (a floor: the same level).
  async add(registry, fields, fits = () => true) {
    try {
      return await this.command(registry + "/create", fields)
    } catch (error) {
      if (error.code !== "invalid_info") throw error
      const same = (await this.command(registry + "/list"))
        .find((one) => key(one.name) === key(fields.name) && fits(one))
      if (!same) throw error
      return same
    }
  }
}

// The sign-in page of the app, in its own tab (DIYWeb.SignInLive). It
// sends its state to the LiveView with push("ha:status", state): loading,
// signing_in, done, or none with an error. The first tab gets the end with
// tell({ended: id, error}).
export class SignIn {
  constructor(deps) {
    Object.assign(this, deps)
    this.state = {state: "loading", url: null, name: null, version: null, error: null}
  }

  show(state, {url = null, error = null} = {}) {
    this.state = {state, url, name: null, version: null, error}
    this.report()
  }

  report() { this.push("ha:status", this.state) }

  // The tab opens with the address, or comes back from Home Assistant with
  // the state of the sign-in.
  start() {
    const params = new URLSearchParams(this.location.search)
    return params.has("state") ? this.finish(params) : this.begin(params)
  }

  // Goes to the sign-in page of Home Assistant. The page keeps the
  // generation of the store: a disconnect after this start ends the
  // sign-in. Only a tab of the app starts a sign-in (fromApp). Else a link
  // of a different site can send the tab to a server of its choice.
  async begin(params) {
    if (!this.fromApp) return this.end(null, null, "unasked")
    const id = signInId(params.get("id"))
    const url = address(params.get("url"))
    if (!url) return this.end(id, null, "url")
    if (blocked(this.location.protocol, url)) return this.end(id, url, "blocked")
    let generation
    try {
      generation = await this.store.generation()
    } catch {
      return this.end(id, url, "storage")
    }
    const {verifier, challenge} = await pkce(this.crypto)
    const state = randomText(this.crypto)
    this.storage.setItem(PENDING, JSON.stringify({url, state, verifier, generation, id}))
    this.show("signing_in", {url})
    this.location.replace(authorizeUrl(url, {client: clientOf(this.location), state, challenge}))
  }

  // Home Assistant sent the tab back: get the tokens for the code, and keep
  // them.
  async finish(params) {
    let pending = null
    try {
      pending = JSON.parse(this.storage.getItem(PENDING))
    } catch {
      pending = null
    }
    this.storage.removeItem(PENDING)
    // The code and the state go away from the address.
    this.history.replaceState(null, "", SIGN_IN)
    if (pending?.state !== params.get("state")) return this.end(signInId(pending?.id), null, "state")
    const {url, id} = pending
    const code = params.get("code")
    if (!code) return this.end(id, url, "denied")

    const client = clientOf(this.location)
    this.show("signing_in", {url})
    let answer
    try {
      answer = await post(this.fetch, url, "/auth/token", {
        grant_type: "authorization_code", code, client_id: client, code_verifier: pending.verifier,
      })
    } catch {
      return this.end(id, url, "unreachable")
    }
    let tokens
    try {
      if (!answer.ok) throw new Error(`HTTP ${answer.status}`)
      tokens = await answer.json()
    } catch {
      return this.end(id, url, "token")
    }
    const session = {
      url, client, access: tokens.access_token, refresh: tokens.refresh_token,
      expires: this.now() + tokens.expires_in * 1000,
    }
    let written
    try {
      written = await this.store.write(session, pending.generation)
    } catch {
      revoke(this.fetch, session)
      return this.end(id, url, "storage")
    }
    if (!written.kept) {
      revoke(this.fetch, session)
      return this.end(id, url, "cancelled")
    }
    // A different session in the store: the new sign-in replaces it.
    if (written.old && written.old.refresh !== session.refresh) revoke(this.fetch, written.old)
    this.end(id, url, null)
  }

  // The end of the sign-in: the page shows it, and the first tab gets it.
  // After a sign-in that worked, the tab closes.
  end(id, url, error) {
    if (id) this.tell({ended: id, error})
    this.show(error ? "none" : "done", {url, error})
    if (!error) this.closeTab()
  }
}

// The hook of LiveView. deps() gives the parts of the browser
// (browserParts). listen(onNews, onOnline, onConnect) gives a function that
// stops the three listeners.
export function homeAssistantHook(deps) {
  return {
    mounted() {
      // A push while LiveView connects again fails: the hook does not wait
      // for its reply (the third argument).
      this.link = new Link({...deps(), push: (event, payload) => this.pushEvent(event, payload, () => {})})
      this.handleEvent("ha:disconnect", () => this.link.disconnect())
      this.handleEvent("ha:rooms_fetch", () => this.link.rooms())
      this.handleEvent("ha:devices_fetch", () => this.link.devices())
      this.handleEvent("ha:add_areas", ({areas}) => this.link.addAreas(areas))
      this.handleEvent("ha:control", ({device, on, part}) =>
        this.link.control(device, on === true, STATION_SWITCHES.includes(part) ? part : null))
      this.handleEvent("ha:energy_fetch", () => this.link.energy())
      this.link.start()
    },
    reconnected() { this.link.report() },
    destroyed() { this.link.stop() },
  }
}

// The hook of the sign-in page. deps() gives the parts of the browser for
// SignIn (signInParts). When LiveView mounts the page again, the sign-in
// does not start again: the hook tells its state.
export function signInHook(deps) {
  let signIn = null
  return {
    mounted() {
      const push = (event, payload) => this.pushEvent(event, payload, () => {})
      if (signIn) {
        signIn.push = push
        return signIn.report()
      }
      signIn = new SignIn({...deps(), push})
      signIn.start()
    },
    reconnected() { signIn.report() },
  }
}

// The BroadcastChannel of the sign-in, or null in a browser with none.
const channelOf = (window) =>
  typeof window.BroadcastChannel === "function" ? new window.BroadcastChannel(CHANNEL) : null

// The devices of Home Assistant for the ghosts: {id, name, area, domains,
// model}. A device of a service (for example, the sun or a backup), or a
// device that the person disabled, does not count. The main entities of a
// device give its domains (light, fan, switch...). The entities of its
// configuration or of its diagnostics are not main entities, and the
// hidden or disabled ones neither. A device with no main entity does not
// count. The area of a device is its own area, else the area of its first
// main entity with an area. A device in no area does not count: it can be
// no ghost. With no name, a device has the name of its model. A power
// station (stationList()) has its maker (station), else null.
export function deviceList(devices, entities, stations = stationList(devices, entities)) {
  const main = new Map()
  for (const entity of entities.filter(isMain)) {
    if (!main.has(entity.device_id)) main.set(entity.device_id, [])
    main.get(entity.device_id).push(entity)
  }
  return devices
    .filter((device) => device.entry_type !== "service" && !device.disabled_by && main.has(device.id))
    .map((device) => {
      const own = main.get(device.id)
      return {
        id: device.id,
        name: device.name_by_user || device.name || device.model || "",
        area: device.area_id ?? own.find((entity) => entity.area_id)?.area_id ?? null,
        domains: [...new Set(own.map((entity) => domainOf(entity.entity_id)))].sort(),
        station: stations.get(device.id)?.maker ?? null,
        model: device.model ?? null,
      }
    })
    .filter((device) => device.area !== null)
}

// A main entity of a device: not of its configuration or of its
// diagnostics, and not hidden or disabled.
const isMain = (entity) =>
  !entity.entity_category && !entity.hidden_by && !entity.disabled_by && Boolean(entity.device_id)

const domainOf = (entityId) => entityId.split(".")[0]

// The entities that the app turns on and off, for each device of the list
// (deviceList). These are its main entities of a domain in CONTROLS, in
// order. A device with no such entity does not count.
export function controlList(list, entities) {
  const devices = new Set(list.map((device) => device.id))
  const controls = new Map()
  for (const entity of entities) {
    if (!devices.has(entity.device_id) || !isMain(entity) || !CONTROLS.includes(domainOf(entity.entity_id))) continue
    controls.set(entity.device_id, [...(controls.get(entity.device_id) ?? []), entity.entity_id].sort())
  }
  return controls
}

// The power stations of the devices (STATION_SOURCES): {maker, parts} for
// each station. A part is the entities of the platform of the source with
// the domain and the unique id of the part, in order. A
// disabled entity does not count. A device is a station of the first
// source that gives it a battery and a power out. All its parts come from
// this source. A part can have more entities: for example the AC outlets
// of 120 V and of 240 V of a DELTA Pro 3.
export function stationList(devices, entities) {
  const own = new Map()
  for (const entity of entities) {
    if (entity.disabled_by || !entity.device_id) continue
    own.set(entity.device_id, [...(own.get(entity.device_id) ?? []), entity])
  }
  const stations = new Map()
  for (const device of devices) {
    for (const source of STATION_SOURCES) {
      if (source.others?.test(device.model ?? "")) continue
      const parts = {}
      for (const [part, unique] of Object.entries(source.parts)) {
        const ids = (own.get(device.id) ?? [])
          .filter((entity) => entity.platform === source.platform && STATION_PARTS[part].includes(domainOf(entity.entity_id)))
          .filter((entity) => unique.test(entity.unique_id ?? ""))
          .map((entity) => entity.entity_id)
        if (ids.length > 0) parts[part] = ids.sort()
      }
      if (parts.battery && parts.output) {
        stations.set(device.id, {maker: source.maker, parts})
        break
      }
    }
  }
  return stations
}

// The state of each station. A sensor gives the first number of its
// entities, in its unit (WATTS), else null. A number out of its range is
// null: a battery is from 0 to 100 %, and a power from 0 W to MAX_POWER.
// A switch is as a device of deviceStates(). The link is true or false
// (LINKED and UNLINKED), else null: Home Assistant does not tell it. A
// part that the station does not have is null.
export function stationStates(stations, states, units = new Map()) {
  const first = (ids) => ids.find((id) => Number.isFinite(Number.parseFloat(states.get(id))))
  const number = (part, ids) => {
    const id = first(ids)
    if (id === undefined) return null
    const value = Number.parseFloat(states.get(id))
    const unit = units.get(id)
    if (part === "battery") return (unit ?? "%") === "%" && value >= 0 && value <= 100 ? value : null
    const watts = value * (WATTS.get(unit ?? "W") ?? Number.NaN)
    return watts >= 0 && watts <= MAX_POWER ? watts : null
  }
  const link = (ids) => {
    const values = ids.map((id) => states.get(id))
    if (first(ids) !== undefined || values.some((value) => LINKED.includes(value))) return true
    return values.some((value) => UNLINKED.includes(value)) ? false : null
  }
  const result = {}
  for (const [device, parts] of stations) {
    result[device] = {}
    for (const part of Object.keys(STATION_PARTS)) {
      const ids = parts[part]
      result[device][part] = !ids ? null : STATION_SWITCHES.includes(part) ? onOff(ids, states)
        : part === "link" ? link(ids) : number(part, ids)
    }
  }
  return result
}

// The state of each device that the app turns on and off (onOff()).
export function deviceStates(controls, states) {
  const result = {}
  for (const [device, ids] of controls) result[device] = onOff(ids, states)
  return result
}

// The state of some entities: "on" when one of them is on, and "off" when
// one is off and none is on. Else it is "unavailable": Home Assistant
// cannot reach them, or does not have them.
const onOff = (ids, states) => {
  const values = ids.map((id) => states.get(id))
  return values.includes("on") ? "on" : values.includes("off") ? "off" : "unavailable"
}

// The sensors of the energy settings of Home Assistant (energy/get_prefs).
// The meter of the house has the kWh from the grid and to the grid. Each
// device has its sensor. The new form of the settings has one sensor for
// each way of a grid. The old form has lists (flow_from and flow_to). A
// sensor that is a part of a different sensor of its device
// (included_in_stat) does not count: the device has its kWh already. The
// registry of the entities gives the device of each sensor.
export function energySources(prefs, entities = []) {
  const from = []
  const to = []
  for (const source of prefs?.energy_sources ?? []) {
    if (source.type !== "grid") continue
    if (typeof source.stat_energy_from === "string") from.push(source.stat_energy_from)
    if (typeof source.stat_energy_to === "string") to.push(source.stat_energy_to)
    for (const flow of source.flow_from ?? []) if (typeof flow.stat_energy_from === "string") from.push(flow.stat_energy_from)
    for (const flow of source.flow_to ?? []) if (typeof flow.stat_energy_to === "string") to.push(flow.stat_energy_to)
  }
  const deviceOf = new Map(entities.map((entity) => [entity.entity_id, entity.device_id ?? null]))
  const sameDevice = (a, b) => deviceOf.get(a) != null && deviceOf.get(a) === deviceOf.get(b)
  const devices = (prefs?.device_consumption ?? [])
    .filter((device) => typeof device.stat_consumption === "string")
    .filter((device) => !(typeof device.included_in_stat === "string" && sameDevice(device.stat_consumption, device.included_in_stat)))
    .slice(0, MAX_ENERGY_DEVICES)
    .map((device) => ({statistic: device.stat_consumption, name: typeof device.name === "string" ? device.name : null}))
  return {from: [...new Set(from)], to: [...new Set(to)], devices}
}

// A time zone that the browser knows, else UTC.
export function zoneOf(timeZone) {
  try {
    new Intl.DateTimeFormat("en-US", {timeZone: timeZone ?? "UTC"})
    return timeZone ?? "UTC"
  } catch {
    return "UTC"
  }
}

// The month ("YYYY-MM") of a time (ms) in a time zone.
export function monthOf(time, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", {timeZone, year: "numeric", month: "2-digit"}).formatToParts(new Date(time))
  const part = (type) => parts.find((one) => one.type === type).value
  return `${part("year")}-${part("month")}`
}

// The start (ms, UTC) of the month that is months - 1 months before the
// month of now: the first month of the energy data.
export function monthStart(now, months) {
  const date = new Date(now)
  return Date.UTC(date.getUTCFullYear(), date.getUTCMonth() - (months - 1), 1)
}

const daysIn = (month) => {
  const [year, number] = month.split("-").map(Number)
  return new Date(Date.UTC(year, number, 0)).getUTCDate()
}

const round = (kwh) => Math.round(kwh * 1000) / 1000

const DAY = 86_400_000

// The date of a time (ms) in a time zone, as a number of days from 1970.
export function dayOf(time, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", {timeZone, year: "numeric", month: "2-digit", day: "2-digit"})
    .formatToParts(new Date(time))
  const part = (type) => Number(parts.find((one) => one.type === type).value)
  return Date.UTC(part("year"), part("month") - 1, part("day")) / DAY
}

// The months of the meter, as a meter file gives them (DIY.Usage). Each
// month is in the time zone of Home Assistant. It has the kWh from the
// grid, the kWh to the grid, and the days with data. The rows are the
// days of the statistics ("change": the kWh since the row before). A row
// with no change does not count. After a stop of Home Assistant, a row
// can come after a gap of days. Its change is for all these days, so the
// hook divides it between them. A day can have a change under zero (a
// small dip of the sensor). The month adds its days. A month under zero
// counts as zero. Home Assistant finds a new meter itself. The last
// METER_MONTHS months only: west of UTC, the statistics start one day
// earlier, in the month before.
export function meterMonths(stats, from, to, timeZone) {
  const months = new Map()
  const add = (ids, key) => {
    for (const id of ids) {
      const rows = (stats?.[id] ?? [])
        .filter((row) => typeof row.change === "number" && typeof row.start === "number")
        .map((row) => ({day: dayOf(row.start, timeZone), change: row.change}))
        .sort((a, b) => a.day - b.day)
      let before = null
      for (const {day, change} of rows) {
        const span = before === null ? 1 : Math.max(1, day - before)
        for (let back = 0; back < span; back++) {
          const name = new Date((day - back) * DAY).toISOString().slice(0, 7)
          if (!months.has(name)) months.set(name, {month: name, kwh: 0, export: 0, days: new Set()})
          const month = months.get(name)
          month[key] += change / span
          month.days.add(day - back)
        }
        before = day
      }
    }
  }
  add(from, "kwh")
  add(to, "export")
  return [...months.values()]
    .sort((a, b) => (a.month < b.month ? -1 : 1))
    .slice(-METER_MONTHS)
    .map((month) => ({
      month: month.month,
      kwh: round(Math.max(month.kwh, 0)),
      export: round(Math.max(month.export, 0)),
      days: Math.min(month.days.size, daysIn(month.month)),
    }))
}

// The energy of each device: the kWh of each month of its sensor. The
// registry of the entities gives the device of each sensor. A sensor of
// no device (for example, a statistic of an integration) does not count,
// and a sensor with no data neither. A month under zero counts as zero.
// The first month of a sensor does not count: a new sensor has only a
// part of it. The hook reads one month more for this. The month of now
// (current) counts: the page shows it as a part of a month. The last
// DEVICE_MONTHS months only.
export function deviceEnergy(devices, stats, entities, timeZone, current) {
  const deviceOf = new Map(entities.map((entity) => [entity.entity_id, entity.device_id ?? null]))
  return devices
    .map(({statistic, name}) => {
      const months = new Map()
      for (const row of stats?.[statistic] ?? []) {
        if (typeof row.change !== "number" || typeof row.start !== "number") continue
        const month = monthOf(row.start, timeZone)
        months.set(month, (months.get(month) ?? 0) + row.change)
      }
      const sorted = [...months].sort(([a], [b]) => (a < b ? -1 : 1))
      const full = sorted.length > 0 && sorted[0][0] !== current ? sorted.slice(1) : sorted
      return {
        device: deviceOf.get(statistic) ?? null,
        statistic,
        name,
        months: full.slice(-DEVICE_MONTHS).map(([month, kwh]) => ({month, kwh: round(Math.max(kwh, 0))})),
      }
    })
    .filter((device) => device.device !== null && device.months.length > 0)
}

// The parts of the browser for the hook of a page.
export function browserParts(window) {
  const channel = channelOf(window)
  return {
    store: sessionStore(window.indexedDB, () => channel?.postMessage("changed")),
    // The news of the other tabs, the device online again, and the key
    // Connect (JS.dispatch("ha:connect") on its form).
    listen: (onNews, onOnline, onConnect) => {
      const connect = (event) => onConnect(event.target.elements.namedItem("url")?.value)
      if (channel) channel.onmessage = (event) => onNews(event.data)
      window.addEventListener("online", onOnline)
      window.addEventListener("ha:connect", connect)
      return () => {
        if (channel) channel.onmessage = null
        window.removeEventListener("online", onOnline)
        window.removeEventListener("ha:connect", connect)
      }
    },
    fetch: (...args) => window.fetch(...args),
    WebSocket: window.WebSocket,
    location: window.location,
    crypto: window.crypto,
    // The tab of the sign-in. The page keeps a link to it, to see if it
    // closed.
    openTab: (path) => window.open(path, TAB),
    now: () => Date.now(),
    setTimer: (f, ms) => window.setTimeout(f, ms),
    clearTimer: (id) => window.clearTimeout(id),
  }
}

// The parts of the browser for the sign-in page. fromApp is true when a
// page of the app opened this tab. Then the pages of Home Assistant in
// this tab get no link to the tab of the app.
export function signInParts(window) {
  let fromApp = false
  try {
    fromApp = window.opener?.location.origin === window.location.origin
  } catch {
    // The page of a different site opened this tab.
  }
  window.opener = null
  const channel = channelOf(window)
  return {
    fromApp,
    store: sessionStore(window.indexedDB, () => channel?.postMessage("changed")),
    tell: (message) => channel?.postMessage(message),
    fetch: (...args) => window.fetch(...args),
    location: window.location,
    history: window.history,
    storage: window.sessionStorage,
    crypto: window.crypto,
    now: () => Date.now(),
    closeTab: () => window.close(),
  }
}
