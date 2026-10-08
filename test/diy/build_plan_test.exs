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
    assert Build.place_item(build, fridge.id, bed.id, %{x: 0, y: 0}) == {:error, :room}
    assert Build.place_item(build, "nothing", kitchen.id, %{x: 0, y: 0}) == {:error, :item}
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

    {:ok, sized} = Build.size_item(build, tv.id, %{w: 57, d: 12, h: 35})
    assert Layout.size(item(sized, tv.id)) == {57, 12, 35}
    {:ok, typical} = Build.size_item(sized, tv.id, nil)
    assert Layout.size(item(typical, tv.id)) == {44, 10, 28}
    assert Build.size_item(build, tv.id, %{w: 0, d: 12, h: 35}) == {:error, :size}

    # A large size: the item stays in its room, at 0.
    {:ok, huge} = Build.size_item(build, tv.id, %{w: 1200, d: 12, h: 35})
    assert item(huge, tv.id).at.x == 0
  end

  test "an item in a van has no place, and gets a free place at home" do
    build = house()
    {:ok, build, station} = Build.add_item(build, room(build, "Laundry").id, "power_station")
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway").id, "camper_van")
    assert item(build, station).at != nil
    assert Build.turn_item(build, Build.zone(build, van, :bay).id) == {:error, :item}

    {:ok, away} = Build.take_to_van(build, station, van)
    assert item(away, station).at == nil
    assert Build.turn_item(away, station) == {:error, :room}
    assert Enum.all?(Build.zones(away, van), &(&1.plan == nil))

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
    ids = Enum.map(build.items, & &1.id)

    on_rooms =
      if rooms == [],
        do: [],
        else: [
          tuple({constant(:move_room), member_of(rooms), integer(-600..900), integer(-600..900)}),
          tuple({constant(:size_room), member_of(rooms), plan()}),
          tuple({constant(:add_item), member_of(rooms), member_of(Catalog.types())}),
          tuple({constant(:delete_room), member_of(rooms)})
        ]

    on_items =
      if ids == [] or rooms == [],
        do: [],
        else: [
          tuple(
            {constant(:place), member_of(ids), member_of(rooms), integer(-100..900),
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
      ] ++ on_rooms ++ on_items
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

  defp apply_step(build, {:delete_room, room}), do: Build.delete_room(build, room.id)
  defp apply_step(build, {:delete_item, id}), do: Build.delete_item(build, id)

  # The rules of the plan (`DIY.Layout`).
  defp assert_rules(build) do
    {house, vans} = Enum.split_with(build.rooms, &(not Build.van_level?(&1.level)))
    assert Enum.all?(house, &Layout.valid_plan?(&1.plan))
    assert Enum.all?(vans, &(&1.plan == nil))

    for {a, i} <- Enum.with_index(house),
        {b, j} <- Enum.with_index(house),
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
    check all(floors <- integer(1..3), seeds <- list_of(integer(), max_length: 20), max_runs: 60) do
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
