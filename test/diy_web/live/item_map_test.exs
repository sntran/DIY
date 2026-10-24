defmodule DIYWeb.ItemMapTest do
  @moduledoc "The map of the room in the sheet of an item (`DIYWeb.Inside.room_map/1`)."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Layout, Stubs}
  alias DIYWeb.Camera

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    settle(view)
    view
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  # The numbers of an attribute of an element of the map.
  defp find(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp attr(view, selector, name) do
    [value] = view |> find(selector) |> LazyHTML.attribute(name)
    value
  end

  defp numbers(view, selector, names),
    do: Enum.map(names, &String.to_integer(attr(view, selector, &1)))

  test "the map shows the item, its front and its space, and a turn changes them", %{conn: conn} do
    build = house()
    yard = room(build, "Backyard")
    {:ok, build, pool} = Build.add_item(build, yard.id, "pool")
    {:ok, at} = Build.item(build, pool)
    view = open(conn, ~p"/inside?#{[item: pool]}", build)

    # The pool (408 by 228) at its place; its front is at the large y.
    {x, y} = {at.at.x, at.at.y}
    assert numbers(view, "#item-map-item", ~w(x y width height)) == [x, y, 408, 228]
    assert numbers(view, "#item-map-front", ~w(x1 y1 x2 y2)) == [x, y + 228, x + 408, y + 228]
    assert has_element?(view, "#item-space", "Its space on the plan: 34 ft by 19 ft.")
    refute has_element?(view, "#item-larger")

    # A turn: the pool is 228 by 408, and its front is at the large x. The
    # yard is 25 ft deep: the pool goes through a wall.
    render_click(view, "turn_item", %{"id" => pool})
    [x, y, 228, 408] = numbers(view, "#item-map-item", ~w(x y width height))
    assert y == 0
    assert numbers(view, "#item-map-front", ~w(x1 y1 x2 y2)) == [x + 228, y, x + 228, y + 408]
    assert has_element?(view, "#item-space", "19 ft by 34 ft")
    assert has_element?(view, "#item-larger", "It is larger than Backyard (36 ft 6 in by 25 ft)")
    assert has_element?(view, "#item-larger", "Make it smaller, or turn it.")

    # Two more turns: the front is at the small y, then at the small x.
    render_click(view, "turn_item", %{"id" => pool})
    [x, y, 408, 228] = numbers(view, "#item-map-item", ~w(x y width height))
    assert numbers(view, "#item-map-front", ~w(x1 y1 x2 y2)) == [x, y, x + 408, y]
    render_click(view, "turn_item", %{"id" => pool})
    [x, y, 228, 408] = numbers(view, "#item-map-item", ~w(x y width height))
    assert numbers(view, "#item-map-front", ~w(x1 y1 x2 y2)) == [x, y, x, y + 408]
  end

  test "the map shows a move, the other items, and an item on a wall or a ceiling", %{conn: conn} do
    build = house()
    living = room(build, "Living room")
    tv = Enum.find(build.items, &(&1.type == "tv"))
    view = open(conn, ~p"/inside?#{[item: tv.id]}", build)

    # The plan of the room, and its other items: the ceiling fan has a
    # dashed line.
    assert numbers(view, "#item-map .stage-map-room", ~w(width height)) == [
             living.plan.w,
             living.plan.d
           ]

    others = Enum.count(build.items, &(&1.room == living.id and &1.id != tv.id))

    assert Enum.count(find(view, "#item-map .stage-map-other")) == others

    assert has_element?(view, "#item-map .stage-map-other.is-up")

    [x, y | _] = numbers(view, "#item-map-item", ~w(x y))
    render_click(view, "nudge_item", %{"id" => tv.id, "dx" => "6", "dy" => "12"})
    assert numbers(view, "#item-map-item", ~w(x y)) == [x + 6, y + 12]
  end

  test "in a van, the map has the axes of the van" do
    build = house()
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway").id, "camper_van")
    galley = Build.zone(build, van, :galley)
    {:ok, build, tank} = Build.add_item(build, galley.id, "water_tank")
    {:ok, item} = Build.item(build, tank)

    html =
      render_component(&DIYWeb.Inside.room_map/1, item: item, room: galley, items: build.items)

    # In a van, the Right arrow moves an item to the small y, and the Down
    # arrow to the large x. On the map, the small y is at the right, and
    # the large x is at the bottom.
    assert Camera.arrows(Camera.van()) == {{0, -1}, {1, 0}}
    assert html =~ ~s|transform="matrix(0 1 -1 0 0 0)"|
  end

  test "a turn keeps an item in its room" do
    build = house()
    laundry = room(build, "Laundry")
    {:ok, build, freezer} = Build.add_item(build, laundry.id, "freezer")
    # The freezer (56 by 30) at the front wall. After a turn (30 by 56)
    # around its center, it would go 13 inches through the wall.
    {:ok, build} =
      Build.place_item(build, freezer, laundry.id, %{x: 0, y: laundry.plan.d - 30})

    {:ok, build} = Build.turn_item(build, freezer)
    {:ok, turned} = Build.item(build, freezer)
    assert Layout.extent(turned) == {30, 56}
    assert turned.at.y + 56 == laundry.plan.d

    # At the back wall: it would go 13 inches through the back wall.
    {:ok, build} = Build.turn_item(build, freezer)
    {:ok, build} = Build.place_item(build, freezer, laundry.id, %{x: 0, y: 0})
    {:ok, build} = Build.turn_item(build, freezer)
    {:ok, turned} = Build.item(build, freezer)
    assert turned.at == %{x: 13, y: 0}
  end

  test "an item larger than its room both ways: a turn does not help", %{conn: conn} do
    build = house()
    yard = room(build, "Backyard")
    {:ok, build, pool} = Build.add_item(build, yard.id, "pool")
    {:ok, build} = Build.size_item(build, pool, %{w: 460, d: 320, h: 6})
    view = open(conn, ~p"/inside?#{[item: pool]}", build)
    assert has_element?(view, "#item-larger", "it goes through a wall. Make it smaller.")
    refute has_element?(view, "#item-larger", "turn it")
  end
end
