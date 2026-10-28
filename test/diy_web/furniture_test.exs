defmodule DIYWeb.FurnitureTest do
  @moduledoc """
  Furniture that the person puts at its place, as an item
  (`DIY.Catalog.furniture/0`): a fireplace, a bathtub, a shower, a pantry,
  a table with chairs and a tree.
  """
  use ExUnit.Case, async: true

  alias DIY.{Build, Catalog, Estimate, House, Layout, Profile, Stubs, Weather}
  alias DIYWeb.{Camera, Decor}
  alias DIYWeb.Icon.Shapes

  @types ~w(fireplace bathtub shower pantry dining_table tree)

  defp build do
    {house, rooms, items} =
      House.preset(%{size: 2000, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  defp item(type, x, y),
    do: %{type: type, at: %{x: x, y: y}, size: nil, turn: 0, params: %{}}

  # The names of the models of the pieces of a room.
  defp names(room, items) do
    names = ~w(rug bed nightstand dresser sofa armchair coffee_table shelf_books dining
               round_table tree tub toilet vanity bath_mat)

    for {model, _x, _y, _turn} <- Decor.pieces(room, items),
        do: Enum.find(names, &(Decor.model(&1) == model)) || :counter
  end

  test "furniture is an item with no power and no parameter" do
    assert Enum.sort(Catalog.furniture()) == Enum.sort(@types)

    build = build()
    {:ok, climate} = Weather.parse(Stubs.power(), 33.25, -96.75, 2016, 2025)

    {build, ids} =
      Enum.reduce(@types, {build, []}, fn type, {build, ids} ->
        place = if type == "tree", do: "Backyard", else: "Living room"
        {:ok, build, id} = Build.add_item(build, room(build, place).id, type)
        {build, [id | ids]}
      end)

    estimate = Estimate.run(build, climate)

    for id <- ids do
      {:ok, item} = Build.item(build, id)
      kind = Catalog.kind(item.type)
      assert kind.features == [] and kind.params == []
      assert item.params == %{}
      assert item.type in Estimate.no_use()
      assert Profile.watts(item) == 0.0
      assert Enum.all?(estimate.months, &(&1.items[id].kwh == 0.0))
      assert "It is furniture: it uses no power." in Estimate.explain(item, 7, estimate)

      # The size of the item is the size of its model.
      {{x0, y0, z0}, {x1, y1, z1}} = Shapes.bounds(Shapes.model(item.type))
      {w, d, h} = Layout.size(item)

      for {size, extent} <- [{w, x1 - x0}, {d, y1 - y0}, {h, z1 - z0}],
          do: assert(abs(size - extent / 0.0254) < 1, item.type)
    end

    # A tree goes outside, and a table goes inside or outside. The others
    # go inside.
    assert Catalog.kind("tree").places == [:outdoor]
    assert Catalog.kind("dining_table").places == [:indoor, :outdoor]
    assert Enum.all?(~w(fireplace bathtub shower pantry), &(Catalog.kind(&1).places == [:indoor]))

    # The search finds them with the words of a person.
    for {word, type} <- [
          {"hearth", "fireplace"},
          {"tub", "bathtub"},
          {"stall", "shower"},
          {"chairs", "dining_table"},
          {"shade", "tree"},
          {"furniture", "pantry"}
        ],
        do: assert(Enum.any?(Catalog.search(word), &(&1.type == type)), word)
  end

  test "a placed piece takes the place of the piece of the same kind" do
    bath = %{name: "Bathroom", place: :indoor, level: "f1", plan: %{x: 0, y: 0, w: 144, d: 144}}
    assert ~w(bath_mat tub toilet vanity) == names(bath, [])

    # A bathtub or a shower takes the place of the bath of the name.
    assert ~w(bath_mat toilet vanity) == names(bath, [item("bathtub", 4, 100)])
    assert ~w(bath_mat toilet vanity) == names(bath, [item("shower", 4, 4)])

    # A half bath has no bath.
    assert ~w(toilet vanity) == names(%{bath | name: "Half bath"}, [])

    # A table takes the place of the table of a dining room, and of the
    # round table of a breakfast room or of a yard.
    dining = %{bath | name: "Dining room", plan: %{x: 0, y: 0, w: 200, d: 200}}
    assert ~w(dining) == names(dining, [])
    assert [] == names(dining, [item("dining_table", 4, 4)])
    assert [] == names(%{dining | name: "Breakfast"}, [item("dining_table", 4, 4)])

    yard = %{dining | name: "Backyard", place: :outdoor, plan: %{x: 0, y: 0, w: 400, d: 400}}
    assert ~w(round_table tree) == names(yard, [])
    assert ~w(round_table) == names(yard, [item("tree", 300, 300)])
    assert ~w(tree) == names(yard, [item("dining_table", 300, 300)])

    # A fireplace and a pantry take the place of no piece.
    living = %{dining | name: "Living room", plan: %{x: 0, y: 0, w: 216, d: 294}}
    assert names(living, []) -- ["armchair"] == names(living, [item("fireplace", 0, 120)])
  end

  test "a tree looks the same at each turn, and its space is a square" do
    {w, d, h} = Catalog.size("tree")
    assert w == d

    look = fn turn ->
      Shapes.placed("tree", %{
        at: {0, 0, 0},
        size: {w * 0.0254, d * 0.0254, h * 0.0254},
        turn: turn,
        camera: Camera.house()
      })
    end

    assert Enum.all?(1..3, &(look.(&1) == look.(0)))
  end
end
