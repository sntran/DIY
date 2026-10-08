// The build stays on the device: in the localStorage of the browser, under
// one key. The server keeps no copy. The LiveView of the page holds the
// build while the page is open, and sends each new build to this module.
//
// The protocol (docs/design.md, "The build on the device", and the TLA+
// model specs/Device.tla):
//
// 1. At the mount, the hook sends the stored text and its stamp to the
//    LiveView ("device:restore"). The LiveView reads the text, or starts a
//    new build.
// 2. After each change, the LiveView sends "device:save" with the new text,
//    the base (the stamp of the stored build that the change comes from)
//    and its epoch. Each change makes a new stamp. The hook writes the text
//    only if the stored stamp is the base (compare and set, in a Web Lock
//    for all the tabs). Else a different tab wrote first: the hook sends
//    "device:conflict" with the stored text, its stamp and the epoch of the
//    save.
// 3. When a different tab writes, the browser gives a "storage" event. The
//    hook sends "device:changed" with the new text and its stamp.

export const KEY = "diy.build"
export const LOCK = "diy.build"

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

// Runs fn with the lock of the build. A browser with no Web Locks runs fn
// directly: then only the compare and set protects the build.
export function withLock(locks, fn) {
  if (locks && typeof locks.request === "function") return locks.request(LOCK, fn)
  return Promise.resolve().then(fn)
}

const message = (error) => String(error && error.message || error)

// Writes text if the stored stamp is base. The result is {saved: stamp},
// {conflict: storedText, stamp: storedStamp}, or {error: message}.
export function save(storage, locks, {text, base}) {
  return withLock(locks, () => {
    let stored
    try {
      stored = storage.getItem(KEY)
    } catch (error) {
      return {error: message(error)}
    }
    const stamp = stampOf(stored)
    if (stamp !== base) return {conflict: stored, stamp}
    try {
      storage.setItem(KEY, text)
      return {saved: stampOf(text)}
    } catch (error) {
      // For example QuotaExceededError: the device has no space.
      return {error: message(error)}
    }
  })
}

// The localStorage of the window. A browser can refuse it (for example with
// all the data of sites off): then each save gives an error, and the page
// tells the person.
export function storageOf(win) {
  try {
    if (win.localStorage) return win.localStorage
  } catch {
    // The browser refuses the storage.
  }
  return {
    getItem() { return null },
    setItem() { throw new Error("The browser does not let this page keep data.") },
  }
}

// The stored text, or null when the browser refuses the storage.
export function load(storage) {
  try {
    return storage.getItem(KEY)
  } catch {
    return null
  }
}

// The LiveView hook. The page gives it the storage, the locks and the
// window, so that the tests can give fakes.
export function deviceHook({storage, locks, target}) {
  return {
    mounted() {
      const text = load(storage)
      this.pushEvent("device:restore", {text, stamp: stampOf(text)})

      this.handleEvent("device:save", ({text, base, epoch}) =>
        save(storage, locks, {text, base}).then((result) => {
          if ("saved" in result) this.pushEvent("device:saved", {stamp: result.saved})
          else if ("conflict" in result) this.pushEvent("device:conflict", {text: result.conflict, stamp: result.stamp, epoch})
          else this.pushEvent("device:error", result)
        }))

      this.onStorage = (event) => {
        if (event.key === KEY) this.pushEvent("device:changed", {text: event.newValue, stamp: stampOf(event.newValue)})
      }
      target.addEventListener("storage", this.onStorage)
    },

    destroyed() {
      target.removeEventListener("storage", this.onStorage)
    },
  }
}
