# Small Steps Home

Small Steps Home helps a beginner find the next small step to lower the
power bill and make the home more ready. It does not sell one big
solution. The name is not final.

The user builds a model of the house. Each item that the user adds, and the
place of the house, turn on the features that apply. A user never sees a
feature that does not apply to the house.

The build stays on the device of the user. The server keeps no copy. See
[`docs/design.md`](docs/design.md).

## Progress

| Phase | What | State |
|---|---|---|
| 0 | The project: Phoenix, the build on the device, the deploy to Cloudflare Workers | Done |
| 1 | The house builder: two doors, presets, rooms, floors, appliances, the weather estimate | Not started |
| 2 | Real usage: the files of Smart Meter Texas and Green Button | Not started |
| 3 | What-if equipment: power station, solar, subpanel, transfer switch, EV | Not started |
| 4 | The plan lesson: the EFL reader and the worksheet (Texas retail choice) | Not started |
| 5 | Van builds: zones, power budget, weight budget | Not started |

## Run on this computer

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the tools. Then:

```sh
mix.com setup
iex.com -S mix phx.server     # http://localhost:4000
```

## Deploy

The app runs on Cloudflare Workers, with the WebAssembly runtime of
[BEAM.com](https://github.com/sntran/BEAM.com). One Durable Object runs
the VM for all the pages. The app has no secret and no variable: the VM
makes `SECRET_KEY_BASE` one time and keeps it in the storage of the
Durable Object.

```sh
npm ci && npm run build           # edge.com (scripts/edge-com.sh)
npx wrangler dev                  # the Worker on this computer
npx wrangler deploy               # deploy to Cloudflare
```

Cloudflare Workers Builds can deploy each push to `main`: connect the
repository in the Cloudflare dashboard, with the build command
`npm run build` and the deploy command `npx wrangler deploy`. Workers
Builds installs the packages of `package-lock.json`.
