defmodule DIYWeb.VanLiveTest do
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

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id
  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build

  defp with_van(build \\ house()) do
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway"), "camper_van")
    {build, van}
  end

  defp add(build, van, zone, type, params \\ %{}) do
    zone = Build.zone(build, van, zone)
    {:ok, build, id} = Build.add_item(build, zone.id, type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  test "no van: the page says how to add one, and the nav has no van", %{conn: conn} do
    view = open(conn, ~p"/van", house())
    assert has_element?(view, "#no-van")
    refute has_element?(view, "nav a", "Van")
  end

  test "a van in the driveway opens its own build", %{conn: conn} do
    build = house()
    view = open(conn, ~p"/inside?add=#{room(build, "Driveway")}", build)
    view |> element("#add-camper_van") |> render_click()
    [van] = DIY.Van.vans(build(view))
    assert_patch(view, ~p"/inside?item=#{van.id}")
    assert has_element?(view, "nav a", "Van")

    view |> element("#open-van") |> render_click()
    assert_patch(view, ~p"/van?id=#{van.id}")
    assert has_element?(view, "#van-weight")
    assert has_element?(view, "#van-power")
    assert has_element?(view, "#van-zones article", "Galley")
    assert render(view) =~ "Ram ProMaster 2500, 159 in, high roof"
    assert render(view) =~ "These numbers are typical of the model"
    assert has_element?(view, "#weight-total", "of 8,900 lb")

    # The van does not change the bill of the house.
    assert render_patch(view, ~p"/estimate") =~ "Camper van"
  end

  test "the items of the zones, their numbers, and the safety notes", %{conn: conn} do
    {build, van} = with_van()
    galley = Build.zone(build, van, :galley)
    view = open(conn, ~p"/van?#{[id: van, add: galley.id]}", build)
    assert has_element?(view, "#add-sheet", "Add to Galley")
    view |> element("#add-stove") |> render_click()
    [{_zone, stove}] = DIY.Van.items(build(view), van)
    assert_patch(view, ~p"/van?#{[id: van, item: stove.id]}")
    assert has_element?(view, "#item-sheet", "Stove")
    assert has_element?(view, "#item-sheet", "the safety notes of the van")
    assert has_element?(view, "#van-notes", "carbon monoxide")
    assert has_element?(view, "#van-notes", "heavier than air")

    # A change of the numbers, and the check of the numbers.
    view
    |> form("#item-form", %{"item_id" => stove.id, "item" => %{"fuel" => "induction"}})
    |> render_change()

    assert has_element?(view, "#van-notes", "needs an inverter or a power station")
    refute has_element?(view, "#van-notes", "carbon monoxide")

    # A battery with no fuse.
    bay = Build.zone(build(view), van, :bay)
    render_click(view, "add_item", %{"room" => bay.id, "type" => "van_battery"})
    assert has_element?(view, "#van-notes", "Battery 1 (200 Ah, 12 V) has no fuse")
    assert render(view) =~ "The batteries keep 2,160 Wh."

    # The item goes: the page shows the van again.
    view |> element("#van-item-#{stove.id}") |> render_click()
    view |> element("#delete-item") |> render_click()
    assert_patch(view, ~p"/van?#{[id: van]}")
    refute Enum.any?(build(view).items, &(&1.id == stove.id))

    # An item that is not in the van, and a zone of no van: no sheet.
    render_patch(view, ~p"/van?#{[id: van, item: "i999", add: "r999"]}")
    refute has_element?(view, "#item-sheet")
    refute has_element?(view, "#add-sheet")
  end

  test "the numbers of the van, and the numbers of its model", %{conn: conn} do
    {build, van} = with_van()
    view = open(conn, ~p"/van?#{[id: van]}", build)
    view |> element("#van-numbers") |> render_click()
    assert has_element?(view, "#item-sheet", "Camper van")

    view
    |> form("#item-form", %{"item_id" => van, "item" => %{"model" => "transit_148"}})
    |> render_change()

    view |> element("#van-model") |> render_click()
    assert render(view) =~ "Ford Transit 250"
    assert render(view) =~ "The app does not know the rating of an axle of this model"
    view |> element("#item-sheet button", "Correct") |> render_click()
    refute render(view) =~ "These numbers are typical of the model"
  end

  test "the budgets: over the weight, and the days off the grid", %{conn: conn} do
    {build, van} = with_van()
    {build, _} = add(build, van, :bed, "storage", %{"weight" => "3000"})
    {build, _} = add(build, van, :bed, "storage", %{"weight" => "1000"})
    {build, _} = add(build, van, :galley, "van_fridge")
    view = open(conn, ~p"/van?#{[id: van]}", build)
    assert has_element?(view, "#weight-total", "over")
    assert has_element?(view, "#weight-rear", "over")
    assert render(view) =~ "more than the van can take"
    assert render(view) =~ "The van has no battery yet."
    refute render(view) =~ "keep 0 Wh"

    {build, _} = add(build, van, :bay, "van_battery", %{"ah" => "100", "fused" => "true"})
    view = open(conn, ~p"/van?#{[id: van]}", build)

    assert render(view) =~
             ~r/Off the grid: \d+\.\d days in [A-Z][a-z]+, the month with the fewest days/

    {large, _} = add(build, van, :bay, "van_battery", %{"ah" => "2000", "fused" => "true"})
    assert render(open(conn, ~p"/van?#{[id: van]}", large)) =~ "30 days or more"

    {sunny, _} = add(build, van, :van_roof, "van_solar", %{"watts" => "2000"})
    assert render(open(conn, ~p"/van?#{[id: van]}", sunny)) =~ "no limit off the grid"

    # With no weather, no power budget. (A ZIP code that no other test
    # uses: the app keeps the weather of each place.)
    Stubs.weather(503)
    {:ok, far} = Build.set_zip(build, "59801")
    view = open(conn, ~p"/van?#{[id: van]}", far)
    assert render(view) =~ "The power shows when the app has the weather of your place."
  end

  test "a station goes from the house to the van, and back", %{conn: conn} do
    {build, van} = with_van()
    {:ok, build, station} = Build.add_item(build, room(build, "Laundry"), "power_station")
    view = open(conn, ~p"/van?#{[id: van]}", build)
    assert has_element?(view, "#van-stations", "at home")

    view |> element("#van-stations button", "Take it in this van") |> render_click()
    assert has_element?(view, "#van-stations", "in this van")
    assert has_element?(view, "#van-zones", "Power station")
    assert render(view) =~ "The batteries keep 1,900 Wh."

    # The house shows it as away, in its room and on the page Power.
    render_patch(view, ~p"/inside")
    assert has_element?(view, "#away-#{station}", "in the van now")
    render_patch(view, ~p"/power")
    assert has_element?(view, "#power-away", "Power station (2 kWh) is in the van now")
    view |> element("#power-away a", "Open the van") |> render_click()
    assert_patch(view, ~p"/van?#{[id: van]}")
    render_patch(view, ~p"/van?#{[id: van, item: station]}")
    view |> element("#item-sheet button", "Bring it home") |> render_click()
    assert has_element?(view, "#van-stations", "at home")

    # Two vans: each has its link, and a station in the other van.
    {build, other} = with_van(build(view))
    {:ok, build} = Build.take_to_van(build, station, other)
    view = open(conn, ~p"/van?#{[id: van]}", build)
    assert has_element?(view, "nav[aria-label='The vans'] a", "Van 2")
    assert has_element?(view, "#van-stations", "in another van")
    view |> element("#van-stations button", "Bring it home") |> render_click()
    assert %{at_home: [_], away: []} = DIY.Van.stations(build(view))
  end

  test "the main panel of the house does not feed the van", %{conn: conn} do
    build = house()
    {:ok, build, _} = Build.add_item(build, room(build, "Roof"), "solar_panels")
    feeds = &Regex.run(~r/The main panel feeds (\d+) items/, render(open(conn, ~p"/power", &1)))
    {with_van, van} = with_van(build)
    {with_van, _} = add(with_van, van, :galley, "van_fridge")
    assert [_, n] = feeds.(build)
    assert [_, ^n] = feeds.(with_van)
  end

  test "the notes of a heater and of a small inverter, and an empty weight that is too large",
       %{conn: conn} do
    {build, van} = with_van()
    {build, _} = add(build, van, :bay, "diesel_heater")
    {build, _} = add(build, van, :galley, "stove", %{"fuel" => "induction", "watts" => "1800"})
    {build, _} = add(build, van, :bay, "inverter", %{"watts" => "300"})
    {:ok, build} = Build.update_item(build, van, %{"front_empty" => "9000"})
    view = open(conn, ~p"/van?#{[id: van]}", build)
    assert has_element?(view, "#van-notes", "takes its air from outside the van")

    assert has_element?(
             view,
             "#van-notes",
             "need 1,800 W, and the inverters and the stations give 300 W"
           )

    assert has_element?(view, "#van-weight", "is not less than the rating")
    refute has_element?(view, "#van-weight", "The van can take")
    # A number of the label: the user checked the numbers.
    refute render(view) =~ "These numbers are typical of the model"
  end

  test "the numbers of another van, and the source of the numbers of a model", %{conn: conn} do
    {build, van} = with_van()
    view = open(conn, ~p"/van?#{[id: van, item: van]}", build)
    assert has_element?(view, "#van-source", "Autopadre")
    assert has_element?(view, "#item-sheet", "typical of the model")

    view
    |> form("#item-form", %{"item_id" => van, "item" => %{"model" => "other"}})
    |> render_change()

    refute has_element?(view, "#van-model")
    refute has_element?(view, "#van-source")
    assert render(view) =~ "The app does not have the numbers of this van: the numbers now are"
  end

  test "the page of the rooms shows the features of a van only with a van", %{conn: conn} do
    build = house()
    {:ok, build, station} = Build.add_item(build, room(build, "Laundry"), "power_station")
    view = open(conn, ~p"/inside?item=#{station}", build)
    refute has_element?(view, "#item-sheet", "the weight budget of the van")
    refute has_element?(view, "#item-form input[name='item[weight]']")

    {build, van} = with_van(build)
    view = open(conn, ~p"/inside?item=#{station}", build)
    assert has_element?(view, "#item-sheet", "the weight budget of the van")
    assert has_element?(view, "#item-form input[name='item[weight]']")

    # The van itself: no station runs it, and its numbers are of its model.
    render_patch(view, ~p"/inside?item=#{van}")
    refute has_element?(view, "#flags-form input[name=backup]")
    assert has_element?(view, "#item-sheet", "typical of the model")
  end

  test "a station in the van: the page Power of the house tells it", %{conn: conn} do
    {build, van} = with_van()
    {:ok, build, station} = Build.add_item(build, room(build, "Laundry"), "power_station")
    {:ok, build} = Build.take_to_van(build, station, van)
    view = open(conn, ~p"/power", build)
    assert has_element?(view, "nav a", "Power")
    assert has_element?(view, "#power-away", "is in the van now")
    refute has_element?(view, "#no-equipment")

    # The buttons tell which station.
    render_patch(view, ~p"/van?#{[id: van]}")

    assert has_element?(
             view,
             "#van-stations button[aria-label='Bring it home: Power station (2 kWh)']"
           )

    # A station of the van does not show the page Power.
    {own, other} = with_van()
    {:ok, own, _} = Build.add_item(own, Build.zone(own, other, :bay).id, "power_station")
    refute has_element?(open(conn, ~p"/", own), "nav a", "Power")
  end

  test "an item of a van does not open on the page of the rooms", %{conn: conn} do
    {build, van} = with_van()
    {build, fridge} = add(build, van, :galley, "van_fridge")
    view = open(conn, ~p"/inside?item=#{fridge}", build)
    refute has_element?(view, "#item-sheet")

    # The item of a house goes back to the rooms after its removal.
    kitchen = Enum.find(build.items, &(&1.type == "fridge"))
    render_patch(view, ~p"/inside?item=#{kitchen.id}")
    view |> element("#delete-item") |> render_click()
    assert_patch(view, ~p"/inside")
    assert render_click(view, "delete_item", %{"id" => "i999"})
  end
end
