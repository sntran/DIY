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
    assert render_patch(view, ~p"/inside") =~ "On the station"

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
    assert render(view) =~ "No item is on the stations."
    assert render(view) =~ ~r/plug into them:\s+no item yet \(open an item/
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
    assert html =~ "With the range of the bill, the equipment saves"
    assert html =~ "A panel lasts 25 to 35 years."
    refute html =~ "A battery of 3,000 cycles"
    assert html =~ "of sun is lost in one year"

    view |> element("button", "I have the planned items now") |> render_click()
    refute Enum.any?(build(view).items, & &1.planned)
    refute has_element?(view, "#plan")
  end

  test "a plan that does not pay back, and a station in an outage of the plan", %{conn: conn} do
    {build, _id} = add(house(), "Laundry", "power_station", %{"cost" => "2000"})
    build = build |> flag("power_station", :planned) |> flag("fridge", :backup)
    view = open(conn, ~p"/power", build)
    html = render(view)
    # In the mode backup, the battery stays full: the bill is the same.
    assert html =~ "On savings alone, the planned equipment saves no money."
    assert html =~ "A different reason: in an outage"
    assert html =~ "(the month with the fewest hours)"
    assert html =~ "A battery of 3,000 cycles"
    # In the mode night with one price, the station costs more.
    night = Build.set_power(build, %{build.power | mode: "night"})

    assert render(open(conn, ~p"/power", night)) =~
             "On savings alone, the planned equipment does not pay back: it costs"

    # Today the house has no station: the page shows no hours of today.
    refute has_element?(view, "#outage")
    # The planned station is on the item sheet of the fridge.
    fridge = item(view, "fridge")
    assert render_patch(view, ~p"/inside?item=#{fridge.id}") =~ "A power station runs it"
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
