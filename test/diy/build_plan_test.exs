defmodule DIY.BuildPlanTest do
  @moduledoc "The plan of the house at scale in a build (`DIY.Layout`)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, House, Layout}

  defp house(floors \\ 2) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: floors, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))
  defp item(build, id), do: elem(Build.item(build, id), 1)

  defp first(build, room, type),
    do: Enum.find(Build.items_in(build, room(build, room).id), &(&1.type == type))

  test "two rooms next to each other can be open: no wall stands between them" do
    build = house()
    names = ["Kitchen", "Living room", "Backyard", "Garage", "Bedroom 2"]
    [kitchen, living, yard, garage, bedroom] = for n <- names, do: room(build, n)
    assert Layout.touch?(kitchen.plan, living.plan)

    # The backyard touches the kitchen, but the plan has no wall for a yard.
    # Bedroom 2 touches the garage, but it is on floor 2. The app ignores
    # them, an id of no room, and the kitchen itself.
    assert Layout.touch?(kitchen.plan, yard.plan) and Layout.touch?(garage.plan, bedroom.plan)
    assert Build.open_choices(build, kitchen) == [living]
    assert Build.open_choices(build, garage) == [room(build, "Laundry")]
    {:ok, open} = Build.set_open(build, kitchen.id, [living.id, yard.id, "nothing", kitchen.id])
    pair = Enum.sort([kitchen.id, living.id])
    assert open.open == [pair]
    assert Build.open_to(open, living.id) == [kitchen.id]
    assert Build.open_to(open, kitchen.id) == [living.id]
    assert open.revision == build.revision + 1
    assert {:ok, %{open: []}} = Build.set_open(build, garage.id, [bedroom.id])
    assert Build.set_open(build, "nothing", []) == {:error, :room}
    {:ok, closed} = Build.set_open(open, living.id, [])
    assert closed.open == []

    # A build has at most 200 pairs.
    full = %{build | open: for(n <- 1..200, do: ["a#{n}", "b#{n}"])}
    assert Build.set_open(full, kitchen.id, [living.id]) == {:error, :open}

    # The JSON keeps the pair. A pair with a room that is not there, a
    # pair that cannot be open, or a second copy goes away. A build of an
    # older version has no pair.
    {:ok, read} = Build.from_json(Build.to_json(open))
    assert read.open == [pair]
    map = open |> Build.to_json() |> Jason.decode!()
    load = &Build.from_json(Jason.encode!(&1))
    stale = [[kitchen.id, "gone"], [living.id, kitchen.id], pair, [garage.id, bedroom.id]]
    assert {:ok, %{open: [^pair]}} = load.(%{map | "open" => stale})
    assert {:ok, %{open: [^pair]}} = load.(%{map | "open" => List.duplicate(pair, 300)})
    assert {:ok, %{open: []}} = load.(Map.delete(map, "open"))

    for bad <- [[["a"]], "x", [[1, 2]]],
        do: assert(load.(%{map | "open" => bad}) == {:error, :open})

    # The pair goes away with a room, and when a room moves away.
    {:ok, gone} = Build.delete_room(open, living.id)
    assert gone.open == []
    {:ok, away} = Build.move_room(open, kitchen.id, -2000, -2000)
    assert away.open == []

    # A new house has no pair.
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    assert Build.put_house(open, house, rooms, items).open == []
  end

  test "a door is an opening between two rooms that touch, at a place along their wall" do
    build = house()
    names = ["Kitchen", "Living room", "Backyard", "Garage", "Bedroom 2", "Laundry", "Driveway"]
    [kitchen, living, yard, garage, bedroom, laundry, drive] = for n <- names, do: room(build, n)

    # A room inside can have a door to a room inside or to a yard, on its
    # layer, along 40 inches at least. The garage and the backyard touch
    # along 6 inches only. Bedroom 2 is on floor 2.
    assert Build.doorway_choices(build, kitchen) == [living, yard]
    assert Build.doorway_choices(build, garage) == [laundry, drive]
    assert Build.doorway_choices(build, yard) == [kitchen, living, laundry]
    assert Build.doorway_choices(build, drive) == [garage]

    # A door with no place is in the middle of the common part: the wall of
    # 294 inches between the kitchen and the living room. The app ignores
    # a room that is not a choice.
    pair = fn a, b, at -> Enum.sort([a.id, b.id]) ++ [at] end
    doors = %{living.id => nil, yard.id => 20, bedroom.id => nil, "nothing" => 4}
    {:ok, door} = Build.set_doorways(build, kitchen.id, doors)
    assert door.revision == build.revision + 1
    assert door.doorways == [pair.(kitchen, living, 147), pair.(kitchen, yard, 20)]

    # A door has 4 inches of wall at each side, at the least: its middle
    # is 20 inches from each end of the common part.
    assert Build.doorways_of(door, kitchen.id) == [
             %{other: living.id, at: 147, range: {20, 274}},
             %{other: yard.id, at: 20, range: {20, 124}}
           ]

    assert Build.doorways_of(door, living.id) == [
             %{other: kitchen.id, at: 147, range: {20, 274}}
           ]

    # The opening is 32 inches, in the side of each room.
    assert Build.doorway_gaps(door, kitchen.id) == [{"x1", {131, 163}}, {"y1", {4, 36}}]
    assert Build.doorway_gaps(door, living.id) == [{"x0", {131, 163}}]

    # A place goes into the common part, with the door and its walls.
    {:ok, ends} = Build.set_doorways(build, kitchen.id, %{living.id => 0, yard.id => 999})
    assert ends.doorways == [pair.(kitchen, living, 20), pair.(kitchen, yard, 124)]

    # Two rooms that are open to each other have no wall, and no door.
    {:ok, open} = Build.set_open(door, kitchen.id, [living.id])
    assert Build.doorway_choices(open, kitchen) == [yard]
    assert open.doorways == [pair.(kitchen, yard, 20)]

    # The doors of the other room stay. No door takes them away.
    {:ok, both} = Build.set_doorways(door, garage.id, %{laundry.id => nil})
    assert length(both.doorways) == 3
    {:ok, none} = Build.set_doorways(both, kitchen.id, %{})
    assert none.doorways == [pair.(laundry, garage, 147)]

    assert Build.set_doorways(build, "nothing", %{}) == {:error, :room}

    # A build has at most 200 doors.
    full = %{build | doorways: for(n <- 1..200, do: ["a#{n}", "b#{n}", 16])}
    assert Build.set_doorways(full, kitchen.id, %{living.id => nil}) == {:error, :doorways}

    # The JSON keeps the doors. A door of a room that is not there, of two
    # rooms that do not touch, or a second door of a pair goes away. A
    # place out of the common part goes into it. A build of an older
    # version has no door.
    {:ok, read} = Build.from_json(Build.to_json(door))
    assert read.doorways == door.doorways
    map = door |> Build.to_json() |> Jason.decode!()
    load = &Build.from_json(Jason.encode!(&1))

    stale = [
      [kitchen.id, "gone", 10],
      [living.id, kitchen.id, 500],
      [kitchen.id, living.id, 30],
      [garage.id, bedroom.id, 20]
    ]

    assert {:ok, %{doorways: [[_, _, 274]]}} = load.(%{map | "doorways" => stale})
    assert {:ok, %{doorways: []}} = load.(Map.delete(map, "doorways"))

    for bad <- [[["a", "b"]], "x", [[1, 2, 3]], [["a", "b", "c"]]],
        do: assert(load.(%{map | "doorways" => bad}) == {:error, :doorways})

    # The door goes away with a room, and when a room moves away.
    {:ok, gone} = Build.delete_room(door, living.id)
    assert gone.doorways == [pair.(kitchen, yard, 20)]
    {:ok, away} = Build.move_room(door, kitchen.id, -2000, -2000)
    assert away.doorways == []

    # A new house has no door.
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    assert Build.put_house(door, house, rooms, items).doorways == []
  end

  test "no item stands in front of a door" do
    build = house()
    {kitchen, living} = {room(build, "Kitchen"), room(build, "Living room")}
    {:ok, door} = Build.set_doorways(build, kitchen.id, %{living.id => nil})

    # The door is at 131 to 163 inches along the wall between the rooms.
    # Its space is 36 inches deep in each room.
    assert Build.door_spaces(door, kitchen.id) == [%{x: 108, y: 131, w: 36, d: 32}]
    assert Build.door_spaces(door, living.id) == [%{x: 0, y: 131, w: 36, d: 32}]
    assert Build.door_spaces(door, "nothing") == []

    # A drop in front of the door does not go. Next to it, it goes.
    {:ok, door, heater} = Build.add_item(door, living.id, "space_heater")
    assert Build.place_item(door, heater, living.id, %{x: 4, y: 140}) == {:error, :door}
    assert {:ok, door} = Build.place_item(door, heater, living.id, %{x: 40, y: 140})

    # A turn or a size that goes in front of the door does not go.
    {:ok, door, freezer} = Build.add_item(door, living.id, "freezer")
    {:ok, door} = Build.place_item(door, freezer, living.id, %{x: 0, y: 95})
    assert Build.turn_item(door, freezer) == {:error, :door}
    assert Build.size_item(door, freezer, %{w: 56, d: 30, h: 33}) |> elem(0) == :ok
    assert Build.size_item(door, freezer, %{w: 56, d: 70, h: 33}) == {:error, :door}

    # An item on a wall over the door (a mini split) does not block it.
    {:ok, door, split} = Build.add_item(door, living.id, "mini_split")
    assert {:ok, _door} = Build.place_item(door, split, living.id, %{x: 0, y: 131})

    # A new door moves the items in front of it to a free place, with the
    # items on them. A free place is not in front of the door.
    {:ok, build, dryer} = Build.add_item(build, kitchen.id, "dryer")
    {:ok, build} = Build.place_item(build, dryer, kitchen.id, %{x: 110, y: 135})
    {:ok, build, top} = Build.add_item(build, kitchen.id, "microwave")
    {:ok, build} = Build.place_item(build, top, kitchen.id, %{x: 112, y: 137}, true)
    assert {:ok, %{on: ^dryer} = before} = Build.item(build, top)
    {:ok, base} = Build.item(build, dryer)
    {:ok, door} = Build.set_doorways(build, kitchen.id, %{living.id => nil})
    {:ok, moved} = Build.item(door, dryer)
    [space] = Build.door_spaces(door, kitchen.id)
    refute Layout.overlap?(Layout.item_box(moved), space)

    for other <- Build.items_in(door, kitchen.id), other.id not in [dryer, top] do
      refute Layout.overlap?(Layout.item_box(moved), Layout.item_box(other))
    end

    {:ok, carried} = Build.item(door, top)
    assert carried.on == dryer
    assert carried.at.x - moved.at.x == before.at.x - base.at.x
    assert carried.at.y - moved.at.y == before.at.y - base.at.y
  end

  test "a room moves with its items, and does not go over a room of its layer" do
    build = house()
    kitchen = room(build, "Kitchen")
    fridge = first(build, "Kitchen", "fridge")

    {:ok, moved} = Build.move_room(build, kitchen.id, -200, 12)
    assert room(moved, "Kitchen").plan == %{kitchen.plan | x: -200, y: 12}
    assert item(moved, fridge.id).at == fridge.at
    assert moved.revision == build.revision + 1

    # Over the living room (floor 1), and over the garage (outside, on the
    # ground too).
    assert Build.move_room(build, kitchen.id, 100, 0) == {:error, :overlap}
    assert Build.move_room(build, kitchen.id, 438, 0) == {:error, :overlap}
    # Floor 2 is a different layer.
    {:ok, _} = Build.move_room(build, room(build, "Bedroom 1").id, 0, 0)
    assert Build.move_room(build, kitchen.id, 20_000, 0) == {:error, :plan}
    assert Build.move_room(build, "nothing", 0, 0) == {:error, :room}
  end

  test "a wall of a room moves: the items keep their place in the house, in the room" do
    build = house()
    kitchen = room(build, "Kitchen")
    range = first(build, "Kitchen", "range")
    assert range.at == %{x: 36, y: 0}

    # The back wall goes 60 inches back: the range stays where it is.
    plan = %{kitchen.plan | x: -60, w: kitchen.plan.w + 60}
    {:ok, wider} = Build.size_room(build, kitchen.id, plan)
    assert item(wider, range.id).at == %{x: 96, y: 0}

    # The room gets small: the items stay in it.
    {:ok, small} = Build.size_room(build, kitchen.id, %{kitchen.plan | w: 40, d: 40})

    for item <- Build.items_in(small, kitchen.id) do
      {w, d} = Layout.extent(item)
      assert item.at.x == 0 or item.at.x + w <= 40
      assert item.at.y == 0 or item.at.y + d <= 40
    end

    assert Build.size_room(build, kitchen.id, %{kitchen.plan | w: 10}) == {:error, :plan}
    assert Build.size_room(build, kitchen.id, %{kitchen.plan | w: 200}) == {:error, :overlap}
  end

  test "an item goes to a place in its room, or in a different room" do
    build = house()
    fridge = first(build, "Kitchen", "fridge")
    kitchen = room(build, "Kitchen")
    garage = room(build, "Garage")

    {:ok, moved} = Build.place_item(build, fridge.id, kitchen.id, %{x: 50, y: 900})
    assert item(moved, fridge.id).at == %{x: 50, y: 294 - 33}

    {:ok, moved} = Build.place_item(build, fridge.id, garage.id, %{x: 10, y: 20})
    assert %{room: room, at: %{x: 10, y: 20}} = item(moved, fridge.id)
    assert room == garage.id

    # A fridge does not go on the roof, or in a van.
    assert Build.place_item(build, fridge.id, room(build, "Roof").id, %{x: 0, y: 0}) ==
             {:error, :place}

    {:ok, build, van} = Build.add_item(build, room(build, "Driveway").id, "camper_van")
    bed = Build.zone(build, van, :bed)
    assert Build.place_item(build, fridge.id, bed.id, %{x: 0, y: 0}) == {:error, :place}
    # A station can go in the bed of a van, but not from the house.
    {:ok, build, station} = Build.add_item(build, kitchen.id, "power_station")
    assert Build.place_item(build, station, bed.id, %{x: 0, y: 0}) == {:error, :place}

    assert Build.place_item(build, fridge.id, Build.zone(build, van, :shell).id, %{x: 0, y: 0}) ==
             {:error, :room}

    assert Build.place_item(build, "nothing", kitchen.id, %{x: 0, y: 0}) == {:error, :item}
  end

  test "a check of a move: the move keeps the rules, with no change" do
    build = house()
    kitchen = room(build, "Kitchen")
    assert Build.can_move?(build, kitchen.id, -24, 0)
    refute Build.can_move?(build, kitchen.id, 24, 0)

    {:ok, build, van} = Build.add_item(build, room(build, "Driveway").id, "camper_van")
    refute Build.can_move?(build, Build.zone(build, van, :cab).id, 0, -6)
    refute Build.can_move?(build, Build.zone(build, van, :shell).id, 0, 6)
    refute Build.can_move?(build, "r999", 0, 6)
  end

  test "the model gives the size of a camper van" do
    build = house()
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway").id, "camper_van")
    assert Build.size_item(build, van, %{w: 30, d: 30, h: 30}) == {:error, :size}
    assert {:ok, _build} = Build.size_item(build, van, nil)

    # A size in a stored build has no effect.
    {:ok, item} = Build.item(build, van)
    assert Layout.size(%{item | size: %{w: 30, d: 30, h: 30}}) == Layout.size(item)
  end

  test "an item turns a quarter turn around its center, and has a size" do
    build = house()
    tv = first(build, "Living room", "tv")
    living = room(build, "Living room")
    {:ok, build} = Build.place_item(build, tv.id, living.id, %{x: 100, y: 100})

    {:ok, turned} = Build.turn_item(build, tv.id)
    # 44 by 10: the center stays near 122, 105.
    assert %{turn: 1, at: %{x: 117, y: 83}} = item(turned, tv.id)
    assert Layout.extent(item(turned, tv.id)) == {10, 44}

    turned =
      Enum.reduce(1..3, turned, fn _, build -> elem(Build.turn_item(build, tv.id), 1) end)

    assert %{turn: 0, at: %{x: 100, y: 100}} = item(turned, tv.id)

    # The watts give the size of solar panels.
    roof = room(build, "Roof")
    {:ok, with_panels, panels} = Build.add_item(build, roof.id, "solar_panels")
    assert Build.size_item(with_panels, panels, %{w: 57, d: 12, h: 35}) == {:error, :size}

    # A stored size of panels has no effect, and it can go.
    stored = %{
      with_panels
      | items:
          Enum.map(
            with_panels.items,
            &if(&1.id == panels, do: %{&1 | size: %{w: 400, d: 30, h: 2}}, else: &1)
          )
    }

    {:ok, panels_item} = Build.item(stored, panels)
    assert Layout.size(panels_item) == Layout.size(%{panels_item | size: nil})
    assert {:ok, cleared} = Build.size_item(stored, panels, nil)
    assert elem(Build.item(cleared, panels), 1).size == nil

    {:ok, sized} = Build.size_item(build, tv.id, %{w: 57, d: 12, h: 35})
    assert Layout.size(item(sized, tv.id)) == {57, 12, 35}
    {:ok, typical} = Build.size_item(sized, tv.id, nil)
    assert Layout.size(item(typical, tv.id)) == {44, 10, 28}
    assert Build.size_item(build, tv.id, %{w: 0, d: 12, h: 35}) == {:error, :size}

    # A large size: the item stays in its room, at 0.
    {:ok, huge} = Build.size_item(build, tv.id, %{w: 1200, d: 12, h: 35})
    assert item(huge, tv.id).at.x == 0
  end

  test "an item in a van has a place in its zone, an item of the shell has none" do
    build = house()
    {:ok, build, station} = Build.add_item(build, room(build, "Laundry").id, "power_station")
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway").id, "camper_van")
    assert item(build, station).at != nil
    assert Build.turn_item(build, Build.zone(build, van, :bay).id) == {:error, :item}

    {:ok, away} = Build.take_to_van(build, station, van)
    assert %{at: %{x: 0, y: 0}} = item(away, station)
    {:ok, turned} = Build.turn_item(away, station)
    assert item(turned, station).turn == 1
    assert Build.zone(away, van, :shell).plan == nil
    {:ok, shelled, walls} = Build.add_item(away, Build.zone(away, van, :shell).id, "walls")
    assert item(shelled, walls).at == nil
    assert Build.turn_item(shelled, walls) == {:error, :room}

    {:ok, home} = Build.bring_home(away, station)
    assert %{at: %{}} = item(home, station)

    # A move by the sheet: a free place in the new room.
    fridge = first(home, "Kitchen", "fridge")
    {:ok, moved} = Build.move_item(home, fridge.id, room(home, "Garage").id)

    assert item(moved, fridge.id).at ==
             Layout.free_at(fridge, room(home, "Garage").plan, others(moved, fridge))
  end

  # The boxes of the other items in the room of an item.
  defp others(build, item) do
    room = item(build, item.id).room
    for o <- build.items, o.room == room, o.id != item.id, do: Layout.item_box(o)
  end

  test "the plan goes to JSON and back" do
    build = house()
    tv = first(build, "Living room", "tv")
    {:ok, build} = Build.turn_item(build, tv.id)
    {:ok, build} = Build.size_item(build, tv.id, %{w: 57, d: 12, h: 35})
    {:ok, build} = Build.move_room(build, room(build, "Garage").id, 500, -300)
    {:ok, read} = Build.from_json(Build.to_json(build))
    assert read.rooms == build.rooms
    assert read.items == build.items
  end

  test "a stored plan that is not valid gets a new plan, and an old build gets a draft" do
    build = house()
    map = Jason.decode!(Build.to_json(build))

    # A build of an older version: no plan, no place.
    old =
      map
      |> Map.update!("rooms", &Enum.map(&1, fn room -> Map.delete(room, "plan") end))
      |> Map.update!("items", &Enum.map(&1, fn item -> Map.drop(item, ~w(at turn size)) end))

    {:ok, read} = Build.from_json(Jason.encode!(old))
    assert read.rooms == build.rooms
    assert read.items == build.items

    # Bad parts: each goes back to a valid value.
    bad =
      map
      |> Map.update!("rooms", fn [roof | rooms] -> [%{roof | "plan" => %{"x" => "a"}} | rooms] end)
      |> Map.update!("items", fn [ac | items] ->
        [%{ac | "at" => %{"x" => 99_999, "y" => 0}, "turn" => 7, "size" => %{"w" => -1}} | items]
      end)

    {:ok, read} = Build.from_json(Jason.encode!(bad))
    [roof | _] = read.rooms
    [ac | _] = read.items
    assert Layout.valid_plan?(roof.plan)
    assert %{turn: 0, size: nil, at: %{}} = ac
  end

  ## The property

  # A random change of the plan.
  defp step(build) do
    rooms = Enum.reject(build.rooms, &Build.van_level?(&1.level))
    # The rooms and the zones with a plan, for a move.
    placed = Enum.filter(build.rooms, & &1.plan)
    ids = Enum.map(build.items, & &1.id)
    vans = for i <- build.items, i.type == "camper_van", do: i.id

    on_rooms =
      if rooms == [],
        do: [],
        else: [
          tuple(
            {constant(:move_room), member_of(placed), integer(-600..900), integer(-600..900)}
          ),
          tuple({constant(:size_room), member_of(placed), plan()}),
          tuple({constant(:add_item), member_of(build.rooms), member_of(Catalog.types())}),
          tuple({constant(:add_item), member_of(rooms), constant("camper_van")}),
          tuple({constant(:delete_room), member_of(rooms)})
        ]

    on_vans =
      if vans == [],
        do: [],
        else: [
          tuple(
            {constant(:van_model), member_of(vans),
             member_of(Enum.map(Catalog.van_models(), &elem(&1, 0)))}
          )
        ]

    on_items =
      if ids == [] or rooms == [],
        do: [],
        else: [
          tuple(
            {constant(:place), member_of(ids), member_of(placed), integer(-100..900),
             integer(-100..900)}
          ),
          tuple({constant(:turn), member_of(ids)}),
          tuple({constant(:size), member_of(ids), one_of([constant(nil), size()])}),
          tuple({constant(:delete_item), member_of(ids)})
        ]

    one_of(
      [
        tuple(
          {constant(:add_room), member_of(Build.levels(build.house.floors)),
           member_of(Catalog.places())}
        )
      ] ++ on_rooms ++ on_vans ++ on_items
    )
  end

  defp plan do
    gen(
      all(
        x <- integer(-600..900),
        y <- integer(-600..900),
        w <- integer(10..800),
        d <- integer(10..800)
      ),
      do: %{x: x, y: y, w: w, d: d}
    )
  end

  defp size do
    gen(all(w <- integer(1..400), d <- integer(1..400), h <- integer(1..200)),
      do: %{w: w, d: d, h: h}
    )
  end

  defp apply_step(build, {:move_room, room, x, y}), do: Build.move_room(build, room.id, x, y)
  defp apply_step(build, {:size_room, room, plan}), do: Build.size_room(build, room.id, plan)

  defp apply_step(build, {:place, id, room, x, y}),
    do: Build.place_item(build, id, room.id, %{x: x, y: y})

  defp apply_step(build, {:turn, id}), do: Build.turn_item(build, id)
  defp apply_step(build, {:size, id, size}), do: Build.size_item(build, id, size)

  defp apply_step(build, {:add_room, level, place}) do
    with {:ok, build, _id} <- Build.add_room(build, "New", level, place), do: {:ok, build}
  end

  defp apply_step(build, {:add_item, room, type}) do
    with {:ok, build, _id} <- Build.add_item(build, room.id, type), do: {:ok, build}
  end

  defp apply_step(build, {:van_model, van, model}),
    do: Build.update_item(build, van, %{"model" => model})

  defp apply_step(build, {:delete_room, room}), do: Build.delete_room(build, room.id)
  defp apply_step(build, {:delete_item, id}), do: Build.delete_item(build, id)

  # The rules of the plan (`DIY.Layout`).
  defp assert_rules(build) do
    {house, vans} = Enum.split_with(build.rooms, &(not Build.van_level?(&1.level)))
    assert Enum.all?(house, &Layout.valid_plan?(&1.plan))

    # The shell of a van has no plan. The engine bay is in front of the
    # dash, and each other zone is in its van.
    for zone <- vans do
      "van:" <> van = zone.level
      {:ok, van} = Build.item(build, van)

      case zone.place do
        :shell ->
          assert zone.plan == nil

        :engine ->
          assert zone.plan == Layout.engine_box(van)

        _place ->
          assert Layout.valid_plan?(zone.plan) and Layout.inside?(zone.plan, Layout.van_box(van))
      end

      # The cab and the roof are at their places for the model.
      if zone.place in [:cab, :van_roof], do: assert([zone.plan] == Layout.van_draft(van, [zone]))
    end

    placed = Enum.filter(build.rooms, & &1.plan)

    for {a, i} <- Enum.with_index(placed),
        {b, j} <- Enum.with_index(placed),
        i < j,
        Layout.layer(a) == Layout.layer(b),
        do: refute(Layout.overlap?(a.plan, b.plan), "#{a.name} and #{b.name} overlap")

    plans = Map.new(build.rooms, &{&1.id, &1.plan})

    for item <- build.items do
      case plans[item.room] do
        nil ->
          assert item.at == nil

        plan ->
          {w, d} = Layout.extent(item)
          assert item.at.x == 0 or (item.at.x >= 0 and item.at.x + w <= plan.w)
          assert item.at.y == 0 or (item.at.y >= 0 and item.at.y + d <= plan.d)
      end
    end
  end

  property "each change keeps the rules of the plan, and the JSON gives the same plan" do
    check all(floors <- integer(1..3), seeds <- list_of(integer(), max_length: 25), max_runs: 80) do
      # The rules hold after each step, not only after the last one.
      build =
        Enum.reduce(seeds, house(floors), fn seed, build ->
          [step] = Enum.take(StreamData.seeded(step(build), seed), 1)

          case apply_step(build, step) do
            {:ok, changed} ->
              assert_rules(changed)
              changed

            {:error, _reason} ->
              build
          end
        end)

      {:ok, read} = Build.from_json(Build.to_json(build))
      assert read.rooms == build.rooms
      assert read.items == build.items
    end
  end

  property "a stored build with any plans and places loads with the rules of the plan" do
    check all(
            floors <- integer(1..3),
            plans <- list_of(one_of([constant(nil), plan()]), length: 20),
            places <- list_of({integer(-900..900), integer(-900..900)}, length: 40),
            max_runs: 60
          ) do
      map = Jason.decode!(Build.to_json(house(floors)))

      stored =
        map
        |> Map.update!("rooms", fn rooms ->
          rooms
          |> Enum.zip(Stream.cycle(plans))
          |> Enum.map(fn
            {room, nil} -> Map.delete(room, "plan")
            {room, plan} -> Map.put(room, "plan", Map.new(plan, fn {k, v} -> {"#{k}", v} end))
          end)
        end)
        |> Map.update!("items", fn items ->
          items
          |> Enum.zip(Stream.cycle(places))
          |> Enum.map(fn {item, {x, y}} -> Map.put(item, "at", %{"x" => x, "y" => y}) end)
        end)

      {:ok, read} = Build.from_json(Jason.encode!(stored))
      assert_rules(read)
    end
  end
end
