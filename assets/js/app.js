// The script of the page: LiveView, with the hooks of the app.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/diy"
import topbar from "../vendor/topbar"
import {deviceHook, storageOf} from "./device.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    // The build on the device (assets/js/device.js).
    Device: deviceHook({storage: storageOf(window), locks: navigator.locks, target: window}),
  },
})

// A bar at the top of the page while a page or a form loads.
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket
