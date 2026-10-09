defmodule DIYWeb.DecorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, House, Layout}
  alias DIYWeb.Decor
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

  # The pieces of a room of the preset house, as the names of their models.
  defp names(build, name) do
    room = room(build, name)

    for {model, _x, _y, _turn} <- Decor.pieces(room, items(build, room)) do
      Enum.find(Decor.names(), &(Decor.model(&1) == model)) || :counter
    end
  end

  # The box of a piece on the plan of its room (inches).
  defp box({model, x, y, turn}) do
    {{x0, y0, _}, {x1, y1, _}} = Shapes.bounds(model)
    {w, d} = {round((x1 - x0) / @m), round((y1 - y0) / @m)}
    {w, d} = if rem(turn, 2) == 0, do: {w, d}, else: {d, w}
    %{x: x, y: y, w: w, d: d}
  end

  defp flat?({model, _x, _y, _turn}) do
    {{_, _, z0}, {_, _, z1}} = Shapes.bounds(model)
    z1 - z0 < 0.02
  end

  test "the name of a room gives its furniture" do
    build = house()
    assert ~w(rug bed nightstand nightstand dresser plant) == names(build, "Bedroom 1")

    # The plant at the back left does not show: the TV is there.
    assert ~w(rug sofa coffee_table armchair shelf_books plant) == names(build, "Living room")

    # The counters fill the back wall of the kitchen at the right of the
    # dishwasher.
    assert [:counter, "dining", "plant"] == names(build, "Kitchen")
    assert ~w(bath_mat tub toilet vanity) == names(build, "Bathroom")
    # The shelf at the back left of the garage does not show: the water
    # heater is there.
    assert ~w(bench) == names(build, "Garage")
    # The washer and the dryer fill the back of the laundry: no shelf.
    assert ~w(basket) == names(build, "Laundry")
    # The furnace is at the back left of the attic.
    assert ~w(boxes) == names(build, "Attic")
    # The AC is at the back left of the backyard: one tree there does not
    # show.
    assert ~w(patio tree bush bush) == names(build, "Backyard")
    assert [] == names(build, "Driveway")
    assert [] == names(build, "Roof")

    # A room with a name that the app does not know: a plant.
    office = %{room(build, "Bedroom 1") | name: "Office"}
    assert [{model, 4, 4, 0}] = Decor.pieces(office, [])
    assert model == Decor.model("plant")
  end

  test "the counters of a kitchen fill the back wall where no item is" do
    kitchen = %{room(house(), "Kitchen") | plan: %{x: 0, y: 0, w: 144, d: 200}}
    item = fn type, x -> %{type: type, at: %{x: x, y: 0}, size: nil, turn: 0, params: %{}} end

    counters = fn items ->
      for {_m, x, 1, 0} = p <- Decor.pieces(kitchen, items), x != 45, do: box(p)
    end

    # With no item: one counter along all the wall.
    assert [%{x: 0, w: 144}] = counters.([])

    # A fridge at the left: the counter starts 4 inches after it.
    assert [%{x: 37, w: 107}] = counters.([item.("fridge", 0)])

    # A range (30 inches) in the middle: two counters. A part shorter than
    # 18 inches stays empty.
    assert [%{x: 0, w: 46}, %{x: 84, w: 60}] = counters.([item.("range", 50)])
    assert [%{x: 0, w: 116}] = counters.([item.("range", 120)])

    # A small item in the space of the fridge (on top of it): the counter
    # starts after the fridge.
    assert [%{x: 37, w: 107}] = counters.([item.("fridge", 0), item.("always_on", 10)])

    # An item past the right wall (a room that became smaller) cuts nothing.
    assert [%{x: 0, w: 144}] = counters.([item.("range", 200)])

    # An item at the front of the room does not cut the counter.
    assert [%{x: 0, w: 144}] = counters.([%{item.("range", 50) | at: %{x: 50, y: 150}}])
  end

  property "a piece is in its room, and never on an item or on a different piece" do
    names = ~w(Bedroom Living Kitchen Bathroom Garage Laundry Attic Office)
    types = Enum.map(Catalog.kinds(), & &1.type) -- ~w(camper_van solar_panels)

    check all(
            name <- member_of(names),
            w <- integer(40..400),
            d <- integer(40..400),
            spots <-
              list_of(tuple({member_of(types), integer(0..400), integer(0..400)}), max_length: 6)
          ) do
      room = %{name: name, place: :indoor, plan: %{x: 0, y: 0, w: w, d: d}}

      items =
        for {type, x, y} <- spots do
          item = %{
            type: type,
            at: %{x: 0, y: 0},
            size: nil,
            turn: 0,
            params: Catalog.defaults(type)
          }

          %{item | at: Layout.clamp(%{x: x, y: y}, item, room.plan)}
        end

      floor = for item <- items, Catalog.lift(item.type) < 60, do: Layout.item_box(item)
      pieces = Decor.pieces(room, items)
      solid = pieces |> Enum.reject(&flat?/1) |> Enum.map(&box/1)

      for piece <- pieces, b = box(piece) do
        assert b.x >= 0 and b.y >= 0 and b.x + b.w <= w and b.y + b.d <= d
      end

      for a <- solid, b <- floor, do: refute(Layout.overlap?(a, b))

      for {a, i} <- Enum.with_index(solid),
          {b, j} <- Enum.with_index(solid),
          i < j,
          do: refute(Layout.overlap?(a, b))
    end
  end

  test "a yard has its furniture, and a different outside room has none" do
    yard = %{name: "Front yard", place: :outdoor, plan: %{x: 0, y: 0, w: 300, d: 300}}
    assert length(Decor.pieces(yard, [])) == 5
    assert Decor.pieces(%{yard | name: "Patio"}, []) == []
    assert Decor.pieces(%{yard | place: :roof, name: "Roof"}, []) == []
  end
end
