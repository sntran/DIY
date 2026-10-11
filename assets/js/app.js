// The script of the page: LiveView, with the hooks of the app.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/diy"
import topbar from "../vendor/topbar"
import {deviceHook, storeOf, CHANNEL} from "./device.js"
import {planHook} from "./plan.js"
import {sheetHook} from "./sheet.js"
import {stageHook} from "./stage.js"
import {topHook} from "./top.js"
import {usageHook} from "./usage.js"
import {eflHook, eflLinksHook} from "./efl.js"
import {homeAssistantHook, browserParts, signInHook, signInParts} from "./home_assistant.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    // The build on the device (assets/js/device.js).
    Device: deviceHook({
      store: () => storeOf(window),
      channel: () => typeof BroadcastChannel === "function" ? new BroadcastChannel(CHANNEL) : null,
    }),
    // The plan of the house at scale: the drag and the zoom (assets/js/plan.js).
    Plan: planHook,
    // A sheet over the page: the Escape key and the focus (assets/js/sheet.js).
    Sheet: sheetHook,
    Stage: stageHook(),
    // A new page starts at its top (assets/js/top.js).
    Top: topHook,
    // A usage file of a meter, read on the device (assets/js/usage.js).
    UsageFile: usageHook,
    // The EFL of a plan, read on the device (assets/js/efl.js).
    EflFile: eflHook,
    EflLinks: eflLinksHook,
    // The sign-in to Home Assistant, on the device (assets/js/home_assistant.js).
    HomeAssistant: homeAssistantHook(() => browserParts(window)),
    // The sign-in page of Home Assistant, in its own tab.
    HomeAssistantSignIn: signInHook(() => signInParts(window)),
  },
})

// A bar at the top of the page while a page or a form loads.
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket
