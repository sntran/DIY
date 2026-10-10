defmodule DIY.HomeAssistantTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, HomeAssistant, House}

  # A build with the preset of a house.
  defp preset(floors \\ 2) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: floors, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room_named(build, name), do: Enum.find(build.rooms, &(&1.name == name))
  defp area(id, name, floor \\ nil), do: %{id: id, name: name, floor: floor}

  test "a name for a match has no case and no spaces" do
    assert HomeAssistant.key("Living Room") == "livingroom"
    assert HomeAssistant.key(" living  ROOM") == "livingroom"
  end

  test "the rooms that can have an area: not the roof, not a zone of a van" do
    build = preset()
    {:ok, build, _van} = Build.add_item(build, room_named(build, "Driveway").id, "camper_van")
    names = Enum.map(HomeAssistant.rooms(build), & &1.name)
    assert "Attic" in names
    assert "Kitchen" in names
    refute "Roof" in names
    refute Enum.any?(HomeAssistant.rooms(build), &Build.van_level?(&1.level))
  end

  test "the match: first the links, then the names" do
    build = preset()
    kitchen = room_named(build, "Kitchen")
    living = room_named(build, "Living room")
    garage = room_named(build, "Garage")
    {:ok, build} = Build.link_area(build, kitchen.id, "cook")
    # Two rooms with a link to one area: only the first keeps it.
    {:ok, build} = Build.link_area(build, garage.id, "cook")
    # A link to an area that is not there now does not count.
    {:ok, build} = Build.link_area(build, living.id, "gone")

    areas = [
      area("cook", "Cooking space", "ground"),
      area("living", "LIVING ROOM"),
      area("pool", "Pool")
    ]

    match = HomeAssistant.match(build, areas)
    assert {kitchen, hd(areas)} in match.both
    assert {living, Enum.at(areas, 1)} in match.both
    assert length(match.both) == 2
    assert garage in match.app
    assert match.ha == [area("pool", "Pool")]
    assert length(match.app) == length(HomeAssistant.rooms(build)) - 2
  end

  test "the place of a new room: the floor of its area, else a guess from its name" do
    floors = [
      %{id: "ground", name: "Ground", level: 0},
      %{id: "up", name: "Up", level: 1},
      %{id: "high", name: "High", level: 5},
      %{id: "none", name: "None", level: nil}
    ]

    assert HomeAssistant.place_of(area("a", "Den", "ground"), floors, 2) == {"f1", :indoor}
    assert HomeAssistant.place_of(area("a", "Den", "up"), floors, 2) == {"f2", :indoor}
    assert HomeAssistant.place_of(area("a", "Den", "up"), floors, 1) == {"f1", :indoor}

    assert HomeAssistant.place_of(area("a", "Back yard", "high"), floors, 3) ==
             {"outside", :outdoor}

    assert HomeAssistant.place_of(area("a", "Front_Porch", nil), floors, 2) ==
             {"outside", :outdoor}

    assert HomeAssistant.place_of(area("a", "Garage", "none"), floors, 2) == {"outside", :indoor}
    assert HomeAssistant.place_of(area("a", "Attic", "zzz"), floors, 2) == {"roof", :indoor}
    assert HomeAssistant.place_of(area("a", "Den", nil), floors, 2) == {"f1", :indoor}
  end

  test "the level of the floor in Home Assistant for a room" do
    assert HomeAssistant.floor_level(%{level: "f1"}) == 0
    assert HomeAssistant.floor_level(%{level: "f3"}) == 2
    assert HomeAssistant.floor_level(%{level: "outside"}) == nil
    assert HomeAssistant.floor_level(%{level: "roof"}) == nil
  end

  test "the changes of a match: the links, and the areas as new rooms" do
    build = preset()
    kitchen = room_named(build, "Kitchen")

    {build, missed} =
      HomeAssistant.apply(build, [{kitchen.id, "cook"}, {"r999", "x"}], [
        {area("patio", "Patio"), "outside", :outdoor},
        {area("loft", "Loft"), "f3", :indoor},
        {area("blank", " "), "f1", :indoor}
      ])

    assert missed == ["Loft", " "]
    assert build.areas[kitchen.id] == "cook"
    patio = room_named(build, "Patio")
    assert %{level: "outside", place: :outdoor} = patio
    assert build.areas[patio.id] == "patio"
    assert map_size(build.areas) == 2
  end

  # A random name like a name of a room: the same name with a different case
  # or spaces, or a name of its own.
  defp names(build) do
    rooms = Enum.map(build.rooms, & &1.name)

    one_of([
      map(member_of(rooms), &String.upcase/1),
      map(member_of(rooms), &String.replace(&1, " ", "")),
      member_of(rooms),
      member_of(["Pool", "Patio", "Den", "Guest Suite"])
    ])
  end

  property "the match puts each room and each area in one list, and misses no name" do
    check all(
            floors <- integer(1..3),
            build = preset(floors),
            names <- list_of(names(build), max_length: 12),
            links <- list_of({integer(0..30), integer(0..14)}, max_length: 6)
          ) do
      areas = names |> Enum.with_index() |> Enum.map(fn {name, i} -> area("a#{i}", name) end)

      build =
        Enum.reduce(links, build, fn {room, area}, build ->
          room = Enum.at(build.rooms, rem(room, length(build.rooms)))

          case Build.link_area(build, room.id, "a#{area}") do
            {:ok, build} -> build
            {:error, _reason} -> build
          end
        end)

      match = HomeAssistant.match(build, areas)
      rooms = HomeAssistant.rooms(build)

      both_rooms = Enum.map(match.both, &elem(&1, 0))
      both_areas = Enum.map(match.both, &elem(&1, 1))
      assert Enum.sort_by(both_rooms ++ match.app, & &1.id) == Enum.sort_by(rooms, & &1.id)
      assert Enum.sort_by(both_areas ++ match.ha, & &1.id) == Enum.sort_by(areas, & &1.id)

      for {room, area} <- match.both do
        assert build.areas[room.id] == area.id or
                 HomeAssistant.key(room.name) == HomeAssistant.key(area.name)
      end

      # A room only in the app has no area of its name only in Home
      # Assistant: the match takes each name that it can.
      app = MapSet.new(match.app, &HomeAssistant.key(&1.name))
      refute Enum.any?(match.ha, &MapSet.member?(app, HomeAssistant.key(&1.name)))
    end
  end
end
