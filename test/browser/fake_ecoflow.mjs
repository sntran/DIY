// A fake cloud of EcoFlow for the browser test: the API for developers
// (assets/js/ecoflow.js). The page calls this API directly, so the test
// serves it in the browser, as a route of Playwright. Each answer has the
// CORS headers that EcoFlow sends. The fake checks the keys and the
// signature of each request, as EcoFlow does: a wrong access key gives
// 8513, and a wrong signature 8521. The account has a DELTA Pro 3 with
// its AC outlets on, and a Wave (not a station).

import { createHmac } from "node:crypto"
import { LIST, QUOTA, SET, signText } from "../../assets/js/ecoflow.js"

export function fakeEcoFlow({ accessKey = "walk-access", secretKey = "walk-secret" } = {}) {
  const fake = { calls: [], quota: { cmsBattSoc: 57, powInSumW: 0, powOutSumW: 2310, flowInfoAcHvOut: 2, flowInfoAcLvOut: 2, flowInfo12v: 0 } }

  // The command of a DELTA Pro 3 sets one key of its state: 2 is on, and
  // 0 is off.
  const keys = { cfgHvAcOutOpen: "flowInfoAcHvOut", cfgLvAcOutOpen: "flowInfoAcLvOut", cfgDc12vOutOpen: "flowInfo12v" }

  fake.route = async (route) => {
    const request = route.request()
    const cors = {
      "access-control-allow-origin": request.headers().origin ?? "*",
      "access-control-allow-methods": "GET, POST, PUT, DELETE, OPTIONS",
      "access-control-allow-headers": "accesskey, nonce, timestamp, sign, content-type",
    }
    if (request.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors })
    const answer = (body) =>
      route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify(body) })

    const url = new URL(request.url())
    const headers = request.headers()
    const params = request.method() === "PUT" ? JSON.parse(request.postData()) : Object.fromEntries(url.searchParams)
    fake.calls.push({ method: request.method(), path: url.pathname, params })
    if (headers.accesskey !== accessKey) return answer({ code: "8513", message: "accessKey is invalid" })
    const text = signText(Object.keys(params).length > 0 ? params : null, headers.accesskey, headers.nonce, headers.timestamp)
    if (createHmac("sha256", secretKey).update(text).digest("hex") !== headers.sign) {
      return answer({ code: "8521", message: "signature is wrong" })
    }

    if (url.pathname === LIST) {
      return answer({ code: "0", data: [
        { sn: "DP3WALK", deviceName: "Garage EcoFlow", online: 1, productName: "DELTA Pro 3" },
        { sn: "WAVEWALK", deviceName: "Bedroom air", online: 1, productName: "Wave 2" },
      ] })
    }
    if (url.pathname === QUOTA) return answer({ code: "0", data: fake.quota })
    if (url.pathname === SET) {
      for (const [key, on] of Object.entries(params.params ?? {})) fake.quota[keys[key]] = on ? 2 : 0
      return answer({ code: "0", message: "Success" })
    }
    return answer({ code: "1000", message: "unknown path" })
  }
  return fake
}
