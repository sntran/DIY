# The design of Small Steps Home

This file tells how the app works, and why. The plan of the owner gives
the phases and the rules of the product. This file gives the decisions of
the code.

## The parts

| Part | What |
|---|---|
| `DIY` | The model of a build and the calculations, with no web code. |
| `priv/data/zips.bin` | The center and the state of each ZIP code (`scripts/zips.exs`). |
| `DIYWeb` | The pages: Phoenix LiveView. |
| `assets/js/` | The script of the page: the hooks of LiveView. |
| `specs/` | The TLA+ models. |
| `worker.js`, `wrangler.jsonc` | The Worker of Cloudflare: the VM of BEAM.com in a Durable Object. |

## The server

The app is a Phoenix LiveView app. `beam.com` makes one file of its
release for the WebAssembly runtime (`npm run build`,
`scripts/edge-com.sh`), and the npm package `beam.com` runs that file on
Cloudflare Workers. One Durable Object runs one VM for all the requests,
so that each page and its WebSocket go to the same VM. This is the setup
of mkfifo.com, the first app on BEAM.com.

The VM has no database. The app keeps no data of a user on the server.

One VM in 128 MB serves all the users. So a WebSocket frame can be 1 MiB
at most, a build from the device can be 512 KiB at most, and the
fallback of long polls is off.

## The build on the device

The build of a user (the house, its rooms and items, and later the vans)
is a JSON text in IndexedDB, in the browser of the user. The server keeps
no copy. The LiveView of a page holds the build while the page is open,
and sends each new build to the device.

Why on the device:

- The plan asks for a low privacy risk: a build can show where a house is
  and what is in it. With no copy on the server, a break-in on the server
  shows no build.
- The app needs no account for the first phases.

The cost: a build is on one browser only. A file export and import moves
a build to a different device (phase 1).

Why IndexedDB, not localStorage: the save is a compare and set, and it
must be atomic for all the tabs of the browser. IndexedDB runs the
transactions of all the tabs one at a time. localStorage does not give
this: a browser can keep a copy of it in each process, and a Web Lock
does not make these copies the same.

### The protocol

`assets/js/device.js` (the hook `Device`) and `DIYWeb.Device` (the
LiveView part) do the protocol. The TLA+ model `specs/Device.tla` checks
it with two and three tabs, with reconnects, reloads, a failed write and a
cleared store.

1. At the mount and after each reconnect, the hook reads the store and
   sends the text and its stamp (`device:restore`). The LiveView shows
   that build, or a new build. It takes only the first restore.
2. Each change makes a new build with a new random stamp and the next
   revision. The LiveView sends `device:save` with the text, the base (the
   stamp of the stored build that the change comes from) and its epoch.
   It does not wait for the answer: the new build is the base of the next
   save.
3. The hook takes the saves in order. For each one, it reads and writes
   in one transaction: it writes only if the stored stamp is the base.
   Then it sends `device:saved`. Else a different tab wrote first: the
   hook sends `device:conflict` at once, in the transaction, with the
   stored text, its stamp and the epoch of the save.
4. In the transaction of a write, the hook tells the other tabs with a
   BroadcastChannel. The hook of each other tab reads the store in its
   queue, and sends `device:changed`. IndexedDB runs that read after the
   write, so the news comes also when the tab of the write closes before
   the end of its transaction. The LiveView shows that build if its
   revision is larger.
5. When a save fails (for example, the device has no space), the hook
   sends `device:error` with the stored stamp that it saw.

The hook sends what it sees of the store on one channel, in the order
that it sees it. A conflict goes in the transaction, so it comes before
the news of a later write of a different tab.

These details come from the model and from the tests. Each one has a
configuration of the model with the fault, and TLC finds the fault:

- **The key is a stamp, not the revision** (`Device.revision.cfg`). The
  LiveView sends a save before the hook answers the last one. With the
  revision as the key, two saves of one tab can have the bases 1 and 2.
  The first one gets a conflict. But the stored build of the other tab
  can have the revision 2, and then the second save writes over it.
- **The epoch** (`Device.epoch.cfg`). When a LiveView takes a build from
  outside, the saves that it sent before come from a build that it does
  not show now. Their answers are old news. A new LiveView has a new
  epoch too. Without the epoch, a tab can show an old build at the end.
- **A new read replaces the old reads** (`Device.reads.cfg`). After two
  reconnects, an old read can come before a save of the queue, and its
  build is old. The property test with real LiveViews found this fault:
  TLC needs two restarts to show it.
- **The news of a write goes in its transaction** (`Device.news.cfg`).
  With the news after the transaction, a tab that writes and then closes
  can leave the other tabs with an old build.

Other cases:

- A failed write keeps the build of the page. The next save comes from
  the stored build, and has all the build.
- When the user removes the data of the site, the browser closes the
  database. The hook opens it again, and the save gets a conflict with no
  stored text. The LiveView saves its build again on the empty store.
- A newer version of the app can open the database with a new version:
  this tab then closes its connection, so that the new version does not
  wait.
