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

    {ghosts, 3} = HomeAssistant.ghosts(build, devices, areas)

    # Only the devices with a kind, in the area of a room, where the kind
    # can go. A pool pump is outside, not in the living room.
    assert Enum.map(ghosts, &{&1.device, &1.name, &1.room, &1.type}) == [
             {"d1", "Kitchen Lights", kitchen.id, "lights"},
             {"d2", "Ceiling Fan", living.id, "ceiling_fan"},
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

    [lights, _fan, tv] = ghosts

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
    {ghosts, 2} = HomeAssistant.ghosts(build, devices, areas)
    assert Enum.map(ghosts, & &1.device) == ["d2", "d7"]
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

      if at == %{x: 0, y: 0} do
        :ok
      else
        assert at.x >= 0 and at.y >= 0 and at.x + w <= rw and at.y + d <= rd
        refute Enum.any?(boxes, &Layout.overlap?(&1, box))
        if Catalog.lift(type) > 0 and type != "ceiling_fan", do: assert(at.y == 0)
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
      assert count == length(ghosts)
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

      assert length(ghosts) + HomeAssistant.away(build, devices, areas) + wrong_place + no_area ==
               with_kind
    end
  end
end
