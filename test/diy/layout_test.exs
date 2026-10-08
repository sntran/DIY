defmodule DIY.LayoutTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, House, Layout}

  @house %{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil}

  defp house(numbers \\ @house) do
    {house, rooms, items} = House.preset(numbers)
    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  test "the floor of a house is a rectangle of 3 by 2 with the area of a floor" do
    assert Layout.footprint(@house) == {438, 294}
    assert Layout.footprint(%{@house | floors: 1}) == {624, 414}
  end

  test "the draft of a preset: the rooms of a floor in a row, and the rooms outside" do
    build = house()
    plan = &room(build, &1).plan

    # Floor 1: the living room is the largest, the laundry the smallest.
    assert plan.("Kitchen") == %{x: 0, y: 0, w: 144, d: 294}
    assert plan.("Living room") == %{x: 144, y: 0, w: 216, d: 294}
    assert plan.("Laundry") == %{x: 360, y: 0, w: 78, d: 294}
    assert plan.("Bedroom 1") == %{x: 0, y: 0, w: 174, d: 294}
    assert plan.("Bathroom") == %{x: 348, y: 0, w: 90, d: 294}
    assert plan.("Roof") == %{x: 0, y: 0, w: 438, d: 294}
    assert plan.("Attic") == %{x: 0, y: 0, w: 438, d: 294}

    # The garage is on the right, the driveway in front of it, and the
    # yard in front of the house.
    assert plan.("Garage") == %{x: 438, y: 0, w: 288, d: 288}
    assert plan.("Driveway") == %{x: 438, y: 288, w: 288, d: 240}
    assert plan.("Backyard") == %{x: 0, y: 294, w: 438, d: 300}

    # Each item is in its room: the first items of a room are along its
    # back wall.
    for item <- build.items, do: assert(item.at != nil)
    [fridge, range | _] = Build.items_in(build, room(build, "Kitchen").id)
    assert fridge.at == %{x: 0, y: 0}
    assert range.at == %{x: 36, y: 0}
  end

  test "more rooms on a floor go in rows, and the house is large enough for them" do
    rooms = for n <- 1..7, do: %{name: "Room #{n}", level: "f1", place: :indoor}
    plans = Layout.draft(%{size: 400, floors: 1}, rooms)
    assert plans |> Enum.map(& &1.y) |> Enum.uniq() |> length() == 2
    assert Enum.all?(plans, &(&1.w >= Layout.min_room() and &1.d >= Layout.min_room()))
    assert Layout.box(plans).w >= 90 * 4
  end

  test "the layers of the rooms" do
    assert Layout.layer(%{level: "outside", place: :outdoor}) == "ground"
    assert Layout.layer(%{level: "f1", place: :indoor}) == "ground"
    assert Layout.layer(%{level: "f2", place: :indoor}) == "f2"
    assert Layout.layer(%{level: "roof", place: :roof}) == "roof"
    assert Layout.layer(%{level: "roof", place: :indoor}) == "attic"
  end

  test "the size of an item: typical, from the user, and an array of panels" do
    fridge = %{type: "fridge", size: nil, turn: 0, params: %{}}
    assert Layout.size(fridge) == {36, 30, 70}
    assert Layout.size(%{fridge | size: %{w: 30, d: 28, h: 66}}) == {30, 28, 66}
    assert Layout.extent(%{fridge | turn: 1}) == {30, 36}
    assert Layout.extent(%{fridge | turn: 2}) == {36, 30}

    panels = %{type: "solar_panels", size: nil, turn: 0, params: %{"watts" => 1600}}
    assert Layout.panel_grid(1600) == {3, 2}
    assert Layout.size(panels) == {123, 138, 2}
    assert Layout.panels(100) == 1
    assert Layout.panel_grid(100) == {1, 1}
  end

  test "an item stays in its room" do
    fridge = %{type: "fridge", size: nil, turn: 0, params: %{}}
    room = %{x: 0, y: 0, w: 100, d: 50}
    assert Layout.clamp(%{x: 90, y: -5}, fridge, room) == %{x: 64, y: 0}
    # Larger than its room: at 0.
    assert Layout.clamp(%{x: 10, y: 10}, fridge, %{room | w: 20}) == %{x: 0, y: 10}
  end

  test "the free place of an item, and a room with no free place" do
    fridge = %{type: "fridge", size: nil, turn: 0, params: %{}}
    room = %{x: 0, y: 0, w: 72, d: 30}
    assert Layout.free_at(fridge, room, []) == %{x: 0, y: 0}
    assert Layout.free_at(fridge, room, [%{x: 0, y: 0, w: 36, d: 30}]) == %{x: 36, y: 0}
    full = [%{x: 0, y: 0, w: 72, d: 30}]
    assert Layout.free_at(fridge, room, full) == %{x: 0, y: 0}
  end

  test "the limits of the plan" do
    assert {Layout.min_room(), Layout.max_room()} == {24, 2400}
    assert {Layout.max_size(), Layout.max_at()} == {1200, 12_000}
  end

  test "a room outside with no room on the ground goes on the right of the house" do
    build = house()

    build =
      Enum.reduce(build.rooms, build, fn room, build ->
        if Layout.layer(room) == "ground",
          do: elem(Build.delete_room(build, room.id), 1),
          else: build
      end)

    {:ok, build, _id} = Build.add_room(build, "Yard", "outside", :outdoor)
    assert room(build, "Yard").plan == %{x: 438, y: 0, w: 240, d: 240}
  end

  test "valid plans and sizes" do
    assert Layout.valid_plan?(%{x: -10, y: 0, w: 24, d: 2400})
    refute Layout.valid_plan?(%{x: 0, y: 0, w: 23, d: 100})
    refute Layout.valid_plan?(%{x: 0, y: 0, w: 2401, d: 100})
    refute Layout.valid_plan?(%{x: 12_001, y: 0, w: 100, d: 100})
    refute Layout.valid_plan?(%{x: 0.5, y: 0, w: 100, d: 100})
    refute Layout.valid_plan?(nil)
    assert Layout.valid_size?(%{w: 1, d: 1200, h: 5})
    refute Layout.valid_size?(%{w: 0, d: 10, h: 5})
    refute Layout.valid_size?(%{w: 10, d: 10, h: 1201})
    refute Layout.valid_size?(%{w: "10", d: 10, h: 10})
    refute Layout.valid_size?(nil)
  end

  test "a new room goes to a free place" do
    build = house()
    # Floor 2 is full: a new room goes on the right of the house.
    {:ok, build, office} = Build.add_room(build, "Office", "f2", :indoor)
    assert room(build, "Office").plan == %{x: 438, y: 0, w: 144, d: 144}

    # Floor 3 does not exist in this house; on a house of 3 floors, a room
    # of floor 3 is in the house.
    {:ok, build} = Build.delete_room(build, office)
    {:ok, build} = Build.update_house(build, %{floors: 3})
    {:ok, build, _id} = Build.add_room(build, "Den", "f3", :indoor)
    assert room(build, "Den").plan == %{x: 0, y: 0, w: 144, d: 144}

    # A second roof is on the right of the first.
    {:ok, build, _id} = Build.add_room(build, "Porch roof", "roof", :roof)
    assert room(build, "Porch roof").plan == %{x: 438, y: 0, w: 144, d: 144}

    # Outside, a new room goes on the right of the rooms of the ground.
    {:ok, build, _id} = Build.add_room(build, "Shed", "outside", :indoor)
    assert room(build, "Shed").plan == %{x: 726, y: 0, w: 144, d: 144}
  end

  test "a house with no room of a floor, and a first roof that covers the house" do
    build = house(%{@house | floors: 1})

    build =
      Enum.reduce(build.rooms, build, fn room, build ->
        if room.level in ["f1", "roof"],
          do: elem(Build.delete_room(build, room.id), 1),
          else: build
      end)

    assert Layout.house_box(build) == %{x: 0, y: 0, w: 624, d: 414}
    {:ok, build, _id} = Build.add_room(build, "Roof", "roof", :roof)
    assert room(build, "Roof").plan == %{x: 0, y: 0, w: 624, d: 414}
  end

  test "a stored plan that overlaps a room before it goes to a free place" do
    build = house()
    kitchen = room(build, "Kitchen")

    rooms =
      Enum.map(build.rooms, &if(&1.name == "Laundry", do: %{&1 | plan: kitchen.plan}, else: &1))

    fixed = Layout.fill(%{build | rooms: rooms})
    assert room(fixed, "Kitchen").plan == kitchen.plan
    refute Layout.overlap?(room(fixed, "Laundry").plan, kitchen.plan)
  end

  # Random rooms of a house.
  defp rooms do
    gen all(
          floors <- integer(1..3),
          size <- integer(200..20_000),
          rooms <-
            list_of(
              tuple({
                member_of(Build.levels(floors)),
                member_of([:indoor, :outdoor, :roof]),
                member_of(~w(Kitchen Living Bath Bedroom Driveway Yard Shed Office Roof))
              }),
              min_length: 1,
              max_length: 25
            )
        ) do
      {%{size: size, floors: floors},
       Enum.map(rooms, fn {level, place, name} -> %{level: level, place: place, name: name} end)}
    end
  end

  property "a draft has valid plans, and no two rooms of a layer overlap" do
    check all({house, rooms} <- rooms()) do
      plans = Layout.draft(house, rooms)
      assert length(plans) == length(rooms)
      assert Enum.all?(plans, &Layout.valid_plan?/1)

      pairs = Enum.zip(rooms, plans)

      for {{a, pa}, i} <- Enum.with_index(pairs),
          {{b, pb}, j} <- Enum.with_index(pairs),
          i < j,
          Layout.layer(a) == Layout.layer(b) do
        refute Layout.overlap?(pa, pb), "#{inspect(a)} and #{inspect(b)} overlap"
      end
    end
  end
end
