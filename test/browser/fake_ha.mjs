// A fake Home Assistant for the browser test. It has the sign-in page,
// the tokens, the revoke and the WebSocket API: only the parts that the
// app uses. The sign-in page sends the browser back at once, with a code. The
// token endpoint checks the client, the way back and the PKCE verifier, as
// Home Assistant does.

import http from "node:http"
import { createHash, randomBytes } from "node:crypto"
import { WebSocketServer } from "ws"

const random = () => randomBytes(12).toString("hex")

const read = (request) => new Promise((resolve) => {
  let text = ""
  request.on("data", (chunk) => { text += chunk })
  request.on("end", () => resolve(new URLSearchParams(text)))
})

export async function fakeHomeAssistant({ name = "Fake house", version = "2026.10.0" } = {}) {
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
      back.search = new URLSearchParams({ code, state: query.get("state") }).toString()
      response.writeHead(302, { Location: back.toString() })
      return response.end()
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
        }
      })
    })
  })

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    revoked,
    sessions,
    close: () => {
      for (const ws of sockets.clients) ws.terminate()
      server.close()
    },
  }
}
