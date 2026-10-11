// The sign-in to Home Assistant on the device, and the socket of the page
// to Home Assistant (docs/design.md, "Home Assistant", and the TLA+ model
// specs/HomeAssistant.tla).
//
// - The person gives the address of Home Assistant, on the screen of a hub
//   or in Settings. The key Connect opens the sign-in page of the app
//   (SIGN_IN) in a new tab. The tab opens in the tap: a browser blocks a
//   tab that a page opens later.
// - The new tab (SignIn) makes a random state and a PKCE challenge, and
//   keeps them in its sessionStorage. It goes to the sign-in page of Home
//   Assistant. Home Assistant sends it back with a code. The new tab gets
//   the tokens for the code, and keeps them in IndexedDB, for all the tabs.
//   The server of the app never sees them. Then the new tab tells its end
//   to the first tab, and closes.
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

const post = (fetch, url, path, fields) =>
  fetch(url + path, {method: "POST", body: new URLSearchParams(fields)})

// Ends a session on Home Assistant. The hook does not wait for it.
const revoke = (fetch, session) => {
  post(fetch, session.url, "/auth/revoke", {token: session.refresh}).catch(() => {})
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
    this.next = CONFIG + 1
    this.wait = FIRST_WAIT
    this.invalids = 0
    this.version = null
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

  // The socket is gone: the commands on it get no answer.
  drop() {
    for (const {reject} of this.commands.values()) reject(offline())
    this.commands.clear()
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

  async message(socket, epoch, message) {
    if (socket !== this.socket) return
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
  // sign-in.
  async begin(params) {
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
    if (pending?.state !== params.get("state")) return this.end(null, null, "state")
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
      this.link = new Link({...deps(), push: (event, payload) => this.pushEvent(event, payload)})
      this.handleEvent("ha:disconnect", () => this.link.disconnect())
      this.handleEvent("ha:rooms_fetch", () => this.link.rooms())
      this.handleEvent("ha:add_areas", ({areas}) => this.link.addAreas(areas))
      this.link.start()
    },
    reconnected() { this.link.report() },
    destroyed() { this.link.stop() },
  }
}

// The hook of the sign-in page. deps() gives the parts of the browser for
// SignIn: store, tell, fetch, location, history, storage, crypto, now and
// closeTab. When LiveView mounts the page again, the sign-in does not start
// again: the hook tells its state.
export function signInHook(deps) {
  let signIn = null
  return {
    mounted() {
      const push = (event, payload) => this.pushEvent(event, payload)
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

// The parts of the browser for the sign-in page. The pages of Home
// Assistant in this tab get no link to the tab of the app.
export function signInParts(window) {
  window.opener = null
  const channel = channelOf(window)
  return {
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
