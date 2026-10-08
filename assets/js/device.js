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
// - In the transaction of a write, the hook tells the other tabs with a
//   BroadcastChannel. The hook of each other tab then reads the store in
//   its queue, and sends "device:changed" with that build. IndexedDB runs
//   that read after the write. After the write, the hook sends
//   "device:saved".
// - When a save fails, the hook sends "device:error" with the stored stamp
//   that it saw.
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

// The store of the build in IndexedDB: read() gives the stored text, and
// save(message, report, notify) does the compare and set. report gets the
// result at the time of the observation: {conflict, stamp} in the
// transaction, {saved} or {error, stamp} at its end. notify runs in the
// transaction of a write.
//
// The store opens the database at the first use. The browser closes it
// when the user removes the data of the site: then the store opens it
// again, one time for each operation. The store closes the connection when
// a newer version of the app opens the database with a new version, so
// that the new version does not wait for this tab.
export function indexedStore(factory) {
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

  // Runs task(db). A closed database gives InvalidStateError: then open it
  // again, and run the task one more time.
  const run = (task) => connect().then((db) => {
    try {
      return task(db)
    } catch (error) {
      if (error && error.name === "InvalidStateError") {
        connection = null
        return connect().then(task)
      }
      throw error
    }
  })

  return {
    connection: connect,

    read() {
      return run((db) => {
        const request = db.transaction(STORE, "readonly").objectStore(STORE).get(KEY)
        return new Promise((resolve, reject) => {
          request.onsuccess = () => resolve(request.result === undefined ? null : request.result)
          request.onerror = () => reject(request.error)
        })
      })
    },

    save({text, base, backup}, report, notify = () => {}) {
      let stamp = ""
      let done = false
      const end = (result) => {
        if (!done) {
          done = true
          report(result)
        }
      }
      return run((db) => {
        const tx = db.transaction(STORE, "readwrite")
        return new Promise((resolve) => {
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
            notify()
          }
          // After a conflict, end() has its result already.
          tx.oncomplete = () => {
            end({saved: stampOf(text)})
            resolve()
          }
          tx.onabort = () => {
            end({error: message(tx.error || "The browser stopped the save."), stamp})
            resolve()
          }
        })
      }).catch((error) => end({error: message(error), stamp}))
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
  return factory
    ? indexedStore(factory)
    : refusedStore("The browser does not let this page keep data.")
}

// The LiveView hook. store() gives the store, and channel() gives a
// BroadcastChannel (or null), so that the tests can give fakes.
export function deviceHook({store, channel}) {
  return {
    mounted() {
      this.store = store()
      this.queue = Promise.resolve()
      this.restore()

      this.channel = channel()
      this.handleEvent("device:save", (save) =>
        this.enqueue((s) => s.save(save, (result) => this.report(result, save), () => this.tell())))

      // A write of a different tab: read the store, in the queue.
      if (this.channel) {
        this.channel.onmessage = () => this.enqueue((s) => s.read().then(
          (text) => this.push("device:changed", {text, stamp: stampOf(text)}),
          () => undefined))
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
      this.queue = this.queue.then(() => task(this.store))
      return this.queue
    },

    // Tells the other tabs about a write, in its transaction.
    tell() {
      if (this.channel) this.channel.postMessage("write")
    },

    report(result, {epoch}) {
      if ("saved" in result) {
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
