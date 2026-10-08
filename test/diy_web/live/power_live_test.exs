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
    _ = :sys.get_state(view.pid)
    Process.sleep(20)
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
    assert render_patch(view, ~p"/power") =~ "What feeds what"

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
    assert html =~ ~r/by plug:\s+Fridge\./
    assert html =~ "In an outage"
    assert html =~ "Jul:"
    assert html =~ "needs 2 to 3 times its power"
    refute has_element?(view, "#backfeed")
    refute has_element?(view, "#permit")

    # A bad flag, or a flag of an item that is not there, changes nothing.
    render_change(view, "flag", %{"item_id" => "i999", "planned" => "true"})
    render_change(view, "flag", %{"item_id" => fridge.id, "planned" => "maybe"})
    refute item(view, "fridge").planned
  end

  test "a station with no item, and no station on the page", %{conn: conn} do
    {build, _id} = add(house(), "Laundry", "power_station")
    view = open(conn, ~p"/power", build)
    assert render(view) =~ "No item is on the stations."
    assert render(view) =~ ~r/by plug:\s+no item yet \(open an item/
  end

  test "a station that powers the panel: the danger of backfeed, the permit, the steps", %{
    conn: conn
  } do
    {build, id} =
      add(house(), "Garage", "power_station", %{"feeds" => "panel", "output_w" => "200"})

    build = build |> flag("fridge", :backup) |> flag("ac", :backup)
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "#backfeed")
    assert has_element?(view, "#permit")
    assert has_element?(view, "#overload")
    refute has_element?(view, "#outage-steps")
    assert render(view) =~ "an inlet → the backup circuits"

    {build, _switch} = add(build, "Garage", "transfer_switch")
    view = open(conn, ~p"/power", build)
    refute has_element?(view, "#backfeed")
    assert has_element?(view, "#outage-steps")
    assert render(view) =~ "the interlock keeps them apart"

    switch = Enum.find(build.items, &(&1.type == "transfer_switch"))
    {:ok, build} = Build.update_item(build, switch.id, %{"device" => "transfer"})
    view = open(conn, ~p"/power", build)
    assert render(view) =~ "the switch moves from the grid to the station"
    assert id
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

    html = render_patch(view, ~p"/power")
    assert has_element?(view, "#plan-months")
    assert html =~ "They cost $800"
    assert html =~ "it pays back in"
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
    assert html =~ "On savings alone, the plan does not pay back"
    assert html =~ "A different reason: in an outage"
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
    assert render(view) =~ "The planned car saves"
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
