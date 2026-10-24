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

    for type <- ~w(washer range pool ev other), do: assert(Stack.takes?(%{type: type}))

    for type <- ~w(solar_panels camper_van smart_meter mini_split),
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

    # An item larger than the item under it is at its center. A tv (44 by
    # 10) on the range (30 by 28): at the center along x.
    {build, tv} = add(build, "Kitchen", "tv")
    {:ok, build} = drop(build, tv, "Kitchen", %{x: base.x - 10, y: base.y + 2})
    tv = item(build, tv)
    assert tv.on == range.id
    assert tv.at.x == base.x - 7
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
    {build, bus} = add(build, "Laundry", "dc_bus")
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

  test "a file keeps the item under an item, and drops a bad one" do
    build = house()
    washer = first(build, "Laundry", "washer")
    {build, dryer} = add(build, "Laundry", "dryer")
    {:ok, build} = drop(build, dryer, "Laundry", washer.at)

    {:ok, read} = Build.from_json(Build.to_json(build))
    assert item(read, dryer).on == washer.id

    map = Jason.decode!(Build.to_json(build))

    for bad <- ["nothing", dryer, 42] do
      items =
        Enum.map(map["items"], &if(&1["id"] == dryer, do: Map.put(&1, "on", bad), else: &1))

      {:ok, read} = Build.from_json(Jason.encode!(%{map | "items" => items}))
      refute Map.has_key?(item(read, dryer), :on)
    end
  end

  test "normalize drops an item on itself, a loop, an item in another room, and an item that is not over" do
    a = %{id: "a", type: "washer", room: "r1", at: %{x: 0, y: 0}, size: nil, turn: 0, params: %{}}
    b = %{a | id: "b", type: "dryer"}

    assert Stack.normalize([Map.put(a, :on, "a")]) == [a]
    assert Stack.normalize([Map.put(a, :on, "b"), Map.put(b, :on, "a")]) == [a, b]
    assert Stack.normalize([a, Map.put(%{b | room: "r2"}, :on, "a")]) == [a, %{b | room: "r2"}]
    far = %{b | at: %{x: 100, y: 0}}
    assert Stack.normalize([a, Map.put(far, :on, "a")]) == [a, far]
    assert Stack.normalize([a, Map.put(%{b | at: nil}, :on, "a")]) == [a, %{b | at: nil}]
    panels = %{b | type: "solar_panels"}
    assert Stack.normalize([a, Map.put(panels, :on, "a")]) == [a, panels]
    good = Map.put(b, :on, "a")
    assert Stack.normalize([a, good]) == [a, good]
    assert Stack.heights([a, good]) == %{"b" => 39}
  end

  test "carry with an item that has no place moves only the item" do
    a = %{id: "a", type: "washer", room: "r1", at: nil}
    assert Stack.carry([a], a, %{a | room: "r2"}, %{"r2" => %{plan: nil}}) == [%{a | room: "r2"}]
  end

  # The rules of a stack (`specs/Stack.tla`): each item on an item is on
  # an item of its room that is there, over it, and of kinds that stack,
  # and no item is under itself. Each item fits its room.
  defp check_rules(build) do
    by_id = Map.new(build.items, &{&1.id, &1})
    rooms = Map.new(build.rooms, &{&1.id, &1})

    for item <- build.items,
        do: assert(Catalog.fits?(Catalog.kind(item.type), rooms[item.room]), item.type)

    for %{on: on} = item <- build.items do
      base = by_id[on]
      assert base, "#{item.id} is on #{on}, which is not there"
      assert base.room == item.room
      assert Stack.goes_on?(item) and Stack.takes?(base)
      assert over?(item, base)

      chain = Stream.iterate(on, &(by_id[&1] && Map.get(by_id[&1], :on)))
      refute item.id in Enum.take(chain, length(build.items) + 1), "#{item.id} is in a loop"
    end
  end

  defp step do
    one_of([
      tuple(
        {constant(:drop), integer(0..9), member_of(["Kitchen", "Laundry", "Backyard"]),
         integer(-20..200), integer(-20..200), boolean()}
      ),
      tuple({constant(:delete), integer(0..9)}),
      tuple({constant(:move), integer(0..9), member_of(["Kitchen", "Laundry", "Backyard"])}),
      tuple({constant(:turn), integer(0..9)})
    ])
  end

  defp run(build, ids, {:drop, i, room, x, y, snap}) do
    Build.place_item(build, Enum.at(ids, i), room(build, room).id, %{x: x, y: y}, snap)
  end

  defp run(build, ids, {:delete, i}), do: Build.delete_item(build, Enum.at(ids, i))

  defp run(build, ids, {:move, i, room}),
    do: Build.move_item(build, Enum.at(ids, i), room(build, room).id)

  defp run(build, ids, {:turn, i}), do: Build.turn_item(build, Enum.at(ids, i))

  property "drops, moves, turns and deletes keep the rules of a stack" do
    types = ~w(washer dryer microwave cpap computer tv pool_pump hot_tub other space_heater)

    check all(steps <- list_of(step(), max_length: 30), max_runs: 60) do
      {build, ids} =
        Enum.reduce(types, {house(), []}, fn type, {build, ids} ->
          {build, id} = add(build, "Laundry", type)
          {build, ids ++ [id]}
        end)

      Enum.reduce(steps, build, fn step, build ->
        case run(build, ids, step) do
          {:ok, build} ->
            check_rules(build)
            build

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
