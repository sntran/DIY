defmodule DIYWeb.CutawayTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, Catalog, House}
  alias DIYWeb.{Cutaway, Iso}
  alias DIYWeb.Icon.Shapes

  defp house(floors \\ 2) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: floors, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id

  defp add(build, room, type, params \\ %{}) do
    {:ok, build, id} = Build.add_item(build, room, type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  defp html(build, selected \\ nil),
    do: render_component(&Cutaway.cutaway/1, view: Cutaway.view(build), selected: selected)

  test "the layers of houses of 1, 2 and 3 floors" do
    ids = fn build -> Enum.map(Cutaway.view(build).levels, & &1.id) end
    assert ids.(house(1)) == ["ground", "attic", "roof"]
    assert ids.(house(2)) == ["ground", "f2", "attic", "roof"]
    assert ids.(house(3)) == ["ground", "f2", "f3", "attic", "roof"]

    # A house with no attic and no roof: no layer for them. A floor with no
    # room still has its slab.
    build = house(2)

    build =
      Enum.reduce(build.rooms, build, fn room, build ->
        if room.level in ["roof", "f2"],
          do: elem(Build.delete_room(build, room.id), 1),
          else: build
      end)

    assert ids.(build) == ["ground", "f2"]
    assert Cutaway.k() == {8.66 * 0.0254, 5.0 * 0.0254, 10.0 * 0.0254}
  end

  test "the surfaces of the rooms, with the data for the hook" do
    build = house()
    html = html(build, room(build, "Kitchen"))
    assert html =~ ~s(data-k="0.219964 0.127 0.254")
    assert html =~ ~s(class="p-floor p-tile p-chosen")
    assert html =~ ~s(data-plan="0 0 144 294")
    # The roof has its rise: 147 inches times 5/12.
    assert html =~ ~s(data-rise="61")
    assert html =~ "p-roof-f"
    assert html =~ "p-gable"
    assert length(Regex.scan(~r/data-handle="/, html)) == 4
    assert html =~ ~s(data-outline=)
    refute html(build) =~ "data-outline"
  end

  test "the materials of the floors" do
    material = &Cutaway.material/1
    assert material.(%{place: :outdoor, name: "Driveway"}) == "asphalt"
    assert material.(%{place: :outdoor, name: "Back patio"}) == "deck"
    assert material.(%{place: :outdoor, name: "Yard"}) == "grass"
    assert material.(%{place: :roof, name: "Porch roof"}) == "membrane"
    assert material.(%{place: :indoor, name: "Master bedroom"}) == "carpet"
    assert material.(%{place: :indoor, name: "Garage"}) == "concrete"
    assert material.(%{place: :indoor, name: "Attic"}) == "ply"
    assert material.(%{place: :indoor, name: "Office"}) == "wood"
  end

  test "panels on the roof go over the ridge, and an AC stands on a slope" do
    build = house()
    roof = room(build, "Roof")
    {build, panels} = add(build, roof, "solar_panels", %{"watts" => "8000"})
    {:ok, build} = Build.place_item(build, panels, roof, %{x: 0, y: 60})
    {build, ac} = add(build, roof, "ac")
    {:ok, build} = Build.place_item(build, ac, roof, %{x: 300, y: 130})
    view = Cutaway.view(build)
    [roof_layer] = Enum.filter(view.levels, &(&1.id == "roof"))
    objects = Map.new(roof_layer.objects, &{&1.id, &1})

    # 20 panels in 7 columns and 3 rows: the panels of the middle row are
    # over the ridge, so they have two parts.
    pv = for {_points, "i-pv"} <- objects[panels].polys, do: 1
    assert length(pv) == 20 + 7

    # The AC is on the roof: its bottom is over the eaves.
    {_x, _y, low, _x1, _y1, _high} = objects[ac].box
    assert low > roof_layer.z

    # A quarter turn: the array is 3 columns and 7 rows.
    {:ok, turned} = Build.turn_item(build, panels)
    [roof_layer] = Enum.filter(Cutaway.view(turned).levels, &(&1.id == "roof"))
    assert Enum.any?(roof_layer.objects, &(&1.id == panels))
  end

  test "panels in a yard stand on a rack, and a planned item shows as a plan" do
    build = house()
    {build, panels} = add(build, room(build, "Backyard"), "solar_panels", %{"watts" => "2400"})
    {:ok, build} = Build.flag_item(build, panels, :planned, true)
    html = html(build)
    assert html =~ "p-pad"
    assert html =~ ~r/class="p-item p-planned"[^>]*data-item="#{panels}"/
  end

  test "a model turns: a face that looks away does not show" do
    frame = fn turn -> %{at: {0, 0, 0}, size: {1.0, 2.6, 1.25}, turn: turn} end
    # The van shows one of its two sides (the profile has 7 corners) in each
    # turn.
    for turn <- 0..3 do
      sides =
        for {:poly, corners, _class} <- Shapes.placed("camper_van", frame.(turn)),
            length(corners) == 7,
            do: 1

      assert sides == [1]
    end

    # The space of a turned item: d by w.
    {xs, ys} =
      Shapes.placed("fridge", %{at: {0, 0, 0}, size: {0.9, 0.7, 1.8}, turn: 3})
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.map(fn {x, y, _z} -> {x, y} end)
      |> Enum.unzip()

    assert_in_delta Enum.max(xs) - Enum.min(xs), 0.7, 0.05
    assert_in_delta Enum.max(ys) - Enum.min(ys), 0.9, 0.05

    model = [{:face, [{0, 0, 0}, {2, 0, 0}, {2, 1, 0}], {0, 0, 1}, "x"}]
    assert [{:poly, _corners, "x"}] = Shapes.placed_model(model, %{at: {1, 1, 0}, turn: 2})
  end

  test "for each kind and each turn, no part of a model paints after a part in front of it" do
    m = 0.0254

    for type <- Catalog.types(), turn <- 0..3 do
      {w, d, h} = Catalog.size(type)
      frame = %{at: {0, 0, 0}, size: {w * m, d * m, h * m}, turn: turn}
      indexed = type |> Shapes.model() |> Shapes.parts(frame) |> Enum.with_index()

      for {a, i} <- indexed, {b, j} <- indexed, i < j, overlap?(part_screen(a), part_screen(b)) do
        refute behind?(b.box, a.box) and not behind?(a.box, b.box),
               "#{type} at turn #{turn}: part #{b.id} is behind part #{a.id}"
      end
    end
  end

  # The box of the polygons of a part on the screen.
  defp part_screen(part) do
    {xs, ys} =
      part.polys |> Enum.flat_map(&elem(&1, 0)) |> Enum.map(&Iso.at({0, 0}, &1)) |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp overlap?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01

  test "each kind and each model of van paint from the back at each turn: a depth check" do
    m = 0.0254

    for turn <- 0..3 do
      for {model, _name, _numbers, _source} <- Catalog.van_models() do
        frame = %{at: {0, 0, 0}, turn: turn}

        polys =
          for {:poly, corners, _class} <- Shapes.placed_model(Shapes.van(model), frame),
              do: corners

        assert depth_faults(polys) == [], "#{model} at turn #{turn}"
      end

      for type <- Catalog.types() do
        {w, d, h} = Catalog.size(type)
        frame = %{at: {0, 0, 0}, size: {w * m, d * m, h * m}, turn: turn}
        polys = for {:poly, corners, _class} <- Shapes.placed(type, frame), do: corners
        assert depth_faults(polys) == [], "#{type} at turn #{turn}"
      end
    end
  end

  # The pairs of polygons (in the order of the paint) where the first one
  # is nearer to the eye at a point that both cover: the second one paints
  # over it. The eye looks along (-1, -1, -1): a larger x + y + z is nearer.
  defp depth_faults(polys) do
    prepared = polys |> Enum.map(&prepare/1) |> Enum.with_index()

    for {a, i} <- prepared,
        {b, j} <- prepared,
        i < j,
        a.plane && b.plane,
        nearer?(a, b),
        do: {i, j}
  end

  defp prepare(corners) do
    screen = Enum.map(corners, &Iso.at({0, 0}, &1))
    {xs, ys} = Enum.unzip(screen)

    %{
      screen: screen,
      plane: plane(corners),
      box: {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
    }
  end

  defp nearer?(a, b) do
    {ax0, ay0, ax1, ay1} = a.box
    {bx0, by0, bx1, by1} = b.box
    {x0, y0, x1, y1} = {max(ax0, bx0), max(ay0, by0), min(ax1, bx1), min(ay1, by1)}

    x1 - x0 >= 0.05 and y1 - y0 >= 0.05 and
      Enum.any?(
        for(i <- 1..7, j <- 1..7, do: {x0 + (x1 - x0) * i / 8, y0 + (y1 - y0) * j / 8}),
        fn point ->
          in_poly?(point, a.screen) and in_poly?(point, b.screen) and
            depth(a.plane, point) > depth(b.plane, point) + 0.03
        end
      )
  end

  defp in_poly?({px, py}, poly) do
    n = length(poly)

    poly
    |> Enum.with_index()
    |> Enum.reduce(false, fn {{xi, yi}, i}, inside ->
      {xj, yj} = Enum.at(poly, rem(i + n - 1, n))

      if yi > py != yj > py and px < (xj - xi) * (py - yi) / (yj - yi + 1.0e-12) + xi,
        do: not inside,
        else: inside
    end)
  end

  defp sub({a, b, c}, {x, y, z}), do: {a - x, b - y, c - z}
  defp cross({a, b, c}, {x, y, z}), do: {b * z - c * y, c * x - a * z, a * y - b * x}
  defp dot({a, b, c}, {x, y, z}), do: a * x + b * y + c * z

  # The plane of a polygon (a normal and a point), or nil for a polygon that
  # is not flat or that the eye sees on its edge.
  defp plane([p | rest] = corners) do
    normals =
      for {q, r} <- Enum.zip(rest, tl(rest)),
          n = cross(sub(q, p), sub(r, p)),
          dot(n, n) > 1.0e-12,
          do: n

    with [n | _] <- normals,
         length = :math.sqrt(dot(n, n)),
         true <- Enum.all?(corners, &(abs(dot(n, sub(&1, p))) / length < 1.0e-4)),
         true <- abs(dot(n, {1, 1, 1})) >= 1.0e-9 do
      {n, p}
    else
      _ -> nil
    end
  end

  # The depth (x + y + z) on a plane at a point of the screen.
  defp depth({n, c}, {sx, sy}) do
    {a, b} = {sx / 8.66, sy / 5.0}
    p0 = {(a + b) / 2, (b - a) / 2, 0.0}
    t = (dot(n, c) - dot(n, p0)) / dot(n, {1, 1, 1})
    dot(p0, {1, 1, 1}) + 3 * t
  end

  test "three boxes that are each behind the next one still get an order" do
    square = [{[{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}], "x"}]
    object = fn id, box -> %{id: id, box: box, key: 0, loose: false, polys: square} end
    # a is behind b along x, b behind c along y, and c behind a along z.
    a = object.("a", {0, 0, 1, 1, 2, 2})
    b = object.("b", {1, 0, 0, 2, 1, 2})
    c = object.("c", {0, 1, 0, 2, 2, 1})
    assert Iso.order([c, b, a]) |> Enum.map(& &1.id) |> Enum.sort() == ["a", "b", "c"]
    # With no cycle: the box at the back first, whatever its key.
    assert Iso.order([%{b | key: -1}, a]) |> Enum.map(& &1.id) == ["a", "b"]
  end

  ## The property

  # A random house: random items in random rooms, at random places, with
  # random turns and sizes.
  defp builds do
    gen all(
          floors <- integer(1..3),
          steps <-
            list_of(
              tuple({
                integer(0..20),
                member_of(Catalog.types()),
                integer(-50..600),
                integer(-50..600),
                integer(0..3),
                one_of([constant(nil), integer(1..300)])
              }),
              max_length: 15
            )
        ) do
      Enum.reduce(steps, house(floors), fn {r, type, x, y, turn, side}, build ->
        rooms = Enum.reject(build.rooms, &Build.van_level?(&1.level))
        room = Enum.at(rooms, rem(r, length(rooms)))

        with {:ok, build, id} <- Build.add_item(build, room.id, type),
             {:ok, build} <- Build.place_item(build, id, room.id, %{x: x, y: y}),
             {:ok, build} <- Build.size_item(build, id, side && %{w: side, d: side, h: side}) do
          Enum.reduce(1..turn//1, build, fn _, build -> elem(Build.turn_item(build, id), 1) end)
        else
          _ -> build
        end
      end)
    end
  end

  property "each point is in the box of the SVG, each id is one of a kind, and the back paints first" do
    check all(build <- builds(), max_runs: 40) do
      view = Cutaway.view(Build.house_view(build))
      html = render_component(&Cutaway.cutaway/1, view: view, selected: nil)
      [x, y, w, h] = box(html)

      for [px, py] <- points(html),
          do: assert(px >= x - 0.1 and px <= x + w + 0.1 and py >= y - 0.1 and py <= y + h + 0.1)

      ids = for [_, id] <- Regex.scan(~r/ id="([^"]+)"/, html), do: id
      assert Enum.uniq(ids) == ids

      # An item larger than its room goes through its walls: then no order
      # is right. The order is for the items that fit in their rooms.
      big = MapSet.new(for item <- build.items, not fits?(build, item), do: item.id)

      for level <- view.levels do
        indexed = level.objects |> Enum.reject(&MapSet.member?(big, &1.id)) |> Enum.with_index()

        for {a, i} <- indexed, {b, j} <- indexed, i < j, cover?(a, b) do
          refute behind?(b.box, a.box) and not behind?(a.box, b.box),
                 "#{b.id} is behind #{a.id}, but it paints after it: #{inspect({b.box, a.box, screen(b), screen(a)})}"
        end
      end
    end
  end

  defp fits?(build, item) do
    case Build.room(build, item.room) do
      {:ok, %{plan: %{w: w, d: d}}} ->
        {ew, ed} = DIY.Layout.extent(item)
        ew <= w and ed <= d

      _van ->
        true
    end
  end

  defp behind?({_, _, _, ax1, ay1, az1}, {bx0, by0, bz0, _, _, _}),
    do: ax1 <= bx0 + 1.0e-6 or ay1 <= by0 + 1.0e-6 or az1 <= bz0 + 1.0e-6

  # True when the boxes of two objects on the screen overlap.
  defp cover?(a, b) do
    {ax0, ay0, ax1, ay1} = screen(a)
    {bx0, by0, bx1, by1} = screen(b)
    ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01
  end

  defp screen(object) do
    {xs, ys} =
      object.polys
      |> Enum.flat_map(fn {points, _class} -> String.split(points) end)
      |> Enum.map(fn pair ->
        pair |> String.split(",") |> Enum.map(&number/1) |> List.to_tuple()
      end)
      |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp box(html) do
    [_, box] = Regex.run(~r/viewBox="([^"]+)"/, html)
    box |> String.split() |> Enum.map(&number/1)
  end

  defp points(html) do
    for [_, list] <- Regex.scan(~r/points="([^"]+)"/, html),
        pair <- String.split(list),
        do: pair |> String.split(",") |> Enum.map(&number/1)
  end

  defp number(text), do: text |> Float.parse() |> elem(0)

  test "a point of the world on the screen" do
    assert Iso.at({0, 0}, {1, 0, 0}) == {8.66, 5.0}
  end
end