- A text that the page cannot read (also a value that is not a text, or a
  text of more than 512 KiB) gives a new build. The next save keeps a copy
  of the old text under the key `backup`, and the page tells the user. If
  that save fails, the save after it keeps the copy.
- The page does not save a build of more than 512 KiB.
- A build of a newer version of the app stops the saves, and the page
  asks the user to load the page again.
- A push of the hook while the socket is down goes nowhere. The restore
  after the reconnect gives the build again. A change that the LiveView
  made, but did not send before the socket went down, is lost.

The tests:

- `test/js/device.test.js`: the hook and the transactions of IndexedDB
  (fake-indexeddb), and a property test (fast-check) of two tabs that
  send saves before the answers, with failed writes.
- `test/diy_web/device_test.exs`: the LiveView part, and a property test
  (StreamData) with real LiveViews, a fake device and reconnects, in
  random order.

## The house builder (phase 1)

### The first session

The first screen has two doors: "My house" and "A house I'm planning".
Then the user gives the ZIP code, and picks a preset: "a house like mine"
by size, age, floors and heat. The front of the house shows the bill
estimate at once, before the user adds an item. For a house that the user
plans, the estimate shows when the house has an AC (the plan: "as soon as
the house has walls and an AC").

A preset has the rooms of the house and its typical items
(`DIY.House`). A typical item has a dashed border and the word "Typical":
its numbers are a guess of the app. A change of a number, or a tap on
"Correct", makes it checked. The range of a checked item is smaller.

### The rooms

The page shows one room at a time (`DIYWeb.Inside`). The rooms of a floor
are in a row, and the floors are in a column, with CSS scroll snap: a
swipe left or right goes to the next room, and a swipe up or down to a
different floor. The browser does the swipe, with no script. Links do the
same for a keyboard. Each room shows its name, its floor and dots. The
roof, the attic, the garage, the backyard and the driveway are rooms too.
At the start, the rooms show the first floor (the hook `ScrollStart`).

An element that a patch of LiveView moves loses the place of its scroll.
So no element before `#levels` in its parent comes and goes: the hint is
in a fixed element.

An item opens in a sheet over the page (a modal dialog). The hook `Sheet`
(`assets/js/sheet.js`) closes it with the Escape key, keeps the focus in
it with the Tab key, and gives the focus back to the item when it closes.

### The data of a place

| Data | Source | Where |
|---|---|---|
| The state and the center of a ZIP code | US Census Bureau: the 2024 Gazetteer of the ZCTAs, and the 2020 ZCTA to county file | `priv/data/zips.bin`, `DIY.Zip` |
| The weather: degree days, temperature, sun, by month, 10 years | NASA POWER, monthly API, no key | `DIY.Weather` |
| Retail choice in Texas, the utility, the median price at 1,000 kWh | Power to Choose (PUCT), the API of its plans | `DIY.Market` |
| The average price for homes of a state | EIA, Electric Power Monthly, table 5.6.B | `DIY.Prices` |

The VM gets the weather and the plans with Req. On Cloudflare, the VM
sends this HTTP through `fetch()` of the Worker. The cache of the VM
(`DIY.Cache`) keeps the answers: they have no person in them. It keeps at
most 200 answers: the weather of one place is near 28 KB, and the
memory of a Durable Object is 128 MB.

In the data of NASA POWER, the sun of the last months comes later than
the degree days. A month with no sun keeps its degree days.

### The estimate

`DIY.Estimate` gives the kWh of each item in each month, and a range.

- The heat through the walls, the roof and the windows: `UA × degree days
  × 24 hours`. UA is the size × a factor for the age × a factor for the
  floors. For heat, the app uses 60% of UA: the sun and the people help in
  the cold. The factors are a simple model of the app, not a measurement,
  and the page says so.
- An AC: `BTU ÷ (SEER2 × 1,000)`. A heat pump: `BTU ÷ (HSPF2 × 1,000)`.
  Electric heat: `BTU ÷ 3,412`. Each one gives at most its size for 85% of
  the hours of a month. The heat that the heat pumps cannot give goes to
  the electric heat (heat strips), if the house has it. A gas furnace:
  only its blower.
- A water heater: 15 gallons for each person in one day, from the
  temperature of the ground to 120 °F.
- The other items: power × hours, or the kWh in one year of the label.
- The range: the weather and the model (15% for heat and cooling, 20% for
  a typical item, 10% for a checked item), added as squares, because they
  are independent. The weather of a month: the same month of each of the
  10 years, with the least and the most kWh. The weather of the year: the
  year with the least and the year with the most kWh.

Each item shows its math for one month (honesty rule 1): each step with
its numbers, and the kWh of the month at the end. A number under 100 has
one decimal, so that a step adds up on the page. For each item in each
month, a test reads the math as the page shows it: each step gives the
value of its numbers (with the rounding of the page), the result of a
step goes into the next one, and the last step gives the kWh of the item.

The price of one kWh: the price that the user gives, else the median of
Power to Choose in a Texas area with retail choice, else the average of
the state. The page tells the source of the price.

A typical house of 2,000 square feet from 2005, in Plano, Texas, gives
near 10,400 kWh in one year with gas heat, 16,900 with a heat pump, and
21,800 with heat strips. A test keeps these numbers in plausible limits.

### The tests of phase 1

- Property tests: the JSON of a random build; `from_json` with random
  text, and with a bad value at a random place of a build (and a test of
  each place with each bad value); the parameters of each kind; the ZIP
  codes of the file; the median; and the estimate (no item under zero,
  each month in its range, one more item never lowers the estimate, a
  better SEER2 never raises it, more degree days never lower it).
- The pages: `test/diy_web/live/home_live_test.exs`, with the real
  answers of NASA POWER and Power to Choose as stubs.
- The browser test (`test/browser/house.mjs`): a person builds a house in
  Chromium, in the light and the dark mode, on a phone and on a desk, and
  axe-core checks each screen. A swipe goes to the next room and to a
  different floor, the sheet of an item keeps the focus and closes with
  the Escape key, a reload keeps the build, a second tab follows the
  first, and a reconnect restores the build. CI runs the same script
  against `wrangler dev` too: the VM in workerd, with the real answers of
  NASA POWER and Power to Choose through `fetch()`.

## Real usage (phase 2)

### The file stays on the device

A smart meter is an item (outside or inside). Its sheet has an input for
the file of the meter. The hook `UsageFile` (`assets/js/usage.js`) reads
the file in the browser, and sends only the sums of each month to the
LiveView. The file never goes to the server. The sums go into the build,
and the build stays on the device (see above).

The app reads these files:

- Smart Meter Texas: the CSV of "Energy Data 15 Min Interval", or of the
  daily readings. The columns: `USAGE_DATE`, `USAGE_KWH` and
  `CONSUMPTION_SURPLUSGENERATION`.
- Green Button: the XML (ESPI) of "Download My Data". Each IntervalBlock
  gets the ReadingType of its own MeterReading (the links of the feed).
  The app reads only electric energy in Wh (uom 72, with its power of
  ten), as the change in each interval (not the totals of a register):
  from the grid, to the grid, or net. The net counts only in a file with
  no flow from the grid and no flow to the grid. The app refuses a file
  of gas or of the demand (kW), and it skips the summaries. For each day,
  it takes the finest readings: hourly and daily readings of the same day
  count once. It uses the time zone and the daylight time of the file.
- Green Button CSV, or a CSV with a date and the kWh: a column of the
  kWh to the grid (export) goes to the grid, a net value under zero too,
  and a row of gas or with units that are not kWh or Wh does not count.

For each month (the last 24 months at most), the build keeps the kWh from
the grid, the kWh to the grid, and the days with data. The page says so.
`DIY.Usage.read/1` accepts only a usage that it can read in full: a month
"YYYY-MM" of 2000 to 2099, with at most the days of that month. When a
file has a month of the year two times (a file of 12 months from the 8th
of a month), the app takes the one with the most days. The removal of
the last smart meter (or of its room), or a new house with no meter,
removes the real usage.

### The real months and the estimate

The Bill page puts each real month next to the estimate of the same month
of the year, with its range (`DIY.Usage.compare/2`). A month with fewer
days of data gets the mean of its days for the other days, and the page
marks it. The front of the house shows the average month from the meter.

`DIY.Usage.fit/2` finds the numbers of the house from the meter and the
weather of the same months (NASA POWER), with least squares:

    kWh of a month = base × days + cool × cooling degree days + heat × heating degree days

No number is under zero: the fit tries each set of the three numbers,
and keeps the best one with no number under zero. It needs 6 months with
20 days of data or more, and with weather.

### The tests of phase 2

- The check of the plan: "the estimate falls inside its own range for
  test houses with meter data". The test makes 24 houses: 4 sizes, 3
  kinds of heat, 2 of each. Each test house is a preset with other numbers
  (a heat loss up to 10% larger or smaller, an AC of one SEER2 more or
  less, a furnace blower and other items up to 20% more or less, one
  person more or less at the water heater). Its months come from the
  weather of July 2024 to June 2025, with 5% noise. The estimate of the
  preset does not know these numbers, and it uses the weather of 2016 to
  2023 only. Each house has 10 of its 12 months in the range at least, and
  all the houses 90% (in October 2026: 269 of 288 months, 93%).

  This is a check of the app with itself, on synthetic meter data: the
  test houses come from the same model as the estimate. It shows that the
  range covers the numbers that the model does not know. It cannot find a
  fault of the model itself: a house with 25% more heat loss than its
  preset has fewer months in the range. A check with real files of meters
  is open (TODO.md).
- Property tests: random files of 15-minute reads give the sums of their
  readings, any text gives a result or an error, a usage goes to JSON and
  back with no change, and the fit finds the numbers of a house from its
  months.
- The browser test adds the meter from the front of the house, opens a
  CSV of Smart Meter Texas, and checks the real months with axe-core.
