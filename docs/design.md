# The design of Small Steps Home

This file tells how the app works, and why. The plan of the owner gives
the phases and the rules of the product. This file gives the decisions of
the code.

## The parts

| Part | What |
|---|---|
| `DIY` | The model of a build and the calculations, with no web code. |
| `DIYWeb` | The pages: Phoenix LiveView. |
| `assets/js/` | The script of the page: the hooks of LiveView. |
| `specs/` | The TLA+ models. |
| `worker.js`, `wrangler.jsonc` | The Worker of Cloudflare: the VM of BEAM.com in a Durable Object. |

## The server

The app is a Phoenix LiveView app. `beam.com` makes one file of its
release (`npm run build`, `scripts/app-com.sh`), and the npm package
`beam.com` runs that file on Cloudflare Workers. One Durable Object runs
one VM for all the requests, so that each page and its WebSocket go to the
same VM. This is the setup of mkfifo.com, the first app on BEAM.com.

The VM has no database. The app keeps no data of a user on the server.

## The build on the device

The build of a user (the house, its rooms and items, and later the vans)
is a JSON text in the `localStorage` of the browser, under the key
`diy.build`. The server keeps no copy. The LiveView of a page holds the
build while the page is open, and sends each new build to the device.

Why on the device:

- The plan asks for a low privacy risk: a build can show where a house is
  and what is in it. With no copy on the server, a break-in on the server
  shows no build.
- The app needs no account for the first phases.

The cost: a build is on one browser only. A file export and import moves
a build to a different device (phase 1).

### The protocol

`assets/js/device.js` (the hook `Device`) and `DIYWeb.Device` (the
LiveView part) do the protocol. The TLA+ model `specs/Device.tla` checks
it with two and three tabs of one browser.

1. At the mount, the hook sends the stored text and its stamp
   (`device:restore`). The LiveView shows that build, or a new build.
2. Each change makes a new build with a new random stamp and the next
   revision. The LiveView sends `device:save` with the text, the base (the
   stamp of the stored build that the change comes from) and its epoch.
   It does not wait for the answer: the new build is the base of the next
   save.
3. The hook writes the text only if the stored stamp is the base (compare
   and set, in a Web Lock for all the tabs). Then it sends `device:saved`.
   Else a different tab wrote first: the hook sends `device:conflict` with
   the stored text, its stamp and the epoch of the save.
4. When a different tab writes, the browser gives a `storage` event, and
   the hook sends `device:changed`. The LiveView shows that build if its
   revision is larger.

Three details come from the model. TLC found a fault in each simpler
form:

- **The key is a stamp, not the revision.** The LiveView sends a save
  before the hook answers the last one. With the revision as the key, two
  saves of one tab can have the bases 1 and 2. The first one gets a
  conflict, but the stored build of the other tab can have the revision 2:
  then the second save writes over it, and an edit is lost
  (`specs/Device.revision.cfg`).
- **The LiveView keeps the newest stored build that it knows.** A conflict
  and a `storage` event come by different paths, in either order. After a
  conflict, the LiveView shows the newest stored build that it knows, not
  the build of the conflict, which can be older.
- **The epoch.** When a LiveView takes a build from outside, the saves
  that it sent before come from a build that it does not show now. Their
  conflicts are old news: a conflict of an old epoch changes no build.
  Without this, a tab can show an old build at the end
  (`specs/Device.epoch.cfg`).

A text that is not a build of this version gives a new build, and the
page tells the user. The next save writes over the text.

The tests:

- `test/js/device.test.js`: the hook, with a fake storage, and a property
  test (fast-check) of two tabs that send saves before the answers.
- `test/diy_web/device_test.exs`: the LiveView part, and a property test
  (StreamData) with two real LiveViews and a fake device, in random order.
