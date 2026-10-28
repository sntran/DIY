defmodule DIYWeb.DecorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, House, Layout}
  alias DIYWeb.{Camera, Decor}
  alias DIYWeb.Icon.Shapes

  @m 0.0254

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))
  defp items(build, room), do: Enum.filter(build.items, &(&1.room == room.id))

  @names ~w(bed nightstand dresser rug bath_mat sofa armchair coffee_table shelf_books dining
             tree tub toilet vanity bench shelf basket boxes round_table)

  # The pieces of a room of the preset house, as the names of their models.
  defp names(build, name) do
    room = room(build, name)

    for {model, _x, _y, _turn} <- Decor.pieces(room, items(build, room)) do
      Enum.find(@names, &(Decor.model(&1) == model)) || :counter
    end
  end

  # The pieces of a room with no item, as the names of their models.
  defp pieces(room) do
    for {model, _x, _y, _turn} <- Decor.pieces(room, []) do
      Enum.find(@names, &(Decor.model(&1) == model)) || :counter
    end
  end

  # The box of a piece on the plan of its room (inches).
  defp box({model, x, y, turn}) do
    {{x0, y0, _}, {x1, y1, _}} = Shapes.bounds(model)
    {w, d} = {round((x1 - x0) / @m), round((y1 - y0) / @m)}
    {w, d} = if rem(turn, 2) == 0, do: {w, d}, else: {d, w}
    %{x: x, y: y, w: w, d: d}
  end

  defp height({model, _x, _y, _turn}) do
    {{_, _, z0}, {_, _, z1}} = Shapes.bounds(model)
    z1 - z0
  end

  defp flat?(piece), do: height(piece) < 0.02

  test "the name of a room gives its furniture" do
    build = house()
    # No room inside has a plant: plants hide the plan.
    assert ~w(rug bed nightstand nightstand dresser) == names(build, "Bedroom 1")
    assert ~w(rug sofa coffee_table armchair shelf_books) == names(build, "Living room")

    # The counters fill the back wall of the kitchen at the right of the
    # dishwasher. The table is in the dining room, not in the kitchen.
    assert [:counter] == names(build, "Kitchen")
    assert ~w(bath_mat tub toilet vanity) == names(build, "Bathroom")
    # The shelf at the back left of the garage does not show: the water
    # heater is there.
    assert ~w(bench) == names(build, "Garage")
    # The washer and the dryer fill the back of the laundry: no shelf.
    assert ~w(basket) == names(build, "Laundry")
    # The furnace is at the back left of the attic.
    assert ~w(boxes) == names(build, "Attic")
    # The AC is at the back left of the backyard: the tree there does not
    # show.
    assert ~w(round_table) == names(build, "Backyard")
    assert [] == names(build, "Driveway")
    assert [] == names(build, "Roof")

    # The stairs go up from floor 1. An upper floor has their opening.
    stairs = %{
      room(build, "Bedroom 1")
      | name: "Entry and stairs",
        level: "f1",
        plan: %{x: 0, y: 0, w: 120, d: 216}
    }

    assert [{model, _x, _y, 0}] = Decor.pieces(stairs, [])
    assert model == Decor.model({"stairs", 13})

    # A room that is less deep has stairs with less steps: 120 inches
    # less 2 gaps of 4 inches give 10 steps of 11 inches. A room with
    # space for less than 4 steps has no stairs.
    short = %{stairs | plan: %{x: 0, y: 0, w: 48, d: 120}}
    assert [{model, _x, _y, 0}] = Decor.pieces(short, [])
    assert model == Decor.model({"stairs", 10})
    assert [] == Decor.pieces(%{stairs | plan: %{x: 0, y: 0, w: 48, d: 48}}, [])

    hall = %{stairs | name: "Hall and stairs", level: "f2", plan: %{x: 0, y: 0, w: 132, d: 144}}

    assert Enum.map(Decor.pieces(hall, []), &elem(&1, 0)) == [Decor.model("stair_well")]

    # "Upstairs" is not the word "stairs": an upstairs bedroom has the
    # pieces of a bedroom.
    upstairs = %{hall | name: "Upstairs bedroom"}
    bedroom = %{hall | name: "Bedroom"}
    assert Decor.pieces(upstairs, []) == Decor.pieces(bedroom, [])

    # A room with a name that the app does not know has no furniture. A
    # hall and a closet have none: the way stays open. This is also true
    # for the closet of a bedroom.
    big = %{room(build, "Bedroom 1") | plan: %{x: 0, y: 0, w: 300, d: 300}}

    for name <- ["Office", "Hall", "Hallway", "Main closet", "Closet of bedroom 2"],
        do: assert(Decor.pieces(%{big | name: name}, []) == [], name)

    # The table with chairs is in the dining room. A kitchen with "dining"
    # in its name has its counters and the table. The breakfast room has a
    # small round table.
    assert ~w(dining) == pieces(%{big | name: "Dining room"})
    assert [:counter, "dining"] == pieces(%{big | name: "Kitchen and dining"})
    assert ~w(round_table) == pieces(%{big | name: "Breakfast"})
  end

  test "the stairs always show, also when they hide an item of a different room" do
    stairs = %{
      name: "Stairs",
      place: :indoor,
      level: "f1",
      plan: %{x: 0, y: 0, w: 54, d: 114}
    }

    living = %{stairs | name: "Living room", plan: %{x: 0, y: 0, w: 216, d: 216}}
    item = %{type: "always_on", at: %{x: 6, y: 90}, size: nil, turn: 0, params: %{}}
    around = Decor.boxes([item], {-42, -24})

    # The stairs hide the item at their back left. A sofa in their place
    # does not show, but the stairs do.
    assert Enum.any?(around, &Decor.hides?(%{x: 0, y: 0, w: 35, d: 110}, 2.0, &1))
    assert [{model, _x, _y, 0}] = Decor.pieces(stairs, [], around)
    assert model == Decor.model({"stairs", 9})
    refute Decor.pieces(living, [], Decor.boxes([item], {0, 0})) == Decor.pieces(living, [])

    # An item of the room of the stairs still stops them.
    refute Decor.pieces(stairs, [%{item | at: %{x: 20, y: 40}}]) |> Enum.any?()
  end

  test "the counters of a kitchen fill the back wall where no item is" do
    kitchen = %{room(house(), "Kitchen") | plan: %{x: 0, y: 0, w: 144, d: 200}}
    item = fn type, x -> %{type: type, at: %{x: x, y: 0}, size: nil, turn: 0, params: %{}} end

    counters = fn items ->
      for {_m, x, 1, 0} = p <- Decor.pieces(kitchen, items), x != 45, do: box(p)
    end

    # With no item: one counter along all the wall, 4 inches from each
    # wall.
    assert [%{x: 4, w: 136}] = counters.([])

    # A fridge at the left: the counter starts 4 inches after it.
    assert [%{x: 37, w: 103}] = counters.([item.("fridge", 0)])

    # A range (30 inches) in the middle: two counters. A part shorter than
    # 18 inches stays empty.
    assert [%{x: 4, w: 42}, %{x: 84, w: 56}] = counters.([item.("range", 50)])
    assert [%{x: 4, w: 112}] = counters.([item.("range", 120)])

    # A small item in the space of the fridge (on top of it): the counter
    # starts after the fridge.
    assert [%{x: 37, w: 103}] = counters.([item.("fridge", 0), item.("always_on", 10)])

    # An item past the right wall (a room that became smaller) cuts nothing.
    assert [%{x: 4, w: 136}] = counters.([item.("range", 200)])

    # An item at the front of the room does not cut the counter.
    assert [%{x: 4, w: 136}] = counters.([%{item.("range", 50) | at: %{x: 50, y: 150}}])

    # An item just in front of the counters (from 29 inches) cuts them. An
    # item from 30 inches does not touch them.
    heater = fn y -> [%{item.("space_heater", 60) | at: %{x: 60, y: y}}] end
    assert [%{x: 4, w: 52}, %{x: 74, w: 66}] = counters.(heater.(29))
    assert [%{x: 4, w: 136}] = counters.(heater.(30))

    # An item on the wall over the counters (a meter) does not cut them.
    assert [%{x: 4, w: 136}] = counters.([item.("smart_meter", 50)])
  end

  # A random room of a name, with random items at random places and turns.
  defp random_room do
    names =
      ["Bedroom", "Living", "Kitchen", "Dining", "Breakfast", "Bathroom", "Garage", "Laundry"] ++
        ["Attic", "Office", "Hall", "Stairs", "Backyard", "Front yard", "Side yard"]

    types = Enum.map(Catalog.kinds(), & &1.type) -- ~w(camper_van solar_panels)

    gen all(
          name <- member_of(names),
          w <- integer(24..400),
          d <- integer(24..400),
          spots <-
            list_of(
              tuple({member_of(types), integer(0..400), integer(0..400), integer(0..3)}),
              max_length: 6
            )
        ) do
      place = if String.contains?(name, "yard"), do: :outdoor, else: :indoor
      room = %{name: name, place: place, level: "f1", plan: %{x: 0, y: 0, w: w, d: d}}

      items =
        for {type, x, y, turn} <- spots do
          item = %{type: type, at: %{x: 0, y: 0}, size: nil, turn: turn, params: %{}}
          %{item | at: Layout.clamp(%{x: x, y: y}, item, room.plan)}
        end

      {room, items}
    end
  end

  property "a piece is in its room, and never on an item under its top or on a different piece" do
    check all({room, items} <- random_room()) do
      pieces = Decor.pieces(room, items)
      solid = Enum.reject(pieces, &flat?/1)

      for piece <- pieces, b = box(piece) do
        assert b.x >= 0 and b.y >= 0 and b.x + b.w <= room.plan.w and b.y + b.d <= room.plan.d
      end

      for a <- solid, b <- Decor.boxes(items, {0, 0}), b.low < height(a) do
        refute Layout.overlap?(box(a), b)
      end

      for {a, i} <- Enum.with_index(solid),
          {b, j} <- Enum.with_index(solid),
          i < j,
          do: refute(Layout.overlap?(box(a), box(b)))
    end
  end

  # The camera looks down to the back and to the left. Take a point of the
  # box of an item, at the middle of its height. A piece hides it when the
  # piece is on the line from it to the eye. The test follows this line in
  # small steps. The points are a grid of 10 by 10, and the steps are not
  # exact: so the limit is 35 points, not 25.
  property "a piece hides at most a quarter of an item at the middle of its height" do
    {ex, ey, ez} = Camera.house().eye
    {kx, ky} = {ex / ez / @m, ey / ez / @m}

    check all({room, items} <- random_room()) do
      for piece <- Decor.pieces(room, items),
          not flat?(piece),
          p = box(piece),
          high = height(piece),
          item <- Decor.boxes(items, {0, 0}),
          mid = (item.low + item.high) / 2,
          mid < high do
        samples =
          for i <- 0..9, j <- 0..9 do
            {x, y} = {item.x + (i + 0.5) * item.w / 10, item.y + (j + 0.5) * item.d / 10}

            Enum.any?(0..20, fn k ->
              t = (high - mid) * k / 20
              {px, py} = {x + t * kx, y + t * ky}
              px > p.x and px < p.x + p.w and py > p.y and py < p.y + p.d
            end)
          end

        assert Enum.count(samples, & &1) <= 35, "#{room.name}: #{inspect({piece, item})}"
      end
    end
  end

  test "a piece does not hide an item behind it, also of a different room" do
    item = fn type, x, y -> %{type: type, at: %{x: x, y: y}, size: nil, turn: 0, params: %{}} end
    living = %{name: "Living room", place: :indoor, plan: %{x: 0, y: 0, w: 216, d: 294}}
    sofa = Decor.model("sofa")

    has_sofa? = fn items, around ->
      Enum.any?(Decor.pieces(living, items, around), &(elem(&1, 0) == sofa))
    end

    # The sofa is at the front of the room. A heater 8 inches behind it is
    # under its shadow: no sofa. A heater at its side shows.
    assert has_sofa?.([], [])
    refute has_sofa?.([item.("space_heater", 100, 240)], [])
    assert has_sofa?.([item.("space_heater", 20, 240)], [])

    # The same heater in a room behind a wall: the boxes of the items of a
    # different room are on the plan of this room.
    behind = Decor.boxes([item.("space_heater", 100, 240)], {0, 0})
    refute has_sofa?.([], behind)

    # An item over the sofa (a fan) is not under its shadow.
    refute Decor.hides?(%{x: 0, y: 0, w: 80, d: 35}, 0.6, %{
             x: 0,
             y: 0,
             w: 10,
             d: 10,
             low: 2.1,
             high: 2.3
           })

    # An item with no size is never hidden.
    refute Decor.hides?(%{x: 0, y: 0, w: 80, d: 35}, 0.6, %{
             x: 0,
             y: 0,
             w: 0,
             d: 10,
             low: 0,
             high: 0.2
           })
  end

  test "a yard has its furniture, and a different outside room has none" do
    # A yard has a round table with chairs and one big tree. In a front
    # yard, the tree is at the front left, away from the house. In a
    # backyard, it is at the back left.
    yard = %{name: "Front yard", place: :outdoor, plan: %{x: 0, y: 0, w: 360, d: 360}}
    tree = Decor.model("tree")
    assert ~w(round_table tree) == pieces(yard)
    assert [{^tree, 8, y, 0}] = Enum.filter(Decor.pieces(yard, []), &(elem(&1, 0) == tree))
    assert y > 180
    back = %{yard | name: "Backyard"}
    assert [{^tree, 8, 8, 0}] = Enum.filter(Decor.pieces(back, []), &(elem(&1, 0) == tree))

    # A side yard has no furniture.
    assert Decor.pieces(%{yard | name: "Side yard"}, []) == []
    assert Decor.pieces(%{yard | name: "Patio"}, []) == []
    assert Decor.pieces(%{yard | place: :roof, name: "Roof"}, []) == []
  end
end
