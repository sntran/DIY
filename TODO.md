# Ideas and open questions

The owner decides about each item.

## Open questions of the plan

- Van builds before or after the plan lesson?
- Money: free, donations, or referral fees? Referral fees conflict with
  honesty rule 4.
- Keep all user data on the device, or offer an account to sync between
  devices? Today: on the device (`docs/design.md`).
- Languages at launch: English only, or also Vietnamese and Spanish? Today:
  English only, with no Gettext.
- Step-by-step wiring guides, or explain the idea and link to code and
  permits only?
- Web app only, or also app stores?
- The name of the app. Today: "Small Steps Home", a name that is not final.

## Ideas

- The weather of the state, in the file of the app, for the estimate when
  NASA POWER does not answer.
- The appraisal data of a county for the preset (phase "later" of the
  plan).
- A lot from a subdivision plan, for "a house I'm planning". Today the
  user gives the size of the lot.
- The check of phase 2 with real files of meters (anonymized), in place of
  synthetic meter data from the model of the estimate.
- A Green Button XML with more than one meter: the finest readings for each
  UsagePoint, each flow and each day (today: for each flow and day). And
  the first day of hourly readings after a meter change: keep the finer
  readings only when they cover the full day.
- The weather of the months of this year (NASA POWER has the months of
  last year and before): a file of the last 12 months then gets its fit.
- Base Power next to a DIY station in the what-if (the plan: a battery of
  25 or 50 kWh for $695 or $995, with its own rate plan).
- The power that a station uses when it is on (its idle power).
- The shape of the real hours of a meter file in the day of a month, in
  place of the shapes of the model.
- The range of the sun (the sunniest and the cloudiest year).
- A mode for each station, in place of one mode for the house.
- A heat pump gives less heat in the cold: its size at 17 °F.
- The direction of the panels for each month (a south roof gives more in
  winter), and the shape of the day of panels to the east or to the west.
  Today one factor for the year, and the same shape of the day.
- A house that I plan: with a planned AC, the front shows no estimate
  until the AC is not planned.
- The circuits of a subpanel by name, in place of the items that a
  station runs.
- The check of phase 4 with a real person with no background in plans:
  the person compares 2 plans with the worksheet.
- The EFL forms that the reader does not know yet: numbers in columns
  under their names, and charges in a table.
- The delivery charges of the utilities change in March and in
  September: a way to update the table of `DIY.Plan.tdu/1` (today by
  hand).
- The check of phase 5 with the van of the owner: the label in the door
  frame, the weight of each axle on a truck scale, and the Wh of a day
  from the app of the battery.
- The place of each zone of a van, from the user (today a typical
  layout).
- The sun of the place of a trip, in place of the sun at the house.
- The axles of the Transit models, and of the Sprinter of 170 in, in the
  models of vans.
- Two sets of solar panels on the same side of the roof: a check of
  their sum against the roof. And a roof that the user adds (a porch):
  today it gets the number of the main roof.
- The range of a fridge around the house with the temperature of each
  year (today the history uses the mean temperature of the month).
- A planned item that replaces a gas item: a heat pump water heater, an
  electric stove or an electric dryer. Today the plan keeps the gas item.
  So the what-if shows more power and the same gas.
- The natural gas price of each state, and of each gas utility of Texas
  (today: the line of Texas, else of the US).
- The therms of each month on the math page (today: the year of each
  item).

## The second play test

A second play test (October 2026) found these faults. The fixes of the
other faults are in the next pull requests.

- "Plan" has two meanings: a planned item (the page Power) and a plan of
  a retail provider (the tab Plans).
- A sheet did not scroll from a swipe at the bottom of the screen (with
  touch emulation). A second check with touch events did not show it:
  check it on a real phone.
- A new station or new panels are items that the user has: the user
  must tick "it is a plan".
- No CPAP in the list of the items, and no note for a medical device.
- The permit notes name Dallas and New Braunfels, not the city of the
  user.
- The bar chart of the bill gives no dollars, and a tap does nothing.
- The labels of the rooms in the picture. Some rooms have no name in the
  view of all the house. The tab of the floor is not marked.
- The handles of a zone of the van cover its name.
- Words that a person with no skill does not know: GVWR, GAWR, LRA,
  DC-DC, LiFePO4, ABYC E-11, degree day, "Ctrl and the mouse wheel".
- The page Bill is the math of the model, not the parts of a real bill.
  The exercise of the lesson wants an EFL file on the phone.
- In the picture of the rooms, the van can cover the garage and the name
  of the driveway. Also, 6,000 W of panels look like a thin strip.

## Ideas of the play test

A play test in the role of a neighbor with no skill in power (October
2026) gave these ideas. The fixes of the other findings are in #16 and
the next pull requests.

- "Am I on a good plan?" The app does not rank plans (honesty rule 4).
  The owner decides if the worksheet must rank them.
