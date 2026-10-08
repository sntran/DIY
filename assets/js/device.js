// The build stays on the device: in IndexedDB, in the browser of the user.
// The server keeps no copy. The LiveView of the page holds the build while
// the page is open, and sends each new build to this hook.
//
// The protocol (docs/design.md, "The build on the device", and the TLA+
// model specs/Device.tla):
//
// - At the mount and after each reconnect, the hook reads the store and
//   sends the text and its stamp ("device:restore"). The read waits for the
//   saves before it, and a new read replaces an old one.
// - After each change, the LiveView sends "device:save" with the new text,
//   the base (the stamp of the stored build that the change comes from) and
//   its epoch. The hook takes the saves in order. For each one, it reads and
//   writes in one transaction (compare and set): it writes only if the
//   stored stamp is the base. Else it sends "device:conflict" with the
//   stored text, its stamp and the epoch of the save.
// - After a write, the hook sends "device:saved", and tells the other tabs
//   with a BroadcastChannel. A different tab sends "device:changed".
// - When a write fails, the hook sends "device:error" with the stored stamp.
//
// The hook sends what it sees of the store in the order that it sees it: a
// conflict goes at once, in the transaction, before a different tab can
// write. IndexedDB runs the transactions of all the tabs one at a time, so
// the compare and set is atomic. (localStorage is not: each process of
// the browser can keep its own copy.)

export const DB = "diy"
export const STORE = "build"
export const KEY = "build"
export const BACKUP = "backup"
export const CHANNEL = "diy.build"

// The stamp of a stored text: "" for no text, or for a text with no stamp.
export function stampOf(text) {
  if (typeof text !== "string") return ""
  try {
    const build = JSON.parse(text)
    const stamp = build && build.stamp
    return typeof stamp === "string" ? stamp : ""
  } catch {
    return ""
  }
}

const message = (error) => String(error && error.message || error)

// Opens the database of the build.
export function open(factory) {
  return new Promise((resolve, reject) => {
    const request = factory.open(DB, 1)
    request.onupgradeneeded = () => request.result.createObjectStore(STORE)
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

// The store of the build in a database: read() gives the stored text, and
// save(message, report) does the compare and set. report gets the result
// at the time of the observation: {conflict, stamp} in the transaction,
// {saved} or {error, stamp} at its end.
export function indexedStore(db) {
  return {
    read() {
      return new Promise((resolve, reject) => {
        const request = db.transaction(STORE, "readonly").objectStore(STORE).get(KEY)
        request.onsuccess = () => resolve(request.result === undefined ? null : request.result)
        request.onerror = () => reject(request.error)
      })
    },

    save({text, base, backup}, report) {
      return new Promise((resolve) => {
        let stamp = ""
        let done = false
        const end = (result) => {
          if (!done) {
            done = true
            report(result)
          }
          resolve()
        }
        let tx
        try {
          tx = db.transaction(STORE, "readwrite")
        } catch (error) {
          end({error: message(error), stamp})
          return
        }
        const store = tx.objectStore(STORE)
        const get = store.get(KEY)
        get.onsuccess = () => {
          const stored = get.result === undefined ? null : get.result
          stamp = stampOf(stored)
          if (stamp !== base) {
            end({conflict: stored, stamp})
            return
          }
          if (backup && stored !== null) store.put(stored, BACKUP)
          store.put(text, KEY)
          tx.oncomplete = () => end({saved: stampOf(text)})
        }
        tx.onabort = () => end({error: message(tx.error || "The browser stopped the save."), stamp})
      })
    },
  }
}

// A store that refuses each save: the browser gives no IndexedDB (for
// example with all the data of sites off). The page tells the user.
export function refusedStore(reason) {
  return {
    read: () => Promise.resolve(null),
    save(_message, report) {
      report({error: reason, stamp: ""})
      return Promise.resolve()
    },
  }
}

// The store of a window: IndexedDB, or a refused store.
export function storeOf(win) {
  let factory
  try {
    factory = win.indexedDB
  } catch {
    factory = null
  }
  if (!factory) return Promise.resolve(refusedStore("The browser does not let this page keep data."))
  return open(factory).then(indexedStore, (error) => refusedStore(message(error)))
}

// The LiveView hook. store() gives a promise of the store, and channel()
// gives a BroadcastChannel (or null), so that the tests can give fakes.
export function deviceHook({store, channel}) {
  return {
    mounted() {
      this.store = store()
      this.queue = Promise.resolve()
      this.restore()

      this.handleEvent("device:save", (save) =>
        this.enqueue((s) => s.save(save, (result) => this.report(result, save))))

      this.channel = channel()
      if (this.channel) {
        this.channel.onmessage = (event) =>
          this.push("device:changed", {text: event.data, stamp: stampOf(event.data)})
      }
    },

    // A new LiveView after a reconnect: it waits for the build.
    reconnected() {
      this.restore()
    },

    destroyed() {
      if (this.channel) this.channel.close()
    },

    // Reads the store after the saves of the queue. A new read replaces the
    // reads before it: an old read can come before saves of the queue, and
    // then its build is old.
    restore() {
      const read = this.reads = (this.reads || 0) + 1
      this.enqueue((s) => {
        if (read !== this.reads) return undefined
        return s.read().then(
          (text) => this.push("device:restore", {text, stamp: stampOf(text)}),
          () => this.push("device:restore", {text: null, stamp: ""}))
      })
    },

    // Runs the tasks of the store one at a time, in order.
    enqueue(task) {
      this.queue = this.queue.then(() => this.store).then(task)
      return this.queue
    },

    report(result, {text, epoch}) {
      if ("saved" in result) {
        if (this.channel) this.channel.postMessage(text)
        this.push("device:saved", {stamp: result.saved})
      } else if ("conflict" in result) {
        this.push("device:conflict", {text: result.conflict, stamp: result.stamp, epoch})
      } else {
        this.push("device:error", {error: result.error, stamp: result.stamp, epoch})
      }
    },

    // A push while the socket is down goes nowhere: the restore after the
    // reconnect gives the build again.
    push(name, payload) {
      try {
        const sent = this.pushEvent(name, payload)
        if (sent && typeof sent.catch === "function") sent.catch(() => {})
      } catch {
        // The LiveView is not connected.
      }
    },
  }
}
