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

      # An item does not move between the house and a van, but it moves
      # between two zones, and between two rooms.
      {:ok, build, station} = Build.add_item(build, room(build, "Laundry"), "power_station")
      assert Build.move_item(build, station, bay.id) == {:error, :place}
      {:ok, away} = Build.take_to_van(build, station, id)
      assert Build.move_item(away, station, room(build, "Garage")) == {:error, :place}
      assert {:ok, _} = Build.move_item(away, station, Build.zone(away, id, :bed).id)
      assert {:ok, _} = Build.move_item(build, station, room(build, "Garage"))

      # A van can go in the garage.
      assert {:ok, _} = Build.move_item(build, id, room(build, "Garage"))
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

      {:ok, away} = Build.take_to_van(build, station, id)
      item = van(away, station)
      assert item.room == Build.zone(away, id, :bay).id
      assert item.home == laundry
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

      # The van goes: the station goes home.
      {:ok, no_van} = Build.delete_item(away, id)
      assert van(no_van, station).room == laundry

      # Its home goes: the station gets a new home in the house (first on
      # the same level), and goes there with the van.
      {:ok, moved} = Build.delete_room(away, laundry)
      home = van(moved, station).home
      assert %{level: "f1", place: :indoor} = Enum.find(moved.rooms, &(&1.id == home))
      assert %{away: [_]} = Van.stations(moved)
      {:ok, no_van} = Build.delete_item(moved, id)
      assert van(no_van, station).room == home

      # The station and the van in the same room: the removal of the room
      # sends the station to its new home.
      driveway = room(build, "Driveway")
      {:ok, both, other} = Build.add_item(build, driveway, "power_station")
      {:ok, both} = Build.take_to_van(both, other, id)
      {:ok, both} = Build.delete_room(both, driveway)
      refute Enum.any?(both.items, &(&1.id == id))
      assert Enum.find(both.rooms, &(&1.id == van(both, other).room)).place == :indoor

      # A station of the van has no home: it does not go to the house.
      {build, own} = add(build, id, :bay, "power_station")
      assert Build.bring_home(build, own) == {:error, :item}
    end

    test "the numbers of a model" do
      {build, id} = with_van()

      # A new model gives its numbers: typical.
      {:ok, build} = Build.update_item(build, id, %{"model" => "transit_148"})
      assert %{"gvwr" => 9070, "front_gawr" => 0} = van(build, id).params
      assert van(build, id).typical

      # A number that is not on the label: still typical. A number of the
      # label: the user checked the numbers.
      {:ok, build} = Build.update_item(build, id, %{"people" => "3"})
      assert van(build, id).typical
      {:ok, build} = Build.update_item(build, id, %{"gvwr" => "9100"})
      refute van(build, id).typical

      # The numbers of the model again.
      {:ok, build} = Build.van_model(build, id)
      assert van(build, id).params["gvwr"] == 9070 and van(build, id).typical

      # Another van: the app has no numbers, and the numbers stay.
      {:ok, other} = Build.update_item(build, id, %{"model" => "other"})
      assert van(other, id).params["gvwr"] == 9070
      fridge = Enum.find(build.items, &(&1.type == "fridge")).id
      assert Build.van_model(build, fridge) == {:error, :item}
    end

    # A house with a van, items in its zones, and a station of the house in
    # the van.
    defp stored do
      {build, id} = with_van()
      {build, _} = add(build, id, :galley, "van_fridge")
      {build, _} = add(build, id, :bay, "van_battery")
      {:ok, build, station} = Build.add_item(build, room(build, "Laundry"), "power_station")
      {:ok, build} = Build.take_to_van(build, station, id)
      {build, id, station}
    end

    test "a van part that is not right does not stop the build from loading" do
      {build, id, station} = stored()
      map = build |> Build.to_json() |> Jason.decode!()
      load = &Build.from_json(Jason.encode!(&1))
      zones = for r <- map["rooms"], String.starts_with?(r["level"], "van:"), do: r
      bay = Build.zone(build, id, :bay).id

      # A zone that is missing: the van gets it again, with a new id, in
      # the order of the zones.
      {:ok, loaded} = load.(%{map | "rooms" => map["rooms"] -- [hd(zones)]})
      assert Enum.map(Build.zones(loaded, id), & &1.place) == Keyword.keys(Catalog.zones())
      refute Enum.any?(loaded.rooms, &(&1.id == hd(zones)["id"]))

      # A zone with no id, or with the id of a room before it, is lost.
      kitchen = room(build, "Kitchen")

      for bad <- [nil, 7, hd(zones)["id"], kitchen] do
        rooms = map["rooms"] ++ [%{hd(zones) | "id" => bad}]
        {:ok, loaded} = load.(%{map | "rooms" => rooms})
        assert length(Build.zones(loaded, id)) == 7
        assert Enum.count(loaded.rooms, &(&1.id == kitchen)) == 1
      end

      # An item of the van with the id of an item of the house, or with no
      # room, goes away.
      fridge = Enum.find(map["items"], &(&1["type"] == "fridge"))
      [battery] = for i <- map["items"], i["type"] == "van_battery", do: i

      for copy <- [%{battery | "id" => fridge["id"]}, Map.delete(battery, "room")] do
        {:ok, loaded} = load.(%{map | "items" => map["items"] ++ [copy]})
        assert Enum.find(loaded.items, &(&1.id == fridge["id"])).type == "fridge"
      end

      # A camper van with flags that are not valid, with no numbers, or in a
      # room where it cannot go (the roof).
      odd = fn van -> %{van | "typical" => "yes", "room" => room(build, "Roof")} end

      odd_van =
        Enum.map(map["items"], &if(&1["id"] == id, do: Map.delete(odd.(&1), "params"), else: &1))

      {:ok, loaded} = load.(%{map | "items" => odd_van})
      assert %{typical: false, params: params, room: room} = van(loaded, id)
      assert params == Catalog.defaults("camper_van")
      assert Enum.find(loaded.rooms, &(&1.id == room)).place in [:outdoor, :indoor]

      # No room where a van can go: the van goes, and its zones.
      roof_only = Enum.filter(map["rooms"], &(&1["place"] == "roof" or &1["level"] =~ "van:"))
      {:ok, loaded} = load.(%{map | "rooms" => roof_only, "items" => odd_van})
      assert Van.vans(loaded) == []
      refute Enum.any?(loaded.rooms, &Build.van_level?(&1.level))

      # A zone with a place that the app does not know: its items go home,
      # or go away.
      lost =
        Enum.map(map["rooms"], &if(&1["id"] == bay, do: %{&1 | "place" => "attic"}, else: &1))

      {:ok, loaded} = load.(%{map | "rooms" => lost})
      assert van(loaded, station).room == room(build, "Laundry")
      refute Enum.any?(loaded.items, &(&1.type == "van_battery"))

      # A model that the app does not know: the default model.
      bad_model =
        Enum.map(map["items"], fn i ->
          if i["id"] == id, do: put_in(i, ["params", "model"], "transit_130"), else: i
        end)

      {:ok, loaded} = load.(%{map | "items" => bad_model})
      assert van(loaded, id).params["model"] == "promaster_159"

      # Numbers that are not a map: the default numbers.
      no_params =
        Enum.map(
          map["items"],
          &if(&1["type"] == "van_battery", do: %{&1 | "params" => "x"}, else: &1)
        )

      {:ok, loaded} = load.(%{map | "items" => no_params})
      assert [%{params: params}] = Enum.filter(loaded.items, &(&1.type == "van_battery"))
      assert params == Catalog.defaults("van_battery")

      # A home on the roof: the first room of the house where a station can
      # go.
      roof = room(build, "Roof")

      on_roof =
        Enum.map(map["items"], &if(&1["id"] == station, do: %{&1 | "home" => roof}, else: &1))

      {:ok, loaded} = load.(%{map | "items" => on_roof})
      home = van(loaded, station).home
      assert Enum.find(loaded.rooms, &(&1.id == home)).place in [:indoor, :outdoor]

      # An item in a room that is not there goes away.
      fridge = Enum.find(map["items"], &(&1["type"] == "fridge"))
      gone = Enum.map(map["items"], &if(&1 == fridge, do: %{&1 | "room" => "r999"}, else: &1))
      {:ok, loaded} = load.(%{map | "items" => gone})
      refute Enum.any?(loaded.items, &(&1.id == fridge["id"]))

      # The part of the house stays strict: a zone on a level of the house,
      # and an item that is not an item.
      bad_level =
        Enum.map(map["rooms"], &if(&1["id"] == bay, do: %{&1 | "level" => "f1"}, else: &1))

      assert load.(%{map | "rooms" => bad_level}) == {:error, :rooms}
      assert load.(%{map | "items" => [1]}) == {:error, :items}
    end

    # A change of the van part of a stored build.
    defp change(map, {:drop_zone, i}, zones, _items),
      do: %{map | "rooms" => map["rooms"] -- [Enum.at(zones, i)]}

    defp change(map, {:zone_place, i, place}, zones, _items),
      do: update(map, "rooms", Enum.at(zones, i)["id"], &Map.put(&1, "place", place))

    defp change(map, {:zone_name, i, name}, zones, _items),
      do: update(map, "rooms", Enum.at(zones, i)["id"], &Map.put(&1, "name", name))

    defp change(map, {:copy_zone, i}, zones, _items) do
      copy = %{Enum.at(zones, i) | "id" => "r#{System.unique_integer([:positive]) + 900}"}
      %{map | "rooms" => map["rooms"] ++ [copy]}
    end

    defp change(map, {:item_room, j, i}, zones, items),
      do:
        update(
          map,
          "items",
          Enum.at(items, j)["id"],
          &Map.put(&1, "room", Enum.at(zones, i)["id"])
        )

    defp change(map, {:item_type, j, type}, _zones, items),
      do:
        update(map, "items", Enum.at(items, j)["id"], fn item ->
          # An item in a room of the house is a part of the house.
          if item["room"] == "r7", do: item, else: Map.put(item, "type", type)
        end)

    defp change(map, {:item_param, j, key, value}, _zones, items) do
      update(map, "items", Enum.at(items, j)["id"], fn
        %{"params" => %{} = params} = item -> %{item | "params" => Map.put(params, key, value)}
        item -> item
      end)
    end

    # An item of a kind that goes only in a van, in a room of the house.
    defp change(map, {:house_room, j}, _zones, items) do
      update(map, "items", Enum.at(items, j)["id"], fn item ->
        if van_only?(item["type"]), do: Map.put(item, "room", "r7"), else: item
      end)
    end

    defp change(map, {:no_key, j, key}, _zones, items) do
      update(map, "items", Enum.at(items, j)["id"], fn item ->
        if item["room"] == "r7", do: item, else: Map.delete(item, key)
      end)
    end

    defp change(map, :van_no_id, _zones, [van | _items]),
      do: update(map, "items", van["id"], &Map.delete(&1, "id"))

    defp change(map, {:home, j, home}, _zones, items),
      do: update(map, "items", Enum.at(items, j)["id"], &Map.put(&1, "home", home))

    defp van_only?(type) do
      case Catalog.kind(type) do
        %{places: places} -> not Enum.any?(places, &(&1 in [:indoor, :outdoor, :roof]))
        nil -> false
      end
    end

    defp update(map, key, id, fun),
      do: Map.update!(map, key, &Enum.map(&1, fn x -> if x["id"] == id, do: fun.(x), else: x end))

    property "a change of the van part gives a build that loads, with the same house" do
      {build, id, station} = stored()
      map = build |> Build.to_json() |> Jason.decode!()
      zones = for r <- map["rooms"], String.starts_with?(r["level"], "van:"), do: r
      # The van (the first), and the items in its zones. The type of the van
      # is a part of the house: it does not change.
      items =
        for i <- map["items"], i["id"] == id or i["room"] in Enum.map(zones, & &1["id"]), do: i

      z = integer(0..(length(zones) - 1))
      j = integer(0..(length(items) - 1))
      k = integer(1..(length(items) - 1))
      text = one_of([constant("attic"), constant(""), constant(nil), string(:alphanumeric)])
      value = one_of([text, integer(), constant(-1.5)])
      key = member_of(~w(model gvwr people ah volts chemistry wh_day kwh weight fused))

      steps =
        list_of(
          one_of([
            tuple({constant(:drop_zone), z}),
            tuple(
              {constant(:zone_place), z, one_of([text, constant("bay"), constant("indoor")])}
            ),
            tuple({constant(:zone_name), z, value}),
            tuple({constant(:copy_zone), z}),
            tuple({constant(:item_room), j, z}),
            tuple({constant(:item_type), k, one_of([text, constant("fridge")])}),
            tuple({constant(:item_param), j, key, value}),
            tuple(
              {constant(:home), j, one_of([text, member_of(Enum.map(build.rooms, & &1.id))])}
            ),
            tuple({constant(:house_room), k}),
            tuple({constant(:no_key), k, member_of(~w(id type room params typical))}),
            constant(:van_no_id)
          ]),
          min_length: 1,
          max_length: 5
        )

      house = Build.house_view(build)
      house_items = Enum.reject(house.items, &(&1.type == "camper_van"))

      check all(steps <- steps) do
        changed = Enum.reduce(steps, map, &change(&2, &1, zones, items))
        assert {:ok, loaded} = Build.from_json(Jason.encode!(changed))

        # The house is the same, and the station of the house is there.
        assert Build.house_view(loaded).rooms == house.rooms
        assert Enum.all?(house_items, &(&1 in loaded.items))
        touched = for {_, j, _} <- steps, do: Enum.at(items, j)["id"]
        assert station in touched or Enum.any?(loaded.items, &(&1.id == station))

        # Each van has each zone one time, and each zone has its van.
        for van <- Van.vans(loaded) do
          places = Enum.map(Build.zones(loaded, van.id), & &1.place)
          assert Enum.sort(places) == Enum.sort(Keyword.keys(Catalog.zones()))
        end

        vans = MapSet.new(Van.vans(loaded), &Build.van_level(&1.id))

        assert Enum.all?(loaded.rooms, &(not Build.van_level?(&1.level) or &1.level in vans))
        assert Build.from_json(Build.to_json(loaded)) == {:ok, loaded}
      end
    end
  end

  # Any term of JSON.
  defp json_term do
    one_of([
      constant(nil),
      boolean(),
      integer(),
      float(),
      string(:printable, max_length: 8),
      constant("van:i1"),
      list_of(integer(), max_length: 2),
      map_of(string(:alphanumeric, max_length: 4), integer(), max_length: 2)
    ])
  end

  # A change of a key of a map: a new term, or no key.
  defp change_key(map, key, :delete) when is_map(map), do: Map.delete(map, key)
  defp change_key(map, key, {:set, value}) when is_map(map), do: Map.put(map, key, value)
  defp change_key(other, _key, _how), do: other

  defp change_at(list, i, fun) when is_list(list) and list != [],
    do: List.update_at(list, rem(i, length(list)), fun)

  defp change_at(list, _i, _fun), do: list

  property "from_json never raises, for each change of a stored build" do
    {build, _id, _station} = stored()
    map = build |> Build.to_json() |> Jason.decode!()
    keys = ~w(id type room level place name typical planned backup home params)
    how = one_of([constant(:delete), tuple({constant(:set), json_term()})])

    steps =
      list_of(
        one_of([
          tuple({constant(:top), member_of(Map.keys(map)), how}),
          tuple({constant(:room), integer(0..40), member_of(keys), how}),
          tuple({constant(:item), integer(0..40), member_of(keys), how}),
          tuple({constant(:param), integer(0..40), string(:alphanumeric, max_length: 6), how}),
          tuple({constant(:whole), member_of(["rooms", "items"]), integer(0..40), json_term()})
        ]),
        min_length: 1,
        max_length: 6
      )

    check all(steps <- steps, max_runs: 300) do
      changed =
        Enum.reduce(steps, map, fn
          {:top, key, how}, map ->
            change_key(map, key, how)

          {:room, i, key, how}, map ->
            Map.update(map, "rooms", [], &change_at(&1, i, fn r -> change_key(r, key, how) end))

          {:item, i, key, how}, map ->
            Map.update(map, "items", [], &change_at(&1, i, fn r -> change_key(r, key, how) end))

          {:param, i, key, how}, map ->
            Map.update(map, "items", [], fn items ->
              change_at(items, i, fn
                %{"params" => p} = item when is_map(p) ->
                  %{item | "params" => change_key(p, key, how)}

                item ->
                  item
              end)
            end)

          {:whole, key, i, value}, map ->
            Map.update(map, key, [], &change_at(&1, i, fn _ -> value end))
        end)

      case Build.from_json(Jason.encode!(changed)) do
        {:ok, %Build{} = loaded} -> assert Build.from_json(Build.to_json(loaded)) == {:ok, loaded}
        {:error, _reason} -> :ok
      end
    end
  end

  test "the estimate and the power of the house do not count the van" do
    {build, id} = with_van()
    {build, _} = add(build, id, :galley, "van_fridge")
    {build, _} = add(build, id, :bay, "power_station")
    climate = climate()
    estimate = Estimate.run(build, climate)
    assert estimate == Estimate.run(Build.house_view(build), climate)

    assert DIY.Power.run(build, estimate, climate, 14.0) ==
             DIY.Power.run(Build.house_view(build), estimate, climate, 14.0)
  end

  describe "the weight budget" do
    test "the weight on each axle, with a lever from the place of each item" do
      {build, id} = with_van()

      {:ok, build} =
        Build.update_item(build, id, %{"people" => "2", "person_lb" => "150", "gear_lb" => "100"})

      {build, _} = add(build, id, :bay, "van_battery", %{"weight" => "60"})

      {build, tank_id} =
        add(build, id, :galley, "water_tank", %{"gallons" => "10", "weight" => "10"})

      van = van(build, id)
      w = Van.weight(build, van)

      # A ProMaster 159: 236 in long, the front axle 41 in from the front,
      # and the doors at the back 3 in thick. On the plan, the bed is from
      # 0 to 61 in, the bay from 61 in, the galley from 115 in, and the cab
      # from 146 to 182 in. The people sit at the middle of the cab (164),
      # the gear is at the middle of the bed (30.5), the battery (7 in
      # deep) at 64.5 and the tank (15 in deep) at 122.5.
      lever = fn y -> (236 - 3 - y - 41) / 159 end
      assert_in_delta Van.lever(van, 30.5), lever.(30.5), 1.0e-9
      tank = 10 + 10 * 8.34
      assert_in_delta w.load, 300 + 100 + 60 + tank, 1.0e-9

      rear =
        300 * lever.(164) + 100 * lever.(30.5) + 60 * lever.(64.5) + tank * lever.(122.5)

      assert_in_delta w.rear, 1762 + rear, 1.0e-9
      assert_in_delta w.front, 3133 + w.load - rear, 1.0e-9
      assert w.payload == 8900 - 4895 and w.empty == 4895
      assert w.over == []
      assert {:galley, tank_lb} = List.keyfind(w.zones, :galley, 0)
      assert_in_delta tank_lb, tank, 1.0e-9

      # The tank goes to the front of the galley: more weight on the front
      # axle. The bed is behind the rear axle: its gear takes some weight
      # off the front axle.
      {:ok, front_tank} =
        Build.place_item(build, tank_id, Build.zone(build, id, :galley).id, %{x: 0, y: 16})

      assert Van.weight(front_tank, van).front > w.front
      assert lever.(30.5) > 1

      # An item of the shell is at the middle of the van (91 in).
      {walls, _} = add(build, id, :shell, "walls", %{"weight" => "100"})
      assert_in_delta Van.weight(walls, van).rear, w.rear + 100 * lever.(91), 1.0e-9

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

        kind =
          Enum.find(Catalog.kinds_for(zone), &(&1.type not in ["power_station", "water_tank"]))

        {build, a} = add(build, id, zone, kind.type, %{"weight" => "#{pounds}"})
        w = Van.weight(build, van(build, id))
        assert_in_delta w.front + w.rear, w.empty + w.load, 1.0e-6
        assert_in_delta w.total, w.empty + w.load, 1.0e-6

        # The same weight at a place more to the back (a smaller y on the
        # plan) puts more on the rear axle.
        kind2 =
          Enum.find(Catalog.kinds_for(back), &(&1.type not in ["power_station", "water_tank"]))

        {other, b} = add(with_van() |> elem(0), id, back, kind2.type, %{"weight" => "#{pounds}"})
        w2 = Van.weight(other, van(other, id))

        if along(other, b) <= along(build, a), do: assert(w2.rear >= w.rear - 1.0e-6)
      end
    end
  end

  # The place along the van of an item (as DIY.Van): the middle of the item
  # on the plan, or the middle of the van for an item of the shell.
  defp along(build, id) do
    {:ok, item} = Build.item(build, id)
    {:ok, zone} = Build.room(build, item.room)
    "van:" <> van_id = zone.level
    {:ok, van} = Build.item(build, van_id)

    case {item.at, zone.plan} do
      {%{y: y}, %{y: zone_y}} -> zone_y + y + elem(DIY.Layout.extent(item), 1) / 2
      _shell -> DIY.Layout.van_box(van).d / 2
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

      # The charge of the engine is at the voltage of the batteries.
      [battery] = for {_zone, %{type: "van_battery"} = b} <- Van.items(build, id), do: b.id
      {:ok, high} = Build.update_item(build, battery, %{"volts" => "24"})

      assert_in_delta Enum.at(Van.power(high, van(high, id), climate).months, 6).drive,
                      30 * 25.6,
                      1.0e-9

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
    {build, second} = add(build, id, :bed, "van_battery")
    {build, _} = add(build, id, :galley, "stove", %{"fuel" => "propane"})
    {:ok, b} = Build.item(build, battery)
    {:ok, b2} = Build.item(build, second)

    assert Van.warnings(build, van(build, id)) ==
             [{:fuse, b2, 1}, {:fuse, b, 2}, :air, :co, :propane]

    {:ok, build} = Build.update_item(build, battery, %{"fused" => "true"})
    {:ok, build} = Build.update_item(build, second, %{"fused" => "true"})
    {build, _} = add(build, id, :living, "co_alarm")
    assert Van.warnings(build, van(build, id)) == [:air, :propane]

    # A heater that burns diesel, and an item on an outlet of 120 V with no
    # inverter and no battery.
    {build2, id2} = with_van()
    {build2, _} = add(build2, id2, :bay, "diesel_heater")
    {build2, _} = add(build2, id2, :living, "devices", %{"outlet" => "ac"})
    assert Van.warnings(build2, van(build2, id2)) == [:air, :co, :heater, :inverter, :no_battery]
    {build2, _} = add(build2, id2, :bay, "power_station")
    assert Van.warnings(build2, van(build2, id2)) == [:air, :co, :heater]

    # An induction stove of 1,800 W on an inverter of 300 W.
    {build3, id3} = with_van()
    {build3, _} = add(build3, id3, :galley, "stove", %{"fuel" => "induction", "watts" => "1800"})
    {build3, _} = add(build3, id3, :bay, "inverter", %{"watts" => "300"})
    {build3, _} = add(build3, id3, :bay, "van_battery", %{"fused" => "true"})
    assert Van.warnings(build3, van(build3, id3)) == [{:output, 1800, 300}]
  end
end
