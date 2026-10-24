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

Later, a person can make an account that syncs the build between
devices, only when the person asks for it. This is a decision of the
owner (October 2026). The device encrypts the build before it goes to
the server, so the server keeps only a text that it cannot read. A person
with no account keeps all the data on the device, as today.

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
by size, age, floors and heat. After a ZIP code that the app does not
know, the field keeps the text that the person typed, and the error shows
under it. The field of the ZIP code in Settings does the same. The front
of the house shows the bill estimate at once, before the user adds an
item. For a house that the user plans, the estimate shows when the house
has an AC. The plan says: "as soon as the house has walls and an AC".

A preset has the rooms of the house and its typical items
(`DIY.House`). It has a bedroom for each person that the preset gives
the house (the people of the water heater). That is 2 under 1,500 sq ft,
3 under 2,200 sq ft, else 4. The bathroom comes after the second
bedroom, so the draft gives the bedrooms better shapes. A typical item
has a dashed border and the word "Typical": its numbers are a guess of
the app. A change of a number, or a tap on "They are right", makes it
checked. The
range of a checked item is smaller.

The front of the house helps a person with no skill in power:

- It tells what a kWh is, what retail choice is, and what the delivery
  charges are.
- A bar chart gives the bill of each month, with its range. Each month
  is a button. A tap or the keyboard gives the dollars of that month in
  the line over the chart. A screen reader reads it. The line starts
  with this month. The dollars are not on the bars: on a phone, 12
  labels are too small to read.
- It asks for the last bill: its total in dollars, its kWh and its month.
  The total divided by the kWh is the price of the plan (`my_bill`). A
  person who thinks that the bill is wrong usually has a price that is
  not the typical price. The kWh and the month fit the estimate (see the
  estimate). After the bill, the form stays closed under "Type the
  numbers of my bill", and one line tells the fit. A play test found
  that the kWh of the bill went nowhere, and that the form went away.
  For a house that the person plans, the bill is of another home: it
  gives only the price.
- With no camper van, a card tells that a van goes in the driveway, and
  adds one with one tap. With a van, a card has a link to the build of
  each van.
- The button "See the rooms and the items" opens the page Rooms.

Each page starts at its top (the hook Top). All the pages are one
LiveView, and a patch keeps the scroll of the page before it. The hook
looks at the name of the page, the step of the lesson and the van. When
one of them changes, the window goes to the top.

The words. A sheet tells a technical word in plain words:

- a ton of cooling is a size, not a weight;
- SEER2 and HSPF2 are efficiencies;
- GVWR and GAWR are the most weight of the van and of one axle;
- Ah are amp hours.

The heat efficiency shows only for a unit that heats. The level of the
garage, the yard and the driveway has the name "Around the house" (not
"Outside"). The sheet of an item in one of these rooms gives no level. A
wide table tells the person to swipe it on
a phone. The bill page gives the room of an item when two items have the
same name. The answers of the exercise stay in the form after a check.
The main buttons are orange in the light and the dark theme. In the
light theme, white words on a dark orange have a contrast of 4.9 (WCAG
AA). In the dark theme, dark words on a light orange have a contrast of
6.7. The red of an error (`--color-error`) is dark in the light theme
and light in the dark theme. Its contrast is 4.5 at least with the page
(6.2 and 6.6), and with the words on a red message (5.8 and 8.0).

### The rooms

The page Rooms shows the plan of the house at scale (`DIYWeb.Inside`, see
"The plan at scale" below). The roof, the attic, the garage, the backyard
and the driveway are rooms too.

A tap on an item brings it to the front of the page, with its panel (see
"The stage of an item" below). The other sheets (a room, a new item, a
new room) are over the page (a modal dialog). The hook `Sheet`
(`assets/js/sheet.js`) closes a sheet with the Escape key. It keeps the
focus in the sheet with the Tab key, and gives the focus back at the close.

### The data of a place

| Data | Source | Where |
|---|---|---|
| The state and the center of a ZIP code | US Census Bureau: the 2024 Gazetteer of the ZCTAs, and the 2020 ZCTA to county file | `priv/data/zips.bin`, `DIY.Zip` |
| The weather: degree days, temperature, sun, by month, 10 years | NASA POWER, monthly API, no key | `DIY.Weather` |
| The sky now: the time of day, the weather, the sunrise and the sunset | Open-Meteo, forecast API, no key | `DIY.Sky` |
| Retail choice in Texas, the utility, the median price at 1,000 kWh | Power to Choose (PUCT), the API of its plans | `DIY.Market` |
| The average price for homes of a state | EIA, Electric Power Monthly, table 5.6.B | `DIY.Prices` |

The VM gets the weather and the plans with Req. On Cloudflare, the VM
sends this HTTP through `fetch()` of the Worker. The cache of the VM
(`DIY.Cache`) keeps the answers: they have no person in them. It keeps at
most 200 answers: the weather of one place is near 28 KB, and the
memory of a Durable Object is 128 MB. The sky of a place has one key,
and its answer is good for 30 minutes: then the cache asks again.

The page asks Power to Choose when the build has a Texas ZIP code and no
market. It does not ask again while it waits, or after an error for the
same ZIP code (the key Try again asks again). When the person changes the
ZIP code, the build forgets its market. When the ZIP code comes back, the
page asks again.

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
- A fridge or a freezer in a room around the house (a garage, a shed).
  The label of a fridge comes from a test that stands for a kitchen near
  72 °F (10 CFR 430, subpart B, appendix A). The heat that comes in
  through its walls is in proportion to the difference between the air
  around it and its inside. The inside is 39 °F in a fridge and 0 °F in a
  freezer, as in the test. Around the house, the app uses the mean air
  outside of the month: a simple model of the app. So a garage fridge in
  Plano uses near 1.4 times its label in July. In a month that is not
  hotter than a kitchen, the app keeps the label: a garage is warmer than
  the air outside. A room that the user adds around the house has no AC,
  so it gets the air outside too.
- The gas, in therms (1 therm is 100,000 BTU):
  - A gas furnace: the BTU of heat ÷ 80%. 80% is the AFUE that the US
    asks of a gas furnace (10 CFR 430.32(e)).
  - A gas water heater: the BTU of the hot water ÷ 0.58. The US asks a
    UEF of 0.58 of a gas tank of 40 gallons, for a medium draw (10 CFR
    430.32(d)).
  - A gas stove and oven: 2.02 million BTU in one year (0.055 therm in
    one day). This is the mean of the US homes that cook with gas (US
    Energy Information Administration, RECS 2020, table CE5.4.ST).
  - A gas dryer: 0.073 therm for each load. The US homes with a gas dryer
    burn 2.06 million BTU in one year (RECS 2020, table CE5.4.ST). The
    test of the US Department of Energy counts 283 loads in one year (10
    CFR 430, subpart B, appendix D1).
  - The gas has its own range, with the same rules as the kWh.
- The range: the weather and the model (15% for heat and cooling, 20% for
  a typical item, 10% for a checked item), added as squares, because they
  are independent. The weather of a month: the same month of each of the
  10 years, with the least and the most kWh. The weather of the year: the
  year with the least and the year with the most kWh.

Each item shows its math for one month (honesty rule 1): each step with
its numbers, and the kWh of the month at the end. A number under 100 has
one decimal, so that a step adds up on the page. For each item in each
month, a test reads the math as the page shows it: each step gives the
value of its numbers (as the page rounds them), the result of a
step goes into the next one, and the last step gives the kWh of the item.

A real bill fits the model (`DIY.Estimate.fit/2`). The heat that goes
through the walls is the part of the model with the most doubt, so the
bill changes UA:

- The factor of UA gives the kWh of the bill in its month, with the mean
  weather of that month. The kWh of a month do not decrease when the
  factor increases, so a bisection finds the factor. A bill over the
  model gives a factor of 1 or more, and a bill under it a factor of 1
  or less. An AC at its capacity gives no more kWh. When the bill is
  more than the items can use, the factor is the least one that gives
  the most kWh.
- Only the items of today count: a planned item is not in the bill.
- The factor stays in 0.25 to 4. When no factor gives the bill, the page
  tells the nearest estimate of the month. It asks the user to check the
  items and the numbers of the bill.
- In a mild month, the heat and the cooling are less than 40% of the kWh
  of the model. Then the other items decide the bill: an error of 20% in
  the other items gives an error of 30% in the factor. So the factor
  stays 1, and the page names the month of the year with the largest
  part of heat and cooling. A house with gas heat has a mild power bill
  in the winter too.
- With solar panels, the bill does not show all the use, so the factor
  stays 1.
- A house can have a heat pump and no heat strips in the app. Then a
  winter bill can give a large factor, and a large estimate of the
  summer. The real house probably has heat strips. The bill of a hot
  month gives a better fit.
- The weather of one month changes from year to year, but the fit uses
  the mean weather. In Plano, the °F-days of cooling of July go from 18%
  under the mean to 33% over it. The range of the estimate does not show
  this doubt.
- The math of each item tells the factor, and the page "How the app gets
  your bill" too.

The price of one kWh: the price that the user gives, else the median of
Power to Choose in a Texas area with retail choice, else the average of
the state. The page tells the source of the price.

The natural gas bill of a month is a fixed charge and a price for each
therm. The app gets the two numbers from the bills of the homes of Texas
in the 12 months of 2024 (US Energy Information Administration):

- The bill of a home in a month: the price of the month × the gas of the
  month ÷ the homes with gas (5,308,705 in Texas).
- A line through the 12 months: $25.59 each month, and $9.90 for each
  1,000 cubic feet. The line is near the bills: R² is 0.95.
- Each 1,000 cubic feet of gas give near 10.37 therms. So a therm costs
  near $0.95.
- Outside Texas, the app uses the same line for the US: $17.90 each
  month, and $10.86 for each 1,000 cubic feet (R² 0.996).
- The count of the homes with gas stops at 2024. So the app uses the
  bills of 2024. The bills of 2025 cost more for each therm.

The front page shows a gas bill only for a house with gas use. It has the
average month, its range, and the month with the most gas, with its
range. A plan can change the gas: a heat pump heats in place of a
furnace. Then the page shows the gas bill with the plan, with its range,
and the bill of today. The plan keeps the gas items of today, so it keeps
the fixed charge. The gas of an item costs its therms × the price of a
therm. The fixed charge is for the house.

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
  answers of NASA POWER and Power to Choose as stubs. The tests run at
  the same time, so the cache keeps nothing in the tests
  (`config/test.exs`): each test gets the answer of its own stub. The
  test of the cache (`test/diy/cache_test.exs`) does not run at the same
  time as the other tests. The tests do not wait a fixed time for an
  answer: they wait while the page waits for one (`settle/1`).
- The browser test (`test/browser/house.mjs`): a person builds a house in
  Chromium, in the light and the dark mode, on a phone and on a desk.
  Axe-core checks each screen. On the plan, a drag moves an item and a
  wall of a room. In the list of the rooms, an arrow key moves an item.
  The stage of an item keeps the focus and closes with the Escape key. A
  reload keeps the build, a second tab follows the first, and a reconnect
  restores the build. CI runs the same script against `wrangler dev` too.
  There, the VM runs in workerd, with the real answers of NASA POWER and
  Power to Choose through `fetch()`.

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

