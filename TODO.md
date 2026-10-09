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
- The axles of the Transit and of the Sprinter in the models of vans.

## Ideas of the play test

A play test in the role of a neighbor with no skill in power (October
2026) gave these ideas. The fixes of the other findings are in #16 and
the next pull requests.

- A fridge or a freezer in a hot garage uses more in the summer. Today
  the app uses the number of the label for each month.
- A 12 V fridge of a van uses more in a hot month. Today it uses the same
  Wh in each month.
- The gas bill. The app knows the gas of a water heater, a furnace and a
  stove, but it shows only the power bill.
- "Am I on a good plan?" The app does not rank plans, and the lesson
  comes before the worksheet. A person with little time may want the
  worksheet first.
- Solar: a typical price for each watt in Texas, with its source, and the
  number of panels that the roof holds.
- The sizes of stations as examples (kWh and watts), with no brand names
  (honesty rule 4).
- More models of each van: other roofs and lengths (for example a Transit
  with a medium roof).
- A medium house of 2 floors gets 2 bedrooms. Many such houses have 3.
- A finger that scrolls the page over the plan has no momentum.
