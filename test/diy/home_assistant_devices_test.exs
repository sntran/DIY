defmodule DIY.HomeAssistantDevicesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, HomeAssistant, House, Layout}

  # A build with the preset of a house.
  defp preset do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room_named(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  defp device(id, name, area, domains \\ [], model \\ nil),
    do: %{id: id, name: name, area: area, domains: domains, model: model}

  defp kind(name, domains \\ [], model \\ nil),
    do: HomeAssistant.kind_of(device("d", name, nil, domains, model))

  test "the kind of a device: the words of its name, then of its model, then its domains" do
    assert kind("Kitchen Lights") == "lights"
    assert kind("Bed lamp") == "lights"
    assert kind("Living Room TV") == "tv"
    assert kind("Fridge Plug") == "fridge"
    assert kind("Garage Freezer") == "freezer"
    assert kind("Washing Machine") == "washer"
    assert kind("Dishwasher") == "dishwasher"
    assert kind("Dryer") == "dryer"
    assert kind("Microwave") == "microwave"
    assert kind("Oven") == "range"
    assert kind("Office PC") == "computer"
    assert kind("CPAP") == "cpap"
    assert kind("EV Charger") == "ev"
    assert kind("Pool pump") == "pool_pump"
    # Two words that make one appliance.
    assert kind("Microwave Oven") == "microwave"
    assert kind("Dish washer") == "dishwasher"
    assert kind("Washer Dryer") == "dryer"
    assert kind("Fridge Freezer") == "fridge"
    assert kind("TV backlight") == "lights"
    # The last word wins, and of two words that end at one place, the
    # longer one: a water heater is not a space heater.
    assert kind("TV Room Lights") == "lights"
    assert kind("Ceiling Fan Light") == "lights"
    assert kind("Water Heater") == "water_heater"
    assert kind("Bathroom Heater") == "space_heater"
    # Two words as one, and a word with an "s" at its end.
    assert kind("HeatPump") == "mini_split"
    assert kind("Waterheater") == "water_heater"
    assert kind("Fans") == "ceiling_fan"
    assert kind("AC") == "mini_split"
    # A word in a different word does not count.
    assert kind("Acoustic panel") == nil
    assert kind("Dishwashers") == "dishwasher"
    # The model, then the domains.
    assert kind("Kitchen", [], "Smart Fridge 2") == "fridge"
    assert kind("Hall", ["light"]) == "lights"
    assert kind("Hall", ["sensor", "fan"]) == "ceiling_fan"
    assert kind("Tank", ["water_heater"]) == "water_heater"
    # A thermostat, a speaker or a plug with no word: no kind.
    assert kind("Ecobee", ["climate"]) == nil
    assert kind("Hvac", ["climate"]) == nil
    assert kind("Speaker", ["media_player"]) == nil
    assert kind("Plug 3", ["switch", "sensor"]) == nil
    assert kind("", []) == nil
    # A long name: the last phrase wins, at its place in the words.
    many = String.duplicate("a ", 126)
    assert kind(many <> "TV") == "tv"
    assert kind("TV " <> many) == "tv"
    assert kind("Water " <> many <> "heater") == "space_heater"
    assert kind(many) == nil
  end

  test "a power station of Pecron or EcoFlow: its kind, its model, and the numbers of its item" do
    station = fn maker, name, model ->
      Map.put(device("s", name, "garage", ["sensor", "switch"], model), :station, maker)
    end

    # The maker gives the kind, whatever the name. A device with no maker
    # is not a station.
    assert HomeAssistant.makers() == ["pecron", "ecoflow"]
    assert HomeAssistant.kind_of(station.("pecron", "Kitchen fridge", nil)) == "power_station"
    assert HomeAssistant.station?(station.("ecoflow", "A", nil))
    refute HomeAssistant.station?(device("p", "Plug", nil, ["switch"]))
    refute HomeAssistant.station?(station.(nil, "Plug", nil))
    assert kind("Kitchen fridge") == "fridge"

    # The model of the device gives the model of the catalog of its maker:
    # no case, no spaces, no signs. The name of the maker can come first.
    for text <- ["E3800LFP", "e3800lfp", "PECRON E3800LFP", "Pecron-E3800 LFP"] do
      assert HomeAssistant.station_model("pecron", text) == "pecron_e3800lfp", text
    end

    assert HomeAssistant.station_model("pecron", "F5000LFP") == "pecron_f5000lfp"

    # The names of EcoFlow Cloud and of EcoFlow BLE. The DELTA Pro Ultra X
    # is a different station.
    for {text, key} <- [
          {"DELTA_PRO", "ecoflow_delta_pro"},
          {"DELTA Pro", "ecoflow_delta_pro"},
          {"DELTA_PRO_3", "ecoflow_delta_pro_3"},
          {"Delta Pro 3", "ecoflow_delta_pro_3"},
          {"EcoFlow DELTA Pro 3", "ecoflow_delta_pro_3"},
          {"DELTA Pro Ultra", "ecoflow_delta_pro_ultra"},
          {"Delta Pro Ultra", "ecoflow_delta_pro_ultra"},
          {"DELTA_PRO_ULTRA_X", nil},
          {"Delta 2", nil},
          {"E3800LFP", nil}
        ] do
      assert HomeAssistant.station_model("ecoflow", text) == key, text
    end

    for {maker, text} <- [
          {"pecron", "E3800"},
          {"pecron", "E1500LFP"},
          {"pecron", "DELTA Pro"},
          {"pecron", "ecoflow_delta_pro"},
          {"pecron", ""},
          {"pecron", "pecron"},
          {"pecron", nil},
          {"pecron", 5},
          {"anker", "SOLIX F3800"},
          {nil, "E3800LFP"}
        ] do
      assert HomeAssistant.station_model(maker, text) == nil, inspect({maker, text})
    end

    # The numbers of the item of a ghost: the model of a known station only.
    assert HomeAssistant.device_values(station.("pecron", "A", "E3800LFP"), "power_station") ==
             %{"model" => "pecron_e3800lfp"}

    assert HomeAssistant.device_values(station.("ecoflow", "A", "DELTA_PRO_3"), "power_station") ==
             %{"model" => "ecoflow_delta_pro_3"}

    assert HomeAssistant.device_values(station.("pecron", "A", "E9"), "power_station") == %{}

    assert HomeAssistant.device_values(device("x", "A", nil, [], "E3800LFP"), "power_station") ==
             %{}

    assert HomeAssistant.device_values(station.("pecron", "A", "E3800LFP"), "lights") == %{}

    # The ghost has the numbers, and its item gets the model, its numbers
    # and its size.
    build = preset()
    garage = room_named(build, "Garage")
    areas = [%{id: "garage", name: "Garage", floor: nil}]
    ghost_of = %{station.("ecoflow", "Backup", "DELTA Pro Ultra") | id: "s1"}
    {[ghost], 1} = HomeAssistant.ghosts(build, [ghost_of], areas)

    assert {ghost.type, ghost.values} ==
             {"power_station", %{"model" => "ecoflow_delta_pro_ultra"}}

    {:ok, added, id} =
      Build.add_device(build, garage.id, ghost.type, ghost.device, ghost.at, ghost.values)

    {:ok, item} = Build.item(added, id)

    {_key, _name, numbers, _size, _source} =
      List.keyfind(Catalog.station_models(), "ecoflow_delta_pro_ultra", 0)

    assert Map.take(item.params, Map.keys(numbers)) == numbers
    assert item.params["model"] == "ecoflow_delta_pro_ultra"
    assert added.devices[id] == "s1"
    assert Layout.size(item) == Catalog.station_size("ecoflow_delta_pro_ultra")

    # With no values, the build has one change. A value that the kind does
    # not take adds nothing.
    {:ok, plain, _id} = Build.add_device(build, garage.id, "power_station", "s2")
    assert plain.revision == build.revision + 1
    assert added.revision == build.revision + 2

    assert Build.add_device(build, garage.id, "power_station", "s3", nil, %{"model" => "x"}) ==
             {:error, {:param, "model"}}
  end

  property "each form of the name of a model of Pecron or EcoFlow gives that model" do
    keys =
      for {key, _, _, _, _} <- Catalog.station_models(),
          maker <- HomeAssistant.makers(),
          String.starts_with?(key, maker <> "_"),
          do: {maker, key}

    assert length(keys) == 5

    check all(
            {maker, key} <- member_of(keys),
            prefix <- boolean(),
            upper <- list_of(boolean(), length: 16),
            sign <- member_of(["", " ", "-", "_", "."])
          ) do
      code = key |> String.replace_prefix(maker <> "_", "") |> String.replace("_", "")

      text =
        code
        |> String.graphemes()
        |> Enum.zip(Stream.cycle(upper))
        |> Enum.map_join(sign, fn {char, up} -> if up, do: String.upcase(char), else: char end)

      text = if prefix, do: maker <> " " <> text, else: text
      assert HomeAssistant.station_model(maker, text) == key
    end
  end

  test "a ghost keeps its place while that place is free" do
    build = preset()
    kitchen = room_named(build, "Kitchen")
    living = room_named(build, "Living room")
    areas = [%{id: "a-k", name: "Kitchen", floor: nil}]
    lamp = device("k1", "Lamp", "a-k", ["light"])

    {[ghost], 1} = HomeAssistant.ghosts(build, [lamp], areas)
    assert ghost.room == kitchen.id

    # A free place in its room stays.
    item = %{type: "lights", size: nil, turn: 0, params: Catalog.defaults("lights")}
    {w, d} = Layout.extent(item)

    others =
      for i <- build.items, i.room == kitchen.id, i.at != nil, do: Layout.item_box(i)

    free =
      for(
        y <- 0..(kitchen.plan.d - d)//6,
        x <- 0..(kitchen.plan.w - w)//6,
        box = %{x: x, y: y, w: w, d: d},
        not Enum.any?(others, &Layout.overlap?(&1, box)),
        do: %{x: x, y: y}
      )
      |> Enum.reject(&(&1 == ghost.at))
      |> hd()

    kept = %{"k1" => %{room: kitchen.id, at: free}}
    assert {[%{at: ^free}], 1} = HomeAssistant.ghosts(build, [lamp], areas, kept)

    # A place on an item, out of the room, or in a different room does not
    # stay.
    [taken | _] = others

    for at <- [%{x: taken.x, y: taken.y}, %{x: kitchen.plan.w, y: 0}] do
      kept = %{"k1" => %{room: kitchen.id, at: at}}
      assert {[%{at: at_now}], 1} = HomeAssistant.ghosts(build, [lamp], areas, kept)
      assert at_now == ghost.at
    end

    kept = %{"k1" => %{room: living.id, at: free}}
    assert {[%{at: at_now}], 1} = HomeAssistant.ghosts(build, [lamp], areas, kept)
    assert at_now == ghost.at
  end

  property "the kind of a device is a kind of the catalog, or nil" do
    words = ~w(lights tv fridge heater water pump heat ac the room 2 plug fan ecobee)

    check all(
            name <- list_of(member_of(words ++ [""]), max_length: 5),
            model <- one_of([constant(nil), string(:alphanumeric, max_length: 12)]),
            domains <- list_of(member_of(~w(light fan switch climate sensor water_heater)))
          ) do
      type = HomeAssistant.kind_of(device("d", Enum.join(name, " "), nil, domains, model))
      assert type == nil or Catalog.kind(type) != nil
      # A name with no word of a kind, no model, and no domain of a kind
      # gives no kind.
      if Enum.all?(name, &(&1 in ["", "the", "room", "2", "plug", "ecobee"])) and model == nil and
           not Enum.any?(domains, &(&1 in ~w(light fan water_heater))),
         do: assert(type == nil)
    end
  end

  test "the ghosts: a device in the area of a room, with a kind, with no item" do
    build = preset()
    kitchen = room_named(build, "Kitchen")
    living = room_named(build, "Living room")
    {:ok, build} = Build.link_area(build, kitchen.id, "cook")

    areas = [
      %{id: "cook", name: "Cooking", floor: nil},
      %{id: "living", name: "Living Room", floor: nil}
    ]

    devices = [
      device("d1", "Kitchen Lights", "cook", ["light"]),
      device("d2", "Ceiling Fan", "living", ["fan"]),
      device("d3", "Hvac", "living", ["climate"]),
      device("d4", "Porch light", "porch", ["light"]),
      device("d5", "Lamp", nil, ["light"]),
      device("d6", "Pool pump", "living", ["switch"]),
      device("d7", "Kitchen TV", "cook", ["media_player"])
    ]

    {ghosts, 4} = HomeAssistant.ghosts(build, devices, areas)

    # Only the devices with a kind, in the area of a room, where the kind
    # can go. A central AC (Hvac) is outside or on the roof, not in the
    # living room. A pool pump goes inside, next to a spa.
    assert Enum.map(ghosts, &{&1.device, &1.name, &1.room, &1.type}) == [
             {"d1", "Kitchen Lights", kitchen.id, "lights"},
             {"d2", "Ceiling Fan", living.id, "ceiling_fan"},
             {"d6", "Pool pump", living.id, "pool_pump"},
             {"d7", "Kitchen TV", kitchen.id, "tv"}
           ]

    # Each ghost has a free place in its room, that no item and no ghost
    # before it has.
    for ghost <- ghosts do
      plan = Enum.find(build.rooms, &(&1.id == ghost.room)).plan
      item = %{type: ghost.type, size: nil, turn: 0, params: Catalog.defaults(ghost.type)}
      box = Layout.item_box(Map.put(item, :at, ghost.at))
      assert box.x >= 0 and box.y >= 0
      assert box.x + box.w <= plan.w and box.y + box.d <= plan.d
    end

    [lights, _fan, _pump, tv] = ghosts

    box = fn ghost ->
      Layout.item_box(%{type: ghost.type, size: nil, turn: 0, params: %{}, at: ghost.at})
    end

    refute Layout.overlap?(box.(lights), box.(tv))

    for item <- Build.items_in(build, kitchen.id) do
      refute Layout.overlap?(Layout.item_box(item), box.(lights))
    end

    # The devices in an area with no room, with a kind: the porch light. The
    # lamp is in no area: no match can help it.
    assert HomeAssistant.away(build, devices, areas) == 1

    # A device with an item is not a ghost.
    {:ok, build, _id} = Build.add_device(build, kitchen.id, "lights", "d1")
    {ghosts, 3} = HomeAssistant.ghosts(build, devices, areas)
    assert Enum.map(ghosts, & &1.device) == ["d2", "d6", "d7"]
    {:ok, build, _id} = Build.add_device(build, kitchen.id, "lights", "d4")
    assert HomeAssistant.away(build, devices, areas) == 0
  end

  test "the plan shows 8 ghosts in a room and 60 in the house, and a device with no name has the name of its kind" do
    build = preset()
    rooms = HomeAssistant.rooms(build)
    areas = for room <- rooms, do: %{id: "a-#{room.id}", name: room.name, floor: nil}
    kitchen = room_named(build, "Kitchen")

    lamps = for i <- 1..10, do: device("k#{i}", "Lamp #{i}", "a-#{kitchen.id}", ["light"])
    {ghosts, 10} = HomeAssistant.ghosts(build, lamps, areas)
    assert Enum.map(ghosts, & &1.device) == Enum.map(Enum.take(lamps, 8), & &1.id)

    many =
      for room <- rooms,
          room.place == :indoor,
          i <- 1..9,
          do: device("#{room.id}-#{i}", "Lamp", "a-#{room.id}", ["light"])

    {ghosts, count} = HomeAssistant.ghosts(build, many, areas)
    assert count == length(many)
    assert length(ghosts) == 60
    assert ghosts |> Enum.frequencies_by(& &1.room) |> Map.values() |> Enum.max() == 8

    # A kind read before counts: the name does not count then.
    {[ghost], 1} =
      HomeAssistant.ghosts(
        build,
        [Map.put(device("x", "  ", "a-#{kitchen.id}"), :kind, "tv")],
        areas
      )

    assert {ghost.type, ghost.name} == {"tv", "TV"}
  end

  test "a ghost goes far from the other items, a mini split on the back wall" do
    room = %{w: 240, d: 240}
    item = fn type -> %{type: type, size: nil, turn: 0, params: Catalog.defaults(type)} end
    corner = [%{x: 0, y: 0, w: 24, d: 24}]

    # Far from the item in the back corner: the front corner (on a grid of
    # 12 inches).
    %{x: x, y: y} = HomeAssistant.spread(item.("tv"), room, corner)
    {w, d} = Layout.extent(item.("tv"))
    assert x + w > 240 - 12 and y + d > 240 - 12

    # A mini split hangs on the back wall. A ceiling fan is on the ceiling.
    assert %{y: 0} = HomeAssistant.spread(item.("mini_split"), room, corner)
    assert %{y: y} = HomeAssistant.spread(item.("ceiling_fan"), room, corner)
    assert y > 0

    # With no item, the back corner. With no free place, the back corner.
    assert HomeAssistant.spread(item.("tv"), room, []) == %{x: 0, y: 0}

    assert HomeAssistant.spread(item.("tv"), room, [%{x: 0, y: 0, w: 240, d: 240}]) == %{
             x: 0,
             y: 0
           }

    # An item that is larger than its room: the back corner.
    {fan_w, _fan_d} = Layout.extent(item.("ceiling_fan"))
    narrow = %{w: fan_w - 1, d: 304}
    assert HomeAssistant.spread(item.("ceiling_fan"), narrow, corner) == %{x: 0, y: 0}
  end

  property "a place of spread/3 is in its room, and on no box, when the room has a free place" do
    check all(
            rw <- integer(30..400),
            rd <- integer(30..400),
            type <- member_of(~w(tv lights fridge mini_split ceiling_fan)),
            boxes <-
              list_of(
                map({integer(0..380), integer(0..380), integer(6..90), integer(6..90)}, fn {x, y,
                                                                                            w, d} ->
                  %{x: x, y: y, w: w, d: d}
                end),
                max_length: 6
              )
          ) do
      item = %{type: type, size: nil, turn: 0, params: Catalog.defaults(type)}
      room = %{w: rw, d: rd}
      at = HomeAssistant.spread(item, room, boxes)
      {w, d} = Layout.extent(item)
      box = %{x: at.x, y: at.y, w: w, d: d}

      free? = fn box ->
        box.x >= 0 and box.y >= 0 and box.x + w <= rw and box.y + d <= rd and
          not Enum.any?(boxes, &Layout.overlap?(&1, box))
      end

      # The place is free. Else it is the back corner, and the room has no
      # free place on the grid. The grid has about 30 steps on each side,
      # with steps of 12 inches at least.
      step = max(12, round(max(rw, rd) / 30))
      wall? = Catalog.lift(type) > 0 and type != "ceiling_fan"

      grid =
        for y <- 0..if(wall?, do: 0, else: max(rd - d, 0))//step,
            x <- 0..max(rw - w, 0)//step,
            do: %{x: x, y: y, w: w, d: d}

      if free?.(box) do
        if wall?, do: assert(at.y == 0)
      else
        assert at == %{x: 0, y: 0}
        refute Enum.any?(grid, free?)
      end
    end
  end

  property "each ghost is a device with no item, in a room of its area, with a kind that can go there" do
    build = preset()
    rooms = HomeAssistant.rooms(build)
    area_ids = Enum.map(rooms, &"a-#{&1.id}") ++ ["other", nil]
    names = ["Lights", "TV", "Fridge", "Pool pump", "Fan", "Thermostat", "Washer", "Heater"]

    check all(
            devices <-
              uniq_list_of(
                tuple(
                  {string(:alphanumeric, min_length: 1, max_length: 6), member_of(names),
                   member_of(area_ids)}
                ),
                uniq_fun: &elem(&1, 0),
                max_length: 12
              ),
            linked <- list_of(boolean(), length: length(devices))
          ) do
      # Some rooms have a link to an area of a different name.
      areas =
        for room <- rooms do
          name = if rem(:erlang.phash2(room.id), 3) == 0, do: "Area #{room.id}", else: room.name
          %{id: "a-#{room.id}", name: name, floor: nil}
        end

      build =
        Enum.reduce(areas, build, fn area, build ->
          if String.starts_with?(area.name, "Area "),
            do: elem(Build.link_area(build, String.trim_leading(area.id, "a-"), area.id), 1),
            else: build
        end)

      devices = for {id, name, area} <- devices, do: device(id, name, area)

      # Some devices have an item already.
      kitchen = room_named(build, "Kitchen")

      build =
        devices
        |> Enum.zip(linked)
        |> Enum.reduce(build, fn
          {device, true}, build ->
            {:ok, build, _id} = Build.add_device(build, kitchen.id, "tv", device.id)
            build

          {_device, false}, build ->
            build
        end)

      {ghosts, count} = HomeAssistant.ghosts(build, devices, areas)
      # The plan shows 8 ghosts in a room at most.
      assert count >= length(ghosts)
      assert ghosts |> Enum.frequencies_by(& &1.room) |> Map.values() |> Enum.all?(&(&1 <= 8))
      items = MapSet.new(Map.values(build.devices))

      for ghost <- ghosts do
        device = Enum.find(devices, &(&1.id == ghost.device))
        room = Enum.find(build.rooms, &(&1.id == ghost.room))
        refute MapSet.member?(items, ghost.device)
        assert device.area == "a-#{room.id}"
        assert ghost.type == HomeAssistant.kind_of(device)
        assert room.place in Catalog.kind(ghost.type).places
      end

      # One ghost for each device at most, and each device with a kind is a
      # ghost, an item, or away.
      assert Enum.uniq_by(ghosts, & &1.device) == ghosts

      with_kind =
        Enum.count(
          devices,
          &(HomeAssistant.kind_of(&1) != nil and not MapSet.member?(items, &1.id))
        )

      wrong_place =
        Enum.count(devices, fn device ->
          type = HomeAssistant.kind_of(device)
          room = Enum.find(rooms, &("a-#{&1.id}" == device.area))

          type != nil and room != nil and not MapSet.member?(items, device.id) and
            room.place not in Catalog.kind(type).places
        end)

      no_area =
        Enum.count(
          devices,
          &(&1.area == nil and HomeAssistant.kind_of(&1) != nil and
              not MapSet.member?(items, &1.id))
        )

      assert count + HomeAssistant.away(build, devices, areas) + wrong_place + no_area ==
               with_kind
    end
  end
end