Home Assistant can also give the months of the meter (see "The energy
data" under "Home Assistant"). They have the same form as the months of
a file.

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

## What-if equipment (phase 3)

### The items and their flags

Phase 3 adds four kinds of items (`DIY.Catalog`):

- A power station: its battery and its extra batteries (kWh), its output,
  its charge from the wall and its solar input (W), what it powers (items
  by plug, or circuits of the house through an inlet), and its price.
- Solar panels: their watts, their direction, what they connect to (a
  power station, or the house and the grid), and their price.
- An interlock, a transfer switch, or a subpanel for the backup circuits
  with a transfer switch, and its price.
- An electric car: its miles in one day, its miles for each kWh, its
  charger, when it charges, and the gas car that it replaces.

Each item of a build has two flags:

- `planned`: the user does not have it yet. The house of today has no
  planned item (`DIY.Build.today/1`). The bill of the house comes from the
  house of today, and the what-if shows the house with the planned items
  next to it.
- `backup`: a power station runs the item (by plug, or on a backup
  circuit). The sheet of an item shows this flag only when the house has a
  station, and only for an item that uses power.

The build also has the settings of its power (`DIY.Power.settings/0`):
the mode of the stations, the price and the hours of the night, the price
that the plan pays for the power to the grid, and the part of the
batteries that the stations keep for an outage.

### The day of a month

`DIY.Profile` spreads the kWh of each item of the estimate over the 24
hours of an average day (cooling in the afternoon, heat before the
sunrise, lights in the evening, a car at the power of its charger), and
the sun from the sunrise to the sunset of the latitude. `DIY.Power` runs
that day hour by hour: the sun, the battery and the grid (see its module
doc). The day starts with the charge that it gives back at its end: the
average day of many days in a row. The charge at the end of a day grows
with the charge at its start, but never by more, so a bisection finds
that charge. The result of each month: the use, the power from the grid
in the day and at night, the power to the grid, the sun of the panels,
the sun that is lost (a full battery, or the sun above the solar input of
a station), the cost, and the hours of an outage.

A medical device (a CPAP) is an item of the house: its watts and its
hours. It runs from 22:00, the start of the sleep. (These are not the
hours of the night price.) An outage starts at 18:00, but a CPAP starts
at 22:00. So on the page Power, the hours of an outage also give the
time when the stations stop. For the same reason, the size for 2 days
is the least battery that runs 48 hours, not a straight line of the
hours. A bisection with the outage of each month finds it, and the page
rounds it up. The sheet of the device tells that a station runs it for
some hours, and to ask the maker which batteries it can use. On a
battery, the person turns off the humidifier (ResMed): then a CPAP uses
near 10 W. The sheet also tells the person to tell the company that
sells the power. In Texas, a home with a medical need can be on a list
(16 TAC §25.497), but the list does not keep the power on. A play test
found no item for a CPAP.

`DIY.Bill` gives the bill from the power of the grid, at the price of the
day and of the night, with the range of the estimate of the use. With no
equipment and one price, the bill is the same as the estimate times the
price.

The numbers of the model, and their sources:

| Number | Value | Source |
|---|---|---|
| The part of the battery that a station uses | 95% | With the next row: 87% of the label at the outlets. Tests of stations at a large load: 87.5% (The Solar Lab, Jackery Explorer 1000 v2), 89% on average (PCWorld). |
| The power of a battery that comes out of the outlets | 92% | See above. |
| The power that goes into a battery and stays in it | 92% | A simple model of the app: the same loss as the output. |
| The power of panels in full sun, for each watt on their labels | 80% | PVWatts of NREL: 14% of losses and an inverter of 96% give 83%. A little less for the heat of Texas. |
| Direction of the panels (for the sun of NASA POWER on a flat surface) | south 110%, south-east or south-west 105%, east or west 95%, up 100% | EIA with PVWatts: a south roof at 20° gives 11% more than a flat one. CAFS: south-west 5% less than south, east or west near 15% less; a study of the UK: east or west 92% of south. |
| The part of the power of a charger that goes into a car | Level 1: 85%, Level 2: 90% | Idaho National Laboratory, Chevrolet Volt: 84% to 89%. |
| The power of a charger | Level 1: 1.4 kW, Level 2: 7.2 kW | 12 A at 120 V, and 30 A at 240 V. |
| A battery of a station lasts | near 8 years | 3,000 cycles to 80% (a common label of LiFePO4 stations), one cycle each day. |
| A panel lasts | 25 to 35 years | A survey of Berkeley Lab, in the plan of DOE for the end of life of the panels. The payback uses 25 years. |
| A motor needs to start | 3 to 8 times its running power, for about one second | A guide to the size of generators (smps.us). The label of the motor gives its LRA. |

The shape of the day of each kind of item, and the running watts of an
item (for the check of the output of a station), are a simple model of
the app, not a measurement (`DIY.Profile`).

### The what-if

`DIY.Power.whatif/6` runs the house of today and the house with the
planned items. It gives the cost of each month, and the bill of each
house with its range (`DIY.Bill`, honesty rule 3). The payback is for the
planned equipment with a price. It has the price, the savings of one
year, and the years of the payback, next to the years that the equipment
lasts. A payback after that time is not a payback. With one price at all
hours, the weather of 10 years changes the two bills the same way. Then
the two ends of the range of the savings are the same, and the page gives
one number. With a price at night, the two ends can differ: then the
page gives the range.

With two parts of equipment or more, each part has its own line
(`parts`). The planned stations and the panels that charge a station are
one part: they work together, and the panels give nothing with no
station. Each other item is a part alone. A line gives the price of the
part, the savings that it adds, and its payback in its own life. The
savings that a part adds are the savings of the plan, less the savings
of the plan with no such part. The life of a part is the shortest life
of its items. So the battery of a station (8 years) does not decide the
payback of panels on the grid (25 years). The plan as one is then
compared with the longest life of its parts. A play test found this
fault: the page said that panels with a station "do not pay back", but
the panels alone did.

The other planned items (a car, a freezer) have no price in the app. For
them, the page shows the change of the bill and the gas that a car
saves, out of the payback. The plan shows only the warnings that the
house of today does not have. The front of the house marks a plan with a
danger or an overload. When the plan does not pay back on savings
alone, the page says it. Then it shows the hours of backup as a
different reason (honesty rule 2). With one price at all hours, a charge
at night does not save money: the page says it. The station loses near
15% of the power.

The hours of backup are the first question of a person with a station.
So they are at the top of the page Power, in large text. They are the
hours of the month with the fewest hours, with the plan when there is
one. When each month has the same hours, the page says "in any month of
the year".
In the mode that keeps the batteries full, the page also gives the kWh
for 2 days: the kWh of now × 48 ÷ the hours. This is near, because the
sun of the next days also charges the station. In the other modes, the
charge at the start of an outage changes with the use of the day: the
page gives no size. With 0 hours (an empty battery at 18:00), the page
tells the mode that keeps the batteries full. With an overload, the page
gives the warning, not the hours. The sheet of a station, and of an item
that a station runs, also gives the hours, with a link to the page
Power. The view "What feeds what" shows the plan when there is one. The
warnings of today under it have their own label.

A second play test (in the role of a neighbor who wants backup in an
outage, and a van) found more faults. The fixes:

- Panels on the grid stop in an outage, because their inverter needs the
  grid. The box of the outage says so. The hours do not count them. A
  station that feeds the circuits through an inlet does not get this
  note. There, a warning tells the user to turn off the breaker of the
  inverter.
- The sheet of a station, of solar panels, of a transfer switch, of a
  meter and of a van gives its note, and no kWh. The page Bill does not
  list them, and the list for a screen reader gives them no kWh. The words "In one year: 0 kWh" looked like a fault.
- The hours of an outage, or the days off the grid of a van, can be the
  same in each month. Then the page says "in any month of the year". The
  words "in each month" read like an amount for each month.
- The front of the house has a link to the build of each van. Before, a
  person had to find the van in the rooms.
- The settings show the price of a bill with 2 decimals.

The sheet of solar panels helps to choose their size and their price
(`DIY.Solar`). It has at most 2 short notes:

- Panels on the roof: the panels of 400 W (45 by 68 in) that one side of
  the roof holds (all of a flat roof). The note says that it is a simple model of the app.
  The roof covers the top floor: the size of the house ÷ its floors. One
  side of a gable roof is half of the roof, × 1.12 for a slope of 6 in
  12. A flat roof is all one side. The app uses 2/3 of the side, for the
  paths and the space at the ridge of the fire code (International
  Residential Code 2021, R324.6). A hip roof has 4 sides, so the note
  says that it holds less.
- Panels that charge a station: a note when no station is in the house,
  or when the solar input of the stations is 0 W. Also a note when the
  sun of the panels is more than the solar input of the stations of the
  house. The sun is 80% of the watts of the labels,
  as on the page Power. The rest is lost in full sun, and the page Power
  gives the kWh of one year. A play test found this fault. It put 6,000
  W of panels on a station of 1,000 W. The page gave a payback of 334
  years, with no word of why.
- Panels on the roof and on the grid in Texas: a typical price for each
  watt, with the installation, before any credit. SolarReviews (October
  2026) gives a price for each size from 4 to 10 kW: $3.40 for 4 kW to
  $2.65 for 10 kW. The app rounds to the nearest kW. Under 3,500 W, the
  note gives no total: a small system costs more for each watt. Over 10
  kW, the note gives $2.25 (EnergySage, October 2026, for 13 kW) to
  $2.65.
- The US tax credit for home solar (section 25D) stops for a system that
  the installer completes after 2025 (Public Law 119-21). Many pages
  still give a price after this credit, so the note tells it.

The help of the battery of a station gives common sizes, with no brand
names (honesty rule 4). The sizes are near 1 kWh (1,800 W of outlets), 2
kWh (2,400 W) and 4 kWh (4,000 W). They come from the data sheets of
common stations of 2025 and 2026.

The page Bill shows the house of today (the planned items are on the page
Power). With a station, panels on the grid, or a price at night, it also
shows the bill of each month from the power of the grid at the prices of
the house, with its range.

### The power view and the safety

The page Power shows what feeds what. It shows the grid, the main panel
and its interlock or transfer switch, the panels, the stations, and the
items that the stations run. `DIY.Power.warnings/1` gives, for the house of
today and for the plan:

- `:backfeed`: a station that powers circuits of the house with no
  interlock and no transfer switch. The page shows a danger: its power
  can go to the lines of the utility, and kill a worker there.
- `:permit`: work that needs a permit in most cities (honesty rule 5).
  The rules are different in each city. The page gives the rules of
  Dallas and New Braunfels as two examples. The work:
  - work on the panel (an inlet, an interlock, a transfer switch or a
    subpanel);
  - panels on a grid-tie inverter (the utility must also approve them);
  - a Level 2 charger (a new circuit of 240 V).
- `:grid_tie`: panels on a grid-tie inverter and a station on the panel.
  In an outage, the inverter can send its power into the output of the
  station. The steps of the page turn off its breaker first.
- `:overload`: the items on the stations need more watts than their
  outputs, when they all run at the same time. Then the plan shows no
  hours of backup.
- `:surge`: a motor needs more power to start.

The page gives the steps of each device: with an interlock, the main
breaker goes off before the inlet breaker goes on; with a transfer switch
(or a subpanel with one), the main breaker stays on, and the switch moves
the backup circuits.

`specs/Backfeed.tla` is the model of the grid, the main breaker, the
inlet, the transfer switch and the station. What it checks: the rule of
each device is enough to stop a backfeed, also when the person changes
anything at any time (`Backfeed.cfg` for an interlock,
`Backfeed.transfer.cfg` for a transfer switch); and the steps of the page
give the backup in an outage, and the grid when it comes back
(`Backfeed.steps.cfg`, `Backfeed.transfer-steps.cfg`). The steps are the
main value of the model: the rule of a device stops a backfeed by its
design. TLC finds the faults: no device (`Backfeed.none.cfg`), a switch
that makes the new side before it breaks the old one
(`Backfeed.makefirst.cfg`), and a person who stops before the end of the
steps (`Backfeed.stop.cfg`). The model has one station and one inlet; the
app adds the stations of a house as one, and it finds a device anywhere
in the house.

### The tests of phase 3

- Property tests: an average day ends with the charge of its start, the
  charge of the battery stays in its limits, and the grid gives at least
  the use less the sun that is not lost, and at most the other items and
  the items of the station through the battery; more battery never gives
  fewer hours in an outage.
- A check with the numbers of a label: a station of 2,048 Wh runs a
  fridge of 400 kWh in one year for 39 hours, as the math by hand gives.
- The pages: `test/diy_web/live/power_live_test.exs`.
- The browser test adds a station that runs the fridge, plans panels on
  the roof, and checks the page Power and the plan with axe-core.

The check of the plan for phase 3 is "the owner's own house gives numbers
that match the real system". It needs the numbers of the real system of
the owner (the stations, the panels, and the kWh of a day from the app of
the station). The app takes them as items; the comparison is open.


## The plan lesson (phase 4)

The page Plans shows only for a house in Texas in an area with retail
choice (`DIY.Market`). The app does not pick a plan, and it does not rank
plans (honesty rule 4). It teaches the math of a bill, and it gets the
data fast.

### The steps

`DIY.Lesson` has four steps. The build keeps the step that the user
reached, the plan that the user did in step 2 (step 3 uses a different
plan), and the plans of the worksheet (10 at most).

The kWh of each month are whole numbers, as the page shows them: the user
does the math with the numbers of the page, and the check accepts it.
When the months come from the estimate, the page shows the range of each
month, and the worksheet shows the least and the most bill of the year in
that range. A credit or a fee changes the bill at its limit of kWh, so
the app checks the ends of the range and each limit in it.

1. A worked example: one sample house, the plan of a real EFL, and 12
   months. The page shows each part of each bill.
2. Your data, with help: the 12 months of the user (from the meter file
   when it has each month of the year, else from the estimate), and one
   plan from its EFL. The user gives each part of the bill of the month
   with the most use. A hint for each part shows the math. The app checks
   each part (right within 5 cents; a credit with its sign or with no
   sign), and tells how many parts are right.
3. Fewer hints: a second plan (from its EFL, or from its numbers). The
   user gives only the total of the bill, and can ask for the hints.
4. On your own: the worksheet. Each plan has the bill of each of the 12
   months, and the cost of the year, in the order that the user added the
   plans.

A person who knows how to read a bill can go to the worksheet at once.
On step 1, the button "Go to the worksheet" is under the text of the
lesson. It opens all the steps.

### The bill of a month

`DIY.Plan` gives the parts of a bill:

    base + energy + TDU base + TDU cents × kWh − credits + minimum usage fee

The energy charge can have tiers (a price from some kWh up), and a
different price at night. For a plan with a price at night, the kWh of a
month at night (a whole number) come from the day of that month of the
house (`DIY.Power`, phase 3), with the hours of the night of the plan.
The page shows them, and tells that they do not come from the EFL. The
tiers are for the kWh of the full month: the kWh of the day pay the mean
price of the tiers for all the kWh.
A credit can have a minimum of kWh, and some months of the year. An
average month of an EFL spreads a credit of some months over the year.

### The EFL reader

The browser reads the PDF of an EFL (`assets/js/efl.js`) with pdf.js. The
page loads pdf.js (`assets/js/pdf.js`, a file of its own, the legacy
build: the modern build needs functions that some browsers do not have)
only when the user opens the first EFL. The reader makes the lines of
each page from the place of each part of the text. It sends the lines to
the server only for an EFL (a line with "average price"), at most 64 KB
of text: the text of a bill that the user opens in error stays on the
device. The PDF stays on the device. The page says so. The links of the
numbers open the PDF with the type of a PDF, whatever the name of the
file.

`DIY.EFL` finds these numbers of the plan in the lines:

- the base charge, the energy charge and its tiers;
- the price at night and its hours;
- the delivery charges of the utility (TDU);
- the credits and the minimum usage fee;
- the averages at 500, 1,000 and 2,000 kWh.

The page shows each number with the line where it came from, and a link
opens the PDF at its page. When the EFL does not give the delivery
charges, the reader takes them from the table of the utility
(`DIY.Plan.tdu/1`). For Oncor and CenterPoint, the table has the charges
of the EFLs of October 2026. For AEP Texas Central, AEP Texas North,
TNMP and Lubbock Power & Light, it has the table of Xoom Energy, with
the rates of 10/4/2026. A line that names more than one utility does not
tell the utility. When the table does not know the utility, the reader
uses the averages at 500 and 2,000 kWh. It does this only when it found
the energy charge. The page tells where they come from; with a fit, only
the average at 1,000 kWh checks the numbers. The form of a plan gives
the delivery charges only of a utility of the table; for another
utility, the user gives them.

The reader joins at most 600 bytes of lines into one sentence, and reads
at most 64 KB of text, so that a crafted message cannot make it slow. The
names of the months of a credit need a capital letter ("may" is not May),
and the reader reads a range ("June through September").

The check of an EFL: the bill of the plan at 500, 1,000 and 2,000 kWh must
give the averages of the label, within 0.05¢ (a label rounds to 0.1¢).
The user can add the plan of an EFL to the worksheet only when the check
passes. When it does not pass, the page shows which average does not
agree, and the user can give the numbers of the plan in a form. A
minimum usage fee under 500 kWh is not in the averages: the page says
that the check does not include it. The build keeps only a plan that it can
read again (`DIY.Plan.read/1`): a number out of range gives an error, not
a build that does not load.

The forms of the EFLs of the providers are not all the same. Of 34 EFLs
of October 2026 (Oncor), the check of 29 passes (counted with the reader
of this version and a check within 0.05¢). The other forms put the
numbers in columns under their names, or give the charges in a table that
the lines do not keep.

### The tests of phase 4

- The check of the plan for phase 4, part 1: the reader gets the numbers
  of 10 test EFLs of October 2026 (`test/fixtures/efl`), as a person reads
  them on each label: the base charge, the energy charge, the delivery
  charges, the credits, the minimum usage fee, the price at night, and the
  averages (`test/diy/efl_test.exs`). Three more test EFLs: one of
  CenterPoint with a minimum usage fee, one with a font that lost its
  letters, and one of a form that the reader does not know (its check
  fails).
- Property tests: an answer from the numbers of the page is right, and an
  answer 6 cents off is wrong; the parts of a bill give its total, more
  kWh never cost less energy, and an average month has the mean credit of
  the 12 months;
  the delivery charges from the averages give the averages back; a plan
  to JSON and back; the EFL reader never raises for lines from parts of
  the test EFLs with other numbers and other text, and a build with its
  plan loads again; the lines of a page keep each letter of the text of
  the PDF.
- The pages: `test/diy_web/live/lesson_live_test.exs`.
- The check of the plan for phase 4, part 2: the browser test is a test
  user that does the four steps. It opens an encrypted EFL and the EFL of
  a plan with a credit (the links of the numbers open the PDF), gives each
  part of a bill, adds a second plan from its numbers
  (a plan from a broker), gives its bill, and gets the worksheet with the
  two plans. Axe-core checks each screen. This is a script, not a person.
  A test with a person with no background in plans is open (`TODO.md`).

## Van builds (phase 5)

A camper van is a small house on wheels, so it uses the same builder. A
van is an item of the house (in the driveway or in the garage), and it
opens its own build: the page Van. Not each person has a van, so the bar
at the bottom has no part Van. The page Van is a part of the rooms. The
van item in the list of the rooms comes forward with its panel (see "The
stage of an item"). The button "Open the build of the van" of the panel
opens the page Van. A station of the house
can be in the van. Then the page Power and the list of the rooms also
have a link to the page Van. On the page Van, the part Rooms of the bar
is the current part. A link at the top goes back to the van in the
rooms.

### The zones

A new van gets its zones: the cab, the galley, the living area, the bed,
the electrical bay, the roof of the van, and the shell. A zone is a room
of the build on the level `"van:ID"` (the id of the van). The zones are
fixed: the user cannot add, rename or remove one. The removal of the van
(or of its room) removes its zones and their items. The kinds of items of
a van (`DIY.Catalog`) go only in the zones, each with its weight; a power
station can go in a house or in a van.

The house has its own numbers: the estimate, the power, the bill and the
lesson use only the rooms and the items of the house
(`DIY.Build.house_view/1`). The van has an estimate of 0 kWh in the
house: its batteries and its power are its own.

### The inside of the van at scale

The page Van shows the van cut open, as the page Rooms shows the house
(`DIYWeb.VanCutaway`, with the rules in `DIY.Layout`). The van has two
layers: its floor, and its roof over it with a gap.

- The plan of a van comes from its model (`DIY.Catalog.van_size/1`): the
  cargo area and the cab in front of it. `y` goes along the van, from the
  doors at the back to the cab. `x` goes across the van, from its right
  side (the side of the sliding door).
- The camera of a van (`DIYWeb.Camera.van/0`) is at its left side (the
  side of the driver), a little to its front (to the cab). The right side
  is at x = 0, far from the eye. The cab is at the left of the screen, and
  the doors at the back are at the right. A test checks the side of the
  driver and of the sliding door.
- The draft (`DIY.Layout.van_draft/2`). From the doors at the back: the
  bed, the electrical bay, the living area and the galley, each across
  the van. The cab is at the front, and the roof of the van is over all
  of it. The shell has no plan: its items are materials.
- The rules are the rules of the house. No two zones of a layer overlap,
  each zone stays in the van, and each item is in its zone. The cab and
  the roof of the van are fixed: they do not move, and they have no
  handles. A new model (or a stored text that breaks a rule) gives all
  the zones the draft again. An item does not go between the house and a
  van. `specs/VanPlan.tla` checks the box of the van and the place of the
  cab. Two faults show that these rules matter.
- The picture shows the walls of the van. The right side has the full
  height of the cargo area, with the opening of the sliding door. The
  doors at the back are cut on a slope: full at the right side, and near
  the floor at the left side. The left side is cut near the floor.
  The picture also shows the wheel wells, the wheels, the seats, the
  dash, the steering wheel, the hood and the bumper. These fixed parts
  do not take a tap: a tap goes to the zone under them. A swivel seat
  (an item) takes the place of the seat that it is on.
- The shell gives the materials: a floor of wood, walls with panels, and
  pink insulation in the cut of the walls. The shell shows under the
  plan, with its items and a button that adds an item.
- The page shows the source of the sizes of the model. The place of the
  front axle, the depth of the cab and the thickness of the doors are
  guesses of the app. The places of the seats, the dash and the wheel
  wells are for the picture only.
- The model of each van (`DIYWeb.Icon.Shapes.van/1`) has the nose, the
  hood, the windshield and the roof of its brand. The ProMaster, the
  Transit and the Sprinter look different in the yard and in the garage.
  The model gives the size of the van: its panel has no size.
- A drag moves an item, also to a different zone. A tap on a zone
  chooses it. Its bar has the buttons that move it. They use the words of
  a van: to the back, to the front, to the right side, to the left side.
  A button that cannot move the zone is disabled. The sheet of a zone
  gives its size. A list of the zones and their items is for a screen
  reader and a keyboard. In the list, the arrow keys move an item or a
  zone.
- A depth check tests the order of the paint of each kind and each model
  of van at each turn. At a point that two faces cover, the face that is
  nearer to the eye paints last.

### The two budgets

`DIY.Van` gives the two budgets of a van, and the page shows them as the
user builds.

The weight budget:

- The payload is the weight rating of the van (GVWR) less its empty
  weight. The items take it, with the water of the tanks (8.34 lb for
  each gallon, USGS). The people and the gear take it too.
- Each item has its place along the van, on the plan of the van. The
  part of its weight on the rear axle comes from that place, the front
  axle and the wheelbase of the model (`DIY.Van.lever/2`). The rest is on
  the front axle. An item behind the rear axle takes some weight off the
  front axle.
- The people sit at the middle of the cab, and the gear is at the middle
  of the bed. An item of the shell is at the middle of the plan of the
  van (the cargo area and the cab).
- The page shows the van in all, each axle against its rating (GAWR),
  and the weight of each zone. The places on the plan are a simple model.
  A truck scale gives the real weight of each axle.

The power budget, for each month:

- The use: the Wh that the items use in one day. A fan works in the warm
  months, and a heater in the cold months. An item on an outlet of 120 V
  loses 10% in the inverter.
- A 12 V fridge: its label gives its use near 77 °F (25 °C) around it,
  with 41 °F (5 °C) inside. Its use is in proportion to the difference
  between the mean air outside and its inside, as for a fridge of the
  house. It is never under the label. A person in the van keeps it warm,
  and the budget of a battery must be on the safe side. Some data show a
  larger rise in the heat. For a 12 V fridge of 45 liters, a store gives
  0.49 kWh in one day at 25 °C and 1.03 kWh at 32 °C. That is near 2
  times ([the store](https://www.mon-camping-car.com/glaciere-congelateur-portable-cfx3-45-dometic.html)).
  So in a hot month, the app can be low.
- The sun: the panels give 80% of their watts in full sun, with the sun
  of NASA POWER at the house.
- The engine: the amps of the alternator charger, at the voltage of the
  batteries (12.8 V for each 12 V), for the hours that the user drives.
- The batteries: lithium (LiFePO4) gives 90% of its label, lead acid or
  AGM 50%, and a power station 95%. The app does not count the loss of
  the outlets of a station.
- The days off the grid: the batteries, divided by the Wh that a day uses
  more than it gets. With more sun and engine than use, there is no
  limit. The page names the month with the fewest days.

The models of vans give typical numbers (`DIY.Catalog.van_models/0`), and
the page shows their sources. There are 9 models: 3 lengths or roofs of
each make.

- Ram ProMaster: 136 in and 159 in with a high roof, and 159 in extended
  (3500). For the 136 in and the 159 in extended, the source is the
  towing charts of Stellantis (2026). They give the rating, the rating of
  each axle and the empty weight on each axle. For the 159 in, Autopadre
  gives the rating and the empty weight, and Auto123 gives the axles.
- Ford Transit: 148 in with a medium roof or a high roof, and 148 in
  extended with a high roof. For the medium roof and the extended van,
  the technical specifications of Ford (2025) give the rating, the empty
  weight and the size. Cars.com gives the split of the empty weight. For
  the high roof, Autopadre gives the rating and the empty weight. The
  split of the high roof is a guess of the app. The app does not know
  the axles of a Transit.
- Mercedes-Benz Sprinter: 144 in, 170 in, and 170 in extended, with a
  high roof. For the 144 in and the 170 in extended, the site mbvans.com
  (2026) gives the rating and the axles. The drawings for upfitters give
  their size. For the 170 in, Autopadre gives the rating, and the split
  is a guess of the app.
- The site mbvans.com gives the empty weight of each axle of a Sprinter
  with rear wheel drive in an order that is not sure. Its van with all
  wheel drive has more weight on the front axle, as a van with its engine
  at the front. So the app puts the larger number on the front axle, and
  the page says so.

A new model gives its numbers. The numbers are typical until the user
changes a number of the label or says that they are correct. A short van
gives the bed less of its draft, so that each zone keeps its smallest
size (24 in). In the picture of the house, the drive is 7.6 m long from
the garage to the street. So the longest van (290 in) fits in it.

### The safety notes

`DIY.Van.warnings/2` gives a note only where it applies:

- A battery with no fuse near its positive post. The ABYC standard E-11
  for boats, which many van builders use, puts it within 7 inches. The
  note names the battery.
- A stove or a heater that burns fuel: fresh air, and a carbon monoxide
  alarm.
- A diesel heater: its air comes from outside the van, and its gas goes
  out.
- A propane or butane stove: the propane alarm goes near the floor.
- An item on an outlet of 120 V: an inverter or a power station. When the
  items need more watts than the inverters and the stations give, a note
  tells it.
- Items that use power: a battery or a power station.

### A station of the house in the van

A power station of the house can go to the electrical bay of a van for a
trip (`DIY.Build.take_to_van/3`), and back (`bring_home/2`).

- In the van, the station keeps its room of the house as its home. The
  room shows it as away: the house loses its capacity while the van has
  it.
- The pages Bill and Power count the house with no van
  (`DIY.Build.house_view/1`). The page Power tells which station is in a
  van.
- The removal of the van sends the station home.
- The removal of its home room gives it a new home: a room of the house
  where it can go, first on the level of the removed room. When the
  removed room has the van too, the station goes to its new home. A
  station goes away only with its own room, or when the house has no room
  for it.
- A station of the van (one that the user added in a zone) has no home,
  and stays in the van.

`specs/Share.tla` is the model of the station, the rooms and the vans in
the rooms, with the steps in any order. The station is never in a place
that is not there, its home is always there, and it goes away only with
its own room or when no room is left (`Share.cfg`). Two configurations
show the faults: when the removal of a room clears the home, a later
removal of the van removes the station (`Share.clear.cfg`); when it keeps
the home, the home is not there (`Share.keep.cfg`).

### A stored van

The van part of a stored build must not stop the build from loading
(`DIY.Build.from_json/1`). The reader makes it whole:

- A zone that is missing comes back with a new id. A second zone with the
  same place gives its items to the first. A zone of no van goes.
- A zone with a place that the app does not know, with no id, or with the
  id of a room before it, is lost.
- An item of a van with a number that is not valid gets the default
  number. An item that cannot go in its zone goes to the electrical bay.
  An item of a van that the app cannot read goes away, and so does an
  item of a van with the id of an item before it.
- An item in a room that is not there goes home, or goes away. This is
  true for an item of the house too: it can be an item of a zone that is
  lost. An item of a kind that goes only in a van, in a room of the
  house, goes the same way.
- A home must be a room of the house where the kind can go: else the
  first such room.
- A camper van with a number that is not valid gets the default number.
  A van in a room where it cannot go goes to the first room where it can
  go, or goes away with its zones. A van with no id goes away with its
  zones.

The rest of the house stays strict: a room or an item of the house that
is not valid gives an error, and the page starts a new build (the device
keeps a copy). `from_json/1` never raises. Two property tests check it:
one changes the van part of a stored build in many ways (the build loads,
with the same house), and one changes each key of the rooms, the items
and the build (the reader gives a build or an error).

### The tests of phase 5

- Property tests: the two axles carry the empty van and the load, and the
  same weight more to the back puts more on the rear axle; more battery
  or more panels never give fewer days off the grid.
- The rules of the build (`test/diy/van_test.exs`): the zones, their
  removal, the station that goes and comes back, the numbers of a model,
  and a stored van part that is not right.
- The pages: `test/diy_web/live/van_live_test.exs`.
- The browser test adds a van in the driveway, items in its zones, takes
  a station of the house to the van, and checks the page Van with
  axe-core.

The check of the plan for phase 5 is "the owner's van gives power and
weight numbers that match the real van". It needs the numbers of the van
of the owner: the label in the door frame, the weight of each axle on a
truck scale, the items, and the Wh of a day from the app of the battery.
The app takes them; the comparison is open.

## The pictures

The app draws its pictures in SVG on the server (`DIYWeb.Scene`, with the
math in `DIYWeb.Geometry` and `DIYWeb.Camera`). The page Power shows
the house on its lot. The page Van shows the van. The first page shows a
house and a plan. The front page shows the house from the outside, in
the look of the plan (see "The house from the outside").

### The cameras

A camera is far away and has no vanishing point: each part of a picture
keeps its scale. It has a turn around the vertical axis (the yaw) and
the angle that it looks down at (the pitch). The app has two cameras:

- The house (yaw 60°, pitch 34°): a dollhouse with no front wall. The
  camera is in front of the house and to its right, and it looks down.
  The house goes along the screen, and its floors go down the screen. An
  item shows its front and its right side. Before, the camera had a yaw
  of 72° and a pitch of 28°. Then the owner chose the look of a picture
  that an artist drew of a house. The picture is for a dashboard of Home
  Assistant (a post of Anton Frolov). Its floor edges give a yaw near 60°
  and a pitch near 34°.
- The van (yaw 18°, pitch 28°): the camera is at the left side of the
  van (the side of the driver). The cab is at the left of the screen, and
  the doors at the back are at the right. The length of the van goes
  along the screen, so the picture shows what is over each axle.

Why not the isometric view of the games (yaw 45°, pitch 35°)? On a phone,
an isometric house is a diamond: much of the screen stays empty, and a
drag moves on a slant. With the dollhouse, the house fills the width of
the phone. A drag left or right moves an item along the house. A drag
up or down moves it to the back or to the front. A view straight on (a
pitch near 0) makes the floor too thin to place an item. A view with a
vanishing point is not at scale. The owner chose these two cameras from
screenshots of four cameras on a phone. Later, the owner chose the camera
of the drawn picture for the house (see above).

For the two cameras, the eye is at the large x, the large y and the
large z. So a box shows its top, its front (at y + d) and its side (at
x + w). The order of the paint is the same for the two cameras. The face
that looks more to the camera is in the light (`-l`), and the other one
is in the shade (`-r`). A face of a round shape looks between the two.
It gets one of three steps between the light and the shade (`-m1`,
`-m2`, `-m3`), from the angle of its normal (`DIYWeb.Camera.light/2`).

- A picture of the house shows only what the house of today has (with no
  planned item). The picture on the page Van counts the planned items of
  the van too, as the budgets of that page do. The house has its floors,
  and a garage when the build has a room outside that is not a yard. The
  equipment shows in its place. The panels are on the roof or in the yard.
  The stations have their extra batteries. The picture also shows the
  switch of the panel, the meter, the pole of the grid, the AC, the pool,
  the car, and the van with its panels and its fan.
- The house has the details of a real house. Its walls and the walls of
  the garage have lap siding: a line every 30 cm. The front of the roof
  has rows of shingles, and its eave has a gutter with a downspout. Each
  square window has two bars and a sill. The door has two panels, and the
  door of the garage has panels and a row of windows. The car is the model
  of the kind "ev": the same car as in the plan of the house.
- A flow shows only where the power goes in the model (`DIY.Power`). The
  grid goes to the meter. The panels go to the stations, or to the house
  or the meter on a grid-tie inverter. The stations go to the switch of
  the panel only when a station powers the circuits of the house. The
  panels of a station that is in a van give no flow.
- The lines of the flows move. With the reduced motion of the system,
  they do not move. Labels give the kW of the panels of each place and
  the kWh of the stations.
- The van shows the weight on each axle, at the wheels of that axle. A
  weight is red when it is over the rating of the axle. The van also
  shows the Wh of its batteries and the watts of its panels.
- A van has the shape of its make (`DIYWeb.Icon.VanShapes`): the Ford
  Transit, the Mercedes-Benz Sprinter or the Ram ProMaster. A medium roof
  rises less behind the windshield. Its length,
  its width, its height and its axles come from `DIY.Catalog.van_size/1`.
  The side profile, the grille and the lights follow photos of each
  model, for the picture only:
  - The Transit has a hood that slopes into the windshield, a wide grille
    in the shape of a trapezoid, and lights that sweep back.
  - The Sprinter has a long, low hood and a tall grille with the star.
    Its roof rises in a curve from the top of the windshield.
  - The ProMaster has a short nose that is almost upright, a large black
    grille, and lights high on the front.
  - Over the bottom of the windows (the belt), the sides lean in. The van
    has its mirrors, its bumpers, and its wheels with their rims. It has
    the windows of its doors, the sliding door on its right side, and the
    doors at its back. A mirror reaches 7 inches out of its side: the
    plan gives a van this space (`DIY.Layout.size/1`).
  - The same shape shows in the pictures and in the plan of the house.
    The plan of the van uses only the height of its hood
    (`DIYWeb.VanCutaway`).
  - On the roof, the panels are in rows of two, in the middle of the
    roof. The fan is at the back. In the drive, the van stands between
    the garage and the street.
- The colors are CSS variables (`assets/css/app.css`): a day in the light
  mode, and a night with lit windows in the dark mode. The van uses the
  colors of the icons (`i-white`). At night, these are dim in a picture
  of a house, as the walls are.
- The pictures are for the eyes only (`aria-hidden`): the text of each
  page gives the same facts. The picture of the front page is the link
  into the house, with a label that tells what the picture shows.
- The LiveView keeps the parts of each picture as an assign
  (`DIYWeb.Scene.parts/1`, `van_parts/2`). An assign with the same value
  does not change, so the page sends a picture again only when its parts
  change.
- The math of a camera: a is the yaw, b is the pitch, and s is 12.25 SVG
  units for each meter. A point at x, y, z goes to the side by
  s (x sin a − y cos a). It goes down by
  s ((x cos a + y sin a) sin b − z cos b). A step along the eye goes to
  the same point (a property test checks the math for each camera). The
  code paints each object from the back to the front, in an order that it
  sets by hand. The lines of the flows go behind the bushes, the person
  and the cars, and the labels go last.
- A property test makes random parts of a house. Each point of the
  picture is in its box, and each flow and label has its equipment.

Each kind of item has its icon (`DIYWeb.Icon`), in the same style. The
camera of the house shows the front of an item. A car and a van show
their side (the camera of a van). An icon is made of boxes, boxes with
round corners, cylinders and details of a material (white, steel, wood,
cloth). The faces of a box have a thin edge, so that a white item shows
on a light page.

- A round shape is a prism: a cylinder has 24 sides, and a corner of a
  box with round corners has 4 sides. Each side has the light of its
  normal, so the shape has a soft light. The sides have no edge between
  them. Under them is the silhouette of the sides that show, and over
  them its edge (`i-outline`).
- A prism can also lie along x or y. A tube is a motor or a pipe, and a
  slab with round corners is the frame of a window.
- The loop of a prism can be not convex: for example, the side profile
  of the car. Then a part of the prism can hide a different part. Its
  faces paint from the far one to the near one, and each face has its
  edge.
- Each kind has the details of a real model, at the size of the kind.
  Some examples:
  - a fridge has its doors and its handles;
  - a range has its knobs and the window of its oven;
  - a microwave has its window and its keys;
  - a water heater has its pipes;
  - an AC has the grille of its fan;
  - the car has the profile of a crossover, its glass, its doors and its
    wheels;
  - a pool pump has its motor, and a strainer with a clear lid;
  - a ceiling fan has four blades, its light and its rod;
  - a CPAP has its water tank, its screen, a knob and the port of its
    hose;
  - a sink has its cabinet, its basin and its faucet;
  - a bed has its drawers, its mattress, a duvet and two pillows;
  - a battery has its label, its handle and its terminals;
  - a power station has the look of the Pecron F5000LFP, which the owner
    chose: a dark body on a trolley with four wheels. Its front has the
    inputs, the screen with two green buttons, and the DC and AC
    outputs, each group in an orange frame. Its side has the dust
    screen. The station is 21.7 by 15 by 13.1 in (Pecron). The data of
    Pecron does not give the trolley. So the height on the trolley (near
    17 in) is an estimate from the photos of Pecron. A new station is
    "Another station": it has this look and this size, with typical
    numbers (2 kWh, 2,400 W). The person can choose its model (see
    "The models of power stations");
  - a busbar has the look of the Victron Lynx Distributor, which many
    people know. It has a blue case with an end cap at each side, and the
    red and black caps of its busbars. Its front has the orange line of
    Victron and a gray light for each position. It also has the green
    light of the power, the white lines of the label, and the hoods for
    the cables. Each hood has a dark port for the cable of each of its
    positions, at its foot: the cables come in from under the hood. A
    small block is between the two hoods in the middle. The material
    `victron` has the blue of the case.

On the plan of the house, a small face of an item keeps two decimals in
its points (`DIYWeb.Camera.plan_points/3`). Thus its shape stays at the
highest zoom. A larger face has one decimal. Each face of the walls, of
the furniture and of the ghosts of Home Assistant also has one decimal:
the plan stays small.

The icon is next to the name of the item in these places:

- the cards of the zones of a van;
- the lists to add an item;
- the sheet of an item;
- the list of the items on the page Bill.


- The root layout has a sprite of the icons: the shapes of each kind one
  time. An icon on a page is a small SVG that uses the shapes of its kind.
  So a page sends each icon in about 100 bytes. The app makes the sprite
  one time, when it compiles.
- The tests check that each kind has shapes of its own. They check that
  each class of the icons has a rule in `app.css`. They also check that
  each point is in the box of its icon, with a margin for the edge.

The bar of the pages uses the icons of Heroicons (MIT), which Phoenix
gives. The other small signs use them too: the arrows, the close buttons,
and the checks of the lesson.

### The models of power stations

The owner asked for the stations that the DIY world knows. The request
was: "Pecron E3800LFP, EcoFlow Delta Pro, EcoFlow DELTA Pro 3, and EcoFlow
DU (whole house), or the Anker Solix". The app reads "EcoFlow DU (whole house)" as
the DELTA Pro Ultra (DPU), the whole-home station of EcoFlow. EcoFlow also
sells the DELTA Pro Ultra X (12 kWh, 12 kW) for the whole home: the owner
can ask for it. It reads
"the Anker Solix" as the SOLIX F3800 and the F3800 Plus. The Pecron
F5000LFP, the look of the kind, is a model too. The person chooses the
model of a station in its panel (the choice "Model",
`DIY.Catalog.station_models/0`).

Each model has its battery, its output, its charge from the wall, its
solar input, its weight and its size (in inches):

- Pecron F5000LFP: 5.12 kWh, 7,200 W, 1,800 W, 5,800 W, 124 lb, 22 × 15
  × 17.
- Pecron E3800LFP: 3.84 kWh, 4,200 W, 1,800 W, 3,000 W, 87 lb, 18 × 12 ×
  15.
- EcoFlow DELTA Pro: 3.6 kWh, 3,600 W, 1,800 W, 1,600 W, 99 lb, 11 × 25 ×
  16.
- EcoFlow DELTA Pro 3: 4.096 kWh, 4,000 W, 1,800 W, 2,600 W, 114 lb, 13 ×
  27 × 16.
- EcoFlow DELTA Pro Ultra: 6.144 kWh, 7,200 W, 1,800 W, 5,600 W, 182 lb,
  27 × 19 × 16.
- Anker SOLIX F3800: 3.84 kWh, 6,000 W, 1,800 W, 2,400 W, 132 lb, 15 × 16
  × 28.
- Anker SOLIX F3800 Plus: 3.84 kWh, 6,000 W, 1,800 W, 3,200 W, 137 lb, 15
  × 16 × 28.

The rules:

- The numbers come from the page of each model of its maker. The panel
  shows the source under the numbers. Where the maker gives only a
  current, the numbers come from Adorama, and the source tells it.
- The charge from the wall is the AC charge from an outlet of 120 V and
  15 A: 1,800 W for each model. A load that runs for hours gets 80% of
  the outlet (1,440 W): the help of the field tells it. The page Power uses it as the limit of
  the charge from the grid in one hour (`DIY.Power`). Many stations take
  more with a cable of 30 A or on 240 V. The source tells that number,
  and the person can give it.
- The size is the width of the front, the depth and the height, in
  whole inches. The front of a DELTA Pro and of a DELTA Pro 3 is the
  short end. The F3800 stands up, on its wheels. The DELTA Pro Ultra is
  the inverter on one battery: the app adds their sizes and their
  weights. The F5000LFP is on its trolley in all the photos of Pecron, so
  its size has the trolley (an estimate). The E3800LFP and the DELTA Pro
  Ultra have no wheels. Their cart and their stand are accessories that
  the app does not show, so their sizes do not have them.
- A new model gives its numbers when the numbers of the station are not
  the numbers of the person (`DIY.Build.update_item/3`,
  `DIY.Build.own_numbers?/1`). A guess of the app, the numbers of a new
  station and the numbers of a model are not the numbers of the person.
  So a pass through the list of models (with the arrow keys, for
  example) never deletes the numbers that the person gave. The key "Use
  the numbers of the model" gives the numbers of the model
  (`DIY.Build.use_model/2`). When the numbers are not the numbers of the
  model, a line under the source tells it. The price, the extra
  batteries and "It powers" always stay.
- A size that the person gives stays with a new model. With no such size,
  a station has the size of its model, and "Another station" has the size
  and the look of the kind (`DIY.Layout.size/1`). The key "The size of
  the model" gives the size of the model again. The focus goes to the
  help of the size, not to a side: LiveView does not change the value of
  a field with the focus.
- A status tells a screen reader the new numbers and the size, or that
  the numbers stay. It comes after a new model, and after "Use the
  numbers of the model". A new model of a van gets a status too.
- A station of a model has the name of the model (`DIY.Catalog.name/1`).
  The title of its panel and the page of a van show it.
- A station from a build from before the models is "Another station".
- Each model with a look of its own has a model of its parts
  (`DIYWeb.Icon.StationShapes`), from the photos and the drawings of its
  maker. The front, the right side, the top, the back and the left side
  each have their parts. The F5000LFP and "Another station" have the
  look of the kind.
  - The E3800LFP: a dark box with an orange cap on each corner (the
    material `orange`). The top half of its front has the groups of
    ports in orange frames (`i-orange-l`). The F5000LFP has this orange
    too: it has a color in the house plan. The bottom half has ribs and
    the badge of the name. The left side has the AC input and a vent.
  - The DELTA Pro: a black body with a gray cap, and a handle at each
    end of the cap. Its front has the screen, the gold button and the
    AC outlets. The right side has two fans and two doors. The back has
    the inputs, the ports for more batteries and a vent. Two wheels are
    at the back.
  - The DELTA Pro 3: a silver body with a dark hood at each end. The
    black frame of its front has the screen and the tray of the AC
    outlets. The right side has a long slot and a door. The back has
    four doors of ports and a vent. Two wheels are at the back.
  - The DELTA Pro Ultra: the black inverter on the battery. The screen
    is at the front of the top, and each end of the front and of the
    back has a silver loop. The battery has a silver plate on its front
    and on its back.
  - The F3800 and the F3800 Plus: a tall box of warm gray (the material
    `titanium`) on wheels. The handle, the blue light (`i-cyan`) and the
    black panel are at the top of its front. The right side has the AC
    outlets and a tall vent. The left side has the inputs and a tall
    vent. The back has the pull handle. The Plus has a light top, blue
    solar inputs, a cover for a generator, a badge, and the TT-30 in
    place of the 14-50.
- The stage aims at the panel of each model
  (`DIYWeb.Icon.StationShapes.screen/1`). The frames of the stage change
  with the code of the models (`DIYWeb.Stage.frames/2`).

## The plan at scale

The page Rooms shows the house cut open, at scale (`DIYWeb.Cutaway`, with
the rules in `DIY.Layout`). Each floor is a layer, with a gap between the
layers. The layers are the ground (the lot, the rooms outside and floor
1), floor 2, floor 3, the attic and the roof. Each room is at its place,
with its size. Each item is at its place in its room, with its size and
its turn. A length is in inches.

- The draft. A new house gets a plan from its size: a floor of 3 by 2
  with the area of one floor. The rooms of a floor are in rows, and a
  living room gets more space than a bathroom. The garage is on the right
  of the house (24 by 25 feet). The driveway is in front of the garage
  (24 by 25 feet). The longest camper van (290 in) fits in each. The
  yard is in front of the house. The first items of a room stand along its back walls. A
  build of an older version gets the draft when it loads.
- The person changes the plan. A drag moves an item, also to a different
  room. A tap opens an item. A tap on a room, on one of its walls or on
  the edge of its slab chooses the room. The chosen room has
  an outline and a handle on each wall. Its bar (under the plan) has its
  size and its buttons. A drag on the chosen room moves it with its
  items, and a drag on a handle moves a wall. A drag on an empty place
  moves the view, and the house stays on the screen. Two fingers, Ctrl
  and the mouse wheel, or the buttons zoom.
- The plan does not trap the page. The mouse wheel alone scrolls the
  page: a note on the plan then tells how to zoom. When the plan shows
  all the house (all its width and all its height), a finger that moves
  up or down scrolls the page. When the finger lifts, the page keeps its
  speed and slows down, as a page that the browser scrolls. A finger that
  stops before it lifts gives no glide. After a zoom in, the finger moves
  the view. The button to add a room is under the plan: so it does not hide
  the name of a room.
- The tabs of the layers. A tab fills the screen with its layer. In the
  house, the other layers hide, and a tap goes through them. The chosen
  room on a layer that hides is not chosen now. In the van, the other
  layers are pale, and a tap on a zone of a different layer ends it. The
  button "Show all the house" (or "Show all the van") ends it. The tab of
  the layer that shows is pressed (`aria-pressed`): it has a gray fill and
  a bar under it.
- A drop. The center of the space of the item on the floor moves with
  the pointer. The item goes to the room that has this center. The script
  tries its own room first, then the rooms of the layer under the pointer,
  then the rooms of its own layer. The pointer does not choose the room:
  it is on the body of the item, above its space.
- With no drag. The part "Where it is" of the panel of an item has
  buttons that move it (6 inches for each tap). Other buttons turn it a
  quarter turn, and give it a size. The panel tells the new place of the
  item in words. The bar of a room has buttons that move it (2 feet for
  each tap): the plan over the bar shows the move. The sheet of a room
  gives its size in feet. So a person with one finger and no drag can do
  each change (WCAG 2.2, 2.5.7). A handle is 24 pixels wide (2.5.8).
- The rules (`DIY.Layout.fill/1`, after each change; `specs/Plan.tla`).
  No two rooms of a layer overlap, and each item is in its room. A room
  does not move over a different room: the page tells why. When a wall
  moves, the items keep their place in the house and stay in the room.
  After a turn or a new size, an item stays in its room. A new item goes
  to a free place in its room.
- A new room goes to a free place in the house. When the floor is full,
  it goes at the back of the house, next to it. A room outside goes on
  the right of the rooms of the ground.
- A drag moves a room or a wall on a grid of 6 inches. The sheet of a
  room takes a size in feet, to the inch.
- Each kind has a typical size (`DIY.Catalog.size/1`). Next to each size
  is its source: the spec sheet of a common model, or a standard size.
  For example, a fridge is the LG LRFXS2503S: 33 by 33 by 70 inches. A
  size with no source is for the plan only. The panel of the item asks
  for the size of the real item.
- The watts of an array of solar panels give its size. A panel of 400 W
  is 45 by 68 inches: a module of 108 half cells, 1134 by 1722 mm. An
  item on a wall or a ceiling (a mini split, a meter, a switch, a fan)
  has a lift.
- The shell. Each room has a slab under it, and a yard is on the ground.
  Each room inside has walls, as in a dollhouse. A wall on the outside at
  the back has its full height (8 feet), where no room or yard is behind
  it. The wall on the outside at the left end of the house is cut on a
  slope. It is full at the back of the house, and near the floor at its
  front. A wall between two rooms is cut at 75 cm (30 inches): the rooms
  look like rooms, as in the drawn picture. A high wall there hides a
  part of the room at its left, because the camera is to the right. A wall
  of 75 cm hides a band of the floor behind it: near 1 m along y, and
  near 55 cm along x. Where an item of the room behind is in this band,
  the wall in front of it is low, also on a slant.
  An item over the wall (a fan) does not count. Each other wall is cut
  near the floor: at the front of a room and at the right end. A wall at
  the back is low where a room or a yard is behind it, also on a slant.
  So a wall does not hide the items of a room or of a yard. The walls are
  16 cm thick, and the slabs 30 cm. The van keeps its look: its walls,
  its colors and its light background.
- The picture of an item is its icon at the size of the item
  (`DIYWeb.Icon.Shapes.placed/2`). A turn turns the model, and a face
  that looks away does not show. Solar panels on a roof lie on its slope.
  In a yard, they stand in rows on a rack.
- The details of the plan:
  - A floor has the lines of its material. Wood has planks (6 inches
    wide), and tile has tiles of 18 inches. Concrete has slabs, a deck
    has boards, and ply has sheets of 4 by 8 feet. Grass has the stripes
    of a mower, and a roof has rows of shingles. A flat roof has the
    seams of its membrane, and the metal floor of a van has ribs. Each
    is an SVG pattern on the plane of the floor
    (`DIYWeb.Cutaway.textures/0`): one unit of a pattern is one inch on
    the floor. A floor of carpet has no lines.
  - An item that stands on a floor has a soft shadow under it, 3 inches
    out from each side. An item on a wall or a ceiling has no shadow.
  - A wall that is higher than the cut near the floor has a baseboard.
    When it has its full height and is 42 inches long or more, it also
    has a window (4 feet wide at most).
  - The look of the drawn picture: warm colors, and brown lines of ink
    on each face (the class `i-face`). The items have warm colors on the
    plan only: cream for white, a dark screen for a TV. The top of each
    wall is a dark cut. A wall has a soft light: lighter at its top, and
    warmer at its floor. The plan is on a dark background, by day too, as
    in the picture.
  - At night (the dark mode), the colors are darker, and the floor of each
    room inside has the warm light of a lamp (`p-glow`).
  - The items that run have small, slow loops. The flame of a furnace
    flickers, and the coils of heat strips and of a space heater glow (the
    classes `i-fire` and `i-coil`). A loop starts when the layer of its item
    shows: when the page opens, or when the person goes to the layer. Each
    loop stops after 4.8 seconds, at its first state (WCAG 2.2.2). A planned
    item does not run: it has no loop. With "reduce motion" in the settings
    of the device, no part moves. A tail light of a car or of a van has no
    loop.
  - The furniture of a room (`DIYWeb.Decor`), as in the drawn picture. A
    word in the name of a room gives its pieces, in capital letters or
    not:
    - "bed": a bed, two nightstands, a dresser, a rug and a plant;
    - "living": a sofa, an armchair, a table, books, a rug and two plants;
    - "kitchen": counters, a table with chairs, and a plant;
    - "bath": a bath, a toilet, a vanity and a mat;
    - "garage": a bench and a shelf;
    - "laundry": a shelf and a basket;
    - "attic": boxes;
    - "yard" (a room outside): a table with chairs, trees and bushes;
    - a different name inside: a plant. A different room outside, and a
      roof, have no furniture.

    Each piece has its place: against the back wall, in the middle, or at
    the front. A piece is 4 inches from the walls, and 8 inches from the
    edge of a yard. A counter is 1 inch from the back wall. In a kitchen,
    counters fill the back wall between the items. A piece does not show
    when it touches an item under its top, or a piece before it. The camera
    looks down to the back and to the left. So a piece also hides the floor
    behind it and at its left (its shadow). A piece does not show when its
    shadow hides more than a quarter of an item at the middle of the height
    of the item. This is also true for an item of a different room of the
    layer. So the items show, and the person can tap them. A piece can hide
    more of the lower part of a tall item. A rug is flat: it paints first,
    and the pieces and the items stand on it. The furniture is for the eyes
    only. It uses no power, and a tap goes through it to the floor of the
    room. It moves with its room in a drag. The leaves of a plant or a tree
    are discs that look to the camera.
  - A long wall has a picture in a frame at the left of its window. A
    garage, a laundry and an attic have no picture, and no picture is
    behind an item (4 feet from the wall at most).
- The order of the paint (`DIYWeb.Camera.order/2`). A wall or an item that
  is behind a different one paints first. A box is behind a different box
  when it is on the far side of it along x, y or z. A wall is flat for
  this order. So an item in a room is in front of the walls at the back,
  and behind the walls at the front. An item that is larger than its
  room goes through walls: it paints by its place only. A rug paints
  first. The parts of a model use the same order, so a turned item paints
  its back part first.
- The script (the hook Plan, `assets/js/plan.js`) moves the parts of the
  SVG while the pointer moves. It sends the change when the pointer
  stops, and the server then draws the plan again. The script has the
  math of the plan and of its inverse, on a floor and on the slopes of a
  roof. It uses the axes of the camera of the SVG (`data-axes`). A
  property test checks that a point goes to the screen and back. It uses
  random cameras that look down more than a roof slopes.
  The zoom is in the `viewBox`, which LiveView keeps
  (`JS.ignore_attributes/1`). The tab keeps it in its session storage,
  with the layer that shows. With no view in the session storage, the
  house starts on floor 1 (`data-start`). The walls and the slabs of
  floor 1 fill the screen, and the other layers hide. The tab of a layer,
  or a tap on a room, also hides the other layers. A room that the person
  chooses in the list, or that an arrow key moves, also shows its layer.
  So does an item on the stage, also after its panel moves it to a room
  of a different layer (`data-open`).
  While one layer shows, the view stays in the box of that layer. So on a
  phone, the floor is in the middle of the screen. The button "Show all
  the house" shows all the layers.
- The plan is for the eyes. A list of the rooms and of their items gives
  the same facts, with the usage of each item. It shows when it has the
  focus. In the list, the arrow keys move an item or a room (6 inches, or
  2 feet with Shift). Each key moves it as it points on the plan: in the
  house, the Up key moves it to the back. A screen reader hears the new
  place, from the left wall and from the back wall. The move buttons of
  a sheet and of a bar point the same way (`DIYWeb.Camera.arrows/1`).
- On a phone. A tap on a room chooses it, and the view zooms in to it:
  its floor, its walls and its items fill the screen. The view shows a
  third of the house at least, so the person sees where the room is.
  Where the names of two rooms overlap, or are nearer than 4 pixels, the
  name of the larger room shows. The other one hides until a zoom in. The
  handles of a small room show only when they are 36 pixels apart at
  least: else they would hide the room.
- From room to room. In the house, the name of a room is on a pill, as in
  the drawn picture. The pill is a round box, and the script gives it the
  size of the text. The pill of the chosen room has the color of the
  choice, and the name of the chosen room shows first. The bar of the
  chosen room has its name between two arrows. They go to the room before
  it and to the next room, in the order of the list. After the last room
  comes the first room. The arrows do not add steps to the history of the
  browser. A screen reader hears the name of the new room. The buttons of
  the bar are in a second row, so the name has space on a phone.
- The zoom to a room. A tap on a room zooms in to it. But a view that
  shows the room in more detail stays: a tap does not zoom out. The
  arrows, the list or a link show all of the room that they choose. When
  a part of the room is out of the view, the view zooms in to the room. A
  page that opens with a chosen room also zooms in to it.
- The chosen room stays while the person opens an item (on the plan or in
  the list), adds an item, or deletes an item. The stage of the item
  closes back to the room. When the panel moved the item to a room on a
  different floor, the floor of the chosen room comes back. So the
  person goes from room to room with one finger, and taps an item to
  change it.
- The tests. Property tests check the draft (no overlap) and random
  changes (the rules, and the JSON gives the same plan). A property test
  draws random houses: each point is in the box of the SVG, and each id
  is one of a kind. No box paints after a box in front of it. A test
  checks the same order for the parts of each kind at each turn. TLC
  checks `specs/Plan.tla`, with the turn and the size of the item. Three
  faults show that the rules matter. The browser test drags an item and
  a wall, and moves an item with a key.

## The stage of an item

A tap on an item of the plan brings the item out of the house. It turns
to the person, as an item that a person takes in the hand. Next to it,
its panel opens (`DIYWeb.Stage`, `DIYWeb.Inside`, and the hook `Stage` in
`assets/js/stage.js`). The panel is the same for each item: a person
learns it one time, and then knows each item.

- The flipbook. The server draws the model of the item from 12 cameras.
  The first camera is the camera of the house. The last camera looks at
  the panel of the item: at its front, or down at the top of a hub. It is
  a little to the side and over the item, so the item keeps its depth.
  The cameras between turn step by step. Each frame has the center of the
  model at the same point, so the model turns in place. The first frame is
  the model of the kind, at its own size and with no turn. So an item with
  a turn, or with a size of its own, changes a little at the start.
- The flight. The hook starts at the next frame of the page, after the
  plan shows the layer of the item. It puts the first frame on the item of
  the plan, at the same size. In 0.9 seconds, the model moves to its place
  on the stage and grows. On its way, the hook shows the frames one after
  the other. The item of the plan does not show while it is on the stage.
  A close does the same in the other direction in 0.65 seconds, from where
  the model is (also in the flight out). Then the stage closes. An item
  that is not in the view of the plan comes from the middle of the stage.
  An item of a plan that is not on the page does the same. For example,
  the page is down at the list of the rooms.
- The place of the panel. On a page of 48rem (768 pixels) or more, the
  panel is at the right of the page, and it is 26rem wide. On a narrower
  page, it is at the bottom, and it has 58% of the height (44% for a hub).
  The model goes in the rest of the page: the whole model, at the middle.
  A notch of the panel points at the model. The panel shows when the
  model lands. Then its title takes the focus, so a screen reader reads
  the name of the item.
- The same parts, in the same order, for each item:
  1. What it costs: the dollars of an average month, and the kWh and the
     dollars of a year. A gas item also has its gas. An item that uses no
     power of the house by itself has its energy in words. When the
     numbers are a guess, a note asks the person to check them on the
     item, with the key They are right. "How the app gets this number"
     opens the math of one month.
  2. Home Assistant, only for a hub: the state of the link, Disconnect,
     and the match of the rooms.
  3. How you use it: the numbers of the item. For a camper van and for a
     power station of a model, also the key "Use the numbers of the
     model". A station of a model also shows the source of its numbers.
  4. Where it is: its room, its place, its size and its turn. The list of
     the rooms has only the rooms where the item can go. An item does not
     go from the house to a van with this list. A small map of the room
     from above shows the item, a thick line on its front, and the other
     items of the room (`Inside.room_map/1`). The map has the axes of the
     move buttons. While the sheet is open, the model on the stage does
     not show the turn, and the plan is behind the sheet. So the map shows
     a turn, a move or a new size at once. Under the map, a text gives the
     space of the item on the floor. When the item is larger than its
     room, a text says so. A turn keeps the item in its room, as a move
     does.
  5. More: the flags (a plan, a power station runs it), what the app
     uses it for, and Remove.

  Each part has a heading, and the panel scrolls: no key hides a part.
  The heading of the cost is only for a screen reader: the dollars of a
  month are the large text at the top.
  The live controls of Home Assistant come as a part after the cost, in a
  later change.
- The same controls for each kind of value (`DIY.Catalog`):
  - a number has − and +, a field and its unit. A tap on − or + gives
    the next round number (`DIY.Catalog.stepped/3`). The step is near 5%
    of the number, as 1, 2 or 5 times a power of ten. Hours go by half
    an hour. The range of the number stops it. A screen reader hears the
    new value (a status in the panel), and an end of the range ("the
    most", "the least"). At an end, the sign of − or + is dimmed, also
    for a screen reader (`aria-disabled`). It is not disabled, so it
    keeps the focus, and its ring of the focus keeps its contrast. A tap
    on it says the end again: the status is empty for 100 ms. The text
    that comes after it shows only when the same item is open, no newer
    status came, and the number did not change;
  - a choice is a row of buttons (radio buttons);
  - yes or no is a switch (a checkbox with the role switch);
  - a name is a field.

  The ids of a number start with `param-`: `param-watts` is the field,
  and `param-watts-field` has its label and its help. A screen reader
  reads the unit, the help and the error with the field
  (`aria-describedby`).

  Each control is 44 pixels (2.75rem) high at least. A link in a text
  ("Show me where") is 24 pixels high at least (WCAG 2.5.8). The text is
  16 pixels. The help, the notes, the year, the place and its keys are
  15 pixels. The headings of the parts and the tags are 14 pixels, in
  capitals for the headings. The label on the screen of a hub is 13.6
  pixels, in capitals. The panel has the colors of the app (daisyUI), in
  the light and the dark mode. An error has the red of the app, with a
  contrast of 4.5 at least (`--color-error`).

  The room is a list (a select), not a row of buttons: a house can have
  many rooms. Each side of the size of an item (width, depth and height)
  has the control of a number: −, the field, "in" and +. A change applies
  at once. When a side is not valid, the error shows under the size. Only
  the sides that are not valid have the mark of the error. A step and the
  key "The typical size" clear the error.
- The tags. A tag on the model shows where a number is on the real item:
  - the EnergyGuide label of a fridge and of a freezer;
  - the watts on the back of a TV and of a computer, and their hours on
    their screen;
  - the watts inside the door of a microwave.

  A tap on a tag goes to its number in the panel. The field comes to the
  middle of the panel, shows a flash, and takes the focus. "Show me
  where" under a number puts a ring on its tag three times. With less
  motion, the ring does not move. It goes after 2 seconds. A tag is a
  point of the face of the item (`DIYWeb.Stage.region/1`): its screen,
  or the middle of its front. The name of a tag starts with its text
  (WCAG 2.5.3): "Watts: Power, on the label on the back". The keys that
  show a tag or the screen show only when the model is in front.
- The hub. A Home Assistant hub is the only item with its own screen.
  Its LED screen on its top has the address of Home Assistant and the
  key Connect (`DIYWeb.HomeAssistant.screen/1`). The hook puts the
  screen on the top of the last frame with a CSS matrix, so the screen
  follows the slant of the top. The model comes near enough: the screen
  is 300 pixels wide (for a font of 16 pixels). On a small area, the
  screen is as wide or as high as the area. A zoom of 400%, or a phone
  on its side, can make that screen less than 220 pixels wide. Then it
  is too small to read on the model. So it covers the whole area, with
  no slant, and its text scrolls. The padding of the screen is in rem,
  not in percent: a padding in percent is a part of the width of the
  page. The rest of the hub is in the same panel as each item. Its part
  Home Assistant has a link to its screen. A bad address shows "Check
  the address." on the screen, and the field keeps the address. A screen
  reader reads the error of the panel with the field. Connect opens the
  sign-in in a new tab, so the hub stays on its stage. While the new tab
  waits for the person, the screen tells the person to sign in there.
- The state of the stage. It is the attribute `data-stage`: placed,
  landed or closing. The CSS has a rule for each. The hook sets it with
  the command of the LiveView (`setAttribute`). The LiveView sets an
  attribute at once, so the panel shows before its title takes the focus.
  And a patch (after a change of a number) keeps it. A class does not do
  this: the LiveView adds it only at the next frame. And when the hook
  adds the class first, a patch removes it.
- The remove asks on the panel: Remove, or Keep it. The browser shows the
  question with the commands of the LiveView (`JS.show` and `JS.hide`),
  and the focus goes to Keep it.
- The keyboard and the screen reader. The stage is a modal dialog, with
  the tags and the screen in it, after the panel: a screen reader reads
  the title first. The Tab key keeps the focus on the stage. The Escape
  key, the key Put it back, or a tap next to the panel puts the item
  back. Then the focus goes back to where it was, for example the item in
  the list. A screen reader does not see the area next to the panel: it
  has the key Put it back. The head of the panel stays on its top, and a
  scroll padding keeps the control with the focus under it (WCAG
  2.4.11). On a page that is less than 30rem high (a zoom of 400%), the
  head scrolls with the text.
- Less motion. With `prefers-reduced-motion`, the model is at once in
  front, and a close is at once.
- The cost. The frames of a water heater have about 100 KB, and take 37
  ms on the BEAM of a computer. So the app keeps the frames of each kind
  after the first time. A new version of the stage, of the shapes or of
  the camera makes new frames. The LiveView keeps
  the frames of the open item: a render, for example of a different page,
  does not send them again. The points have one decimal: a step of 0.1%
  of the model.
- The van. An item of a van comes forward on the page Van, with the same
  stage and the same panel (`DIYWeb.Inside.item_stage/1`). The first
  frame of its model is from the camera of the van plan
  (`DIYWeb.Stage.frames/2` with `:van`). So the flight starts on the item
  of the plan. The close goes back to the van. The panel of an item
  in a van differs only where the van is different:
  - the first part has its weight and its Wh in a day of July and of
    January, not the dollars of the house;
  - the list of "Where it is" has the zones of the van where the item
    can go;
  - "More" has no flags of the house. It has the budgets of the van that
    the item counts in, and "Bring it home" for a station of the house.
    This key closes the panel, and a message tells that the station is at
    home now;
  - the remove asks "Remove this item from the van?".

  The key "The numbers of the van" brings the van itself to the front. It
  has the panel of an item of the house, with no key to its own page and
  no remove.

The tests:

- `test/diy_web/components/stage_test.exs`: the frames of each kind. The
  first frame has the polygons of the plan: of the house, and of the van
  for each kind that can go in a van. Each point and each corner of the
  face is in the view. Each tag is a number of its kind, on the face. A
  property test checks that the center of the model stays in each frame.
- `test/diy_web/live/stage_live_test.exs`:
  - the stage and its tags;
  - the same parts in the same order for a fridge, a TV and a hub;
  - the same control for each kind of value, with the texts that a
    screen reader reads with it;
  - − and +, and the status of the new value;
  - the remove;
  - the screen of a hub, with a bad address.
- `test/diy_web/live/van_stage_live_test.exs`:
  - an item of a van: its stage with the frames of the van plan, and the
    same parts in the same order. Its weight and its energy, and its
    zones. A change of a number and of the zone, and the remove;
  - the van itself, on its page and on the page Rooms. A planned van
    opens on its page;
  - a station in the van goes home from its panel;
  - an item is on the stage of its own page only;
  - a smart meter (an item with no numbers) tells its new size;
  - − and + of the size, a typed size, a size that is not valid, and the
    ends of the range;
  - the field of a ZIP code after an error, on the start page and in
    Settings.
- `test/diy/catalog_test.exs`: the steps of − and +. A property test
  checks each number of each kind. The new value is valid and in the
  range. It goes in the right direction, one step at most. It is a
  multiple of its step (or an end of the range). A step is 1, 2 or 5
  times a power of ten, from 3% to 8% of the value.
- `test/js/stage.test.js`: the math of the rest pose (a property test
  with fast-check). Also the math of the area, of the place of the
  model, and of the screen of a hub. The flight runs with a fake clock,
  and the hook runs on a fake page. As with the LiveView, an attribute
  of a command is on the element at once, and a patch keeps it. The
  fakes keep the attribute `hidden` of each frame, as a browser does.
  The tests close in the flight out, and before it starts. They remove
  the stage before the flight starts, and in a flight. They tap a tag
  and "Show me where", and the ring goes after its time. A hub on a
  short page shows its whole screen, and on a very small page its screen
  covers the area.
- `specs/Stage.tla` is the model of the flights. Three things occur in
  any order: the frames of the page, a close by the person, and the
  patches and the removal by the LiveView. The model has them with and
  without less motion. TLC checks four rules. The close patches the page
  one time at most. No call changes the stage after its removal. The
  panel shows only when the model is in front. The stage keeps its state
  through a patch. Also, a close ends with its patch, and the model lands
  unless the stage closes first. Each fault has a configuration, and TLC
  finds it:
  - a step that does not check its flight (`Stage.noalive.cfg`): the
    flight out lands while the model flies back;
  - a second close that does not stop (`Stage.noclosing.cfg`): two
    patches;
  - a removal that does not stop the start (`Stage.nogone.cfg`): the
    start flies a stage that is not on the page. The model found this
    fault in the hook, and the hook now has the fix;
  - a state that the LiveView does not keep (`Stage.nokeep.cfg`). After
    a patch, the stage has no state. The panel and the model are not at
    their place.
- The browser test taps the fridge on the plan: the frames change in the
  flight. Then the title of the panel has the focus. A tap on the tag of
  the EnergyGuide label gives the focus to its number, and + gives the
  next round number. After this change, the stage keeps its state, and
  the panel stays on the page. The walk also opens items in the list,
  changes their numbers, and turns an item. Axe checks the stage after it
  lands. On a desktop, the walk asks for less motion: so it checks the
  two ways, and the flights do not make it too long.

## The house from the outside

The page House shows the house from the outside (`DIYWeb.Outside`). It
is the house of the plan of the page Rooms: the same rooms, the same
camera and the same look. A tap on the picture opens the plan.

- The picture shows the house of today: a planned item does not show.
  Each floor stands on the floor under it. A floor is a slab of 30 cm,
  then walls of 2.4 m on the sides with no room of the same floor.
- A part of a floor with no room over it stays open at the top. For
  example, with no bathroom on floor 2, the kitchen under it shows from
  above. The plan of the page Rooms has the same hole.
- A garage has its walls, a wide door and a flat roof. It has its own
  wall on a side with a room of the house.
- The front and the right end of a floor have windows: one window for
  each 8 feet of wall. The largest room of floor 1 with a wall at the
  front has the door, at the middle of the longest part of that wall. The
  person stands beside the door.
- The roof is on the top floor with rooms. It has its slopes, its gable
  and its panels. Only a room on the roof on the level of the roof is the
  roof. A house with no such room gets a roof with no item. The attic is
  in the roof, and the items in the rooms do not show.
- The yards and the driveway show their furniture (`DIYWeb.Decor`) and
  their items, as in the plan: the AC, the panels, a car.
- A room outside on a floor (a balcony or a patio) is on its slab, with
  its floor, its furniture and its items. It has no wall. A room outside
  on the roof does not show.
- The grid. A pole is at the back of the lot, and its wire goes to the
  meter on the right end of the house. The power flows in the wire 5
  times (4.5 seconds) when the page opens. It does not flow when the
  person asks for less motion.
- The labels tell the kW of the panels on the roof and of the other
  panels. A label also tells the kWh of the stations, with one decimal.
  The panels on the roof of a garage or of a porch do not show. They are
  in the label of the other panels. That label is over the first yard or
  balcony with panels, else over the middle of the lot.
- The picture is the link into the house. Its label for a screen reader
  tells what the picture shows. These are the floors, the garage, the
  panels, the items outside, the stations, the wire and the person.
- At night (the dark mode), the windows have the warm light of the
  rooms.
- The order of the paint is the order of the plan
  (`DIYWeb.Camera.order/2`). For the order, a wall is flat, on its line.
  The slabs on the ground paint first. An item in a yard that is taller
  than floor 1 paints by its depth only. No order is right for it and the
  floors over it.
- The LiveView makes the picture only for the page House, as an assign
  (`DIYWeb.Outside.view/1`). The page Power keeps the picture of
  `DIYWeb.Scene`.
- The tests. A property test draws random houses: rooms go away, move,
  change their size or are new, and random items are in random rooms.
  Each point of a polygon, a label, a text and the wire is in the box of
  the SVG. Only the items of today in the yards and on the roof show. No
  box paints after a box in front of it. The browser test taps the
  picture and goes in.

## A shared house

A person can share a house with a link. The link shows the house and its
numbers to a different person, for example on Nextdoor. This is a request
of the owner (October 2026): a real house with real numbers is easier to
understand than a text about the app.

### The link

The link has the house in its path: `/s/DATA`. `DATA` is the shared
house as JSON, compressed with raw DEFLATE, in base64url (`DIY.Share`).
The first character of `DATA` is the version of the format (`1`).

The link carries the house. The server keeps no copy of it:

- The server reads a shared house only to answer a request for its link
  or its picture. It writes the house nowhere: no database, no file, no
  cache of the server.
- The log of the requests does not show the path of a link
  (`DIYWeb.Endpoint.log_level/1`). The invocation logs of Cloudflare stay
  off.
- This changes the rule of "The build on the device" for a shared house
  only: the server sees a shared house while it answers. The owner
  accepted this (October 2026). Before, the plan put the house after `#`
  in the link, where the server never sees it. But a site that shows a
  preview of a link reads only the page that the server gives. The part
  after `#` does not get to the server.

The shared house is the build with these changes (`DIY.Share.strip/2`):

- No link to Home Assistant or to a maker: `areas`, `devices` and `units`
  are empty. The data of these links is never necessary for the numbers.
- No state of the app of the person: no `revision`, `stamp`, `lesson`,
  `lesson_plan` or `hints`. No plans of the lesson (`plans`): the
  numbers of the link do not need them.
- The ZIP code stays, because the weather and the plans need it. The
  sheet of the share tells this, and it has a box that removes it.
- The bill, the prices and the real months of the meter stay: they give
  the numbers. The sheet tells that the link has the months of the meter,
  and it shows the numbers of the year.

The link also has a summary:

- the kWh of each month and of the year;
- the cost of the year, when the app knows a price;
- the language of the person who shares;
- the sky of the picture ("The sky at the house");
- the 6 items with the most kWh in a year, for the labels of the
  picture. Each item has its id, its kWh of a year, and its cost of a
  year. The numbers are of the house of today, as the numbers of the
  year: with a planned item, the page Rooms can show different numbers.
  The cost uses the price of the page Rooms. An item with less than 1 kWh
  has no label. A link of an older version has no items: its
  picture has no labels.

The LiveView of the person who shares makes the summary from the
numbers of the bill on the page House. Thus the server needs no weather
and no price to answer a link. The link shows the numbers that the
person saw. The picture and the title of the preview are in the
language of the link. The page of the link is in the language of the
person who opens it.

Any person can write a link with any summary. A link shows only its own
numbers, and the server checks that each number is in its range.

A typical house gives a link of about 1,400 characters and 8 KB of JSON
(October 2026). A link has these limits (`DIY.Share.decode/1`):

- a `DATA` of 6,000 characters at most;
- a JSON of 32 KiB at most after the inflate;
- 150 items and 50 rooms at most.

The decode counts the items and the rooms before it reads the house. It
counts the rooms again after the read, because the read gives each van
its zones. So a small link cannot become a large house. This is important, because
the one VM serves all the pages. The picture of a house with 900 items
takes about 8 times the time of a typical house. The sheet of the share
uses the same limits. A house that a link cannot carry gets a message,
and no link.

### The share

The page House has the button **Share this house**. It opens a sheet:

- The facts that the link shows: the house, the numbers of the year, and
  the ZIP code. A box removes the ZIP code from the link.
- The button **Share**. On a phone, it opens the share sheet of the
  phone (`navigator.share`). Else it copies the link
  (`navigator.clipboard`) and tells it.

### The page of a link

A link opens the page of the shared house (`DIYWeb.HomeLive`, the action
`:shared`). It shows the house from the outside, the numbers of the year
and a bar for each month. It changes nothing on the device until the
person taps **Start from this house**.

- **Start from this house** puts the shared house in the place of the
  build of the device. The import of a file does the same
  (`DIY.Build.import/2`).
  So the device saves it with the protocol of "The build on the device".
  This needs no new state, and the model `specs/Device.tla` does not
  change.
- When the device has a house, the button asks first: the house of the
  device goes away. The sheet has the link to keep a file of it.
- A link that is not a house shows the page "This link has no house",
  with a link to the first screen. Examples: a bad text, a bad version,
  a number out of its range.

### The preview of a link

The page of a link has the tags of Open Graph:

- `og:title`: the house and its year, for example "A house of 2,400 sq ft
  in 75070: 14,200 kWh a year".
- `og:description`: the cost of the year, when the link has it, and a
  line about the app.
- `og:image`: `/s/DATA/picture.png`, a PNG of 1200 × 630 pixels.

The picture has the house cut open, the numbers of the year, and the
bars of the months (`DIYWeb.Picture`). The server makes the SVG, and the
NIF resvg draws it (`DIY.Picture.NIF`, `native/resvg`,
`priv/resvg.wasm`, `scripts/nif.sh`).

The house in the picture is the house of the page Rooms
(`DIYWeb.Cutaway`), so a neighbor sees where the electricity goes, not
only the total. This is a decision of the owner (October 2026):

- The picture shows each floor of the house, one over the other, as on
  the page Rooms. Floor 1 has the rooms outside: the yard, the drive and
  a pool. The attic and the roof show only when they have an item with a
  label, for example a furnace in the attic. The picture has no lot and
  no names of rooms. The box of the house is only around its rooms and
  its items. Thus the house is as large as possible in the picture.
- The sky of the link is behind the house ("The sky at the house"). It
  has the sun or the moon, the clouds, and the rain or the snow over the
  house. The colors of the house follow the time of day, as on the page.
  In the house cut open, a window has the color of the sky. At night,
  each room has the light of a lamp.
- The 6 items with the most kWh have labels. A label has the name of the
  item, then its kWh and its cost of a year. An example is "Central AC"
  and "6,828 kWh · $908 a year". With no cost in the link, the label has
  the kWh only. The label is above its item, with a line down to the
  item.
- The labels must not overlap (`DIYWeb.Picture.Labels`). The item with
  the most kWh gets its place first. Each label goes to the nearest free
  place above its item. At each height, the label can be at the center
  of the item, at its left or at its right. A label with no free place in
  the box is not in the picture.
- `specs/Labels.tla` checks three rules: two labels never overlap, each
  label is in the box, and the first label always has a place when it
  fits. Two faults break the model. One has no check of a free place
  (`Labels.nocheck.cfg`). One does not keep a place in the box
  (`Labels.noclamp.cfg`).
- The size of a text in resvg is not known before the draw. Thus the
  width of a label comes from its letters. `scripts/inter-widths.mjs`
  reads the width of each letter of the fonts of the NIF (311 letters,
  Inter regular and bold, the larger one). It writes
  `priv/picture/inter_widths.json`. resvg moves on for each code point.
  Thus the width of a text is the sum of the widths of its code points.
- resvg draws nothing for a letter that is not in the fonts, for example
  an emoji or a Chinese letter. Thus the name of a label keeps only the
  letters of the fonts. A name with no such letter is "…". A name of more
  than 24 letters ends in "…". A different text of a label gets the
  width of W (1.038) for each letter that is not in the fonts. So a label
  is not narrower than its text.
- The box of the house clips the sky, the rain and the snow
  (`clipPath`). They do not go on the paper around the box.

The PNG and the NIF:

- A site that shows a preview reads PNG and JPEG, not SVG.
- The NIF is resvg 0.48.1 in WebAssembly, as in mkfifo.com, with the text
  of resvg. Two fonts are in the file: Inter, regular and bold
  (`native/resvg/fonts`). Each font has only the letters of English,
  Spanish and Vietnamese, so it is 85 KB. The NIF reads the fonts one
  time. It reads no file and no image. It refuses entities of a DTD and a
  picture of more than 1,048,576 pixels. A panic of resvg is a trap of
  the module: beam.com raises an error in the process of that request
  only (docs/NIFS.md of BEAM.com). The NIF of mkfifo.com has no text, so
  DIY has its own NIF. This is a decision of the owner (October 2026).
- resvg reads no CSS of the page: no variables and no `color-mix`. Thus
  the SVG of the picture has the style of each shape in its attributes.
  `scripts/picture-styles.mjs` asks Chromium for the style of each class
  of the picture in `app.css`, for each scene of the sky. It writes
  `priv/picture/styles.json`.
  The browser test checks that the file is the same as the style of
  `app.css`. A stroke that does not scale on the page
  (`vector-effect: non-scaling-stroke`) gets the width for the scale of
  the picture. For each scene, the file also has the classes that are
  different in the house cut open ("SCENE-inside"). For example, at
  night a window of the house from the outside has the light of a lamp.
  In the house cut open, it has the color of the night.
- In workerd, the request of the picture of a typical house takes about
  0.65 s: the decode, the SVG and the draw. The house cut open has more
  shapes than the house from the outside (0.25 s). A site that shows
  previews asks for the picture one time (see the cache below). The NIF
  adds about 3 MB to the Worker (October 2026).
- The answer has `Cache-Control: public, max-age=31536000, immutable`:
  the picture of a link never changes. A site that shows previews keeps
  the picture in its own cache.
- The sheet of the share makes its link when it opens, when the box of
  the ZIP code changes, and when the numbers change. A render of the page
  does not make the link again.

### The tests of a shared house

- Properties: a stripped build gives the same build and summary (with
  its items) after an encode and a decode. A stripped build has no data
  of a link. A text of random bytes gives an error and never a crash. A
  decode never inflates more than its limit, and a stream that ends early
  is an error. A link with bad items is an error.
- The picture: the SVG has no class and no `<style>`, and each class of
  the picture has a style in `priv/picture/styles.json`. Two classes of
  one shape never set a property to two values. The NIF gives a PNG of
  1200 × 630 pixels. It refuses a bad SVG, entities, a large picture and
  a text that is not UTF-8. The picture shows each floor, and the attic
  and the roof only with a label. The labels have the kWh and the cost of
  their items, in the language of the process.
- The labels (properties): two labels never overlap, and each label is
  in the box. The labels keep their order, and the first label always
  has a place. A label is above its item, or at the top of the box.
- The limits: a property gives houses with more items and rooms. Each
  house within the limits gives the same house after a decode, and each
  other house gives an error.
- The LiveView: the share sheet and its box of the ZIP code. The page of
  a link, a bad link, and the tags of Open Graph. The button Start from
  this house, with a house on the device and with no house.
- The log: a request for a link, its picture and the mount of its page
  write no line with the house.
- JavaScript: the hook of the share, with and without `navigator.share`.
- The browser walk: a share from the page House, the page of its link,
  its picture, and **Start from this house**. On the Worker, the walk
  draws the picture in workerd.
- CI builds the NIF again when a pull request changes `native/resvg`, and
  the bytes must be the same as `priv/resvg.wasm`.

## Home Assistant

Many people keep their rooms, their devices and their meters in Home
Assistant. The app links to it, so that the person does not type them
again. The parts that are done: the link (the sign-in and the socket),
the match of the rooms, and the devices as ghosts in their rooms. The
page also shows the states of the lights, the switches and the fans, and
it has a switch for each. It reads the energy data of Home Assistant: the
meter of the house, and the energy of each device.

### The sign-in stays on the device

The page links to Home Assistant directly, from the browser. The server
of the app never sees the tokens: they stay in IndexedDB, as the build
does (see "The build on the device"). This is the way of the web app of
Home Assistant Cast. A Home Assistant at home is often on a home network,
where the server of the app cannot go. The browser on that network can.

The limit: this page uses HTTPS, so the browser blocks an http address
of Home Assistant (mixed content). The person uses the HTTPS address of
Home Assistant (for example, from Home Assistant Cloud). The page tells
this before the sign-in, and the hook does not send the browser to an
http address from an HTTPS page.

A test on a real Home Assistant 2026.10 showed that it accepts this. Its
token endpoint and its revoke endpoint answer to each origin (CORS), and
its WebSocket API takes each origin.

The sign-in page of the app gets the code of Home Assistant in its
address, so the server of the app can see the code. The code is of no use
without the PKCE verifier, and the verifier stays in the tab of the
sign-in.

### The protocol

`assets/js/home_assistant.js` (the hook `HomeAssistant`) and
`DIYWeb.HomeAssistant` (the LiveView part, the assign `:ha`) do the
link. A card (`DIYWeb.HomeAssistant.card/1`) shows it, in two places:
the panel of a Home Assistant hub, and Settings. On the hub, the address
and the key Connect are on its LED screen
(`DIYWeb.HomeAssistant.screen/1`),
and the panel has the rest of the card. Settings has the whole card, with
a link to the hub, or a hint to add one.

The hub is an item of a room, as the other items are:

- It is a Home Assistant Green of 112 by 112 by 32 mm, so 4 by 4 by 1
  inches. Its datasheet gives 1.7 W at idle and 3 W under load. The hub
  is mostly idle: the app takes 2 W all the time, and the estimate counts
  it.
- At its real size, a hub is too small to see and to tap on a phone. So a
  pill over it has a light and the name "Home Assistant"
  (`DIYWeb.Cutaway.hub_label/4`). The light shows the state of the link
  (`data-ha` on the page Rooms). It is gray with no link, amber while the
  link waits, and green when it is connected.
- The pill is a part of the item for the hook Plan. A tap on it opens the
  hub, and a drag moves it with the hub. Its rank is larger than the area
  of each room, so it shows over the label of a room.
- Sometimes no hub is on the stage: for example, the person closed the
  hub during the sign-in. Then the page Rooms shows the error of the
  sign-in, or of a session that ended.
- The pill of a planned hub is pale, as the hub is.

The app links to one Home Assistant. A second hub shows the same link.

1. The person gives the address, and pushes Connect. The sign-in page of
   the app (`/ha/sign-in`, `DIYWeb.SignInLive`) opens in a new tab, with
   the address and a random id of the sign-in. A browser lets a page open
   a tab only in the tap. So the key sends the address to the hook in the
   browser, not to the server (`JS.dispatch("ha:connect")`). The hook
   checks the address, and opens the tab at once. The first tab stays on
   the hub, and its screen tells the person to sign in on the new tab.
   When the browser blocks the tab, the card tells the person to let the
   site open pop-ups.
2. The new tab (the hook `HomeAssistantSignIn`) starts only when a page of
   the app opened it (`window.opener` has the origin of the app). Else a
   link of a different site can send the tab to a server of its choice.
   Then the store gets the tokens of that server. The page tells the
   person to connect again on the page of the app. The new tab reads the
   generation of the store (see below). It makes a random state and a PKCE
   pair (RFC 7636, S256). It keeps them in its sessionStorage. Then it
   goes to the sign-in page of Home Assistant. The client is the address
   of the app, and the way back is the sign-in page of the app. Home
   Assistant accepts a way back on the host of the client, and adds its
   answer to the query. The pages of Home Assistant in the new tab get no
   link to the tab of the app: the new tab sets `window.opener` to null.
3. Home Assistant sends the new tab back with a code and the state. The
   hook removes them from the address (and `storeToken`, which Home
   Assistant adds when the person asks it to keep the sign-in). It gets
   the tokens for the code with the verifier, and writes the session in
   IndexedDB. The session has the address, the two tokens and the end of
   the access token. The hook revokes a different session in the store.
   The revoke continues after the tab closes (`keepalive`). Then the new
   tab tells its end to the first tab (`{ended: id, error}` on the
   BroadcastChannel), and closes. When the sign-in did not work, the new
   tab shows the error, and the first tab shows it too.
4. The first tab checks the new tab each second. When the new tab closed
   with no end, the first tab reads the store, because the sign-in can be
   done. With no session, it tells that the tab closed before the end.
   The person can also stop the sign-in on the first tab. The browser
   closes the new tab only when it shows a page of the app: the new tab
   has no opener. A sign-in that goes on in the new tab keeps nothing
   (the generation), and the new tab tells it.
5. The hook of each tab of the app reads the store. It opens a WebSocket
   to `/api/websocket`, signs in with the access token, and asks for the
   configuration. The page shows the name of the home and the version of
   Home Assistant.
6. An access token lasts 30 minutes. When a socket signs in, the hook
   first gets a new access token if the old one ends in 60 seconds or
   less. A socket that signed in stays open after the end of its access
   token. When Home Assistant refuses an access token, the hook gets a new
   one and tries again one time.
7. Home Assistant refuses a refresh token with `invalid_grant` when the
   session ended (for example, the person removed it in Home Assistant).
   Then the page asks for a new sign-in. Other refusals can pass (for
   example, a 403 for a user that Home Assistant allows only at home):
   the hook tries again later. A refusal ends a socket only when the
   socket uses the refused session.
8. When the socket closes, the page shows that Home Assistant does not
   answer. The hook tries again after 1, 2, 4 seconds and so on, up to 60
   seconds. When the device is online again, it tries at once.
9. A disconnect clears the store and revokes the session on Home
   Assistant (`/auth/revoke`). It also adds one to the generation in the
   store. A sign-in that started before it keeps nothing, and revokes its
   new session: the new tab tells that a disconnect stopped the sign-in.
10. A write or a clear of the store tells the other tabs with a
    BroadcastChannel. The hook of each other tab reads the store, and
    follows it: a new socket for a new session, or no socket.
11. When LiveView mounts the page again, the old hook stops: it takes no
    more news, and it opens no socket. The new tab of a sign-in stays
    open, and its session comes to the new hook. When LiveView mounts the
    sign-in page again, the sign-in does not start again.

The hook sends its state to the LiveView (`ha:status`): `none`,
`signing_in`, `connecting`, `connected`, `offline` or `signed_out`, and
an error for the last step. The sign-in page also has `done`. The
LiveView takes only the states and the errors that it knows, and texts of
a limited length.

The TLA+ model `specs/HomeAssistant.tla` checks three rules with two
tabs, three sign-ins in their own tabs, and the answers of Home Assistant
in any order. Each rule has a configuration with the fault, and TLC finds
the fault:

- **The generation** (`HomeAssistant.nogen.cfg`). A disconnect adds one
  to the generation in the store. A sign-in keeps its tokens only when
  the generation is the same as at its start. Else it revokes them. A
  sign-in is in a different tab, so the epoch of one tab cannot stop it.
  Without the generation, a disconnect while a sign-in finishes gives the
  store the session of a sign-in that started before the disconnect.
- **The compare and set** (`HomeAssistant.nocas.cfg`). A refresh writes
  its access token only when the store still has its refresh token.
  Without it, a refresh in flight puts back a session that a disconnect
  of a different tab revoked.
- **The owner** (`HomeAssistant.noowner.cfg`). A refused refresh ends
  only the socket of its own session. Without this check, a late refusal
  of an old session closes the socket of the new session of a different
  sign-in.

The tests:

- `test/js/home_assistant.test.js`: the hook of the page and the hook of
  the sign-in page, with a fake WebSocket, a fake fetch, fake tabs and
  fake-indexeddb. A property test (fast-check) checks the generation and
  the compare and set. It has two tabs of the app, the tabs of their
  sign-ins, and the answers in any order. The test counts the disconnects
  itself: it does not read the generation of the store. It has the
  shortest steps to each fault as fixed examples, so it finds each fault
  in each run. A test with fixed steps checks the owner. A property test
  checks that the sign-in page stays on the app, and gives back the
  address and the id. A sign-in page that no tab of the app opened does
  not leave the app.
- `test/diy_web/home_assistant_test.exs` and
  `test/diy_web/live/sign_in_live_test.exs`: the LiveView part, the card
  in Settings and on the panel of a hub, and the sign-in page. A property
  test checks that the sign-in page shows only the states and the errors
  that it knows.
- The browser test adds a hub, and signs in from its screen on a fake
  Home Assistant (`test/browser/fake_ha.mjs`). The sign-in opens in a new
  tab. While the new tab waits for the person, the screen of the hub
  tells it. The fake checks the code, the way back and the PKCE verifier
  as Home Assistant does. It adds its answer to the query of the way
  back. The new tab closes, and the first tab stays on the hub. The test
  checks the green light of the pill. Then it disconnects, and checks the
  revoke. It also opens the sign-in page with a bad address.
- A test by hand used Home Assistant 2026.10 with its demo. It signed in
  on the page of Home Assistant, loaded the page again, opened a second
  tab, and disconnected. Home Assistant then had no session of the app.

### The match of the rooms

Home Assistant has floors and areas. A floor has a level: 0 is the
ground floor. An area is a room, on a floor or on none. The app and Home
Assistant can have the same rooms, so the person does not make them two
times. The card links to a sheet: "Match the rooms with Home Assistant"
(`/inside?sheet=ha_rooms`, `DIYWeb.HomeAssistant.rooms_sheet/1`).

1. When the sheet opens, the LiveView sends `ha:rooms_fetch`. The hook
   reads the floors, the areas and the user of Home Assistant on its
   socket (`config/floor_registry/list`, `config/area_registry/list` and
   `auth/current_user`). It sends them to the LiveView (`ha:rooms`). The
   sheet reads them again when the link comes back.
2. `DIY.HomeAssistant.match/2` makes three lists: the rooms in both, the
   rooms only in the app, and the areas only in Home Assistant. A room
   with a link to an area is in both. The build keeps the links (`areas`:
   the id of the area for each room). Then the name matches. Home
   Assistant compares names with a case fold and no spaces, and so does
   the app.
   The roof and the zones of a van have no area.
3. For an area only in Home Assistant, the sheet suggests a place: the
   floor of the area, else a word of its name. For example, a patio is
   outside the house, a garage is around the house, and an attic is under
   the roof. The person can change the place, or skip the area.
4. "Match the rooms" (`ha_sync`) links the rooms in both. It adds the
   areas that the person chose as rooms, each with its link: 50 at most
   for each match. The rooms only in the app that the person chose go to
   the hook (`ha:add_areas`), with the level and the name of their floors.
5. The hook adds each floor that Home Assistant does not have (by level),
   and then each area, on its floor. A room around the house or in the
   attic has no floor. The hook sends the ids of the new areas
   (`ha:areas_added`). The LiveView links the rooms, and reads the areas
   again.

An area has one room at most (`DIY.Build.link_area/3`). Home Assistant
refuses a second area with one name. So the sheet does not offer a room
when Home Assistant has an area with its name. It also does not offer the
second of two rooms with one name (`DIY.HomeAssistant.blocked/2`). The
sheet tells the person to give the room a different name.

Only an admin of Home Assistant can add floors and areas. For a user that
is not an admin, the sheet tells this, and adds no rooms to Home
Assistant. The rooms of Home Assistant still come into the app.

Home Assistant refuses a second floor or area with the same name
(`invalid_info`, "already in use"). This occurs when two tabs do the
match at the same time, or when a person adds the area in Home Assistant
first. Then the hook reads the list again, and uses the area of that
name. It uses a floor of that name only when the floor has the same
level. Else, the room is not added. The sheet tells that Home Assistant
has a floor of that name at a different level.

The TLA+ model `specs/RoomSync.tla` checks these rules with two tabs,
twin rooms (two rooms with one name), and a person in Home Assistant.
Each fault has a configuration, and TLC finds it:

- **A new name** (`RoomSync.suffix.cfg`). The hook adds the area with a
  new name ("Den 2"). Then Home Assistant has two areas for one room.
- **The old list** (`RoomSync.snapshot.cfg`). The hook looks for the area
  in the list from the start of the sheet. The area of the other tab is
  not in it, so the room gets no area.
- **No rules for the names** (`RoomSync.twins.cfg`). The sheet offers the
  twin of a room with an area, and the LiveView links the twin. Then two
  rooms have one area.
- **Only the check of the links** (`RoomSync.nooffer.cfg`). The sheet
  offers each room, and the LiveView refuses a second room for an area.
  An area still has one room (`RoomSync.nooffer-rooms.cfg`), but the twin
  gets no area.

The LiveView takes at most 100 floors and 500 areas. With more, the sheet
tells that Home Assistant has too many. A floor or an area with a bad
value, or a text of more than 255 bytes, does not count. An area on a
floor with a longer id has no floor. When Home
Assistant refuses a command (for example, a version with no floors), the
sheet tells that the match needs Home Assistant 2024.4 or later.

Sometimes a link goes to an area that is not there now. For example, the
person removed the area in Home Assistant. Then the link does not count:
the room is only in the app again. When a room goes away, its link goes
too. A new house has no links. When a stored build has two rooms for one
area, the first room keeps the link.

The tests:

- `test/diy/home_assistant_test.exs`: the match, the blocked rooms and the
  places. A property test checks that each room and each area is in one
  list. Also, no room only in the app has the name of an area only in
  Home Assistant. The rooms that the sheet offers have names that are not
  in use.
- `test/js/home_assistant.test.js`: the commands on the socket, the
  errors, and a property test with two tabs and the answers in any order.
  Each room gets an area of its name, on the floor of its level.
- `test/diy_web/home_assistant_test.exs`: the sheet, the choices, the
  answers of the hook, and the payloads that the LiveView refuses.
- The browser test opens the sheet from the panel of the hub. A fake Home
  Assistant has a floor and three areas: the living room matches, and
  two areas come in as rooms. Home Assistant adds the other rooms, with
  a new floor for floor 2.

### The devices as ghosts

The devices of Home Assistant come into the house as ghosts: pale models
in their rooms. A tap on a ghost puts its item in the house. The
prototype "Hub in Hand" showed this way: things in the house, not cards.

1. When the link becomes connected, the LiveView sends
   `ha:devices_fetch`. The hook reads the devices, their entities and the
   areas of Home Assistant (`config/device_registry/list`,
   `config/entity_registry/list` and `config/area_registry/list`). It
   sends a short list to the LiveView (`ha:devices`, `deviceList` in
   `assets/js/home_assistant.js`):
   - A device of a service (for example, the sun or a backup) does not
     count, and a device that the person disabled neither.
   - The main entities of a device give its domains: `light`, `fan`,
     `switch` and so on. The entities of its configuration or of its
     diagnostics do not count, and the hidden or disabled ones neither. A
     device with no main entity does not count.
   - The area of a device is its own area, else the area of its first main
     entity with an area. A device in no area does not count: it can be
     no ghost, and no match of the rooms can help it.
   - A device with no name has the name of its model.
   - A power station has its maker (see "The power stations of Pecron and
     EcoFlow").
2. After the first read, the hook watches the three registries
   (`subscribe_events` for `device_registry_updated`,
   `entity_registry_updated` and `area_registry_updated`). After a
   change, it waits 1 second (`REGISTRY_WAIT`) and reads the devices
   again: one read for many changes. When the socket closes, the watch
   stops. When Home Assistant refuses the watch, the next read tries
   again.
3. The LiveView takes 1000 devices and 500 areas at most, with texts of 255
   bytes at most (`DIYWeb.HomeAssistant.read_devices/1`). It reads the
   kind of each device one time. It takes an answer only while the link
   is connected. After a disconnect, it forgets the devices.
4. `DIY.HomeAssistant.kind_of/1` gives the kind of the catalog for a
   device, or none. The words of its name come first, then the words of
   its model: "Kitchen fridge" is a fridge. Of two words, the last in the
   name wins: "TV room lights" are lights. When two words end at one
   place, the longer one wins. For example, a water heater is not a
   space heater, and a microwave oven is not a range. A word can have an
   "s" at its end, and two words can be one word ("HeatPump"). With no
   word, the domains give the kind: a light, a fan or a water heater. A
   thermostat, a speaker or a plug can be many things: with no word, it
   gets no kind. The search starts at the last word and looks one time
   at each word, so a long name costs little.
5. `DIY.HomeAssistant.ghosts/4` gives the ghosts, and the count of all
   of them. A ghost is a device with a kind and with no item, in the area
   of a room. The match of the rooms gives the room of an area: the
   links, then the names. The kind must go in the room: a central AC is
   not a ghost in a living room. A device with no name has the name of
   its kind. A large Home Assistant can have hundreds of devices: the
   plan shows 8 ghosts in a room and 60 in the house at most. The next
   ones come when the person adds them.
6. Each ghost gets a free place in its room. It is the place that is the
   farthest from the other items and from the ghosts before it
   (`DIY.HomeAssistant.spread/3`). So the ghosts and their names do not
   cover each other. The places are on a grid of about 30 steps on each
   side, with steps of 12 inches at least. An item that hangs on a wall
   (a mini split) goes on the back wall. A ceiling fan is on the ceiling:
   it can be anywhere. A ghost keeps its place while that place is free.
   So when the person adds one ghost, the other ghosts do not move.
7. The LiveView keeps the ghosts. It finds them again only when the
   rooms, the items, the areas, the links or the devices change. The
   plan with 60 ghosts takes about 100 ms more for each change of the
   build, as a plan with 60 more items does.

On the plan (`DIYWeb.Cutaway.ghost_view/5`), a ghost is the model of its
kind, pale and blue, with a dashed edge and no shadow. The edge has a
contrast of 3:1 at least on each floor: #0b3375 in the light mode and
#bbdefb in the dark mode. A pill over it has the name of the device. The
pill shows over the name of a room, and under the pill of a hub. With
motion, a ghost comes in, and its opacity goes down and up one time. A
tap on a ghost or on its pill adds the item (`ha_add_device`). The item
goes to the place of its ghost. A drag on a ghost moves the view, as a
drag on the floor does. On a hidden layer, the pills of the ghosts and
of the hubs take no tap, as the rest of the layer.

The list of the rooms has a key for each ghost, for a keyboard and a
screen reader: "Add Kitchen Lights from Home Assistant (Lights)". Over
the plan, a status (`#ha-ghosts`) tells how many devices are not in the
house yet. It tells that a keyboard can use the list of the rooms. When
the plan does not show all the ghosts, it tells how many it shows. It
also tells how many devices are in an area with no room, with a link to
the match of the rooms. The status is on the page before its text, so a
screen reader reads each new text. When the page cannot read the
devices, the status tells it:

- "Home Assistant has more than 1,000 devices in its areas: too many
  for the ghosts."
- "The app cannot read the devices of Home Assistant now." (no socket,
  or Home Assistant refused a command)

The item of a device (`DIY.Build.add_device/6`):

- It has the numbers of one device: one bulb, one fan
  (`DIY.Build.device_params/1`). The lights of a preset are the bulbs of
  a whole house. A power station has the model of its device (see "The
  power stations of Pecron and EcoFlow").
- It goes to the place of its ghost (`at`). A place out of the limits of
  the layout is no place: the item goes to a free place.
- The build keeps the link of the item to the device (`devices`: the id
  of the device for each item). A device has one item at most. When the
  item goes away, its link goes too. A new house has no links. In a
  stored build, only an item in a room of the house keeps a link, and the
  first item of a device keeps it.
- Its panel has the part Home Assistant. It tells the device: "This is
  Kitchen Lights in Home Assistant". When Home Assistant does not have
  the device now, the part tells it. The house can have a different item
  of the same kind with no link, for example the TV of the preset. Then
  the part tells that it can be the same thing. This is not for the
  lights and the fans: a house has many of them. A hub has its own part
  for Home Assistant: it does not get this part too.

Two tabs can show the same ghost. The build on the device has a compare
and set (see "The build on the device", and `specs/Device.tla`). A save
from an old build gets a conflict, and the tab takes the stored build.
So two tabs cannot add two items for one device, and the TLA+ models do
not change.

The tests:

- `test/diy/home_assistant_devices_test.exs`: the kinds of the names,
  the ghosts, their places, the limits of 8 and 60, and the devices away.
  A property test checks that each kind is a kind of the catalog. A
  property test checks each ghost: it is a device with no item, in a room
  of its area. Its kind can go there. Each device with a kind is a
  ghost, an item, away, or in a room where its kind cannot go. A
  property test checks that a place of `spread/3` is in its room and on
  no box, when the room has a free place.
- `test/diy/build_devices_test.exs`: the item of a device, its place,
  the errors, and the links in the text of a build. A property test
  checks that each device has one item of the house at most.
- `test/diy_web/live/ghost_live_test.exs`: the ghosts on the plan and in
  the list, the status, the tap, and the place of the new item. It also
  checks the panel of the item and of a hub, and the answers that the
  page cannot read.
- `test/js/home_assistant.test.js`: the list of the devices, with a
  property test, the watch of the registries, and the commands.
  `test/js/plan.test.js`: a tap on a ghost, and a drag on it.
- The browser test: a fake Home Assistant has two devices in the living
  room and a fan on the patio. After the match, the walk adds the lights
  with the keyboard, and the TV with a tap on the plan. It checks the
  color and the dashes of the edge of a ghost, and that a pill on a
  hidden layer takes no tap. Axe checks the page with the ghosts, and
  the panel of the new item.

### The states of the lights, the switches and the fans

The item of a device of Home Assistant shows the state of the device: on,
off, or not known. The person can turn a light, a switch or a fan on and
off from the panel of its item.

1. Each read of the devices also gives the entities that the app turns on
   and off (`controlList` in `assets/js/home_assistant.js`). These are
   the main entities of a device of the list, of the domains `light`,
   `switch` and `fan`. A media player or a climate entity does not count:
   its service is not on and off only. One switch turns all these
   entities of a device on or off: for example, the light and the fan of
   a ceiling fan. This is a decision of the owner (October 2026): one
   switch for each device.
2. The hook watches the states of these entities (`subscribe_entities`
   with their ids). Home Assistant sends all their states first (`a`),
   then each change (`c`) and each entity that goes (`r`). A change of
   the attributes only has no state: the hook sends nothing for it. A
   watch with no entity gets the states of all the entities. So with no
   entity, the hook starts no watch.
3. The state of a device (`deviceStates`) is `on` when one of its
   entities is on. It is `off` when one is off and none is on. Else it is
   `unavailable`: Home Assistant cannot reach it, or has no state of it.
4. After a change, the hook waits 150 ms (`STATE_WAIT`). Then it sends
   the state of each device to the LiveView (`ha:states`): one message
   for many changes.
5. A new read with the same entities keeps the watch, and sends the
   states again at once: a new LiveView has none. Before the first states
   of the watch, it sends nothing. The order of the registry does not
   count. When the entities change, the hook ends the old watch
   (`unsubscribe_events`), clears its states, and starts a new watch. A
   late event of the old watch changes nothing. When Home Assistant
   refuses a watch, the next read tries again.
6. When the socket closes, the hook clears the states, and stops the wait
   of step 4. The ids of the commands start again on each socket, so the
   hook takes only the messages of its open socket.

The LiveView (`DIYWeb.HomeAssistant`):

- It takes the states only while the link is connected. It takes 1000
  devices at most, with ids of 255 bytes at most, and only the states
  `on`, `off` and `unavailable`. Else the payload changes nothing. When
  the link is not connected, it forgets the states and the controls.
- On the plan and on its stage, the item of a device has its state
  (`data-ha`). The shade and the bulb of a lamp glow when the device is
  on, and they are gray when the device is off. When Home Assistant
  cannot reach the device, they are pale and gray. A screen is light when
  its device is on. The list of the rooms tells the state in words:
  "Lights, on now".
- The panel of the item has the switch Power: a button with the role
  `switch` and `aria-checked`, in the part Home Assistant. The word Power
  is its label: a tap on the word is a tap on the switch. A status under
  it tells the state in words, for example "It is on." or "Home Assistant
  cannot reach it now."
- A tap on the switch (`ha_switch`) sends the control to the hook
  (`ha:control`). It does this only when the state is on or off, and no
  control of the device waits. The hook asks Home Assistant to turn on or
  off each entity of the device (`call_service`, `turn_on` or `turn_off`,
  one call for each domain). It tells the end (`ha:control_done`), with
  no error, or with `offline` or `failed`. With no end after 10 seconds
  (`CONTROL_WAIT`), it tells `timeout`, and the status tells that Home
  Assistant does not answer now. Home Assistant can still do the control
  later: then the watch tells the new state, and the error goes.
- While a control waits, the status tells it ("Home Assistant turns it
  off."), and the track and the knob of the switch are pale. The switch
  is `aria-disabled`, not `disabled`, so it keeps the focus of the
  keyboard, and its focus ring keeps its contrast. When Home Assistant
  refuses, the status tells it: "Home Assistant did not do it. Try
  again." A new state of the device ends this error.
- The new state comes with the watch of the states, not with the end of
  the control. Home Assistant sends the change before the end. The hook
  then sends the states at once, before the end (`flushStates`). So the
  switch never shows the old state after the end. It shows what Home
  Assistant has, not what the person asked for.
- When the link closes while the panel is open, the switch stays, so that
  it keeps the focus. It has no state. The status tells that the app has
  no link to Home Assistant now. After a disconnect, the page forgets the
  devices, and the switch goes.

The TLA+ model `specs/HomeAssistantStates.tla` checks the watch with two
devices, in any order of the steps. A person changes a state or the
registry, the socket closes, and the page sends a control. The late
messages of an old socket can come after the messages of the new socket.
When all is quiet, the page shows the states of Home Assistant, no
control waits, and Home Assistant has one watch for the hook. With no
link, the page shows no state. Each rule has a configuration with the
fault, and TLC finds the fault:

- **The socket** (`HomeAssistantStates.noepoch.cfg`). The hook takes the
  messages of its open socket only. Without this rule, the late first
  states of an old socket replace a new state.
- **The watch** (`HomeAssistantStates.noid.cfg`). The hook takes the
  events of its watch only. Without this rule, the first states of the
  old watch can come after the start of the new watch. Then a state that
  Home Assistant removes stays.
- **The old states** (`HomeAssistantStates.noclear.cfg`). A new watch and
  a closed socket clear the states of the hook. Without this rule, a
  state that Home Assistant removed while the socket was closed stays.
- **The end** (`HomeAssistantStates.nounsub.cfg`). A new watch ends the
  old watch. Without this rule, Home Assistant keeps two watches.
- **The LiveView** (`HomeAssistantStates.nolvclear.cfg`). The LiveView
  forgets the states when the link is not connected. Without this rule,
  the page shows the states of a link that is gone.

The model does not have the order of the end and the states, a refused
watch, or a LiveView that mounts again. The tests of the hook check them.

The tests:

- `test/js/home_assistant.test.js`: the entities that the app turns on
  and off, and the state of a device, with a property test. The watch:
  the first states, the changes, and a change of the attributes only. It
  also checks an entity that goes, the same entities in a different
  order, and new entities. Then a refused watch, two reads at the same
  time, and a socket that closes. The control: the states before the
  end, one call for each domain, a refusal, no answer, and a socket that
  closes. A property test does many steps, with the answers of each step
  in any order. The steps are changes of a person, states that go,
  controls, changes of the registry, and a socket that closes and opens
  again. When all is quiet, the last states are the states of Home
  Assistant, and Home Assistant has one watch at most. While the socket
  is closed, the hook sends no states.
- `test/diy_web/live/ha_control_live_test.exs`: the states on the plan,
  on the stage, in the list and in the panel, and the switch with the end
  of a control. It also checks a refusal, an error that a new state ends,
  a device with no switch, and a link that closes. A property test checks
  that the page takes only the states that it knows.
- The browser test: the fake Home Assistant has the states and the
  services. The lights come in from their ghost. They are on, and the
  switch turns them off. A person turns them on in Home Assistant, and
  the page follows. The keyboard turns them off again, and the switch
  keeps the focus. Axe checks the panel with the switch.

### The power stations of Pecron and EcoFlow

The person can see a power station of Pecron or EcoFlow in the app, also
away from home, and turn its outlets on and off. This is a decision of
the owner (October 2026): when an integration of Home Assistant gives the
station, the app uses it. Not every person has Home Assistant. Then the
app links to the cloud of the maker through a relay on its server (see
"The direct link to a maker"). Here, the app reads the station through Home
Assistant, with no link of its own to the cloud of a maker:

- A page of the app cannot call the cloud of Pecron
  (`https://app.pecron.com/api/ha/`): its answers have no CORS headers.
  A sign-in of Pecron also needs a client that Pecron registers.
- Home Assistant has the tokens of the makers already. So the app never
  sees a token of a maker, as it never sees the tokens of Home Assistant.
- Some integrations get the station with no cloud: by Bluetooth or by the
  LAN.

The integrations that the app knows (`STATION_SOURCES` in
`assets/js/home_assistant.js`). Each one gives a unique id of its own form
to each entity:

- The integration of Pecron (the platform `pecron`), from the portal of
  Pecron (`app.pecron.com`), through the cloud of Pecron:
  `entry:device:code`. The codes are `battery_percentage`,
  `total_input_power`, `total_output_power`, `ac_switch_hm` and
  `dc_switch_hm`. `docs/E3800LFP.md` of pecron-monitor calls this switch
  "DC Output", and it lists the USB and 12 V outlets as DC outputs. No
  source tells if the switch also turns off the USB outlets. The entities
  stay available
  when the station is not online, with their last values (the property
  `available` in `entity.py`). The binary sensor `entry:device:online`
  (`binary_sensor.py`) tells the link of the station. A device with "WB"
  in its model is not a station, as for pecron-monitor (below).
- pecron-monitor (`attractify-logan/pecron-monitor`), through MQTT (the
  platform `mqtt`). It reads the station by Bluetooth or by the LAN, with
  no cloud, else by the cloud: `pecron_key_name`. The names are
  `battery`, `total_input`, `total_output`, `ac` and `dc`. It sends its
  states as retained messages (`ha_state.py`), with no availability and
  no `expire_after`. So when the monitor or the station stops, Home
  Assistant keeps the last states, and nothing tells the link. It also
  gives a WB12200, a battery with no inverter. The app uses its rule:
  a device with "WB" in its name is a WB12200 (`ha_discovery.py`), and it
  is not a station. The model of a device is the product name from the
  cloud of Pecron (`resolve_devices` in `cloud_api.py`). With no cloud, it
  is the name of the device in `config.yaml` (`_build_devices_from_config`
  in `monitor_cloud.py`). Then the app can find no model of its catalog,
  and the station is another station. The rule "WB" also reads that name.
- EcoFlow Cloud (`tolwi/hassio-ecoflow-cloud`, the platform
  `ecoflow_cloud`): `ecoflow-sn-key`, with `-` for `.` and `_` in the
  key. Each family of stations has its keys. For example the battery of a
  DELTA Pro is `ems.lcdShowSoc`, and of a DELTA Pro 3 `cms_batt_soc`. The
  battery is the battery of all the packs, not of the main pack. The DC
  switch is the 12 V outlets only ("DC (12V) Enabled", or
  `flowInfo12v` of a DELTA 3 Max Plus). The USB outlets have a different
  switch. The entities keep their last values when the station is
  offline. The sensor `status` tells the link: `online`, or `offline`.
  It is `offline` when EcoFlow tells it, or after 15 minutes with no data:
  three times the option `assume_offline_sec` (`devices/status_tracker.py`).
  This option is 300 seconds by default (`DEFAULT_ASSUME_OFFLINE_SEC` in
  `__init__.py`). A DELTA Pro Ultra or a DELTA 3 Max
  Plus of the public API has the sensor `status.scheduled` in its place
  (`QuotaScheduledStatusSensorEntity` in `sensor.py`).
- EcoFlow BLE (`rabits/ha-ef-ble`, the platform `ef_ble`), by Bluetooth:
  `ef_sn_key`. The keys are `battery_level`, `input_power`,
  `output_power`, `ac_ports`, `ac_ports_2`, `ac_lv_port`, `ac_hv_port` and
  `dc_12v_port`. With no Bluetooth link, each entity is unavailable
  (`entity.py`). So its battery also tells the link.

EcoFlow has no integration of its own for Home Assistant. Its
integrations also give fridges, air conditioners, plugs and panels. So a
device of an integration is not always a station. A Wave (an air
conditioner) and a Glacier (a fridge) are not stations, also when they
have a battery.

The limits of the keys of EcoFlow:

- The app has no switch for the USB outlets. It also has no switch for
  the 24 V outlet of a DELTA Pro 3. The DC ports of a DELTA Pro Ultra by
  Bluetooth have no switch too. The DC part is the 12 V outlets only, so
  that one label tells one thing.
- A RIVER mini of EcoFlow Cloud has its battery in `inv.soc` only. It is
  not a station in the app.
- The public API of EcoFlow has no switch for the AC outlets of a DELTA
  Pro Ultra. It has a switch "DC Mode"
  (`hs_yj751_pd_appshow_addr.showFlag.6`, `devices/public/delta_pro_ultra.py`),
  but no source tells which outlets it turns off. So it is not a part in
  the app.

#### The integration for Pecron

The owner asked the app to select the most robust way to talk to a
station of Pecron (October 2026). The integration of Pecron is the first
way of the app. pecron-monitor is the second way, with no cloud.
The app does not use the integration of the community
(`jsight/ha-pecron`). The reasons:

- The integration of Pecron uses the API that Pecron made for Home
  Assistant (`/api/ha/`). The server of Pecron gives the full state of
  each device in one answer. It also gives the entities of each model, so
  a new model needs no change of the integration.
- Its token is a token of Home Assistant only, not the password of the
  account. The person can revoke it on the portal of Pecron. When Pecron
  refuses the token, Home Assistant asks for a new one.
- pecron-monitor reads the station by Bluetooth or by the LAN. For many
  models this works with no cloud. Its notes tell the limits for the
  models of the catalog. On the LAN, an E3800LFP gives only its settings
  and its battery: no power. An F5000LFP gives nothing, and a write of a
  control does not change the station, with no error. For these models,
  pecron-monitor uses the cloud of the app of Pecron. That cloud
  is not an API for other apps. Some accounts have a limit of about 1,280
  reads in a day (`docs/known-pecron-api-quirks.md`), and the data comes
  in parts.
- pecron-monitor keeps the password of the account of Pecron, and it needs
  a computer that runs all the time, and an MQTT broker.
- The integration of the community uses the same cloud of the app of
  Pecron, also with the password of the account. It has no way with no
  cloud. It reads the cloud each 600 seconds by default (`const.py`). Its
  domain is also `pecron`, so Home Assistant cannot have it and the
  integration of Pecron at the same time.

The integration of Pecron has its limits too:

- It needs the internet. When Home Assistant cannot reach the cloud of
  Pecron, its entities are unavailable, and the app has no numbers. When
  only the station is not online (a low battery, or no Wi-Fi), the
  entities keep their last values. Then the binary sensor `online` is
  off, and the panel tells that the numbers are the last numbers.
- It reads the cloud each 30 seconds (`SCAN_INTERVAL` in `const.py`). But
  the station sends its numbers to the cloud at its own rate. An E3800LFP
  sends them about each 3 minutes, and about each 30 seconds only with
  the setting `high_frequency_reporting` (`docs/E3800LFP.md` of
  pecron-monitor). An E3600LFP sends one packet of each type about each
  20 minutes (`docs/known-pecron-api-quirks.md`). The integration does not
  set `high_frequency_reporting`. The portal of Pecron asks for it only
  while its page is open (`POST /api/devices/high-frequency`).
- It imports the package `async_timeout`, and its manifest has no
  requirements. Home Assistant 2026.10.2 on Python 3.14 does not require
  this package. The Docker image of Home Assistant (Home Assistant OS and
  Home Assistant Container) installs the requirements of all the
  integrations (`requirements_all.txt`). This file does not name
  `async-timeout`, but packages in it require it (for example `adax` and
  `adb-shell`). So the image has `async-timeout` 4.0.3, and the
  integration loads there. A Home Assistant Core in a
  Python environment of its own does not have the package. There, the
  integration does not load until the person installs `async-timeout`.
  A check of its imports against Home Assistant 2026.10.2 found all the
  other names.
- It is new (version 0.1.0, October 2026).
- With an extra battery, the battery of an E3800LFP can be the battery of
  the main pack only (the notes of pecron-monitor).

The steps:

1. The list of the stations (`stationList`) finds the parts of each
   device (`STATION_PARTS`). These are its battery (%), its power in and
   out (W), the switches of its AC and DC outlets, and its link. A part is
   the entities with a domain of the part (`sensor`, `switch`, or
   `binary_sensor` for the link) and the unique id of the part. They are
   of the platform of the integration. A disabled entity does not count.
2. A device is a station of the first integration that gives it a battery
   and a power out. All its parts come from this integration. A model
   that is not a station (`others`) does not count: a Wave, a Glacier or
   a WB12200.
3. A part can have more entities. For example a DELTA Pro 3 has AC outlets
   of 120 V and of 240 V: one switch turns on or off the two. This is the
   rule of the lights: one switch for each device, and here one switch
   for each part.
4. The list of the devices (`deviceList`) gives the maker of each station
   (`station`: `pecron` or `ecoflow`). It also gives the switches that
   the station has (`switches`: `ac` and `dc`). Its kind is
   `power_station`, whatever its name (`DIY.HomeAssistant.station?/1`).
5. The model of the device gives the model of the catalog
   (`DIY.HomeAssistant.station_model/2`), among the models of its maker.
   The match has no case, no spaces and no signs. The name of the maker
   can come first. For example "E3800LFP" and "PECRON E3800LFP" are the
   E3800LFP, and "DELTA_PRO_3" and "Delta Pro 3" are the DELTA Pro 3.
   The ghost has the model (`DIY.HomeAssistant.device_values/2`). Its
   item then gets the numbers and the size of the model. A model that the
   catalog does not have gives another station. The DELTA Pro Ultra X is
   not the DELTA Pro Ultra.
6. A station has no switch of the whole device: the list of the controls
   (`controlList`) does not have it. The watch of the states has the
   entities of the parts too. The hook sends the parts of each station
   (`ha:stations`, `stationStates`) after the states, with the same wait.
   A sensor gives the first number of its entities, or `null`. The watch
   also gives the unit of each entity (`unit_of_measurement`). A power in
   kW becomes W. A number with a different unit is `null`, and a number
   with no unit is in W or %. A number out of its range is `null`: a
   battery is from 0 to 100 %, and a power from 0 to 1,000,000 W
   (`MAX_POWER`). A switch gives `on`, `off` or `unavailable`, as a light.
   The link is `true` (`on`, `online`, or a number), `false` (`off`,
   `offline`, `assume_offline` or `unavailable`), else `null`. A part that
   the station does not have is `null`. With no station, the hook sends
   the stations only one time, to clear them.
7. A switch of a part sends a control of that part only (`ha:control`
   with `part`: `ac` or `dc`). The hook turns on or off the entities of
   the part. Its end (`ha:control_done`) has the part.

The LiveView (`DIYWeb.HomeAssistant`):

- It takes the stations only while the link is connected: 1000 stations
  at most, else the payload changes nothing. It reads each station and
  each part separately. A station with an id of more than 255 bytes does
  not count. A part that it cannot read is `nil`, and the other parts and
  stations stay. A battery is from 0 to 100 %, and a power from 0 to
  1,000,000 W. A switch has the state `on`, `off` or `unavailable`, or
  none. The link is `true`, `false` or `nil`. When the link is not
  connected, it forgets the stations, as it forgets the states.
- It takes only the makers that it knows (`DIY.HomeAssistant.makers/0`).
- A control of a part has the key `{device, part}` in `:ha_control`. The
  end of a control of the whole device, or of the other part, does not
  end it. A new state of the part ends the error of its last control.
- The part Home Assistant of the panel (`DIYWeb.HomeAssistant.station/2`)
  shows the battery level, the power in and the power out. A number that
  Home Assistant does not give is "Not known". The numbers change each 5
  seconds to 20 minutes: each integration and each station has its own
  rate. EcoFlow Cloud gives new data to Home Assistant each 5 seconds by
  default (`DEFAULT_REFRESH_PERIOD_SEC` in `__init__.py`, and
  `update_interval` in `devices/data_coordinator.py`). The station sends
  its data to EcoFlow BLE. EcoFlow BLE gives it
  to Home Assistant at most each 10 seconds by default
  (`DEFAULT_UPDATE_PERIOD` in `const.py`). `devicebase.py` uses it as the
  shortest time between two updates. EcoFlow Cloud gets the data
  through MQTT when the station sends it. For Pecron, see "The
  integration for Pecron". So the numbers are not a live region.
- The numbers and the texts of the station are in one element
  (`#ha-station-info`) that stays while the item is a station. A text
  that comes or goes above the switches moves the switches in the page,
  and then a switch loses the focus (WCAG 2.4.3).
- The panel tells the link of the station (`link_text/1`). With no link,
  it tells that the numbers are the last numbers. When Home Assistant does
  not tell the link (pecron-monitor), it tells that a number can be old.
- The panel has two switches, "AC outlets" and "DC outlets", as the
  switch Power of a light. For EcoFlow, the second switch is "12 V
  outlets". Each switch has its status. A part that the station does not
  have has no switch. The panel shows its name, and its status tells that
  the app has no switch for it. The device of the station tells its
  switches (`switches`). The page keeps the devices while the link is not
  connected, so a part that the station does not have gets no switch
  then too. Thus no switch comes and goes when the link closes and comes
  back. With no link of the station, the switches do not work, and their
  status tells the last state.
- The item of a station has no switch Power, also when its device is not
  a station now. For example, the person disables the battery of the
  station in Home Assistant. Then the device has switches for its outlets
  and its modes, and one switch Power would turn all of them on or off
  together (`DIYWeb.HomeAssistant.power/2`). The plan also shows no state
  of that device for the item (`item_states/1`): the device is "on" when
  one of its modes is on. The panel tells that Home Assistant does not
  give the battery and the power out of the station now.

The TLA+ model `specs/HomeAssistantStates.tla` has one entity for each
device. A part of a station is a device of the model, as a light is. A
light with more entities is one device of the model, and a part with more
entities is too. Each part has its own state and its own control. It is
in the same watch as the lights, with the same rules: the socket, the
watch, the old states and the end. The LiveView forgets the stations when
the link is not connected, as the model asks for the states. So the
model checks the parts too. The link of a station is a part, as the
other parts. Three rules of the stations are not in the model, and the
tests check them. With no station, the hook sends the stations only one
time, to clear them. This step is safe, because the page gets its
stations only from the hook. Also, the page clears them when the link is
not connected. With no link of a station, a switch sends no control. A
part that the station does not have (`switches`) has no switch, so it
sends no control too. These two rules only remove steps, so the
invariants stay true. The new rules are in the tests:

- `test/js/home_assistant.test.js`: the stations of the four
  integrations, and the entities of their parts. The entities of the
  integration of the community give no station. The list of the devices
  has the switches of each station. Also a disabled entity, a
  key that is not a part, and a part in the wrong domain. Also an entity
  of a different platform, a Wave, a Glacier, a WB12200, and a battery
  with no power out. A table of unique ids gives the part of each key of
  each integration, and of keys that are not parts. A device with the
  parts of two integrations is a station of the first one. Property
  tests check that each station comes from the first integration that
  gives it a battery and a power out. They also check that each part is
  an entity of its integration, and that each state is a state of the
  page. A state is the first number, in its unit and its range, or the
  link. The hook
  watches the parts, sends their states and units, and turns off
  the AC outlets of a station of Pecron with one call. It turns off the
  two AC outlets of a DELTA Pro 3 together. It refuses a part that the
  station does not have, and a part that is not a switch. A new station
  with the same controls starts a new watch.
- `test/diy/home_assistant_devices_test.exs`: the kind, the models of
  Pecron and EcoFlow with a property test of their forms, the ghost and
  its item.
- `test/diy_web/live/ha_station_live_test.exs`: the numbers and the
  switches in the panel, a DELTA Pro 3, the controls and their end, and
  the errors. Also a link that closes, a station with no link, and a
  station that does not tell its link. Also two stations where one has a
  number that the page cannot read. Also a station with no DC switch,
  before its numbers and while the link is not connected. Also the item
  of a station with a device that is not a station now. A property test
  sends parts of each form.
- The browser test: a station of Pecron comes in from its ghost,
  with the model of its device. It shows its numbers, and the keyboard
  turns its AC outlets off. The station goes offline and back, and the
  switch keeps the focus. Then Home Assistant restarts with no DC switch.
  The link to Home Assistant closes and comes back while the AC switch
  has the focus. The AC switch keeps the focus, and the DC outlets get no
  switch. Axe checks the panel.

### The direct link to a maker

A person with no Home Assistant also sees a power station of Pecron from
anywhere, and turns its outlets on and off. The app calls the cloud of
Pecron with the API that Pecron made for Home Assistant (`DIY.Pecron`):
the same calls as the integration of Pecron. A person with EcoFlow uses
the API of EcoFlow for developers ("The direct link to EcoFlow", below).

The token:

- The person makes a long-lived token on the portal of Pecron
  (`app.pecron.com`). It starts with `phk_`, and the person can stop it
  there at any time.
- The card Pecron in Settings (`DIYWeb.MakerLink.card/1`) has the field
  of the token. The key Connect sends the DOM event `maker:connect` to
  the hook (`JS.dispatch/1`): the token never goes to the LiveView. The
  field goes empty. After Connect and Disconnect, the status of the card
  takes the focus: the form or the key goes. The key Disconnect comes
  just after the status. An error or a form that comes goes below it, so
  the key keeps the focus.
- The hook keeps the token on the device (IndexedDB, the database
  `diy-makers`). A different tab gets the news (BroadcastChannel
  `diy.makers`).

The relay (`DIYWeb.RelayController`, `/relay/pecron/…`):

- A page of the app cannot call the cloud of Pecron: its answers have no
  CORS headers. So the hook calls the relay of the app, and the relay
  calls the cloud.
- The token comes in each request (`authorization: Bearer phk_…`): only
  a token of the portal of Pecron. The relay keeps no token and writes no
  token to a log. This is a decision of the owner (October 2026): the
  server sees the token for each call.
- It takes a request of a page of the app only (`sec-fetch-site:
  same-origin`). A page of a different site cannot use it.
- It sends only two requests to the cloud: the list of the stations, and
  a control of the AC or DC outlets of one station. It follows no
  redirect, so the token goes to no other path. It gives back only the
  parts that the app reads, with no cache (`cache-control: no-store`).
- Each call to the cloud has one deadline of 15 seconds, and 10 seconds
  for each part of the answer. A body that is not JSON is `failed`.
- Its answers: the stations, or an error. `token`: Pecron refuses the
  token. `unreachable`: Pecron does not answer. `failed`: a different
  answer. `origin` (403): the request is not of a page of the app.
  `request` (400): the request is not one that the relay knows.
- An id of a device has letters, digits, `-` and `_`, or the form
  `productKey:deviceKey` that the portal of Pecron knows
  (`matchesDeviceId`).

The hook (`assets/js/maker_link.js`) reads the stations at the start, and
then each 30 seconds while the page shows. A hidden page reads them again
when it shows. Pecron can refuse a control (a 401 or a 403). An example
is the option "Allow HA to send control commands" off on the portal. No
source tells the answer of Pecron in that case. Then only the control
has the error (`denied`). The token can still read, so the poll
after the control goes on. Only a poll that Pecron refuses stops the link
(`refused`). A link that stops (a page that goes) does nothing more. A
new token, a disconnect and a page that goes stop the calls that wait
(the signal of their wait). The TLA+ model `specs/MakerLink.tla` checks
six rules:

- **The generation** (`MakerLink.nogen.cfg`). A new token or a disconnect
  starts a new generation. An answer of an old generation changes
  nothing. Without this rule, a late answer of the old account shows on
  the page.
- **One poll at a time** (`MakerLink.overlap.cfg`). A timer while a poll
  waits does nothing: the next timer polls. Without this rule, the answer
  of an older poll can come last, and the page shows the old state.
- **A poll after a control** (`MakerLink.nopoll.cfg` and
  `MakerLink.noagain.cfg`). The end of a control starts a poll. While a
  poll waits, it marks a poll "again" for the end of that poll. Without
  this rule, the page keeps the state from before the control.
- **The timeout** (`MakerLink.notimeout.cfg`). The network can lose a
  request or an answer, also the body of an answer. The wait for an
  answer ends after 20 seconds (`ANSWER_WAIT`): the signal of the wait
  also stops the body. A poll then ends with no new state. A control ends
  with an error, and its request can still change the station later.
  Without this rule, the hook waits for ever, and it polls no more (the
  property `Live`).
- **The end after the poll** (`MakerLink.earlyend.cfg`). The end of a
  control with no error goes to the page after the answer of the poll
  after it. Until then, the switch waits. An end with an error goes at
  once. When that poll fails, the end goes too, with no error. The
  status of the link has the error, and the page tells that it has no
  link. Without this rule, the switch
  shows the state from before the control as its new state, until the
  next poll (the invariant `EndNew`). The link to Home Assistant has the
  same rule: its hook sends the states before the end of a control.
- **The wait for the station** (`MakerLink.nosettle.cfg`), for EcoFlow
  only ("The direct link to EcoFlow", below).

When all is quiet, and a poll read the cloud after the last change of a
person, the page shows the state of the cloud. After a disconnect, it
shows no station. A poll and a control always end (`Live`, with the
fairness of the network and of the timers). For the hook, a command that
the cloud gets after the end of its control is as a change of a person.
This is a command after a timeout, or a command of an old generation when
the person connects the same account again. The next poll shows its
change. The model has two accounts, two changes of a person, three new
tokens or disconnects, three timers, one control and one lost message.
TLC finds no error in 784,045 distinct states. With a station that
applies a command after its answer (`MakerLink.lag.cfg`), TLC finds no
error in 1,040,463 distinct states.

Five rules of the hook are not in the model. They only remove steps, or
they end a step that the model has:

- A poll that the maker refuses (`refused`) stops the polls, until a new
  token comes.
- A page that cannot sign a request to EcoFlow (`crypto`) stops the
  polls too.
- A hidden page does not poll. It polls when it shows again.
- An answer with an error ends a poll or a control as a timeout does.
- The model has one value and one control at a time. A control of the AC
  outlets and a control of the DC outlets can wait at the same time. They
  change different values, and each end starts a poll or marks a poll
  "again", as in the model. So for each value, the steps are the steps of
  the model. TLC with two controls, one after the other
  (`MaxControls = 2`), also finds no error (9,213,679 distinct states).

The station:

- The build keeps the link of a power station to its unit (`units`:
  `"pecron:id"`, `DIY.Build.link_unit/3`). A unit has one station at
  most. A link that the app cannot read goes away when the build loads.
- The panel of a power station with no link has the part Pecron: the
  stations of the account that no item has. A tap links one. A station of
  a known model gets the model (`DIY.HomeAssistant.station_model/2`),
  when the person did not choose one.
- An item of a device of Home Assistant gets no choice and no link: the
  app uses Home Assistant for it. The build refuses such a link, also in
  a stored build. The link of an item to its device does not end. So
  when the person stops Home Assistant, or the device goes, the item
  gets no direct link. The person then removes the item and adds a new
  station.
- A choice has the name of the station, which the person gave in the app
  of Pecron. A long name wraps, so a choice fits at 320 px. After the
  link, the part tells this name, and it wraps there too. An empty name
  is no name: the choice then tells the maker and the model.
- The part shows the battery level, the power in and the power out, and
  the switches of the AC and DC outlets. These are the same parts as for
  a station of Home Assistant, with the same component. The field
  `online` of the device tells if Pecron can reach the station. When it
  cannot, the part tells it and shows its last numbers, and the switches
  do not work. The part tells this only while the link is connected. It
  tells that these are its last numbers only when it has a known number.
  When the account does not have the station now, the part tells it too.
- The part tells the state of the link. While the link connects, it tells
  that the app connects. With no link, it asks the person to connect in
  Settings. When the app cannot reach Pecron, it tells that these are the
  last numbers, if the station has a known number. With the link not
  connected, the switches do not work.
  The notes of the link are in one element that stays. A note that comes
  or goes above the switches makes a switch lose the focus. The parts of
  the station, and the rows of its switches, are in elements that stay
  too. So the key "Remove the link" keeps the focus when the switches
  come. After a link, or after its end, the title of the part takes the
  focus: the key with the focus goes away. The page moves the focus at
  once (the event `diy:focus` of `assets/js/app.js`). `JS.focus/1` moves
  it again after two frames, and a page that is not in front gets the
  frames late. Then the title takes the focus from the next key. After
  the end of a link with no choices (for example with no link), the part
  goes with its title. Then the LiveView gives the focus to the title of
  the panel after its patch (the event `phx:diy:focus`).
- The page keeps the switches of each station of the last list, also
  when a new token makes the stations `nil`. So a part that the station
  does not have gets no switch while the page waits for a new list, and
  the other switch stays. Before the first list, the station has no
  switches: the page does not know them, and they come with the list. A
  switch that comes does not move the focus, and no key below it moves.
- A control that waits stays while a poll fails: the hook ends it with
  its error. Only a new token or a disconnect ends it.
- The relay and the page read each number on its own. A battery is from
  0 to 100 %, and a power from 0 to 1,000,000 W. Else the number is not
  known, and the other numbers and stations stay.
- A station in a van links too.

The limits:

- The app shows the station only while a page of the app is open. It
  keeps no history: a history needs a server that reads the cloud when
  the page is closed, and keeps the numbers of the person.
- Each tab of the app polls. Two tabs make two polls each 30 seconds. The
  limit of `/api/ha` for an account is not known. On the older cloud of
  the app of Pecron, pecron-monitor tells of about 1,280 polls in a day.
- After a control, the page shows the poll after it. A station can apply
  a write later (pecron-monitor tells it for an F5000LFP), so the switch
  can show the old state until a later poll.
- A poll can remove a switch that has the focus: a switch with no value,
  or a list without the station. Then the focus goes to the page. This is
  rare, and the app does not move the focus then.
- When a poll fails, the part with its choices goes, also when its title
  or a choice has the focus. Then the focus goes to the page. The choices
  come back with the next list.
- After the LiveView connects again (for example after a short loss of
  the network), the page has no control that waits. Until the next poll,
  a switch can show the state from before its control.
- The relay has no limit of requests for each address. A script can use
  the relay to call `/api/ha` with its own token. It gets no data that it
  cannot get from Pecron directly. But Pecron sees the address of the
  server of the app, not of the script. If Pecron limits or blocks that
  address, the direct link stops for all persons. Each call also holds
  the server for up to 15 seconds.
- A switch that Pecron gives with no value, or with a value that the app
  cannot read, is "no switch" for that list. The official integration
  makes its switches from the entities of the device. A real answer of
  `/api/ha/devices` can show if the relay must read them too.
- A browser with no Fetch Metadata (`sec-fetch-site`, Safari before 16.4)
  cannot use the direct link.
- The relay reads all the body of an answer of Pecron before it reads
  the devices (100 at most).
- No real answer of `/api/ha/devices` is in the sources of the app. The
  codes of the parts are the codes of the TSL of Pecron. The official
  integration takes the keys of its entities from the server, with no
  list of codes. The portal gives each entity the key of its TSL code
  (`tslToHaEntities`). `unofficial-pecron-api` 0.4.1 (`models.py`) names
  the codes of the numbers and of the switches (`ac_switch_hm` and
  `dc_switch_hm`), and so does pecron-monitor (`protocol.py`).
  `jsight/ha-pecron` names the codes of the numbers (`const.py`). A
  number or a switch as text (`"82"`, `"true"`) is not known.

The tests:

- `test/diy/pecron_test.exs` and
  `test/diy_web/controllers/relay_controller_test.exs`: the calls of the
  cloud, the parts, the errors, and each request that the relay refuses.
  Property tests check the parts of any answer of the cloud.
- `test/js/maker_link.test.js`: the token, the polls, the generation, the
  controls, the errors, the store and the hook. Also a body that never
  ends, a control that Pecron refuses for the token, and a stopped link.
  A property test does many steps in any order: new tokens, disconnects,
  timers, controls and changes of a person. As in the model, the cloud
  serves a call, and its answer comes later. The page shows only the
  station of the account of the token. When all is quiet and a poll read
  the cloud after the last change of a person, the page shows the cloud.
  The end of a control with no error comes after stations that the cloud
  read after its command (`EndNew`).
- `test/diy/build_units_test.exs` and
  `test/diy_web/live/maker_link_live_test.exs`: the links, the card, the
  part of the panel, the switches, and the payloads that the page
  refuses. Also a station with no DC switch, through a new token, an
  error and a disconnect, and before the first list.
- The browser test connects Pecron with a token, links a station, and
  turns its AC outlets with the keyboard. Then the relay does not answer:
  the switch does not work and keeps the focus. Axe checks the card and
  the panel. On the Worker, the walk has no stub of the cloud of Pecron,
  so it does not connect Pecron (`DIY_STUBS`).

#### The direct link to EcoFlow

The page calls the API of EcoFlow for developers directly
(`assets/js/ecoflow.js`). Its answers have CORS headers for each site:
OPTIONS and GET on `api-a.ecoflow.com` and `api-e.ecoflow.com` give
`access-control-allow-origin` with the origin of the request. They also
allow the headers that the request asks for (a probe of October 2026).
So the app needs no relay, and the keys never go to the server of the
app.

The keys:

- The person asks for access as a developer on the developer site of
  EcoFlow, then makes an access key and a secret key. The official docs
  of the API need such an account.
- The region of the account selects the host: `api-a.ecoflow.com` for
  the Americas, and `api-e.ecoflow.com` for Europe. For the API for
  developers, EcoFlow Cloud gives only these two hosts
  (`config_flow.py`). Its text of the error 8513 names them for these
  regions (`translations/en.json`). A key of a different region is not
  valid. No source names a host for a different region (for example
  Asia). So the card tells the person to try the other region when
  EcoFlow does not accept the keys. The client ecoflow-api-mqtt also
  names `api.ecoflow.com` for the United States (`const.py`). It has the
  same CORS headers (a probe), but no source tells which accounts of
  developers it serves. So the app does not offer it.
- The card EcoFlow in Settings has the region and the two keys. The key
  Connect sends them to the hook, not to the LiveView. The hook keeps them
  on the device (IndexedDB), as the token of Pecron. The fields of the
  keys go empty.
- The status of the link tells the LiveView the region of the last keys
  (not a key). So after a refused answer, the form comes again with that
  region. A patch of the page does not change the choice of the person
  (`phx-update="ignore"`).
- A value of the store that is not a token is no token, and it goes
  from the store. An example is a region of a different version of the
  app. So a tab of an older version deletes keys of a region that only a
  newer version knows. A region that is not in `HOSTS` sends no request.
  So the keys go to no other host.

The calls (the clients of the community:
`tolwi/hassio-ecoflow-cloud` (EcoFlow Cloud) for the public API,
`TarasKhust/ecoflow-api-mqtt`, and the npm packages
`@ecoflow-api/rest-client` 0.6.0 and `@ecoflow-api/schemas` 0.7.0):

- Each request has a signature (`signText`, `hmac`). The parameters
  become one level: a key in a key is `a.b`, and an item of a list is
  `a[0]`. The keys are sorted and joined as `key=value` with `&`. Then
  come the access key, a nonce and the time in ms. The sign is
  HMAC-SHA256 of this text with the secret key, in hex (WebCrypto). A
  boolean signs as `true` or `false`. The three clients agree on this
  form, with one difference. The npm client puts `sn` in the query of
  `quota/all`, but it signs no parameters. EcoFlow Cloud
  (`public_api.py`) and ecoflow-api-mqtt sign `sn` too, and the app does
  the same. The nonce is 6 random digits, as ecoflow-api-mqtt sends.
  EcoFlow Cloud sends 5 to 7 digits, and the npm client sends a UUID.
- A poll reads the list of the devices (`/iot-open/sign/device/list`),
  then the state of each station of a known family
  (`/iot-open/sign/device/quota/all`). The calls of the states go at the
  same time, so one wait of 20 seconds covers a poll of many stations.
  The families are the DELTA Pro, the DELTA Pro 3 and the DELTA Pro
  Ultra, by the product name of the device. A different device (for
  example a Wave) does not count. Nor does a device with a serial number
  that the page cannot read (as `DIY.Pecron.id?/1`). The app reads 100
  devices at most.
- The parts of each family:
  - DELTA Pro (the files of the public devices of EcoFlow Cloud): the
    battery is `ems.lcdShowSoc`. The power in is `pd.wattsInSum`, and the
    power out `pd.wattsOutSum`. The AC outlets are `inv.cfgAcEnabled`,
    and the 12 V outlets `mppt.carState` (1 is on).
  - DELTA Pro 3 (`@ecoflow-api/schemas` and ecoflow-api-mqtt): the
    battery is `cmsBattSoc`. The power in is `powInSumW`, and the power
    out `powOutSumW`. The AC outlets are `flowInfoAcHvOut` (240 V) and
    `flowInfoAcLvOut` (120 V), and the 12 V outlets `flowInfo12v` (2 is
    on). EcoFlow Cloud reads `cfgHvAcOutOpen`, `cfgLvAcOutOpen` and
    `cfgDc12vOutOpen` (1 is on) instead.
  - DELTA Pro Ultra: the battery, the power in and the power out of
    `hs_yj751_pd_appshow_addr`. The app has no switch for it. EcoFlow
    Cloud has a command for its DC outlets, and ecoflow-api-mqtt has
    commands for its AC and DC outlets. The schemas have none, and the
    sources do not agree, so the app does not send them yet.
- A control (`/iot-open/sign/device/quota`, PUT). A DELTA Pro gets
  `{sn, params: {cmdSet: 32, id: 66, enabled: 1}}` for the AC outlets.
  The 12 V outlets use the id 81. EcoFlow Cloud and ecoflow-api-mqtt send
  these commands. The schemas also send `xboost` with the id 66;
  the app follows the two clients. A DELTA Pro 3 gets `{sn, cmdId: 17,
  dirDest: 1, dirSrc: 1, cmdFunc: 254, dest: 2, needAck: true, params:
  {cfgHvAcOutOpen: true}}` (the schemas and ecoflow-api-mqtt). Its AC
  outlets need two commands: 240 V (`cfgHvAcOutOpen`) and 120 V
  (`cfgLvAcOutOpen`). Its 12 V outlets use `cfgDc12vOutOpen`.
- The errors: EcoFlow refuses the keys with two codes. The code 8513
  tells that the access key is not valid, also for a key of a different
  region. The code 8521 tells that the signature is wrong, for a wrong
  secret key or a wrong time. The app shows them as `token`. The code
  8524 ("invalid parameter") comes with no keys, and also for a command
  that EcoFlow does not accept. The app always sends the keys, so it is
  `failed`, as a different code (for example 1006, a device that the API
  does not allow). No answer is `unreachable`. A page with no WebCrypto
  (an address with no https) cannot sign a request (`crypto`). Then the
  polls stop, because a new try cannot work.

The hook has the same rules as for Pecron. These are the generation, one
poll at a time, a poll after a control, the timeout, and the end after
the poll. The model `specs/MakerLink.tla` reads the station in one step.
A poll of EcoFlow reads each station in a call of its own. So each
station is as the station of the model, and the rules stay true for each
station.

A station of EcoFlow can apply a command after its answer:
ecoflow-api-mqtt waits 3 seconds after a command before it reads the
state again (`switch.py`). It also tells that a station that sleeps can
give an old state through the REST API (`hybrid_coordinator.py`). So the
hook has one more rule, **the wait for the station**. The end of a
control with no error waits 3 seconds (`APPLY_WAIT`). Then it goes with
the next poll. Until then, the switch waits. The model has a station
that applies a command in a later step (`Lag`, the step `Apply`). It
takes that the station applies the command in the wait (the step
`Settle` comes after `Apply`). Without this rule
(`MakerLink.nosettle.cfg`), the page shows the state from before the
control as its new state (`EndNew`). With `Lag`, the model has one
command at a time: the cloud answers no new command while the station
must still apply one.

EcoFlow can fail to give the state of a station (an error of that call).
Then the station keeps its parts of the last poll, and it is not online.
The part tells that EcoFlow cannot reach the station, and shows these
last numbers. A switch of the last list stays, and it does not work.
With no last list, the station has no numbers and no switches. The part
tells that EcoFlow cannot reach the station, with no "last numbers". It
shows no switch, and it does not tell "no switch".

The limits:

- The AC outlets of a DELTA Pro 3 need two commands. When the second one
  fails, the outlets of 240 V and of 120 V can be different. The control
  then has its error, and the next poll shows the state.
- The two AC commands are for a DELTA Pro 3 of the Americas (240 V and
  120 V). No source tells of a DELTA Pro 3 of Europe. There, the command
  of 120 V can fail.
- A station that is slower than the wait shows its change with a later
  poll. Until then, the switch shows the state from before the control
  as its state (up to 30 seconds), and a screen reader reads it.
- One poll has one wait of 20 seconds. The call of the state of one
  station can get no answer. Then the poll ends with a timeout, and the
  page tells that it cannot reach EcoFlow. This is so also for the other
  stations of the account.
- The time of the device signs each request. A time of about 60 seconds
  or more before the time of EcoFlow gives 8521 (a probe with random
  keys). Then the card tells the person to look at the region, the keys
  and the clock of the device.
- The fields of the keys are password fields. A password manager of the
  browser can offer to keep them (`autocomplete="off"` does not stop
  it). Then they are also in that manager, and it can sync them.
- The app has no Content-Security-Policy. A `connect-src` cannot list
  the hosts of the links: the address of Home Assistant can be any
  address.
- The app has no switch for the USB outlets, as through Home Assistant.

The tests:

- `test/js/ecoflow.test.js`: the signature against `node:crypto`, and the
  flat parameters and their order (property tests). Also the family of a
  product name, and the parts of each family (a property test). Also the
  stations, the host of each region, the commands and the errors. Also a
  region that is not in `HOSTS` (no request), and the calls of the states
  at the same time. Also a station with no state (its last parts).
- `test/js/maker_link.test.js`: the keys, a poll and a control from the
  page, and the wait for the station (also with a poll in the wait). Also
  refused keys, the timeout, and the form of EcoFlow. Also a stored value
  that is not a token, and the stop of the calls that wait. Also the
  region in the status, and a page with no WebCrypto.
- `test/diy_web/live/maker_link_live_test.exs`: the card of EcoFlow, the
  region after a refused answer, the link of a DELTA Pro 3 with its
  model, and its switches. Also a station that EcoFlow cannot reach, with
  and with no last numbers.

### The energy data

The energy settings of Home Assistant name the sensor of the meter of the
house, and the sensor of each device that measures its energy. The
statistics of Home Assistant give their kWh. The app reads them in the
browser, so the data stays on the device, as with the file of a meter.

1. When the link becomes connected, the LiveView sends `ha:energy_fetch`.
   The hook reads the energy settings (`energy/get_prefs`) and the
   entities. With no energy settings, Home Assistant answers `not_found`:
   then the app has no meter and no device.
2. `energySources` takes the sensors of each grid: from the grid and to
   the grid. The new form of the settings has one sensor for each way.
   The old form has lists (`flow_from` and `flow_to`). The app reads both
   forms. It also takes the sensor of each device (`device_consumption`),
   200 at most. A sensor that is a part of a different sensor of its
   device (`included_in_stat`) does not count: the device has its kWh
   already.
3. The hook reads the statistics (`recorder/statistics_during_period`,
   the type `change`, in kWh). It reads the meter for each day of the
   last 24 months. It reads the devices for each month of the last 13
   months, and one month more (see 5). With no sensor, the hook sends no
   command for the statistics.
4. `meterMonths` makes the months of the meter in the time zone of Home
   Assistant (from `get_config`). Each month has the kWh from the grid,
   the kWh to the grid, and the days with data. These are the numbers of
   the file of a meter (`DIY.Usage`, with the source `home_assistant`).
   The change of a row is the kWh since the row before. After a stop of
   Home Assistant, a row can come after a gap of days: the hook divides
   its change between these days. (Home Assistant fills only the last 10
   days of a stop.) A day can have a change under zero (a small dip of
   the sensor). The month adds its days. A month under zero counts as
   zero. Home Assistant finds a new meter itself. West of UTC, the
   statistics start one day earlier, in the month before: the hook keeps
   the last 24 months.
5. `deviceEnergy` makes the kWh of each month of each device. The
   registry of the entities gives the device of each sensor. A sensor of
   no device (for example, a statistic of an integration) does not count.
   The rows of Home Assistant have no count of days. So the first month
   of a sensor does not count: a new sensor has only a part of it. The
   month of now counts, as a part of a month. A month after it does not
   count.
6. The hook sends `ha:energy`: `{meter, devices, month}`, or `{error:
   "offline"}` or `{error: "failed"}`. The month is the month of now, in
   the time zone of Home Assistant.

The LiveView (`DIYWeb.HomeAssistant.read_energy/1`):

- It takes the energy data only while the link is connected. The meter
  must be a usage that `DIY.Usage.read/1` accepts, with the source
  `home_assistant`: else the page has no meter, and the devices stay. It
  takes 200 devices at most, each with 13 months at most, with a month
  "YYYY-MM" and the kWh. A device that it cannot read does not count. Two
  sensors of one device give the sum of their kWh. After a disconnect, it
  forgets the energy data.
- A build that uses the meter of Home Assistant gets its new months each
  time. The data can come before the build of the device, for example
  after a reconnect: then the build gets them when it comes. A build of a
  different tab does not get them: two tabs with different data must not
  change the build again and again. A different Home Assistant also
  gives its meter to a build that uses the meter of Home Assistant.
- A different build keeps its usage: a file, or no usage. The panel of
  the smart meter offers the meter of Home Assistant. The front of the
  house offers it to a build with no usage, when the house has a smart
  meter or a room for one. The key is "Use Home Assistant"
  (`ha_use_meter`). A house with no smart meter gets one: outside, else
  inside. When the person removes the real usage, the months of Home
  Assistant do not come back by themselves.
- The panel of the item of a device tells the energy that Home Assistant
  measured. It uses the last 12 months that are over, and it gives the
  estimate of the same months. The month that is not over does not count,
  because a part of a month is not the estimate of a month. When Home
  Assistant has only the month that is not over, the panel tells its kWh
  so far. Then it gives no estimate. A kind that uses no power (for
  example, a power station) gets no estimate. An example of the text: "Home
  Assistant measured 120 kWh in 3 months, from November 2025 to January
  2026. The estimate for the same months: 131 kWh."

The TLA+ models do not change. The energy data is one question and its
answer, under the rules of the socket. An answer after a disconnect does
not count. Two tabs can put the same meter in the build: the build on the
device has a compare and set (`specs/Device.tla`).

The tests:

- `test/js/home_assistant.test.js` checks the sensors of both forms of
  the settings, and a sensor that is a part of a different sensor. It
  checks the months in a time zone, also at the end of a month, and the
  months of the meter and of each device. It checks a dip of a sensor, a
  month under zero, and a stop of Home Assistant. It checks the first
  month of a sensor, and 24 months at most. It also checks the commands. A property
  test compares the months of the meter with a model of the rules.
- `test/diy_web/live/ha_energy_live_test.exs`: the energy data that the
  page reads, with a property test against a model of the rules. It
  checks the offer of the meter, the new months, a file that stays, and a
  usage that the person removes. It checks the data that comes before the
  build, and the month of now in the time zone of Home Assistant. It also
  checks the energy of a device in its panel, a house with no room
  outside, and a house with no room.
- The browser test: the fake Home Assistant has the energy settings and
  the statistics. The panel of the lights tells their energy. The front
  of the house offers the meter of Home Assistant, and the page Bill
  shows its months.

## The wires

The owner decided this: the person connects the wires. The app warns
about a connection that is not correct. It uses the rules of the NEC
(NFPA 70, the edition of 2023) and the facts of the products. The app
does not do the work. It does not replace an electrician or the
inspector of a city. It tells the rules, so that the person can ask the
right questions.

### A wire

A wire is the pair of conductors of one circuit between two items (the
positive and the negative, or the hot and the neutral). The build keeps
the wires (`DIY.Build`, `wires`).

- The kinds that take wires have the feature `:wires`. They are a power
  station, a battery bank, an inverter, a busbar, an alternator charger,
  a transfer switch and a shore power inlet. Solar panels do not take
  wires yet. The rules of solar circuits are different (NEC 690.8).
- A wire goes from the item that gives the current (`from`) to a
  different item (`to`). A new wire joins two items of one place: the
  house, or one van. A wire stays when a station goes to a van and back.
  While the station is in the other place, the wire waits: the panels
  do not show it, and a busbar does not count it. It shows again when
  the station comes back.
- Its numbers (`DIY.Wire`) are the system, the most current of the
  port, the length one way, and two ways. The system is 12, 24 or 48 V
  DC, or 120 or 240 V AC. A wire has two ways when the far end also
  gives current: a battery, or a busbar with a battery on it.
- A new wire gets typical numbers: 30 A and 6 ft. Its system is the
  system of a battery at an end. At a busbar, it is 12 V DC. At a
  transfer switch or a shore power inlet, it is 120 V AC. Else it is
  12 V DC.
  On DC, a wire to a battery or to a busbar has two ways.
- When a battery is at an end, the system of the wire is the voltage of
  the battery. A battery joined to a battery of a higher voltage (through
  a busbar or a wire) is a fault.
  Then each wire of the battery gets the higher voltage, and the card
  tells why. A change of the battery changes its wires
  (`DIY.Build.change/2`), and the card shows the system as a text. So
  a check never uses an old voltage.
- A busbar is on DC. A wire at a busbar gets the voltage of the
  batteries on the busbar (`DIY.Wire.end_system/4`). An example is the
  wire from the busbar to the inverter of a van of 48 V. A battery is on
  a busbar when a wire joins them. A wire between two busbars, between a
  battery and a busbar, or between two batteries joins their terminals
  in one node. The busbars of a node have the voltages of all its
  batteries (`DIY.Build.bus_voltages/1`).
  With no battery on the busbar, the card gives only the DC systems.
- The batteries on one busbar must have one voltage. When they do not,
  the panel of the busbar shows a fault. The wires then get the highest
  voltage, because the DC ratings must be for it. This is also true for
  each wire of a battery with a lower voltage: its + is on the busbar.
- When the ends of a wire change places and the new far end is a battery
  or a busbar, the wire has two ways.
- What the person has: the wire size, and the breaker or the fuse at
  each end with its DC rating. Each one is empty until the person gives
  it.
- A build has 100 wires at most. The person can add a wire only when
  each end has less than 24 wires, the most positions of a busbar. This
  limit keeps the panel small. A stored build is not checked for the limit of
  an item. A wire goes away with an item at its end. A wire that the app
  cannot read goes away when the build loads: a wire must not stop the
  build from loading. The first 100 good wires stay.

### The busbar

The new kind "DC busbar or distributor" (`dc_bus`) is a busbar with
fuse holders, for example a Victron Lynx Distributor. It has two
numbers. The first is its positions for wires (its studs or its fuse
holders), from 1 to 24: the Lynx has 4. The second is the smallest fuse
that its holders take. The Lynx takes MEGA fuses. For 48 V, the
smallest MEGA fuse of Victron is 40 A, rated 80 V (the part
CIP138040020, in the listings of retailers). The manual of the Lynx
Distributor gives its size and its weight: 290 by 170 by 80 mm, and
2.2 kg. A busbar uses no power: the estimate does not count it.

The model of a busbar has the look of the Lynx Distributor. It shows a
gray light for each position, and a hood for the cables of each two
positions (`DIYWeb.Icon.Shapes.look/1`). The positions share the width
of the case, so each number of positions has the same size on the plan. The
panel tells how many positions have a wire. When more wires connect to
the busbar than it has positions, the panel shows a fault.

### The rules

`DIY.Wire.advise/2` gives what the rules ask for. `check/1` gives the
faults of what the person has.

- The current of the port is a load all the time (a continuous load).
  So the wire and the breaker are at least 125% of it. The rules are
  NEC 210.19(A) and 210.20(A) for a branch circuit, and NEC 215.2(A)(1)
  and 215.3 for a feeder. The number is the same. The page tells the
  current with the margin, and that it is for a load all the time.
- The ampacity of copper wire comes from the 75 °C column of NEC Table
  310.16. The terminals at the two ends must be rated 75 °C (NEC
  110.14(C)). The page tells this.
- A breaker or a fuse protects the wire: its rating is not more than the
  ampacity of the wire (NEC 240.4). When the ampacity is not a standard
  rating, the next standard rating is permitted (NEC 240.4(B)). Wire of
  14, 12 and 10 AWG takes 15, 20 and 30 A at most (NEC 240.4(D)). The
  standard ratings come from NEC Table 240.6(A).
- A breaker or a fuse is at the end where the wire gets its current
  (NEC 240.21). A wire with two ways has one at each end: it is
  protected from all the sources (NEC 705.30(A)). A busbar at an end
  takes no fuse less than its smallest fuse. So the wire must carry that
  fuse.
- On DC, a breaker or a fuse is rated for DC, at the highest voltage of
  the battery or more (NEC 706.31(C) and 110.3(B)). The app uses
  LiFePO4: a cell charges to 3.65 V at most (for example, the data
  sheet of the EVE LF280K cell). This is 14.6 V for 12 V (4 cells),
  29.2 V for 24 V (8 cells), and 58.4 V for 48 V (16 cells). The page
  tells this. The manual of the Lynx Distributor says that MEGA fuses
  of 58 V are for 48 V systems. A full battery of 16 cells can have
  58.4 V, so the app asks for more, on the safe side.
- The voltage drop is 3% or less. This is the advice of an
  informational note of NEC 210.19(A), not a rule. The app uses the DC
  resistance of stranded copper of NEC Chapter 9, Table 8. The current
  goes out and comes back: the copper is two times the length.

The advice is the smallest wire that meets all the rules, and the
smallest standard breaker at each end. A wire of 4/0 AWG or less is not
always enough: then the page tells the person to ask an electrician.

The example of the owner: the cascade port of a Pecron E3600LFP gives
30 A at 48 V to a Lynx Distributor. The 30 A is the number of the
owner. The page of the MJ32 cable of Pecron gives 44 to 58 V DC. It
gives 1200 W at most for each XT60 plug: 27.3 A at 44 V. So 30 A is on
the safe side. The breaker at the station is 125% of 30 A at least:
37.5 A, so 40 A. The Lynx takes no fuse less than 40 A, so its fuse is
40 A too. The wire must carry 40 A: 8 AWG (50 A, with a drop of 0.6%
on 6 ft). The breakers are for DC, at 58.4 V or more. A breaker that
is rated 48 V DC is not enough. When the Lynx has a fuse of 60 A, the
person sets its smallest fuse to 60 A. Then the wire must carry 60 A:
6 AWG (65 A, and a fuse of 70 A at most by NEC 240.4(B)).

The app does not check these yet:

- the rules of solar circuits (NEC 690);
- the correction for more than three conductors together, or for a hot
  place (NEC 310.15);
- the interrupting rating of a fuse next to a large battery (NEC 110.9);
- wire of aluminum, and the 60 °C column for terminals that are not
  rated 75 °C;
- a lead acid battery, which has a different highest voltage. The card
  tells this when a battery at an end is lead acid;
- the rule for the wire from an energy storage system. NEC 706.30(B) of
  the edition of 2020 asks that this wire carries the full rating of
  its fuse, with no next standard rating. The app could not get the
  text of 2023, so the owner must check it;
- the wires on the plan.

### The panel

The panel of each item that takes wires has the part Wires
(`DIYWeb.Wires`). It lists the wires of the item. Each wire is a card:

1. Its title: the names of the two ends. Two wires between the same
   two items get a number ("wire 2").
2. Its numbers: the end that gives the current (a choice of the two
   ends), the system, the current of the port and the length. On DC, a
   switch tells that the far end also gives current. The two ends stay
   in one order (the order of their ids). When the ends change places,
   only the choice that is on changes. LiveView does not change the
   value of the field that has the focus, so a change of the values
   breaks the choice.
3. What the rules ask for: the current with the margin, the wire, and
   the breaker or the fuse at each end. The breaker has a range: from
   the smallest rating to the largest that the wire takes. On DC, the
   page tells the DC rating and why. A load all the time is a load of 3
   hours or more (NEC Article 100).
4. What the person has: the wire size, and the breaker or the fuse at
   each end with its DC rating. The breakers and the DC ratings are
   whole numbers: their fields take only whole numbers, and their error
   tells it.
5. The faults, each with its rule of the NEC, in a status: a screen
   reader reads a change. A fault has the color of a danger and a bar
   at its start, so the color is not the only sign. With no fault, the
   card tells that what the person has meets the rules.
6. A button removes the wire, after a question, as for an item. The
   focus then goes to the title of the part, and a status tells that
   the wire is removed.

Under the cards, the person adds a wire from the item to a different
item of the same place. A status tells that the wire is added, with its
number when two wires join the same items. The same status a second
time is empty for a short time first, so a screen reader reads it
again. When the build, the item or each other item has its most wires,
a text tells which one in place of the form. A number that is not
valid shows its error at its field, and the wire does not change. The
text of the positions of a busbar is a status too, and so is the fault
of batteries of different voltages on a busbar.

The TLA+ models do not change. A check is a function of the numbers of
one wire, with no steps in time. The property tests check it for all
the numbers.

### The tests of the wires

- `test/diy/wire_test.exs` checks all the numbers of the tables of the
  NEC, and the numbers at the limits of the rules. It checks the example
  of the owner, a wire on AC and the voltage drop. It also checks the numbers
  from a form or from JSON. Property tests check that the advice meets
  the rules, and that it is the smallest wire that does. More current
  never gives a smaller wire or a smaller breaker. A model of the rules,
  with its own tables, gives the same faults as `check/1` for any
  numbers.
- `test/diy/build_wires_test.exs` checks a wire between two items, its
  numbers, and its ends that change places. It checks a wire that goes
  away with its item, the wires of a van, and the system of a battery.
  It also checks the limits, and the wires in the JSON of the build. A property test checks
  that each wire has an item that takes wires at each end, after any
  steps.
- `test/diy_web/live/wires_live_test.exs` checks the part Wires in the
  panel. It has the example of the owner, each fault, and the errors of
  the fields. It also has the order of the ends and a wire on AC. It has
  the wires of a van, a wire that waits, and an item with its most
  wires.
- The browser test: the person adds a busbar and a wire from the power
  station. The page shows the advice and a fault, and axe checks the
  panel with the wire. The current then comes from the busbar, and from
  the station again, with a click on each choice.

## The languages

The owner decided this: the app is in English, Spanish and Vietnamese.

### The texts

The texts of the pages are in Gettext (`DIY.Gettext`). The English text
is the key: it is in Simplified Technical English. The keys are in
`priv/gettext/default.pot`, and the translations are in
`priv/gettext/es/LC_MESSAGES/default.po` and
`priv/gettext/vi/LC_MESSAGES/default.po`.

- A module of the pages uses `gettext/1`. A text with a number or a name
  has a key for it, for example `%{size} · %{area} sq ft`.
- A text of the core (for example the label of a kind of house in
  `DIY.House`) is a key with `gettext_noop/1`. A text with values is a
  key and its values, for example the source of a price in
  `DIY.Prices`. The page translates it when it shows it
  (`DIY.Gettext.t/1`). A page that is not translated yet shows it in
  English (`DIY.Gettext.en/1`).
- A notice (a flash) is in the language of the page. A notice from a
  script of the page is in English: it is `{"en", text}`, and the notice
  has `lang="en"`.
- A text with a count has a form for each plural form of the language
  (`ngettext/3`). Vietnamese has one form.
- The numbers, the money and the dates keep the form of the United
  States. The app is for houses in the United States: ZIP codes, the
  NEC, and the prices of Texas.
- The translations need a check by a person who speaks the language (an
  open question of `TODO.md`).

### The language of a page

`DIYWeb.Locale` gives the language of a page:

1. The choice of the person: the cookie `diy_language`, for one year. It
   stays on the device, as the build does.
2. Else the header Accept-Language of the browser: the language of the
   app with the largest weight. A region (for example `es-MX`) counts as
   its language.
3. Else English.

The plug puts the language in the assigns, for the attribute `lang` of
the page (WCAG 3.1.1). The signed session of the LiveView keeps the
language of the first render (`DIYWeb.Locale.live_session/1`), and the
hook of the LiveView reads it. A reconnect of the socket, after a deploy
or when a phone wakes up, reads the cookie session again. The cookie can
have a newer language from a different tab. The signed session wins, so
the texts stay in the language of the attribute `lang`. A reload shows
the new language.

The person chooses a language with a link on the first screen or on the
page Settings (`/language/:locale`). Each name is in its own language
(`lang` and `hreflang`), so a screen reader reads it well. The current
language has `aria-current`. The link works with no script. A change of
a language does no harm, so the link needs no token of the session. A
link of a different site can only change the language, and the person
can change it back on the page Settings. The link goes back to a path of
the app only: letters, digits and a simple query. Each other value goes
to `/`. The cookie is `Secure` on https.

### The steps

The first step has the tools and the choice of the language. It also
translates the frame of the pages, the first screens, and the page
Settings. The frame is the bar of the parts, the state of the save, and
the notices. The next steps translate the other pages, one group at a
time. Until then, those pages are in English, and their main part has
`lang="en"` (WCAG 3.1.2): a screen reader reads them with an English
voice. The cards of Home Assistant and of Pecron on the page Settings
also have `lang="en"` for now. So does the page of the sign-in of Home
Assistant.

### The tests of the languages

- `test/diy_web/locale_test.exs` checks the header Accept-Language, with
  a property test against a model. It checks the cookie before the
  header, the link of a language with a property test of its return
  path, and the signed session. It checks the first screens, the
  notices and the page Settings in Spanish and in Vietnamese. It checks
  that the pages that are not translated have `lang="en"` and English
  sources. It also checks that each key has a translation in each
  language, with the same keys of names. A translation is not the
  English text, except a name.
- `mix.com precommit` checks that the keys follow the code
  (`gettext.extract --check-up-to-date`).
- The browser test shows the first screen in Spanish and in Vietnamese,
  with the checks of axe, and then goes on in English. It also checks
  the screen of the house presets at 320 px in Spanish and in
  Vietnamese: the page is not wider than the screen.

## A pool and the search of the items

A neighbor asked for a pool and for a Tesla charger. So the app has a
pool, three items for a pool and a search in the sheet Add.

### A pool is an item

The owner decided this (October 2026): "A pool is an item of any room,
indoor or outdoor. A spa is just a pool inside the room." A person adds
a pool to the backyard. The yard stays a yard, with the grass around the
pool.

- The kind `"pool"` goes in a room inside or outside. It is heavy: it
  does not go in the attic. A roof deck (a room outside on the level of
  the roof) takes it. A hot tub is heavy too.
- A new pool has water of 30 by 15 ft, with a coping of 2 ft around it.
  So the item is 34 by 19 ft (`DIY.Catalog`). In a room that is smaller,
  a new pool fills the room. A room with no plan gets a pool of the
  typical size. A very large room gives a pool of the largest size of an
  item. The person changes its size in its sheet, as
  for each item, and drags it on the plan.
- The water is in the box of the item (`DIY.Layout.water/1`). The coping
  is an eighth of the short side of a small pool. New items go next to
  the pool, not on it, as for each item (`DIY.Layout.fill/1`).
- The plan and the house from outside draw the coping with pavers. The
  water has the color `--p-water` and a texture of waves (`tex-water`).
  The water is lower than the coping. So the eye sees the walls of the
  pool (`--p-pool-wall`) at the far sides.
- A pool uses no power: its pump and its heater are items next to it.
  The estimate counts them, not the pool.
- A file or a link of October 2026 can have a room of the kind `"pool"`.
  The read keeps the room, with no kind. It adds a pool item at the place
  of its water. The deck of the water was 3 ft at the sides and at the
  front, and 10 ft at the back. A room on the level of the roof gets no
  pool. The new item gets an id after the largest id of the file.

### The places of an item

A kind has places (`DIY.Catalog`). `Catalog.fits?(kind, room)` is true
when the place of the room is a place of the kind. A heavy kind also
must not be in the attic. Each check of a place uses this function.
These are a new item, a move, a file, the home of a station and the
devices of Home Assistant.

- The pool pump, the pool heater and the hot tub go in a room inside or
  outside, next to a pool. So a pool pump of Home Assistant can be a
  ghost in a room inside.
- `specs/Pool.tla` checks these rules with TLC. Each item fits its room.
  No pool and no hot tub is in the attic, and a roof deck takes them. Two
  models have a fault. `Pool.nocheck.cfg` moves an item with no check of the
  room. `Pool.light.cfg` checks the place only, so a pool goes in the
  attic. A property test of `test/diy/pool_test.exs` does random steps
  on a build, with the same invariants. It also reads the file of each
  build again.

### Items on items

The owner asked for items on items, with a snap that helps the person
(October 2026). A person puts a dryer on a washer, a power
station on a freezer, or a pool pump on the coping of a pool
(`DIY.Stack`).

- An item has the key `on`: the id of the item under it. An item on the
  floor has no key. The file and the link keep the key.
- An item A holds an item B when two rules are true. The center of the
  space of B is over A. The space of A is at least half of the space of
  B. So a TV goes on a narrow stand, and a dryer that turns stays on its
  washer. But a fridge does not go on a microwave. A pool holds an item
  only on its coping: an item over the water is not on the pool.
- A drop on the plan puts the item on the item that holds it. When two
  or more items hold it, it goes on the item with the highest top. Near
  an end of the item under it (6 inches or less), it goes to that end.
  Near the center, it goes to the center. An item that is larger than
  the item under it goes to its center. Then it goes next to an item on
  the same item, as on the floor. On a pool, it stays where the person
  drops it.
- A drop on the floor can move the item to the side of an item on the
  floor near it (6 inches or less). Then the two have no gap. Items on a
  wall or a ceiling have no effect on this, and they do not move this
  way.
- The arrow keys do not move the item to an end or a side. The item goes
  on the item that holds it, or on the floor.
- When an item moves, the items on it move with it, by the same
  distance, also to a different room. In a drag, the page moves them
  with it (`data-on`). Each item stays in its room. An item that does
  not fit the new room stays, with the items on it: a TV does not go
  outside on a pool pump.
- After each change, an item that is not held by the item under it
  comes down. For example, the item under it goes away, or turns, or
  gets a new size. Or the list of the sheet moves it to a new room. An
  item that comes down goes on the highest item that holds it there, if
  there is one. The other items on the floor stay where they are: a new
  item does not take an old item on it.
- Two items can overlap, on the floor or on the top of an item, as
  before. For example, a full room gives a new item a place over an old
  item. The snap helps the person to put the items side by side.
- An item on an item is on its top: the picture adds the height of the
  item under it. A pool is in the floor, so an item on a pool is at the
  floor. An item over the top of an item has no shadow. The top item
  paints after the item under it (`DIYWeb.Camera.order/2`).
- Solar panels, a camper van, a car and an item on a wall or a ceiling
  do not stack. A pool holds an item, but it does not go on an item. The
  items of the roof and of a van do not stack.
- When a file moves an item from a van to the house, the item gets a
  free place in the house (`DIY.Layout.fill/1`).
- The sheet of the item tells the item under it: "Under it: Clothes
  washer."
- `specs/Stack.tla` checks the rules with TLC. Each item fits its room.
  The item under an item is there, in the same room and under it. No
  item is under itself. An item that comes down goes on an item that
  holds it (the step property `SeatFallen`). Four models have a fault:
  - `Stack.noloop.cfg` puts an item on an item that is on it.
  - `Stack.nodrop.cfg` deletes an item, but the items on it stay on it.
  - `Stack.nofit.cfg` moves the items on an item to a room that they do
    not fit.
  - `Stack.noseat.cfg` keeps an item that comes down on the floor, also
    in an item that holds it.

  A property test of `test/diy/stack_test.exs` does random drops, moves,
  turns, sizes, walls and deletes, with the same invariants. It also
  reads the file of each build again.

### The new items

- **Pool heater.** A heat pump or an electric heater uses its watts for
  its hours in one day. The default is 5,500 W for 1.5 hours, the mean
  of the season. A heater runs more in spring and fall. The sheet shows
  the watts or the kBTU/h of the heater, for its fuel. A gas heater
  uses no kWh for heat. It burns gas: kBTU/h × 1,000 × hours × days ÷
  100,000 gives the therms. Its blower uses near 300 W. The default
  season is April to October. A heat pump and a gas heater have a motor
  for the check of the start of a station. An electric heater has no
  motor.
- **Hot tub.** The person gives the kWh of one day: 5 kWh is the
  default, for a tub with a good cover. The default season is all year.
- **Tesla Wall Connector.** The charger of a car has the choice "Level
  2: Tesla Wall Connector, 48 A (11.5 kW)". It charges at 11.5 kW, with
  the efficiency of a charger of Level 2 (0.9). It counts as a charger
  of Level 2 for the permits.

### The search of the sheet Add

- The sheet Add has a box of search. Each word of the text must be the
  start of a word of a kind: of its name or of its more words
  (`Catalog.words/0`). Capitals have no effect. For example "Tesla" and "wall connector" find the car, and
  "spa" finds the pool and the three items of a pool.
- The list shows the kinds that fit the room and match the text.
- A kind that matches but does not fit the room shows under "Not for
  this room", with the places where it goes. An example is "Central AC:
  in a room outside or the roof." So the person knows where to add it.
- The item Other always shows: it takes any name and power. With no
  match, the sheet tells the person to use it.
- A status that only a screen reader reads tells the count of the
  matches.
- A new sheet Add starts with no text. The text has 40 characters at
  most.

## The sky at the house

The picture of the house from the outside shows the sky at the house:
day, sunset or night, with sun, clouds, rain or snow. The page keeps the
theme of the phone. Only the picture follows the time at the house.

### The sky of now

- `DIY.Sky.now/3` asks Open-Meteo (https://open-meteo.com) for the
  weather of now. The service is free and needs no key. The request has
  a point on a grid of 0.25°, as for the weather history
  (`DIY.Weather`). So many ZIP codes have the same point.
- The answer has the code of the weather of the WMO and the temperature.
  It also has the offset of the time of the place, and the sunrise and
  the sunset of the day.
- The time of day comes from the clock of the server and the offset of
  the place, not from the time of the answer. It is "sunset" from 30
  minutes before to 30 minutes after the sunset or the sunrise. Between
  them, it is "day". Else it is "night". Near the sunrise, the form says
  "Sunrise"; the picture is the same as at a sunset.
- With no sunrise and no sunset in the day (near a pole), it is "day" or
  "night" all day, from `is_day` of Open-Meteo. In a polar night, the
  sunrise and the sunset are the same time. In a polar day, the sunset is
  24 hours or more after the sunrise.
- The code of the weather gives "sun" (0 and 1), "clouds" (2, 3 and
  fog), "rain" (drizzle, rain, showers and storms) or "snow".
- The cache keeps the answer of a point for 30 minutes, under one key.

### The page

- The page asks for the sky when the build gets a ZIP code. Until the
  answer comes, the picture is a day with sun.
- After an answer, the page asks again in 30 minutes, or sooner at the
  next change of the time of day. It keeps the sky of before until the
  new answer comes.
- An error keeps the answer of before, with the clock of now: the time
  of day can change while the service does not answer. With no answer
  of before, the picture is a day with sun. Then the page asks again in
  5 minutes.
- A new timer cancels the timer before, and a new ZIP code cancels it
  too. A message of a timer for a different ZIP code asks nothing.
- An answer for a ZIP code that the page left goes away.
- `specs/Sky.tla` checks these rules with TLC: the page shows the sky of
  its ZIP code or no sky, and one timer waits at most. In the model, a
  cancel cannot take back the message of a timer that ended. Two models
  have a fault. `Sky.nocheck.cfg` takes each answer, and
  `Sky.nocancel.cfg` keeps the old timer.

### The choice of the sky

- Under the picture, the person can choose a time of day (Now, Day,
  Sunset or Night) and a weather (Now, Sun, Clouds, Rain or Snow). "Now"
  is the sky at the house. The sheet of the share has the same choice.
  The person does not have to wait for the night to share a picture of
  the night.
- The link of a share carries the sky of its picture ("t" and "w" in
  its summary). A link of an older version has no sky: a day with sun.
- A link with no ZIP code carries no sky of now: there, "Now" is a day
  with sun. The sky of now and the time of the post can tell the place.
  A sky that the person chooses stays in the link. The sheet then shows
  no sky of now.

### The drawing

- `DIYWeb.Outside.sky/2` gives the shapes of the sky. Behind the house:
  the sky, the sun or the moon, the stars and the clouds. Over the house:
  the rain or the snow, in a group that moves, and then the warm light
  of a sunset, which does not move.
- The SVG has `data-scene` (the time of day) and `data-weather`. The
  colors of the plan follow the scene, not the theme of the page. A day
  and a sunset have the light colors, and a night has the dark colors
  and the warm light in the windows. The selectors of a scene are
  stronger than the selectors of the theme (app.css).
- Snow covers the yard and the roof.
- The rain and the snow fall for 4.8 seconds, and then they stop (WCAG
  2.2.2). With "reduce motion", they do not move.
- The form of the sky has the language of the page (`lang`). Its text is
  translated, but the part of the page around it is in English.
- The picture of a link (`DIYWeb.Picture`) has the styles of its scene.
  `priv/picture/styles.json` has the styles of each scene, and the
  classes that snow changes. The tests check the styles of each class in
  each sky.

## In a car

The owner wants the app in a car later: Android Auto and Android
Automotive OS. For now, the app is a web app only. This is a decision
of the owner (October 2026): a native app is too much work, and it
needs the approval of the stores. The parts of the app that a car can
show follow these rules now, so that a car app can use them.

The facts of the platform (developer.android.com, "Use the Android for
Cars App Library", "Build IoT apps for cars", "Template restrictions",
"Car Hardware APIs"):

- A car app is a native Android app with the Android for Cars App
  Library. It shows templates, not a web page. One app is for Android
  Auto (on the phone), and one is for Android Automotive OS (in the car).
- The app fits the category IoT: actions on connected devices from the
  car, for example a garage door or the lights of the house. For IoT,
  the library advises the `GridTemplate`.
- A task shows 5 templates at most. A new state of a toggle on the same
  template does not count.
- The car app can read the energy level of the car: the battery, the
  fuel and the range.

The rules for the app:

1. **A car view is data, not HTML.** A module gives the facts and the
   actions that a car can show. The facts are the power now (the grid
   and the sun) and the charge of the stations. A van or an electric car
   also gives its battery and its range. The actions turn devices on or
   off. A
   native car app shows this data with the templates. A page of the web
   app shows the same data, for the tests.
2. **Short tasks.** A task has 3 steps at most: the home, a group of
   devices, a device. Each label is short.
3. **No text in the car.** The plan and the editor of the rooms stay on
   the phone. In the car, the person only reads facts and does simple
   actions. On Android Auto, the car app uses the sign-in of the phone
   app. An app on Android Automotive OS is in the car, so it needs its own
   sign-in. The library has a `SignInTemplate` for it, for example with a
   PIN or a QR code that the person uses on the phone. Home Assistant has
   no grant for a device code. So a relay gives the code of the sign-in to
   the car. The relay carries only that code, and the car keeps the PKCE
   verifier: the tokens never go through the server of the app.
4. **A confirmation for an action with a risk**, for example a garage
   door or a lock.
5. **The data goes to the native part.** The build and the session of
   Home Assistant are in IndexedDB of the page. A native service cannot
   read the IndexedDB of a WebView. So the page gives them to the native
   part with a JavaScript bridge, and the native part keeps a copy. The
   car service can run when no page is open: it uses that copy. The
   native part encrypts the tokens with a key in the Android Keystore,
   and keeps them in its own store. On Android Automotive OS, no page of
   the app is in the car. That car app gets its facts from Home Assistant
   with its own sign-in. A later step gives it the build, for example as
   a file of the build from the phone.
6. **An address for away from home.** A car cannot use the address of
   Home Assistant on the home network. A phone with mobile data cannot
   use it either. The car app needs an address that works from outside
   (for example, from Home Assistant Cloud).
7. **Icons that a car can show.** The icons of the items are simple
   vector shapes (`DIYWeb.Icon`). A script can make vector drawables of
   them.
