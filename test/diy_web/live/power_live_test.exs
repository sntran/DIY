defmodule DIYWeb.PowerLiveTest do
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    settle(view)
    view
  end

  defp house(door \\ "my_house") do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), door)
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp add(build, room, type, params \\ %{}) do
    room = Enum.find(build.rooms, &(&1.name == room)).id
    {:ok, build, id} = Build.add_item(build, room, type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  defp flag(build, type, flag) do
    item = Enum.find(build.items, &(&1.type == type))
    {:ok, build} = Build.flag_item(build, item.id, flag, true)
    build
  end

  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build
  defp item(view, type), do: Enum.find(build(view).items, &(&1.type == type))

  test "the page Power shows only for a house with power equipment, a car or a plan", %{
    conn: conn
  } do
    view = open(conn, ~p"/", house())
    refute has_element?(view, "nav a", "Power")
    render_patch(view, ~p"/power")
    assert has_element?(view, "#no-equipment")
    refute has_element?(view, "#view")

    {build, _id} = add(house(), "Driveway", "ev")
    view = open(conn, ~p"/", build)
    assert has_element?(view, "nav a", "Power")
  end

  test "a station, its items, and an outage", %{conn: conn} do
    {build, _id} = add(house(), "Laundry", "power_station", %{"kwh" => "2", "output_w" => "2000"})
    view = open(conn, ~p"/inside", build)

    fridge = item(view, "fridge")
    html = render_patch(view, ~p"/inside?item=#{fridge.id}")
    assert html =~ "A power station runs it"
    view |> form("#flags-form", %{"backup" => "true", "planned" => "false"}) |> render_change()
    assert item(view, "fridge").backup
    assert render_patch(view, ~p"/inside") =~ "on the station"

    # The station itself and the meter do not go on a station.
    station = item(view, "power_station")
    refute render_patch(view, ~p"/inside?item=#{station.id}") =~ "A power station runs it"

    html = render_patch(view, ~p"/power")
    assert html =~ "1 power station: 2.0 kWh, 2,000 W"
    assert html =~ ~r/feed the items that plug into them:\s+Fridge\./
    assert html =~ "In an outage"
    assert html =~ "From the charge of the battery at 18:00"
    assert html =~ "Jul:"
    assert html =~ "needs 3 to 8 times its running power"
    assert html =~ "How the app gets these numbers"
    refute has_element?(view, "#today-backfeed")
    refute has_element?(view, "#today-permit")

    # A bad flag, or a flag of an item that is not there, changes nothing.
    render_change(view, "flag", %{"item_id" => "i999", "planned" => "true"})
    render_change(view, "flag", %{"item_id" => fridge.id, "planned" => "maybe"})
    refute item(view, "fridge").planned
  end

  test "a station with no item, and no station on the page", %{conn: conn} do
    {build, _id} = add(house(), "Laundry", "power_station")
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#backup", "No item is on the stations yet.")
    assert render(view) =~ ~r/plug into them:\s+no item yet\./
    refute has_element?(view, "#outage")
  end

  test "a station that powers the panel: the danger of backfeed, the permit, the steps", %{
    conn: conn
  } do
    {build, id} =
      add(house(), "Garage", "power_station", %{"feeds" => "panel", "output_w" => "200"})

    build = build |> flag("fridge", :backup) |> flag("ac", :backup)
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#today-backfeed")
    assert has_element?(view, "#today-permit")
    assert has_element?(view, "#today-overload")
    refute has_element?(view, "#outage-steps")
    assert render(view) =~ "feed the backup circuits through an inlet"

    {build, _switch} = add(build, "Garage", "transfer_switch")
    view = open(conn, ~p"/power", build)
    refute has_element?(view, "#today-backfeed")
    assert has_element?(view, "#outage-steps", "Turn off the main breaker")
    assert has_element?(view, "#outage-steps", "Connect the station to the inlet")
    assert render(view) =~ "the interlock keeps them apart"

    switch = Enum.find(build.items, &(&1.type == "transfer_switch"))
    {:ok, transfer} = Build.update_item(build, switch.id, %{"device" => "transfer"})
    view = open(conn, ~p"/power", transfer)
    assert render(view) =~ "the switch moves the backup circuits from the grid to the station"
    assert has_element?(view, "#outage-steps", "The main breaker stays on")
    refute has_element?(view, "#outage-steps", "Turn off the main breaker")

    {:ok, subpanel} = Build.update_item(build, switch.id, %{"device" => "subpanel"})
    view = open(conn, ~p"/power", subpanel)
    assert render(view) =~ "the backup circuits are on the subpanel"

    # Panels on a grid-tie inverter too: a warning, a permit with the
    # utility, and a step for the breaker of the inverter.
    {build, _panels} = add(build, "Roof", "solar_panels", %{"to" => "grid"})
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#today-grid-tie")
    assert has_element?(view, "#today-permit", "the utility must approve them")
    assert has_element?(view, "#outage-steps", "Turn off the breaker of the grid-tie inverter")
    assert id
  end

  test "the furnace on a station: a month with no use", %{conn: conn} do
    {build, _id} = add(house(), "Laundry", "power_station")
    view = open(conn, ~p"/power", flag(build, "furnace", :backup))
    assert render(view) =~ "Jul: no use"
    assert render(view) =~ ~r/Jan: \d/
  end

  test "the page Bill with a planned item, and with a station and a price at night", %{
    conn: conn
  } do
    {build, _id} = add(house(), "Laundry", "power_station")
    view = open(conn, ~p"/estimate", flag(build, "power_station", :planned))
    assert has_element?(view, "#planned-note", "The planned items (1) are not in this bill")
    assert has_element?(view, "#items")
    refute has_element?(view, "#bill-math")

    build = Build.set_power(build, %{build.power | night_cents: 5.0})
    view = open(conn, ~p"/estimate", build)
    assert has_element?(view, "#bill-math", "at night (22:00 to 6:00)")
    # On a narrow screen, the table scrolls: the keyboard can scroll it too.
    assert has_element?(
             view,
             ~s(#bill-math [role=region][tabindex="0"][aria-label="The bill of each month with your equipment"] #bill-months)
           )

    assert render(view) =~ "kWh × price"
    assert render_patch(view, ~p"/") =~ "At night (22:00 to 6:00)"

    # Panels on the grid, and a price for the power to the grid.
    {build, _id} = add(house(), "Roof", "solar_panels", %{"watts" => "9000", "to" => "grid"})
    build = Build.set_power(build, %{build.power | buyback_cents: 4.0})
    view = open(conn, ~p"/estimate", build)
    assert has_element?(view, "#bill-math", "less the kWh to the grid × 4.0¢")
    assert has_element?(view, "#bill-months", "To the grid")
    assert render_patch(view, ~p"/") =~ "For each kWh to the grid, the plan pays 4.0¢."
  end

  test "the plan: today next to the plan, the payback, and the plan done", %{conn: conn} do
    {build, _id} = add(house(), "Laundry", "power_station", %{"solar_w" => "1600"})
    {build, _id} = add(build, "Roof", "solar_panels", %{"watts" => "1600", "cost" => "800"})
    build = build |> flag("fridge", :backup) |> flag("solar_panels", :planned)
    build = Build.set_power(build, %{build.power | mode: "solar"})
    view = open(conn, ~p"/", build)

    html = render(view)
    assert html =~ "With your plan, in an average month"
    assert html =~ "1 planned item"

    assert html =~ "The range with the plan"

    html = render_patch(view, ~p"/power")
    assert has_element?(view, "#plan-months")
    assert has_element?(view, "#plan-range")
    assert html =~ "The planned equipment costs $800"
    assert html =~ "it pays back in"
    # The page gives one number for the savings: the weather changes the
    # two bills the same way.
    refute html =~ "With the range of the bill, the equipment saves"
    assert html =~ "A panel lasts 25 to 35 years."
    # The station of today runs the fridge: the hours are at the top.
    assert has_element?(view, "#backup", "In an outage, with the plan")
    assert has_element?(view, "#backup-hours")
    # The view shows the plan.
    assert has_element?(view, "#view", "With the planned items.")
    refute html =~ "A battery of 3,000 cycles"
    assert html =~ "of sun is lost in one year"

    view |> element("button", "I have the planned items now") |> render_click()
    refute Enum.any?(build(view).items, & &1.planned)
    refute has_element?(view, "#plan")
  end

  test "panels on the grid stop in an outage: the box says so, and the hours do not count them",
       %{conn: conn} do
    {base, _id} = add(house(), "Laundry", "power_station")
    base = flag(base, "fridge", :backup)
    view = open(conn, ~p"/power", base)
    hours = view |> element("#backup-hours") |> render()
    refute has_element?(view, "#backup-grid-panels")

    {build, panels} = add(base, "Roof", "solar_panels", %{"to" => "grid", "watts" => "9000"})
    view = open(conn, ~p"/power", build)
    assert view |> element("#backup-hours") |> render() == hours

    assert has_element?(
             view,
             "#backup-grid-panels",
             "Panels on the grid stop in an outage: their inverter needs the grid. These hours do not count them."
           )

    # The same panels on the station: more hours.
    {:ok, on_station} = Build.update_item(build, panels, %{"to" => "station"})
    view = open(conn, ~p"/power", on_station)
    refute view |> element("#backup-hours") |> render() == hours

    # A station that feeds the circuits through an inlet. A warning tells
    # to turn off the inverter, and the note does not show.
    station = Enum.find(build.items, &(&1.type == "power_station"))
    {:ok, inlet} = Build.update_item(build, station.id, %{"feeds" => "panel"})
    view = open(conn, ~p"/power", inlet)
    refute has_element?(view, "#backup-grid-panels")
    assert has_element?(view, "#today-grid-tie")
  end

  test "a CPAP on a small station: the time when it stops, and the size for 2 nights", %{
    conn: conn
  } do
    {build, _id} = add(house(), "Bedroom 1", "cpap")
    {build, _id} = add(build, "Bedroom 1", "power_station", %{"kwh" => "0.256"})
    build = flag(build, "cpap", :backup)
    view = open(conn, ~p"/power", build)
    # The outage starts at 18:00, and the CPAP at 22:00: 0.224 kWh at the
    # outlets give 50 W for 4.5 hours.
    assert has_element?(view, "#backup-hours", "8.5 hours")
    assert render(view) =~ "8.5 hours (from 18:00 to 2:28), in any month of the year"
    # Two nights of 0.4 kWh, with the losses of the battery: 0.92 kWh. The
    # page rounds up, so that a station of this size runs 48 hours.
    assert has_element?(view, "#backup-size", "the stations need near 1 kWh")
  end

  test "a plan that does not pay back, and a station in an outage of the plan", %{conn: conn} do
    {build, _id} = add(house(), "Laundry", "power_station", %{"cost" => "2000"})
    build = build |> flag("power_station", :planned) |> flag("fridge", :backup)
    view = open(conn, ~p"/power", build)
    html = render(view)
    # In the mode backup, the battery stays full: the bill is the same.
    assert html =~ "On savings alone, the planned equipment saves no money."
    assert html =~ "A different reason: in an outage"
    # The fridge uses the same kWh in each month: the hours are the same.
    assert html =~ "on day 3), in any month of the year"
    assert html =~ "A battery of 3,000 cycles (a cycle is one full charge and one full use)"
    # The hours are at the top of the page, with the size for 2 days.
    assert has_element?(view, "#backup-hours", "hours")
    refute has_element?(view, "#backup-grid-panels")
    assert has_element?(view, "#backup-size", "For 2 days (48 hours), the stations need near")
    refute has_element?(view, "#parts")
    # In the mode night with one price, the station costs more.
    night = Build.set_power(build, %{build.power | mode: "night"})

    assert render(open(conn, ~p"/power", night)) =~
             "On savings alone, the planned equipment does not pay back: it costs"

    # Today the house has no station: the hours of each month are the
    # hours of the plan.
    assert has_element?(view, "#outage")
    # The planned station is on the item sheet of the fridge, with its
    # hours and a link to the page Power. The station has them too.
    fridge = item(view, "fridge")
    assert render_patch(view, ~p"/inside?item=#{fridge.id}") =~ "A power station runs it"

    assert has_element?(
             view,
             "#item-power",
             "In an outage, the stations of the plan run their items for"
           )

    assert has_element?(view, ~s(#item-power a[href="/power"]), "Open the page Power")
    station = item(view, "power_station")
    render_patch(view, ~p"/inside?item=#{station.id}")
    assert has_element?(view, "#item-power", "In an outage")
    # An item that no station runs: no hours.
    render_patch(view, ~p"/inside?item=#{item(view, "ac").id}")
    refute has_element?(view, "#item-power")
    assert render_patch(view, ~p"/inside") =~ "Plan"
  end

  test "a plan that pays back in less than one year", %{conn: conn} do
    {build, _id} =
      add(house(), "Roof", "solar_panels", %{"watts" => "5000", "to" => "grid", "cost" => "10"})

    view = open(conn, ~p"/power", flag(build, "solar_panels", :planned))
    assert render(view) =~ "it pays back in less than one year"

    # A payback after the life of the panels.
    {build, _id} =
      add(house(), "Roof", "solar_panels", %{"watts" => "100", "to" => "grid", "cost" => "50000"})

    view = open(conn, ~p"/power", flag(build, "solar_panels", :planned))

    assert render(view) =~
             "after its life of near 25 years, so on savings alone it does not pay back"
  end

  test "a station and panels in the plan: each one has its own payback, in its own life", %{
    conn: conn
  } do
    {build, _id} = add(house(), "Laundry", "power_station", %{"cost" => "1500"})

    {build, _id} =
      add(build, "Roof", "solar_panels", %{"watts" => "6000", "to" => "grid", "cost" => "15000"})

    build =
      build
      |> flag("power_station", :planned)
      |> flag("solar_panels", :planned)
      |> flag("fridge", :backup)

    view = open(conn, ~p"/power", build)
    html = render(view)
    # All the equipment: no life decides it, so the battery of 8 years does
    # not decide the panels of 25 years.
    refute html =~ "after its life of near 8 years"
    assert has_element?(view, "#parts li", "Solar panels ($15,000): it adds")
    assert has_element?(view, "#parts li", "in a life of near 25 years")

    assert has_element?(
             view,
             "#parts li",
             "Power station ($1,500): it adds no savings. On savings alone, it does not pay back. The reason is the backup in an outage."
           )

    # With a price at night, the two ends of the savings differ: the page
    # gives the range.
    night = Build.set_power(build, %{build.power | night_cents: 5.0})
    assert has_element?(open(conn, ~p"/power", night), "#savings-range", "the equipment saves")
    refute has_element?(view, "#savings-range")
  end

  test "panels that charge a station are one part with it, and the plan has the shortest life", %{
    conn: conn
  } do
    {build, _id} = add(house(), "Laundry", "power_station", %{"cost" => "1500"})
    {build, _id} = add(build, "Roof", "solar_panels", %{"watts" => "1600", "cost" => "800"})
    build = build |> flag("power_station", :planned) |> flag("solar_panels", :planned)
    view = open(conn, ~p"/power", build)
    # One part: no lines of parts. The battery of 8 years decides.
    refute has_element?(view, "#parts")
    refute render(view) =~ ~r/it pays back in [\d.]+ years\./

    # With a transfer switch, there are two parts. Each part has its own
    # line. The switch has no life, so the plan as one has the life of the
    # battery.
    {build, _id} = add(build, "Garage", "transfer_switch", %{"cost" => "600"})
    view = open(conn, ~p"/power", flag(build, "transfer_switch", :planned))

    assert has_element?(
             view,
             "#parts li",
             "Power station and solar panels ($2,300): they add"
           )

    assert view |> element("#parts") |> render() |> String.split("<li") |> length() == 3

    assert has_element?(
             view,
             "#parts li",
             "The reason is a safe backup of the circuits of the house."
           )
  end

  test "the hours of backup at the top: zero hours, an overload, and the size only in the mode backup",
       %{conn: conn} do
    # A small station in the mode of the sun, with no reserve and no
    # panels: the battery is empty at 18:00.
    {build, _id} = add(house(), "Laundry", "power_station", %{"kwh" => "1"})
    build = build |> flag("fridge", :backup)
    empty = Build.set_power(build, %{build.power | mode: "solar", reserve: 0})
    view = open(conn, ~p"/power", empty)
    assert has_element?(view, "#backup-hours", "0.0 hours")
    assert has_element?(view, "#backup", "the batteries can be empty at 18:00")
    refute has_element?(view, "#backup-size")

    # In the mode backup, the size for 2 days.
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#backup-size", "They have 1 kWh.")

    # An overload: no hours, but the warning.
    {build, _id} = add(house(), "Laundry", "power_station", %{"output_w" => "200"})
    view = open(conn, ~p"/power", flag(build, "ac", :backup))
    assert has_element?(view, "#backup", "need more watts than the stations give")
    refute has_element?(view, "#backup-hours")
  end

  test "a station with no item on it, or with an item that uses no power", %{conn: conn} do
    {build, _id} = add(house(), "Laundry", "power_station")
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#backup", "No item is on the stations yet.")
    refute has_element?(view, "#backup", "with the plan")

    # A TV of 0 hours in one day on the station.
    tv = Enum.find(build.items, &(&1.type == "tv"))
    {:ok, build} = Build.update_item(build, tv.id, %{"hours" => "0"})
    view = open(conn, ~p"/power", flag(build, "tv", :backup))
    assert has_element?(view, "#backup", "The items on the stations use no power.")
  end

  test "the warnings of the plan: a planned station on the panel, too small", %{conn: conn} do
    {build, _id} =
      add(house(), "Garage", "power_station", %{"feeds" => "panel", "output_w" => "200"})

    build = build |> flag("power_station", :planned) |> flag("ac", :backup)
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#plan-backfeed")
    assert has_element?(view, "#plan-overload")
    assert has_element?(view, "#plan-permit")
    assert render(view) =~ "cannot run all their items at the same time"
    refute render(view) =~ "A different reason"
    # The sheet of the AC gives the overload, not hours.
    render_patch(view, ~p"/inside?item=#{item(view, "ac").id}")
    assert has_element?(view, "#item-power", "need more watts than the stations give")
    render_patch(view, ~p"/power")
    # Today the house has no station: no warning of today.
    refute has_element?(view, "#today-backfeed")
    # The front shows a mark of the problem.
    assert render_patch(view, ~p"/") =~ "The plan has a problem of safety or of size"

    # The same danger today and in the plan shows one time.
    {build, _id} =
      add(house(), "Garage", "power_station", %{"feeds" => "panel", "output_w" => "200"})

    {build, _panels} = add(build, "Roof", "solar_panels")
    view = open(conn, ~p"/power", flag(build, "solar_panels", :planned))
    assert has_element?(view, "#today-backfeed")
    refute has_element?(view, "#plan-backfeed")
    refute has_element?(view, "#plan-permit")

    # Today the station is too small, and the plan adds more on it: the
    # overload of the plan shows with its watts.
    {build, _id} = add(house(), "Laundry", "power_station", %{"output_w" => "100"})
    {build, heater} = add(build, "Laundry", "space_heater")
    build = build |> flag("fridge", :backup)
    {:ok, build} = Build.flag_item(build, heater, :backup, true)
    {:ok, build} = Build.flag_item(build, heater, :planned, true)
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#today-overload")
    assert has_element?(view, "#plan-overload")

    # Planned panels on the grid add work: the permit of the plan shows.
    {build, grid} = add(build, "Roof", "solar_panels", %{"to" => "grid"})
    {:ok, build} = Build.flag_item(build, grid, :planned, true)
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#plan-permit", "the utility must approve them")
  end

  test "the modes and the reserve of the stations, and the price of the power to the grid", %{
    conn: conn
  } do
    {build, _id} = add(house(), "Laundry", "power_station")
    {build, _id} = add(build, "Backyard", "solar_panels", %{"to" => "grid", "watts" => "9000"})
    view = open(conn, ~p"/power", flag(build, "fridge", :backup))

    view
    |> form("#power-form", %{"mode" => "night", "reserve" => "30", "buyback_cents" => "4"})
    |> render_submit()

    assert %{mode: "night", reserve: 30, buyback_cents: 4.0} = build(view).power
    html = render(view)
    assert html =~ "a charge at night does not save money"
    assert html =~ "To the grid"
    assert html =~ "At night"

    assert view |> form("#power-form", %{"reserve" => "half"}) |> render_submit() =~
             "Give a part from 0 to 100%."

    assert render_submit(view, "power", %{"mode" => "turbo"}) =~
             "Choose how you use the batteries."

    assert render_submit(view, "power", %{"buyback_cents" => "-1"}) =~
             "Give the price in cents, from 0 to 200."
  end

  test "the price at night, on the settings", %{conn: conn} do
    view = open(conn, ~p"/settings", house())
    before = :sys.get_state(view.pid).socket.assigns.bill.cost

    view
    |> form("#settings-night", %{"night_cents" => "0", "night_from" => "21", "night_to" => "7"})
    |> render_submit()

    assert %{night_cents: +0.0, night_from: 21, night_to: 7} = build(view).power

    assert view |> form("#settings-night", %{"night_cents" => "free"}) |> render_submit() =~
             "Give the price at night in cents"

    assert view |> form("#settings-night", %{"night_from" => "30"}) |> render_submit() =~
             "Give an hour from 0 to 23."

    assert view
           |> form("#settings-night", %{"night_from" => "7", "night_to" => "7"})
           |> render_submit() =~ "The night must start and end at different hours."

    # Free nights lower the bill.
    assert :sys.get_state(view.pid).socket.assigns.bill.cost < before
  end

  test "a car: the home charge next to gas, and a charge that takes too long", %{conn: conn} do
    {build, _id} = add(house(), "Driveway", "ev", %{"miles" => "200", "charger" => "l1"})
    view = open(conn, ~p"/power", build)
    html = render(view)
    assert html =~ "200 miles in one day: the home charge is"
    assert html =~ "The charger cannot give it in one day"

    car = item(view, "ev")

    assert render_patch(view, ~p"/inside?item=#{car.id}") =~
             "the cost of the home charge next to gas"

    view = open(conn, ~p"/power", flag(build, "ev", :planned))
    html = render(view)

    assert has_element?(
             view,
             "#plan-others",
             "Electric car: they change the bill of one year by +$"
           )

    assert html =~ "The home charge costs"
    assert html =~ "less than the gas"
    refute has_element?(view, "#payback")

    {build, _id} =
      add(house(), "Driveway", "ev", %{"miles" => "5", "mpg" => "50", "gas" => "0.5"})

    view = open(conn, ~p"/power", flag(build, "ev", :planned))
    assert render(view) =~ "more than the gas"
  end

  test "the features of the panels and of a switch", %{conn: conn} do
    {build, panels} = add(house(), "Roof", "solar_panels")
    {build, switch} = add(build, "Garage", "transfer_switch")
    view = open(conn, ~p"/inside?item=#{panels}", build)
    assert render(view) =~ "the power of the sun"
    assert render_patch(view, ~p"/inside?item=#{switch}") =~ "the permit notes"
  end

  test "a house with no estimate yet", %{conn: conn} do
    {house, rooms, []} =
      House.scratch(%{size: 1800, year: 2026, floors: 1, heat: "gas", lot: nil})

    {:ok, plan} = Build.choose_door(Build.new(), "planning")
    {:ok, plan} = Build.set_zip(plan, "75070")
    {plan, _id} = add(Build.put_house(plan, house, rooms, []), "Backyard", "ac")
    view = open(conn, ~p"/power", flag(plan, "ac", :planned))
    assert render(view) =~ "The page shows the power when the house has its estimate."
  end
end
