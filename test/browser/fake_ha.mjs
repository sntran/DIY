// A fake Home Assistant for the browser test. It has the sign-in page,
// the tokens, the revoke and the WebSocket API: only the parts that the
// app uses. The registry of the floors and of the areas refuses a second
// floor or area with the same name, as Home Assistant does. It has the
// registries of the devices and of their entities. The sign-in
// page has a link "Log in" that sends the tab back with a code. The token
// endpoint checks the client, the way back and the PKCE verifier, as Home
// Assistant does.

import http from "node:http"
import { createHash, randomBytes } from "node:crypto"
import { WebSocketServer } from "ws"

const random = () => randomBytes(12).toString("hex")

const read = (request) => new Promise((resolve) => {
  let text = ""
  request.on("data", (chunk) => { text += chunk })
  request.on("end", () => resolve(new URLSearchParams(text)))
})

// The name of a floor or an area for a match: no case and no spaces.
const key = (name) => name.toUpperCase().toLowerCase().replaceAll(" ", "")

export async function fakeHomeAssistant({
  name = "Fake house",
  version = "2026.10.0",
  floors = [],
  areas = [],
  admin = true,
  devices = [],
  entities = [],
} = {}) {
  const registry = { floors: structuredClone(floors), areas: structuredClone(areas), devices, entities }
  const codes = new Map()
  const sessions = new Map()
  const accesses = new Map()
  const revoked = []

  const json = (response, status, body) => {
    response.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" })
    response.end(JSON.stringify(body))
  }

  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, "http://fake")
    if (request.method === "OPTIONS") {
      response.writeHead(200, {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST",
        "Access-Control-Allow-Headers": "Content-Type",
      })
      return response.end()
    }

    if (url.pathname === "/auth/authorize") {
      const query = url.searchParams
      const client = new URL(query.get("client_id"))
      const back = new URL(query.get("redirect_uri"))
      if (client.origin !== back.origin) return json(response, 400, { error: "invalid_request" })
      const code = random()
      codes.set(code, { client: query.get("client_id"), challenge: query.get("code_challenge") })
      // Home Assistant adds its answer to the query of the way back.
      back.searchParams.append("code", code)
      back.searchParams.append("state", query.get("state"))
      const href = back.toString().replaceAll("&", "&amp;").replaceAll('"', "&quot;")
      response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" })
      return response.end(
        `<!doctype html><html lang="en"><title>Fake house</title>` +
          `<main><h1>Fake house</h1><a id="log-in" href="${href}">Log in</a></main></html>`,
      )
    }

    const form = await read(request)
    if (url.pathname === "/auth/token" && form.get("grant_type") === "authorization_code") {
      const entry = codes.get(form.get("code"))
      codes.delete(form.get("code"))
      const verifier = form.get("code_verifier") ?? ""
      const challenge = createHash("sha256").update(verifier).digest("base64url")
      if (!entry || entry.client !== form.get("client_id") || entry.challenge !== challenge) {
        return json(response, 400, { error: "invalid_request" })
      }
      const refresh = random()
      const access = random()
      sessions.set(refresh, new Set([access]))
      accesses.set(access, refresh)
      return json(response, 200, { access_token: access, refresh_token: refresh, expires_in: 1800, token_type: "Bearer" })
    }

    if (url.pathname === "/auth/token" && form.get("grant_type") === "refresh_token") {
      const refresh = form.get("refresh_token")
      if (!sessions.has(refresh)) return json(response, 400, { error: "invalid_grant" })
      const access = random()
      sessions.get(refresh).add(access)
      accesses.set(access, refresh)
      return json(response, 200, { access_token: access, expires_in: 1800, token_type: "Bearer" })
    }

    if (url.pathname === "/auth/revoke") {
      const refresh = form.get("token")
      revoked.push(refresh)
      for (const access of sessions.get(refresh) ?? []) accesses.delete(access)
      sessions.delete(refresh)
      return json(response, 200, {})
    }

    json(response, 404, {})
  })

  // The commands of the registry, and the user.
  const command = (message) => {
    const ok = (result) => ({ success: true, result })
    const inUse = (list) => list.some((one) => key(one.name) === key(message.name))
    const refuse = () => ({
      success: false,
      error: { code: "invalid_info", message: `The name ${message.name} (${key(message.name)}) is already in use` },
    })
    switch (message.type) {
      case "config/floor_registry/list":
        return ok(registry.floors)
      case "config/area_registry/list":
        return ok(registry.areas)
      case "auth/current_user":
        return ok({ id: "u1", name: "Owner", is_admin: admin })
      case "config/device_registry/list":
        return ok(registry.devices)
      case "config/entity_registry/list":
        return ok(registry.entities)
      case "config/floor_registry/create": {
        if (inUse(registry.floors)) return refuse()
        const floor = { floor_id: key(message.name), name: message.name, level: message.level ?? null, aliases: [] }
        registry.floors.push(floor)
        return ok(floor)
      }
      case "config/area_registry/create": {
        if (inUse(registry.areas)) return refuse()
        const area = { area_id: key(message.name), name: message.name, floor_id: message.floor_id ?? null }
        registry.areas.push(area)
        return ok(area)
      }
      default:
        return { success: false, error: { code: "unknown_command", message: "Unknown command." } }
    }
  }

  const sockets = new WebSocketServer({ noServer: true })
  server.on("upgrade", (request, socket, head) => {
    if (request.url !== "/api/websocket") return socket.destroy()
    sockets.handleUpgrade(request, socket, head, (ws) => {
      const send = (message) => ws.send(JSON.stringify(message))
      send({ type: "auth_required", ha_version: version })
      ws.on("message", (data) => {
        const message = JSON.parse(data)
        if (message.type === "auth") {
          if (accesses.has(message.access_token)) {
            send({ type: "auth_ok", ha_version: version })
          } else {
            send({ type: "auth_invalid", message: "Invalid access token" })
            ws.close()
          }
        } else if (message.type === "get_config") {
          send({ id: message.id, type: "result", success: true, result: { location_name: name, version } })
        } else {
          send({ id: message.id, type: "result", ...command(message) })
        }
      })
    })
  })

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    revoked,
    sessions,
    registry,
    close: () => {
      for (const ws of sockets.clients) ws.terminate()
      server.close()
    },
  }
}
