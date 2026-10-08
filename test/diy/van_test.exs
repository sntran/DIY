defmodule DIY.VanTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, Estimate, House, Stubs, Van, Weather}

  defp climate do
    {:ok, climate} = Weather.parse(Stubs.power(), 33.25, -96.75, 2016, 2025)
    climate
  end

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 2000, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id

  # A house with a camper van in the driveway.
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

  defp van(build, id) do
    {:ok, van} = Build.item(build, id)
    van
  end

  describe "the build of a van" do
    test "a van gets its zones, and its numbers are typical of its model" do
      {build, id} = with_van()
      van = van(build, id)
      assert van.typical
      assert van.params["model"] == "promaster_159"
      zones = Build.zones(build, id)
      assert Enum.map(zones, & &1.place) == Keyword.keys(Catalog.zones())
      assert Enum.all?(zones, &(&1.level == "van:" <> id))
      assert Build.zone(build, id, :bay).name == "Electrical bay"
      assert Build.zone(build, "i999", :bay) == nil

      # The house has no zone and no item of a van.
      {build, _fridge} = add(build, id, :galley, "van_fridge")
      house = Build.house_view(build)
      refute Enum.any?(house.rooms, &Build.van_level?(&1.level))
      refute Enum.any?(house.items, &(&1.type == "van_fridge"))
      assert Enum.any?(house.items, &(&1.type == "camper_van"))

      # The van does not change the estimate of the house.
      climate = climate()

      assert Estimate.run(house, climate).kwh ==
               Estimate.run(Build.house_view(house()), climate).kwh +
                 Estimate.run(house, climate).items[id].year

      assert Estimate.run(house, climate).items[id].year == 0

      assert Build.from_json(Build.to_json(build)) == {:ok, build}
    end

    test "the zones are fixed" do
      {build, id} = with_van()
      bay = Build.zone(build, id, :bay)
      assert Build.rename_room(build, bay.id, "Garage") == {:error, :room}
      assert Build.delete_room(build, bay.id) == {:error, :room}
      assert Build.add_room(build, "Loft", "van:" <> id, :indoor) == {:error, :level}

      # An item of the house cannot go in a zone, and an item of a van cannot
      # go in a room of the house.
      assert Build.add_item(build, bay.id, "fridge") == {:error, :place}
      assert Build.add_item(build, room(build, "Kitchen"), "van_fridge") == {:error, :place}

      # A new number of floors keeps the van.
      assert {:ok, %{house: %{floors: 2}}} = Build.update_house(build, %{floors: 2})
    end

    test "the removal of the van, or of its room, removes its zones and items" do
      {build, id} = with_van()
      {build, _id} = add(build, id, :galley, "van_fridge")
      {:ok, gone} = Build.delete_item(build, id)
      refute Enum.any?(gone.rooms, &Build.van_level?(&1.level))
      refute Enum.any?(gone.items, &(&1.type == "van_fridge"))

      {:ok, gone} = Build.delete_room(build, room(build, "Driveway"))
      assert Van.vans(gone) == []
      refute Enum.any?(gone.rooms, &Build.van_level?(&1.level))
      assert Build.from_json(Build.to_json(gone)) == {:ok, gone}
    end

    test "a station goes from the house to the van, and back" do
      {build, id} = with_van()
      laundry = room(build, "Laundry")
      {:ok, build, station} = Build.add_item(build, laundry, "power_station")
      {:ok, build} = Build.flag_item(build, station, :backup, true)

      {:ok, away} = Build.take_to_van(build, station, id)
      item = van(away, station)
      assert item.room == Build.zone(away, id, :bay).id
      assert item.home == laundry
      refute item.backup
      # The house loses the station while the van has it.
      refute Enum.any?(Build.house_view(away).items, &(&1.id == station))
      assert %{at_home: [], away: [{%{id: ^station}, %{id: ^id}}]} = Van.stations(away)
      assert Build.from_json(Build.to_json(away)) == {:ok, away}

      {:ok, back} = Build.bring_home(away, station)
      assert van(back, station).room == laundry and van(back, station).home == nil
      assert %{at_home: [%{id: ^station}], away: []} = Van.stations(back)

      # Errors: not a station, a station that is not in the house, no van,
      # and a station that is not in a van.
      fridge = Enum.find(build.items, &(&1.type == "fridge")).id
      assert Build.take_to_van(build, fridge, id) == {:error, :item}
      assert Build.take_to_van(away, station, id) == {:error, :room}
      assert Build.take_to_van(build, station, "i999") == {:error, :van}
      assert Build.take_to_van(build, "i999", id) == {:error, :item}
      assert Build.bring_home(build, station) == {:error, :item}
      assert Build.bring_home(build, "i999") == {:error, :item}

      # The van goes: the station goes home. Its home goes: the station
      # stays in the van with no home, and goes back to a room inside.
      {:ok, no_van} = Build.delete_item(away, id)
      assert van(no_van, station).room == laundry

      {:ok, no_home} = Build.delete_room(away, laundry)
      assert van(no_home, station).home == nil
      {:ok, back} = Build.bring_home(no_home, station)
      assert Enum.find(back.rooms, &(&1.id == van(back, station).room)).place == :indoor

      # A station of the van with no home, in a house with no room inside.
      {house, rooms, []} =
        House.scratch(%{size: 900, year: 2000, floors: 1, heat: "gas", lot: nil})

      outside = Build.put_house(house(), house, Enum.filter(rooms, &(&1.place == :outdoor)), [])
      {outside, van_id} = with_van(outside)
      {outside, own} = add(outside, van_id, :bay, "power_station")
      assert Build.bring_home(outside, own) == {:error, :room}
    end

    test "the numbers of a model" do
      {build, id} = with_van()
      {:ok, build} = Build.update_item(build, id, %{"model" => "transit_148"})
      refute van(build, id).typical
      {:ok, build} = Build.van_model(build, id)
      assert %{"gvwr" => 9070, "front_gawr" => 0} = van(build, id).params
      assert van(build, id).typical
      {:ok, build} = Build.update_item(build, id, %{"model" => "other"})
      {:ok, other} = Build.van_model(build, id)
      assert van(other, id).params["gvwr"] == 9070
      fridge = Enum.find(build.items, &(&1.type == "fridge")).id
      assert Build.van_model(build, fridge) == {:error, :item}
    end

    test "a stored build with zones that are not right does not load" do
      {build, id} = with_van()
      {build, station} = add(build, id, :bay, "power_station")
      map = build |> Build.to_json() |> Jason.decode!()
      load = &Build.from_json(Jason.encode!(&1))
      assert {:ok, _} = load.(map)

      zones = for r <- map["rooms"], String.starts_with?(r["level"], "van:"), do: r

      # A zone of no van, a van with a zone that is missing, a zone on a
      # level of the house, and a place of the house on the level of a van.
      no_van = %{map | "items" => Enum.reject(map["items"], &(&1["id"] == id))}
      no_van = %{no_van | "items" => Enum.reject(no_van["items"], &(&1["id"] == station))}
      assert load.(no_van) == {:error, :vans}
      assert load.(%{map | "rooms" => map["rooms"] -- [hd(zones)]}) == {:error, :vans}

      bad_place =
        Enum.map(map["rooms"], fn r ->
          if r["id"] == hd(zones)["id"], do: %{r | "place" => "indoor"}, else: r
        end)

      assert load.(%{map | "rooms" => bad_place}) == {:error, :rooms}

      bad_level =
        Enum.map(map["rooms"], fn r ->
          if r["id"] == hd(zones)["id"], do: %{r | "level" => "f1"}, else: r
        end)

      assert load.(%{map | "rooms" => bad_level}) == {:error, :rooms}

      # A home that is not a room of the house.
      bad_home =
        Enum.map(map["items"], fn i ->
          if i["id"] == station, do: Map.put(i, "home", hd(zones)["id"]), else: i
        end)

      assert load.(%{map | "items" => bad_home}) == {:error, :items}
    end
  end

  describe "the weight budget" do
    test "the weight on each axle, with a lever from the front axle" do
      {build, id} = with_van()

      {:ok, build} =
        Build.update_item(build, id, %{"people" => "2", "person_lb" => "150", "gear_lb" => "100"})

      {build, _} = add(build, id, :bay, "van_battery", %{"weight" => "60"})
      {build, _} = add(build, id, :galley, "water_tank", %{"gallons" => "10", "weight" => "10"})
      w = Van.weight(build, van(build, id))

      # The people in the cab (0.1), the gear under the bed (1.0), the
      # battery in the bay (0.95), the tank in the galley (0.4).
      tank = 10 + 10 * 8.34
      assert_in_delta w.load, 300 + 100 + 60 + tank, 1.0e-9
      rear = 300 * 0.1 + 100 * 1.0 + 60 * 0.95 + tank * 0.4
      assert_in_delta w.rear, 1762 + rear, 1.0e-9
      assert_in_delta w.front, 3133 + w.load - rear, 1.0e-9
      assert w.payload == 8900 - 4895 and w.empty == 4895
      assert w.over == []
      assert {:galley, tank_lb} = List.keyfind(w.zones, :galley, 0)
      assert_in_delta tank_lb, tank, 1.0e-9

      # Over the rating of the van and of the rear axle.
      {heavy, _} = add(build, id, :bed, "storage", %{"weight" => "3000"})
      {heavy, _} = add(heavy, id, :bed, "storage", %{"weight" => "1000"})
      assert Van.weight(heavy, van(heavy, id)).over == [:gvwr, :rear]

      # A rating of 0 is not known: no check of that axle.
      {:ok, unknown} = Build.update_item(heavy, id, %{"rear_gawr" => "0", "front_gawr" => "0"})
      assert Van.weight(unknown, van(unknown, id)).over == [:gvwr]
      {:ok, front} = Build.update_item(build, id, %{"front_gawr" => "3200"})
      assert :front in Van.weight(front, van(front, id)).over
    end

    property "the two axles carry the empty van and the load, and the back takes more on the rear" do
      check all(
              zone <- member_of(Keyword.keys(Catalog.zones())),
              back <- member_of(Keyword.keys(Catalog.zones())),
              pounds <- integer(0..2000)
            ) do
        {build, id} = with_van()
        kind = Enum.find(Catalog.kinds_for(zone), &(&1.type != "power_station"))
        {build, _} = add(build, id, zone, kind.type, %{"weight" => "#{pounds}"})
        w = Van.weight(build, van(build, id))
        assert_in_delta w.front + w.rear, w.empty + w.load, 1.0e-6
        assert_in_delta w.total, w.empty + w.load, 1.0e-6

        # The same weight in a zone more to the back puts more on the rear
        # axle.
        kind2 = Enum.find(Catalog.kinds_for(back), &(&1.type != "power_station"))
        {other, _} = add(with_van() |> elem(0), id, back, kind2.type, %{"weight" => "#{pounds}"})
        w2 = Van.weight(other, van(other, id))

        if Van.place(back) >= Van.place(zone) and kind.type != "water_tank" and
             kind2.type != "water_tank",
           do: assert(w2.rear >= w.rear - 1.0e-6)
      end
    end
  end

  describe "the power budget" do
    test "the use, the sun, the engine, and the days off the grid" do
      {build, id} = with_van()
      {:ok, build} = Build.update_item(build, id, %{"drive_hours" => "0"})
      {build, _} = add(build, id, :galley, "van_fridge", %{"wh_day" => "400"})

      {build, _} =
        add(build, id, :living, "devices", %{"watts" => "90", "hours" => "2", "outlet" => "ac"})

      {build, _} = add(build, id, :bay, "inverter", %{"idle_w" => "10", "hours" => "2"})
      climate = climate()
      van = van(build, id)

      # No battery: no days.
      assert Enum.all?(Van.power(build, van, climate).months, &(&1.days == nil))
      assert Van.power(build, van, nil) == nil

      {build, _} = add(build, id, :bay, "van_battery", %{"ah" => "100", "volts" => "12"})
      power = Van.power(build, van, climate)
      assert_in_delta power.storage, 100 * 12 * 0.9, 1.0e-9
      july = Enum.at(power.months, 6)
      assert_in_delta july.use, 400 + 90 * 2 / 0.9 + 10 * 2, 1.0e-9
      assert july.sun == 0 and july.drive == 0
      assert_in_delta july.days, 1080 / july.use, 1.0e-9

      # Panels on the roof, and the engine.
      {build, _} = add(build, id, :van_roof, "van_solar", %{"watts" => "400"})
      {build, _} = add(build, id, :cab, "dc_charger", %{"amps" => "30"})
      {:ok, build} = Build.update_item(build, id, %{"drive_hours" => "1"})
      power = Van.power(build, van(build, id), climate)
      july = Enum.at(power.months, 6)
      assert_in_delta july.sun, 400 * climate.months[7].sun * 0.8, 1.0e-9
      assert_in_delta july.drive, 30 * 12.8, 1.0e-9
      assert july.days == :unlimited

      # A station and a lead acid battery.
      {build, _} =
        add(build, id, :bed, "van_battery", %{
          "ah" => "100",
          "chemistry" => "agm",
          "volts" => "24"
        })

      {build, _} = add(build, id, :bay, "power_station", %{"kwh" => "1", "extra_kwh" => "0"})
      assert_in_delta Van.power(build, van(build, id), climate).storage, 1080 + 1200 + 950, 1.0e-9
    end

    test "the Wh of each kind in one day" do
      item = fn type, params ->
        %{type: type, params: Map.merge(Catalog.defaults(type), params)}
      end

      assert Van.wh_day(
               item.("stove", %{"fuel" => "induction", "watts" => 1800, "minutes" => 30}),
               7
             ) == 1000.0

      assert Van.wh_day(item.("stove", %{}), 7) == 0.0
      assert Van.wh_day(item.("water_pump", %{"watts" => 60, "minutes" => 10}), 7) == 10.0
      assert Van.wh_day(item.("van_fan", %{}), 7) == 240.0
      assert Van.wh_day(item.("van_fan", %{}), 1) == 0.0
      assert Van.wh_day(item.("diesel_heater", %{}), 1) == 200.0
      assert Van.wh_day(item.("diesel_heater", %{}), 7) == 0.0
      assert Van.wh_day(item.("van_lights", %{}), 7) == 80.0
      assert Van.wh_day(item.("devices", %{}), 7) == 180.0
      assert Van.wh_day(item.("bench", %{}), 7) == 0.0
      assert Van.weight(item.("water_tank", %{"gallons" => 0})) == 10.0
    end

    property "more battery or more panels never give fewer days off the grid" do
      check all(
              ah <- integer(1..400),
              more <- integer(0..400),
              watts <- integer(0..600),
              panels <- integer(0..600)
            ) do
        {build, id} = with_van()
        {build, _} = add(build, id, :galley, "van_fridge", %{"wh_day" => "#{watts + 1}"})
        {build, bank} = add(build, id, :bay, "van_battery", %{"ah" => "#{ah}"})
        {build, sun} = add(build, id, :van_roof, "van_solar", %{"watts" => "#{panels}"})
        climate = climate()
        base = Van.power(build, van(build, id), climate).months

        {:ok, bigger} = Build.update_item(build, bank, %{"ah" => "#{ah + more}"})
        {:ok, sunnier} = Build.update_item(build, sun, %{"watts" => "#{panels + more}"})

        for changed <- [bigger, sunnier] do
          for {a, b} <- Enum.zip(base, Van.power(changed, van(changed, id), climate).months) do
            case {a.days, b.days} do
              {_, :unlimited} -> :ok
              {:unlimited, other} -> flunk("#{inspect(other)}")
              {x, y} -> assert y >= x - 1.0e-9
            end
          end
        end
      end
    end
  end

  test "the safety notes" do
    {build, id} = with_van()
    assert Van.warnings(build, van(build, id)) == []

    {build, battery} = add(build, id, :bay, "van_battery")
    {build, _} = add(build, id, :galley, "stove", %{"fuel" => "propane"})
    {:ok, b} = Build.item(build, battery)
    assert Van.warnings(build, van(build, id)) == [{:fuse, b}, :co, :propane]

    {:ok, build} = Build.update_item(build, battery, %{"fused" => "true"})
    {build, _} = add(build, id, :living, "co_alarm")
    assert Van.warnings(build, van(build, id)) == [:propane]

    # A heater that burns diesel, and an item on an outlet of 120 V with no
    # inverter and no battery.
    {build2, id2} = with_van()
    {build2, _} = add(build2, id2, :bay, "diesel_heater")
    {build2, _} = add(build2, id2, :living, "devices", %{"outlet" => "ac"})
    assert Van.warnings(build2, van(build2, id2)) == [:co, :inverter, :no_battery]
    {build2, _} = add(build2, id2, :bay, "power_station")
    assert Van.warnings(build2, van(build2, id2)) == [:co]
  end
end
