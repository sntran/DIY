defmodule DIYWeb.TreeTest do
  @moduledoc """
  The kinds of a tree (`DIY.Catalog.tree_kinds/0`): their sizes, their
  models (`DIYWeb.Icon.TreeShapes`) and the cut in the view of the rooms.
  Also the doors: a tree stands on its trunk (`DIY.Layout.foot_box/1`).
  """
  use ExUnit.Case, async: true

  alias DIY.{Build, Catalog, House, Layout}
  alias DIYWeb.{Camera, Cutaway}
  alias DIYWeb.Icon.{Shapes, TreeShapes}

  @m 0.0254

  defp build do
    {house, rooms, items} =
      House.preset(%{size: 2000, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  defp item(build, id), do: elem(Build.item(build, id), 1)

  # The box of the polygons on the screen of the camera of the house.
  defp screen(polys) do
    camera = Camera.house()

    {xs, ys} =
      polys
      |> Enum.flat_map(fn {:poly, corners, _class} -> corners end)
      |> Enum.map(&Camera.at(camera, {0, 0}, &1))
      |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  # The box on the screen of a box of the world from {0, 0, 0}.
  defp box_screen({w, d, h}) do
    camera = Camera.house()

    {xs, ys} =
      for(x <- [0, w], y <- [0, d], z <- [0, h], do: Camera.at(camera, {0, 0}, {x, y, z}))
      |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp frame(size, turn \\ 0),
    do: %{at: {0.0, 0.0, 0.0}, size: size, turn: turn, camera: Camera.house()}

  test "a tree has a kind, and the kind gives its typical size" do
    assert Enum.map(Catalog.tree_kinds(), &elem(&1, 0)) == ~w(live_oak pine palm crape_myrtle)
    assert Catalog.defaults("tree") == %{"kind" => "live_oak"}
    assert Catalog.tree_size("live_oak") == Catalog.size("tree")
    assert Catalog.tree_size("nothing") == Catalog.size("tree")

    # Each kind has a round crown, so its space is a square. A live oak and
    # a pine are taller than a house of two floors (about 30 ft).
    for {kind, _name} <- Catalog.tree_kinds() do
      {w, d, _h} = Catalog.tree_size(kind)
      assert w == d
    end

    assert elem(Catalog.tree_size("live_oak"), 2) > 360
    assert elem(Catalog.tree_size("pine"), 2) > 360

    # The size of the person goes first.
    tree = %{type: "tree", size: nil, params: %{"kind" => "pine"}}
    assert Layout.size(tree) == Catalog.tree_size("pine")
    assert Layout.size(%{tree | size: %{w: 100, d: 100, h: 300}}) == {100, 100, 300}

    # The look of a tree is its kind. The search finds a tree by its kind.
    assert Shapes.look(%{type: "tree", params: %{"kind" => "palm"}}) == {"tree", "palm"}

    for word <- ~w(oak pine palm myrtle),
        do: assert(Enum.any?(Catalog.search(word), &(&1.type == "tree")), word)
  end

  test "the crown fills the size on the screen, and the trunk has its real size" do
    for {kind, _name} <- Catalog.tree_kinds(),
        {w, d, h} <- [Catalog.tree_size(kind), {200, 200, 300}, {600, 600, 900}] do
      size = {w * @m, d * @m, h * @m}
      {x0, y0, x1, y1} = screen(Shapes.placed({"tree", kind}, frame(size)))
      {bx0, by0, bx1, by1} = box_screen(size)

      # The tree is in the box of its size on the screen. Its crown fills
      # the width or the height: a short pine is narrow.
      e = 0.01 * (by1 - by0)
      assert x0 >= bx0 - e and x1 <= bx1 + e and y0 >= by0 - e and y1 <= by1 + e, kind
      assert x1 - x0 >= 0.5 * (bx1 - bx0) or y1 - y0 >= 0.6 * (by1 - by0), kind

      # The trunk does not grow with the crown, and the bed of mulch is
      # 1 meter at most.
      model = TreeShapes.model(kind, size)

      for {:cyl, _center, r, _h, "wood"} <- List.flatten(Enum.map(model, &parts/1)),
          do: assert(r >= 0.05 and r <= 18 * @m + 1.0e-9, kind)

      [{:face, mulch, {0, 0, 1}, "i-wood-t"} | _] = model
      {xs, _ys, _zs} = unzip3(mulch)
      assert Enum.max(xs) - Enum.min(xs) <= 2.0 + 1.0e-9
    end

    # A taller tree has a thicker trunk, up to the limit of its kind.
    trunk = fn kind, h ->
      [{:cyl, _, r, _, _} | _] = parts(List.last(TreeShapes.model(kind, {9.0, 9.0, h})))
      r
    end

    assert trunk.("live_oak", 6.0) < trunk.("live_oak", 12.0)
    assert trunk.("live_oak", 20.0) == trunk.("live_oak", 30.0)
    assert trunk.("palm", 4.0) < trunk.("palm", 8.0)
  end

  test "the trunks of the model are in the box of the trunks on the plan" do
    for {kind, _name} <- Catalog.tree_kinds(),
        {w, d, h} <- [Catalog.tree_size(kind), {60, 60, 216}, {360, 360, 720}, {12, 360, 480}],
        turn <- [0, 1] do
      item = %{
        type: "tree",
        at: %{x: 0, y: 0},
        size: %{w: w, d: d, h: h},
        turn: turn,
        params: %{"kind" => kind}
      }

      foot = Layout.foot_box(item)
      {ew, ed} = Layout.extent(item)
      size = {ew * @m, ed * @m, h * @m}

      for {:cyl, {x, y, _z}, r, _h, "wood"} <-
            Enum.flat_map(TreeShapes.model(kind, size), &parts/1) do
        {x0, x1, y0, y1} = {(x - r) / @m, (x + r) / @m, (y - r) / @m, (y + r) / @m}
        assert x0 >= foot.x and x1 <= foot.x + foot.w, "#{kind} #{inspect({w, d, h, turn})}"
        assert y0 >= foot.y and y1 <= foot.y + foot.d, "#{kind} #{inspect({w, d, h, turn})}"
        assert x0 >= 0 and x1 <= ew + 1.0e-6 and y0 >= 0 and y1 <= ed + 1.0e-6
      end
    end

    # The trunks of a crape myrtle in front of a door: the tree does not go.
    build = build()
    {kitchen, yard} = {room(build, "Kitchen"), room(build, "Backyard")}
    {:ok, build} = Build.set_doorways(build, yard.id, %{kitchen.id => nil})
    [space] = Build.door_spaces(build, yard.id)
    {:ok, build, myrtle} = Build.add_item(build, yard.id, "tree")
    {:ok, build} = Build.update_item(build, myrtle, %{"kind" => "crape_myrtle"})
    {:ok, build} = Build.size_item(build, myrtle, %{w: 60, d: 60, h: 216})
    assert Build.place_item(build, myrtle, yard.id, %{x: space.x + 14, y: 0}) == {:error, :door}
  end

  test "a tree looks the same at each turn, and fills its turned space" do
    for {kind, _name} <- Catalog.tree_kinds() do
      look = fn size, turn -> Shapes.placed({"tree", kind}, frame(size, turn)) end
      assert Enum.all?(1..3, &(look.({3.0, 3.0, 6.0}, &1) == look.({3.0, 3.0, 6.0}, 0))), kind

      # A tree of 4 by 2 meters, after a quarter turn, is the tree of 2 by
      # 4 meters.
      assert look.({4.0, 2.0, 6.0}, 1) == look.({2.0, 4.0, 6.0}, 0), kind
      assert look.({4.0, 2.0, 6.0}, 3) == look.({2.0, 4.0, 6.0}, 2), kind
      assert look.({4.0, 2.0, 6.0}, 2) == look.({4.0, 2.0, 6.0}, 0), kind
    end

    # A tree of 91 by 60 inches, after a quarter turn: its space is 60 by
    # 91 inches (`DIY.Layout.extent/1`). The tree is in that space.
    item = %{type: "tree", at: %{x: 0, y: 0}, size: %{w: 91, d: 60, h: 158}, turn: 1, params: %{}}
    assert Layout.extent(item) == {60, 91}

    {x0, y0, x1, y1} = screen(Shapes.placed("tree", frame({91 * @m, 60 * @m, 158 * @m}, 1)))
    {bx0, by0, bx1, by1} = box_screen({60 * @m, 91 * @m, 158 * @m})
    e = 0.01 * (by1 - by0)
    assert x0 >= bx0 - e and x1 <= bx1 + e and y0 >= by0 - e and y1 <= by1 + e
  end

  test "the view of the rooms cuts a tree, and the house from outside shows all of it" do
    build = build()
    yard = room(build, "Backyard")
    {:ok, build, id} = Build.add_item(build, yard.id, "tree")
    {:ok, build} = Build.place_item(build, id, yard.id, %{x: 0, y: 200})
    tree = item(build, id)
    camera = Camera.house()

    # Cut: the trunk to the height of the low walls, the bed of mulch, and
    # the shadow of the crown on the ground.
    cut = Cutaway.item_view(tree, yard, 0.0, camera)
    {_, _, _, _, _, high} = cut.box
    assert high <= 0.75 + 1.0e-9
    assert Enum.any?(cut.polys, fn {_corners, class} -> class == "p-shadow p-crown" end)

    # The shadow covers the space of the tree.
    shadow = for {corners, "p-shadow p-crown"} <- cut.polys, {x, y, _z} <- corners, do: {x, y}
    {xs, ys} = Enum.unzip(shadow)
    {w, d} = Layout.extent(tree)
    assert_in_delta Enum.max(xs) - Enum.min(xs), w * @m, 0.01
    assert_in_delta Enum.max(ys) - Enum.min(ys), d * @m, 0.01

    # A tree with no kind (an older file) is a live oak.
    old = Cutaway.item_view(%{tree | params: %{}}, yard, 0.0, camera)
    assert old.polys == cut.polys

    # Whole: as high as the tree.
    whole = Cutaway.item_view(tree, yard, 0.0, camera, false)
    {_, _, _, _, _, high} = whole.box
    assert high >= elem(Catalog.size("tree"), 2) * @m

    # The whole page of the rooms has the cut tree. The ground of a yard is
    # 2 cm up.
    plan = Enum.flat_map(Cutaway.view(build).levels, & &1.objects)
    assert %{box: {_, _, _, _, _, top}} = Enum.find(plan, &(&1.id == id))
    assert top <= 0.02 + 0.75 + 1.0e-9
  end

  test "a tree blocks a door only with its trunk" do
    build = build()
    {kitchen, yard} = {room(build, "Kitchen"), room(build, "Backyard")}
    {:ok, build} = Build.set_doorways(build, yard.id, %{kitchen.id => nil})
    [space] = Build.door_spaces(build, yard.id)

    # The box of the trunk, with 1 inch more at each side. A live oak of
    # 300 inches has a trunk of 7.5 inches. A small tree has a thinner
    # trunk: it stays in the space of the tree.
    tree = %{type: "tree", at: %{x: 10, y: 20}, size: %{w: 200, d: 100, h: 300}, turn: 0}
    assert Layout.trunks(tree) == [{100.0, 50.0, 7.5}]
    assert Layout.foot_box(tree) == %{x: 101, y: 61, w: 18, d: 18}

    assert Layout.foot_box(%{tree | size: %{w: 10, d: 100, h: 300}}) == %{
             x: 10,
             y: 64,
             w: 10,
             d: 12
           }

    fridge = %{type: "fridge", at: %{x: 1, y: 2}, size: nil, turn: 0, params: %{}}
    assert Layout.foot_box(fridge) == Layout.item_box(fridge)

    # The crown of a tree is over the door: the tree goes.
    {:ok, build, big} = Build.add_item(build, yard.id, "tree")
    {:ok, build} = Build.size_item(build, big, %{w: 200, d: 200, h: 400})
    assert {:ok, build} = Build.place_item(build, big, yard.id, %{x: space.x - 50, y: 0})
    assert Layout.overlap?(space, Layout.item_box(item(build, big)))

    # Its trunk is in front of the door: the tree does not go.
    {:ok, build, small} = Build.add_item(build, yard.id, "tree")
    {:ok, build} = Build.size_item(build, small, %{w: 40, d: 40, h: 120})
    assert Build.place_item(build, small, yard.id, %{x: space.x, y: 0}) == {:error, :door}
  end

  defp parts({:group, parts}), do: parts
  defp parts(part), do: [part]

  defp unzip3(points) do
    {Enum.map(points, &elem(&1, 0)), Enum.map(points, &elem(&1, 1)),
     Enum.map(points, &elem(&1, 2))}
  end
end
