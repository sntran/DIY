defmodule DIY.StackTest do
  @moduledoc "Items on other items, with a snap (`DIY.Stack`, `specs/Stack.tla`)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, House, Layout, Stack}

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))
  defp item(build, id), do: elem(Build.item(build, id), 1)

  defp first(build, room, type),
    do: Enum.find(Build.items_in(build, room(build, room).id), &(&1.type == type))

  defp add(build, room, type) do
    {:ok, build, id} = Build.add_item(build, room(build, room).id, type)
    {build, id}
  end

  # A drop on the plan: with a snap.
  defp drop(build, id, room, at), do: Build.place_item(build, id, room(build, room).id, at, true)

  defp center(item) do
    box = Layout.item_box(item)
    {box.x + box.w / 2, box.y + box.d / 2}
  end

  defp over?(item, base) do
    {cx, cy} = center(item)
    box = Layout.item_box(base)
    cx >= box.x and cx <= box.x + box.w and cy >= box.y and cy <= box.y + box.d
  end

  test "the kinds that go on an item, and the kinds that take an item" do
    for type <- ~w(microwave dryer tv cpap computer hot_tub),
        do: assert(Stack.goes_on?(%{type: type}))

    for type <- ~w(solar_panels camper_van pool ev smart_meter ceiling_fan),
        do: refute(Stack.goes_on?(%{type: type}))

    for type <- ~w(washer range pool other), do: assert(Stack.takes?(%{type: type}))

    for type <- ~w(solar_panels camper_van ev smart_meter mini_split),
        do: refute(Stack.takes?(%{type: type}))
  end

  test "a dryer dropped near the top of a washer snaps on it" do
    build = house()
    washer = first(build, "Laundry", "washer")
    {build, dryer} = add(build, "Laundry", "dryer")

    # 4 inches from the back corner of the washer: it snaps to it.
    at = %{x: washer.at.x + 4, y: washer.at.y + 3}
    {:ok, build} = drop(build, dryer, "Laundry", at)
    dryer = item(build, dryer)
    assert dryer.on == washer.id
    assert dryer.at == washer.at
    assert Stack.heights(build.items) == %{dryer.id => 39}

    # The arrow keys do not snap: the dryer moves 6 inches, and it is still
    # on the washer (its center is over it).
    {:ok, build} = Build.place_item(build, dryer.id, dryer.room, %{x: at.x + 6, y: at.y})
    assert %{on: on, at: %{x: x}} = item(build, dryer.id)
    assert {on, x} == {washer.id, at.x + 6}

    # Far from the washer: the dryer is on the floor.
    {:ok, build} = Build.place_item(build, dryer.id, dryer.room, %{x: 0, y: 70})
    refute Map.has_key?(item(build, dryer.id), :on)
    assert Stack.heights(build.items) == %{}
  end

  test "an item on an item snaps to an edge or to the center, and stays in its space" do
    build = house()
    range = first(build, "Kitchen", "range")
    {build, cpap} = add(build, "Kitchen", "cpap")
    base = Layout.item_box(range)

    # Near the center of the range (30 by 28): the cpap (10 by 6) goes to
    # it. Near the right end and the front: it goes to them.
    {:ok, build} = drop(build, cpap, "Kitchen", %{x: base.x + 9, y: base.y + 12})
    assert item(build, cpap).at == %{x: base.x + 10, y: base.y + 11}
    {:ok, build} = drop(build, cpap, "Kitchen", %{x: base.x + 16, y: base.y + 19})
    assert item(build, cpap).at == %{x: base.x + 20, y: base.y + 22}
    assert item(build, cpap).on == range.id

    # On a freezer (56 by 30), 10 inches from its left end: far from an
    # end and from the center, so it stays there.
    {build, freezer} = add(build, "Kitchen", "freezer")
    {:ok, build} = drop(build, freezer, "Kitchen", %{x: 0, y: 70})
    top = Layout.item_box(item(build, freezer))
    {:ok, build} = drop(build, cpap, "Kitchen", %{x: top.x + 10, y: top.y})
    assert item(build, cpap).at == %{x: top.x + 10, y: top.y}
    assert item(build, cpap).on == freezer

    # A TV (44 by 10) on the range (30 by 28): the range is more than half
    # of the space of the TV. The TV is at the center of the range along x.
    {build, tv} = add(build, "Kitchen", "tv")
    {:ok, build} = drop(build, tv, "Kitchen", %{x: base.x - 10, y: base.y + 2})
    assert %{on: on, at: %{x: x}} = item(build, tv)
    assert {on, x} == {range.id, base.x - 7}

    # A fridge (33 by 33) over the microwave (24 by 19): the microwave is
    # less than half of the space of the fridge. The fridge is on the floor.
    microwave = first(build, "Kitchen", "microwave")
    {build, fridge} = add(build, "Kitchen", "fridge")
    {:ok, build} = drop(build, fridge, "Kitchen", %{x: microwave.at.x - 4, y: 0})
    refute Map.has_key?(item(build, fridge), :on)
  end

  test "an item on an item goes next to an item on the same item" do
    build = house()
    washer = first(build, "Laundry", "washer")
    {build, cpap} = add(build, "Laundry", "cpap")
    {build, hub} = add(build, "Laundry", "home_assistant")
    {:ok, build} = drop(build, cpap, "Laundry", washer.at)
    assert item(build, cpap).at == washer.at

    # The hub (4 by 4) 1 inch to the right of the cpap (10 by 6): next to it.
    {:ok, build} = drop(build, hub, "Laundry", %{x: washer.at.x + 11, y: washer.at.y + 1})
    assert item(build, hub).at == %{x: washer.at.x + 10, y: washer.at.y}
    assert item(build, hub).on == washer.id
  end

  test "an item dropped near an item on the floor snaps to its side" do
    build = house()
    dishwasher = first(build, "Kitchen", "dishwasher")
    box = Layout.item_box(dishwasher)
    {build, computer} = add(build, "Kitchen", "computer")

    # 4 inches to the right of the dishwasher, and at its back wall.
    {:ok, build} = drop(build, computer, "Kitchen", %{x: box.x + box.w + 4, y: 0})
    assert item(build, computer).at == %{x: box.x + box.w, y: 0}
    refute Map.has_key?(item(build, computer), :on)

    # In front of the dishwasher, with a gap of 5: flush with its front.
    {:ok, build} = drop(build, computer, "Kitchen", %{x: box.x, y: box.y + box.d + 5})
    assert item(build, computer).at == %{x: box.x, y: box.y + box.d}
  end

  test "the items on an item move with it, also to another room, and stay in the room" do
    build = house()
    washer = first(build, "Laundry", "washer")
    {build, dryer} = add(build, "Laundry", "dryer")
    {build, cpap} = add(build, "Laundry", "cpap")
    {:ok, build} = drop(build, dryer, "Laundry", washer.at)
    {:ok, build} = drop(build, cpap, "Laundry", item(build, dryer).at)
    assert item(build, cpap).on == dryer
    assert Stack.above(build.items, washer.id) == [dryer, cpap]
    assert Stack.heights(build.items) == %{dryer => 39, cpap => 78}

    # The washer moves 20 inches: the two items go with it.
    before = Map.new([dryer, cpap], &{&1, item(build, &1).at})
    to = %{x: washer.at.x + 20, y: washer.at.y + 10}
    {:ok, moved} = Build.place_item(build, washer.id, washer.room, to)

    for id <- [dryer, cpap] do
      assert item(moved, id).at == %{x: before[id].x + 20, y: before[id].y + 10}
    end

    assert item(moved, cpap).on == dryer

    # To the kitchen: the items go too, on the washer.
    {:ok, moved} = Build.place_item(build, washer.id, room(build, "Kitchen").id, %{x: 0, y: 60})
    assert item(moved, dryer).room == room(build, "Kitchen").id
    assert item(moved, dryer).on == washer.id
    assert item(moved, cpap).on == dryer
  end

  test "an item that does not fit the new room stays, with the items on it" do
    build = house()
    {build, pump} = add(build, "Laundry", "pool_pump")
    {build, cpap} = add(build, "Laundry", "cpap")
    {build, bus} = add(build, "Laundry", "home_assistant")
    {:ok, build} = drop(build, pump, "Laundry", %{x: 0, y: 80})
    {:ok, build} = drop(build, cpap, "Laundry", item(build, pump).at)
    {:ok, build} = drop(build, bus, "Laundry", item(build, cpap).at)
    assert Stack.above(build.items, pump) == [cpap, bus]

    # The pump goes to the backyard. A cpap does not go outside: it stays
    # in the laundry, on the floor, with the item on it.
    {:ok, moved} = Build.place_item(build, pump, room(build, "Backyard").id, %{x: 0, y: 0})
    assert item(moved, cpap).room == room(build, "Laundry").id
    refute Map.has_key?(item(moved, cpap), :on)
    assert item(moved, bus).on == cpap
    assert item(moved, bus).room == room(build, "Laundry").id
  end

  test "an item that goes away, or that moves with the list, leaves the items on it on the floor" do
    build = house()
    washer = first(build, "Laundry", "washer")
    {build, dryer} = add(build, "Laundry", "dryer")
    {:ok, build} = drop(build, dryer, "Laundry", washer.at)

    {:ok, gone} = Build.delete_item(build, washer.id)
    refute Map.has_key?(item(gone, dryer), :on)
    assert item(gone, dryer).at == washer.at

    {:ok, moved} = Build.move_item(build, washer.id, room(build, "Kitchen").id)
    refute Map.has_key?(item(moved, dryer), :on)
    assert item(moved, dryer).room == washer.room
  end

  test "an item does not go on an item that is on it, or in a van" do
    build = house()
    washer = first(build, "Laundry", "washer")
    {build, dryer} = add(build, "Laundry", "dryer")
    {:ok, build} = drop(build, dryer, "Laundry", washer.at)

    # The washer under the dryer: the dryer is on the washer, so the washer
    # stays on the floor, and the dryer goes with it.
    {:ok, build} = drop(build, washer.id, "Laundry", %{x: washer.at.x + 2, y: washer.at.y})
    refute Map.has_key?(item(build, washer.id), :on)
    assert item(build, dryer).on == washer.id
  end

  test "the items of the roof and of a van do not stack" do
    build = house()
    roof = room(build, "Roof")
    {build, ac} = add(build, "Roof", "ac")
    {build, ac2} = add(build, "Roof", "ac")
    {:ok, build} = drop(build, ac, "Roof", %{x: 100, y: 100})
    {:ok, build} = drop(build, ac2, "Roof", %{x: 102, y: 100})
    refute Map.has_key?(item(build, ac2), :on)
    assert roof.place == :roof

    # A file with a pump on a tank in a van: the van has no stack.
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway").id, "camper_van")
    galley = Build.zone(build, van, :galley).id
    {:ok, build, tank} = Build.add_item(build, galley, "water_tank")
    {:ok, build, pump} = Build.add_item(build, galley, "water_pump")
    {:ok, build} = Build.place_item(build, pump, galley, item(build, tank).at, true)
    refute Map.has_key?(item(build, pump), :on)

    map = Jason.decode!(Build.to_json(build))
    items = Enum.map(map["items"], &if(&1["id"] == pump, do: Map.put(&1, "on", tank), else: &1))
    {:ok, read} = Build.from_json(Jason.encode!(%{map | "items" => items}))
    refute Map.has_key?(item(read, pump), :on)
  end

  test "the floor snap does not see an item on a wall or a ceiling, and such an item does not snap" do
    build = house()
    living = room(build, "Living room")
    {build, fan} = add(build, "Living room", "ceiling_fan")
    {:ok, build} = Build.place_item(build, fan, living.id, %{x: 100, y: 100})
    {build, other} = add(build, "Living room", "other")

    # 3 inches from the right side of the fan, which is up on the ceiling:
    # no snap.
    {:ok, build} = drop(build, other, "Living room", %{x: 155, y: 110})
    assert item(build, other).at == %{x: 155, y: 110}

    # The fan near the item on the floor: no snap.
    {:ok, build} = drop(build, fan, "Living room", %{x: 100, y: 113})
    assert item(build, fan).at == %{x: 100, y: 113}
  end

  test "a file keeps the item under an item, and repairs a bad one" do
    build = house()
    washer = first(build, "Laundry", "washer")
    {build, dryer} = add(build, "Laundry", "dryer")
    {:ok, build} = drop(build, dryer, "Laundry", washer.at)

    {:ok, read} = Build.from_json(Build.to_json(build))
    assert item(read, dryer).on == washer.id

    map = Jason.decode!(Build.to_json(build))

    # A bad item under the dryer goes away. The dryer is over the washer,
    # so it goes on it again. Far from the washer, it is on the floor. The
    # read does not see an `on` that is not a text.
    for bad <- ["nothing", dryer, 42], at <- [washer.at, %{x: 0, y: 70}] do
      items =
        Enum.map(map["items"], fn item ->
          if item["id"] == dryer,
            do: Map.merge(item, %{"on" => bad, "at" => at}),
            else: item
        end)

      {:ok, read} = Build.from_json(Jason.encode!(%{map | "items" => items}))

      assert Map.get(item(read, dryer), :on) ==
               if(at == washer.at and is_binary(bad), do: washer.id)
    end
  end

  test "normalize drops an on that breaks a rule, and puts the item on the item that holds it" do
    a = %{id: "a", type: "washer", room: "r1", at: %{x: 0, y: 0}, size: nil, turn: 0, params: %{}}
    b = %{a | id: "b", type: "dryer"}
    rooms = %{"r1" => %{place: :indoor, level: "f1"}, "r2" => %{place: :indoor, level: "f1"}}
    on = &Map.put(&1, :on, &2)

    # An item on itself, and a loop: the on goes away. Then the items go on
    # each other again, with no loop.
    assert Stack.normalize([on.(a, "a")], rooms) == [a]
    assert Stack.normalize([on.(a, "b"), on.(b, "a")], rooms) == [a, on.(b, "a")]

    # A loop under an item: the loop goes away, and the item stays on it.
    # An item on an item that is not there comes down.
    c = %{b | id: "c", type: "cpap"}
    result = Stack.normalize([on.(a, "b"), on.(b, "a"), on.(c, "a")], rooms)
    assert Enum.find(result, &(&1.id == "c")).on == "a"
    assert Stack.normalize([on.(a, "x"), on.(c, "a")], rooms) == [a, on.(c, "a")]

    # In a different room, not over, or with no place: the item is on the
    # floor.
    other = %{b | room: "r2"}
    assert Stack.normalize([a, on.(other, "a")], rooms) == [a, other]
    far = %{b | at: %{x: 100, y: 0}}
    assert Stack.normalize([a, on.(far, "a")], rooms) == [a, far]
    loose = %{b | at: nil}
    assert Stack.normalize([a, on.(loose, "a")], rooms) == [a, loose]

    # Kinds that do not stack, a larger item, and a room with no stack (the
    # roof, a van, a room that is not there).
    panels = %{b | type: "solar_panels"}
    assert Stack.normalize([a, on.(panels, "a")], rooms) == [a, panels]
    # The freezer is larger than the washer: it comes down.
    freezer = %{b | type: "freezer"}
    assert Stack.normalize([a, on.(freezer, "a")], rooms) == [a, freezer]

    for room <- [%{place: :roof, level: "roof"}, %{place: :living, level: "van:v1"}, nil] do
      assert Stack.normalize([a, on.(b, "a")], %{"r1" => room}) == [a, b]
    end

    # A dryer that comes down goes on the washer that holds it. A dryer on
    # the floor that did not come down stays on the floor.
    good = on.(b, "a")
    c = %{b | id: "c"}
    assert Stack.normalize([a, on.(c, "x"), b], rooms) == [a, on.(c, "a"), b]
    assert Stack.normalize([a, good], rooms) == [a, good]
    assert Stack.heights([a, good]) == %{"b" => 39}
  end

  test "a pool takes an item on its coping, not on its water" do
    pool = %{
      id: "p",
      type: "pool",
      room: "r1",
      at: %{x: 0, y: 0},
      size: nil,
      turn: 0,
      params: %{}
    }

    pump = %{pool | id: "q", type: "pool_pump", at: %{x: 100, y: 0}}
    # The coping is 24 inches. The pump (25 by 8) at the back: its center
    # is on the coping. In the middle: on the water.
    assert Stack.holds?(pool, pump)
    refute Stack.holds?(pool, %{pump | at: %{x: 100, y: 100}})
    refute Stack.holds?(pool, %{pump | at: nil})
    assert Stack.heights([pool, Map.put(pump, :on, "p")]) == %{"q" => 0}
  end

  test "carry with an item that has no place moves only the item" do
    a = %{id: "a", type: "washer", room: "r1", at: nil}
    assert Stack.carry([a], a, %{a | room: "r2"}, %{"r2" => %{plan: nil}}) == [%{a | room: "r2"}]
  end

  # The rules of a stack (`specs/Stack.tla`). Each item on an item is on
  # an item of its room that is there and holds it. The two kinds stack.
  # No item is under itself. An item that came down in the step is on the
  # floor only when no item holds it. Each item fits its room. A file
  # gives the same items.
  defp check_rules(before, build) do
    by_id = Map.new(build.items, &{&1.id, &1})
    rooms = Map.new(build.rooms, &{&1.id, &1})

    for item <- build.items,
        do: assert(Catalog.fits?(Catalog.kind(item.type), rooms[item.room]), item.type)

    for %{on: on} = item <- build.items do
      base = by_id[on]
      assert base, "#{item.id} is on #{on}, which is not there"
      assert base.room == item.room
      assert Stack.goes_on?(item) and Stack.takes?(base)
      assert over?(item, base) and Stack.holds?(base, item)

      chain = Stream.iterate(on, &(by_id[&1] && Map.get(by_id[&1], :on)))
      refute item.id in Enum.take(chain, length(build.items) + 1), "#{item.id} is in a loop"
    end

    was = Map.new(before.items, &{&1.id, Map.get(&1, :on)})

    for item <- build.items,
        was[item.id] != nil and Map.get(item, :on) == nil and item.at != nil and
          Stack.goes_on?(item) and Stack.stacks?(rooms[item.room]),
        base <- build.items,
        base.id != item.id and base.room == item.room and Stack.takes?(base) and
          Stack.holds?(base, item) do
      assert base.id in Stack.above(build.items, item.id),
             "#{item.id} is on the floor in #{base.id}"
    end

    {:ok, read} = Build.from_json(Build.to_json(build))
    assert read.items == build.items
  end

  defp step do
    one_of([
      tuple(
        {constant(:drop), integer(0..9), member_of(["Kitchen", "Laundry", "Backyard"]),
         integer(-20..200), integer(-20..200), boolean()}
      ),
      tuple({constant(:delete), integer(0..9)}),
      tuple({constant(:move), integer(0..9), member_of(["Kitchen", "Laundry", "Backyard"])}),
      tuple({constant(:turn), integer(0..9)}),
      tuple({constant(:size), integer(0..9), integer(4..80), integer(4..80)}),
      tuple({constant(:room), member_of(["Kitchen", "Laundry"]), integer(40..200)})
    ])
  end

  defp run(build, ids, {:drop, i, room, x, y, snap}) do
    Build.place_item(build, Enum.at(ids, i), room(build, room).id, %{x: x, y: y}, snap)
  end

  defp run(build, ids, {:delete, i}), do: Build.delete_item(build, Enum.at(ids, i))

  defp run(build, ids, {:move, i, room}),
    do: Build.move_item(build, Enum.at(ids, i), room(build, room).id)

  defp run(build, ids, {:turn, i}), do: Build.turn_item(build, Enum.at(ids, i))

  defp run(build, ids, {:size, i, w, d}),
    do: Build.size_item(build, Enum.at(ids, i), %{w: w, d: d, h: 30})

  defp run(build, _ids, {:room, name, w}) do
    room = room(build, name)
    Build.size_room(build, room.id, %{room.plan | w: w})
  end

  property "drops, moves, turns, sizes and deletes keep the rules of a stack" do
    types = ~w(washer dryer microwave cpap computer tv pool_pump hot_tub other space_heater)

    check all(steps <- list_of(step(), max_length: 30), max_runs: 60) do
      {build, ids} =
        Enum.reduce(types, {house(), []}, fn type, {build, ids} ->
          {build, id} = add(build, "Laundry", type)
          {build, ids ++ [id]}
        end)

      Enum.reduce(steps, build, fn step, build ->
        case run(build, ids, step) do
          {:ok, after_} ->
            check_rules(build, after_)
            after_

          {:error, _reason} ->
            build
        end
      end)
    end
  end

  property "a drop on an item puts it in the space of the item, or at its center" do
    check all(
            x <- integer(-10..140),
            y <- integer(-10..140),
            type <- member_of(~w(cpap tv computer dryer))
          ) do
      build = house()
      washer = first(build, "Laundry", "washer")
      {build, id} = add(build, "Laundry", type)
      {:ok, build} = drop(build, id, "Laundry", %{x: x, y: y})
      dropped = item(build, id)

      # The washer is at the back corner of the laundry: the walls clamp an
      # item that is larger than it.
      if Map.get(dropped, :on) == washer.id do
        box = Layout.item_box(dropped)
        base = Layout.item_box(washer)

        for {a, size, from, length} <- [
              {box.x, box.w, base.x, base.w},
              {box.y, box.d, base.y, base.d}
            ] do
          if size <= length,
            do: assert(a >= from and a + size <= from + length),
            else: assert(a == max(from + div(length - size, 2), 0))
        end
      end
    end
  end

  property "the items on an item keep their place on it when it moves in its room" do
    check all(dx <- integer(-60..60), dy <- integer(-60..60)) do
      build = house()
      washer = first(build, "Laundry", "washer")
      {build, dryer} = add(build, "Laundry", "dryer")
      {:ok, build} = drop(build, dryer, "Laundry", washer.at)
      plan = room(build, "Laundry").plan

      to = %{x: washer.at.x + dx, y: washer.at.y + dy}
      {:ok, moved} = Build.place_item(build, washer.id, washer.room, to)
      new = item(moved, washer.id)
      assert new.at == Layout.clamp(to, washer, plan)
      assert item(moved, dryer).at == new.at
      assert item(moved, dryer).on == washer.id
    end
  end
end
