// The script of the page: LiveView, with the hooks of the app.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/diy"
import topbar from "../vendor/topbar"
import {deviceHook, storeOf, CHANNEL} from "./device.js"
import {planHook} from "./plan.js"
import {sheetHook} from "./sheet.js"
import {shareHook} from "./share.js"
import {stageHook} from "./stage.js"
import {topHook} from "./top.js"
import {usageHook} from "./usage.js"
import {eflHook, eflLinksHook} from "./efl.js"
import {homeAssistantHook, browserParts, signInHook, signInParts} from "./home_assistant.js"
import {makerLinkHook, makerParts} from "./maker_link.js"

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
    // The share of the link of a house (assets/js/share.js).
    Share: shareHook,
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
    // The direct link to the cloud of the maker of a power station, with
    // the token on the device (assets/js/maker_link.js).
    MakerLink: makerLinkHook(() => makerParts(window)),
  },
})

// A key that goes away gives the focus to an element of the page with the
// event "diy:focus" (JS.dispatch/2). The focus moves at once. JS.focus/1
// also moves it again after two frames, and then it can take the focus
// from a key that the person uses after it.
window.addEventListener("diy:focus", (event) => event.target.focus())
// The LiveView moves the focus after its patch (push_event "diy:focus"),
// for example when the key with the focus goes with its part.
window.addEventListener("phx:diy:focus", (event) => document.querySelector(event.detail.to)?.focus())

// A bar at the top of the page while a page or a form loads.
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket
