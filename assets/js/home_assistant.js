// The sign-in to Home Assistant on the device, and the socket of the page
// to Home Assistant (docs/design.md, "Home Assistant", and the TLA+ model
// specs/HomeAssistant.tla).
//
// - The person gives the address of Home Assistant. The hook sends the
//   browser to the sign-in page of Home Assistant, with a random state and
//   a PKCE challenge. The state and the verifier stay in sessionStorage of
//   the tab.
// - Home Assistant sends the browser back to /settings with a code. The
//   hook gets the tokens for the code, and keeps them in IndexedDB, for all
//   the tabs. The server of the app never sees them.
// - The hook opens a WebSocket to Home Assistant with the access token.
//   When a socket signs in, the hook first gets a new access token if the
//   old one ends in 60 seconds or less. A socket that signed in stays open
//   after the end of its access token.
// - A disconnect clears the store, and revokes the session on Home
//   Assistant. A BroadcastChannel tells the other tabs to read the store.
//
// Three rules come from the model:
// - The epoch: a disconnect makes a new epoch of the tab. An answer of an
//   old epoch keeps nothing. An exchange of an old epoch revokes its new
//   session.
// - The compare and set: a refresh writes its access token only when the
//   store still has the same refresh token.
// - The owner: a refused refresh ends only the socket of its own session.

export const DB = "diy-ha"
export const STORE = "session"
export const KEY = "session"
export const CHANNEL = "diy.ha"
export const PENDING = "diy.ha.pending"
// The page of the app where Home Assistant sends the browser back.
export const BACK = "/settings"
// A socket that signs in gets a new access token when the old one ends in
// 60 seconds or less.
export const EARLY = 60_000
// The first and the longest wait before the hook opens the socket again.
export const FIRST_WAIT = 1_000
export const MAX_WAIT = 60_000

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

// The client of the app for Home Assistant: the address of the app.
export const clientOf = (location) => location.origin + "/"

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

// The sign-in page of Home Assistant for this app.
export function authorizeUrl(url, {client, state, challenge}) {
  const query = new URLSearchParams({
    response_type: "code",
    client_id: client,
    redirect_uri: client.replace(/\/$/, "") + BACK,
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  })
  return `${url}/auth/authorize?${query}`
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

// The store of the session in IndexedDB. Each operation is one
// transaction. notify() runs in the transaction of a write or a clear.
// The store opens the database again when the browser closed it (the
// person removed the data of the site).
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

  // Reads the session, and gives it to change(store, session) in the same
  // transaction. The result of change is the result of the operation.
  const run = (mode, change) => connect().then((db) => new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode)
    const store = tx.objectStore(STORE)
    let result = null
    store.get(KEY).onsuccess = (event) => { result = change(store, event.target.result ?? null) }
    tx.oncomplete = () => resolve(result)
    tx.onabort = () => reject(tx.error)
  }))

  return {
    read: () => run("readonly", (_store, session) => session),
    // Writes a new session, and gives the old one.
    write: (session) => run("readwrite", (store, old) => {
      store.put(session, KEY)
      notify()
      return old
    }),
    // Writes new fields of the session with this refresh token. False when
    // the store has a different session (the compare and set).
    update: (refresh, fields) => run("readwrite", (store, session) => {
      if (!session || session.refresh !== refresh) return false
      store.put({...session, ...fields}, KEY)
      return true
    }),
    // Clears the session (only the one with this refresh token, if given),
    // and gives it.
    clear: (refresh) => run("readwrite", (store, session) => {
      if (!session || (refresh !== undefined && session.refresh !== refresh)) return null
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

  // The start of the page: a sign-in that comes back, or the stored
  // session.
  start() {
    this.unlisten = this.listen(() => this.load(this.epoch), () => this.again())
    const params = new URLSearchParams(this.location.search)
    return params.has("state") ? this.finish(params) : this.load(this.epoch)
  }

  // The hook goes away (LiveView mounts the page again): no more news, no
  // more tries, and no socket.
  stop() {
    this.epoch += 1
    this.close()
    this.session = null
    this.unlisten()
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
    if (!session) return this.show("none", {error})
    this.open(epoch)
  }

  // The person asks to connect: the browser goes to the sign-in page.
  async connect(text) {
    const url = address(text)
    if (!url) return this.show("none", {error: "url", url: null})
    if (blocked(this.location.protocol, url)) return this.show("none", {error: "blocked", url})
    const {verifier, challenge} = await pkce(this.crypto)
    const state = randomText(this.crypto)
    this.storage.setItem(PENDING, JSON.stringify({url, state, verifier}))
    this.show("signing_in", {url})
    this.location.assign(authorizeUrl(url, {client: clientOf(this.location), state, challenge}))
  }

  // The sign-in page sent the browser back: get the tokens for the code.
  async finish(params) {
    const epoch = this.epoch
    let pending = null
    try {
      pending = JSON.parse(this.storage.getItem(PENDING))
    } catch {
      pending = null
    }
    this.storage.removeItem(PENDING)
    // Keep the state of LiveView in the history: Back needs it.
    this.history.replaceState(this.history.state, "", this.location.pathname)
    if (!pending || pending.state !== params.get("state")) return this.load(epoch, "state")
    const code = params.get("code")
    if (!code) return this.load(epoch, "denied")

    const {url} = pending
    const client = clientOf(this.location)
    this.show("signing_in", {url})
    let answer
    try {
      answer = await this.post(url, "/auth/token", {
        grant_type: "authorization_code", code, client_id: client, code_verifier: pending.verifier,
      })
    } catch {
      return this.show("none", {url, error: "unreachable"})
    }
    let tokens
    try {
      if (!answer.ok) throw new Error(`HTTP ${answer.status}`)
      tokens = await answer.json()
    } catch {
      return this.show("none", {url, error: "token"})
    }
    const session = {
      url, client, access: tokens.access_token, refresh: tokens.refresh_token,
      expires: this.now() + tokens.expires_in * 1000,
    }
    if (epoch !== this.epoch) return this.revoke(session)
    let old
    try {
      old = await this.store.write(session)
    } catch {
      this.revoke(session)
      return this.show("none", {url, error: "storage"})
    }
    if (old && old.refresh !== session.refresh) this.revoke(old)
    if (epoch !== this.epoch) return
    this.close()
    this.session = session
    this.open(epoch)
  }

  // The person asks to disconnect.
  async disconnect() {
    this.epoch += 1
    const epoch = this.epoch
    this.close()
    this.session = null
    let old = null
    try {
      old = await this.store.clear()
    } catch {
      old = null
    }
    if (old) this.revoke(old)
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
    socket?.close()
  }

  async message(socket, epoch, message) {
    if (socket !== this.socket) return
    if (message.type === "auth_required") {
      const access = await this.access(epoch)
      if (access && socket === this.socket) socket.send(JSON.stringify({type: "auth", access_token: access}))
    } else if (message.type === "auth_ok") {
      this.invalids = 0
      this.version = message.ha_version
      socket.send(JSON.stringify({id: 1, type: "get_config"}))
    } else if (message.type === "auth_invalid") {
      this.invalid(epoch)
    } else if (message.type === "result" && message.id === 1 && message.success) {
      this.wait = FIRST_WAIT
      this.show("connected", {name: message.result.location_name, version: this.version})
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
      answer = await this.post(session.url, "/auth/token", {
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

  revoke(session) {
    this.post(session.url, "/auth/revoke", {token: session.refresh}).catch(() => {})
  }

  post(url, path, fields) {
    return this.fetch(url + path, {method: "POST", body: new URLSearchParams(fields)})
  }
}

// The hook of LiveView. deps() gives the parts of the browser: store,
// listen, fetch, WebSocket, location and history. It also gives storage
// (sessionStorage), crypto, now, setTimer and clearTimer.
// listen(onNews, onOnline) gives a function that stops the two listeners.
export function homeAssistantHook(deps) {
  return {
    mounted() {
      this.link = new Link({...deps(), push: (event, payload) => this.pushEvent(event, payload)})
      this.handleEvent("ha:connect", ({url}) => this.link.connect(url))
      this.handleEvent("ha:disconnect", () => this.link.disconnect())
      this.link.start()
    },
    reconnected() { this.link.report() },
    destroyed() { this.link.stop() },
  }
}

// The parts of the browser for the hook.
export function browserParts(window) {
  const channel = typeof window.BroadcastChannel === "function" ? new window.BroadcastChannel(CHANNEL) : null
  return {
    store: sessionStore(window.indexedDB, () => channel?.postMessage("changed")),
    listen: (onNews, onOnline) => {
      if (channel) channel.onmessage = onNews
      window.addEventListener("online", onOnline)
      return () => {
        if (channel) channel.onmessage = null
        window.removeEventListener("online", onOnline)
      }
    },
    fetch: (...args) => window.fetch(...args),
    WebSocket: window.WebSocket,
    location: window.location,
    history: window.history,
    storage: window.sessionStorage,
    crypto: window.crypto,
    now: () => Date.now(),
    setTimer: (f, ms) => window.setTimeout(f, ms),
    clearTimer: (id) => window.clearTimeout(id),
  }
}
