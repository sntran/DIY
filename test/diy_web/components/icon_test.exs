defmodule DIYWeb.IconTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.Catalog
  alias DIYWeb.{Camera, Geometry, Icon}
  alias DIYWeb.Icon.{Shapes, StationShapes}

  # The looks of the models of power stations, each with its size in
  # inches.
  defp stations do
    for {key, _name, _numbers, size, _source} <- Catalog.station_models(),
        key in StationShapes.models(),
        do: {{"power_station", key}, size}
  end

  test "each kind has shapes of its own" do
    shapes = for kind <- Catalog.kinds(), do: Shapes.shapes(kind.type)
    assert length(Enum.uniq(shapes)) == length(Catalog.kinds())
  end

  test "each class of the icons has a rule in app.css" do
    css = File.read!("assets/css/app.css")

    looks = Enum.map(Catalog.kinds(), & &1.type) ++ Enum.map(stations(), &elem(&1, 0))

    classes =
      for look <- looks,
          {:poly, _corners, class} <- Shapes.shapes(look),
          name <- String.split(class),
          uniq: true,
          do: name

    # The rule of the class itself, at the start of a line or after a
    # different rule: not only a rule of the house plan. The classes of the
    # small loops (a flame, a hot coil) have rules only in the house plan.
    for class <- classes do
      if class in ~w(i-fire i-coil),
        do: assert(css =~ ".cutaway-house .#{class} {"),
        else: assert(css =~ ~r/(?:^|\}\s*)\.#{class} \{/m, "no rule for #{class}")
    end

    # Each material has its colors in the house plan, in light and in the
    # two blocks of the dark mode.
    materials =
      for class <- classes,
          [_, name] <- [Regex.run(~r/^i-([a-z-]+)-t$/, class)],
          uniq: true,
          do: name

    assert Enum.all?(~w(victron orange titanium), &(&1 in materials))

    # Each shade has a rule, also in the house plan, and each light has its
    # house color in the three blocks.
    for name <- materials do
      for shade <- ~w(t l r m1 m2 m3) do
        assert css =~ ~r/(?:^|\}\s*)\.i-#{name}-#{shade} \{/m, "no rule for i-#{name}-#{shade}"
        assert css =~ ".cutaway-house .i-#{name}-#{shade} {", "no house rule for #{name}-#{shade}"
      end

      for light <- ~w(t l r) do
        assert length(Regex.scan(~r/--c-#{name}-#{light}:/, css)) == 3,
               "no house colors for #{name}-#{light}"
      end
    end
  end

  test "the sprite has a group for each kind, and an icon uses its group in a square box" do
    sprite = render_component(&Icon.sprite/1, %{})

    for kind <- Catalog.kinds() do
      assert sprite =~ ~s(id="icon-#{kind.type}")
      html = render_component(&Icon.item/1, type: kind.type)
      assert html =~ ~s(<use href="#icon-#{kind.type}")
      assert html =~ ~s(aria-hidden="true")
      [_, box] = Regex.run(~r/viewBox="([^"]+)"/, html)
      [_x, _y, w, h] = String.split(box)
      assert w == h
    end

    # Each point of the sprite is in the box of its icon, with a margin for
    # the edge of the faces.
    for kind <- Catalog.kinds() do
      [_, box] = Regex.run(~r/viewBox="([^"]+)"/, render_component(&Icon.item/1, type: kind.type))
      [x, y, w, h] = box |> String.split() |> Enum.map(&(&1 |> Float.parse() |> elem(0)))

      camera =
        if kind.type in ["camper_van", "ev"], do: Camera.van(), else: Camera.house()

      for {:poly, corners, _class} <- Shapes.shapes(kind.type, camera), corner <- corners do
        {px, py} = Camera.at(camera, {0, 0}, corner)
        assert px >= x + 0.9 and px <= x + w - 0.9 and py >= y + 0.9 and py <= y + h - 0.9
      end
    end
  end

  test "the model of each kind has the size of the kind, so the plan does not squash it" do
    # On the plan, solar panels are a rack or a part of a roof
    # (`DIYWeb.Cutaway`). A camper van has the size of its model
    # (`DIY.Layout.size/1`).
    for kind <- Catalog.kinds(), kind.type not in ["solar_panels", "camper_van"] do
      {w, d, h} = Catalog.size(kind.type)
      {{x0, y0, z0}, {x1, y1, z1}} = Shapes.bounds(Shapes.model(kind.type))

      for {model, inches} <- [{x1 - x0, w}, {y1 - y0, d}, {z1 - z0, h}] do
        assert abs(model / (inches * 0.0254) - 1) <= 0.05,
               "#{kind.type}: #{Float.round(model, 3)} m for #{inches} in"
      end
    end
  end

  test "the model of each power station has the size of its model" do
    assert length(stations()) == 6

    for {look, {w, d, h}} <- stations() do
      {{x0, y0, z0}, {x1, y1, z1}} = Shapes.bounds(Shapes.model(look))

      for {model, inches} <- [{x1 - x0, w}, {y1 - y0, d}, {z1 - z0, h}] do
        assert abs(model / (inches * 0.0254) - 1) <= 0.05,
               "#{inspect(look)}: #{Float.round(model, 3)} m for #{inches} in"
      end
    end
  end

  test "a camper van shows its model" do
    van = fn model -> %{type: "camper_van", params: %{"model" => model}} end
    assert Shapes.look(van.("sprinter_144")) == {"camper_van", "sprinter_144"}

    assert Shapes.model({"camper_van", "sprinter_144"}) ==
             DIYWeb.Icon.VanShapes.van("sprinter_144")

    refute Shapes.shapes({"camper_van", "sprinter_144"}) ==
             Shapes.shapes({"camper_van", "promaster_136"})
  end

  test "a power station shows its model, when the model has a look of its own" do
    station = fn model -> %{type: "power_station", params: %{"model" => model}} end
    assert Shapes.look(station.("ecoflow_delta_pro")) == {"power_station", "ecoflow_delta_pro"}
    assert Shapes.look(station.("pecron_f5000lfp")) == "power_station"
    assert Shapes.look(station.("other")) == "power_station"

    # Each model has its own shapes, and the Plus differs from the F3800.
    shapes = for {look, _size} <- stations(), do: Shapes.shapes(look)
    assert length(Enum.uniq([Shapes.shapes("power_station") | shapes])) == 7
  end

  test "a busbar shows its positions, with one size for each number" do
    default = Shapes.bounds(Shapes.model("dc_bus"))
    assert Shapes.model("dc_bus") == Shapes.model({"dc_bus", 4})

    for ports <- 1..24 do
      model = Shapes.model({"dc_bus", ports})
      assert Shapes.bounds(model) == default
      # A gray light for each position, and the green light of the power
      # in the middle.
      assert Enum.count(model, &match?({:face, _, _, "i-off"}, &1)) == ports

      assert [{:face, green, _, "i-led"}] =
               Enum.filter(model, &match?({:face, _, _, "i-led"}, &1))

      {xs, _ys, _zs} = green |> Enum.map(&Tuple.to_list/1) |> Enum.zip() |> List.to_tuple()
      assert_in_delta Enum.sum(Tuple.to_list(xs)) / tuple_size(xs), 0.158, 1.0e-9

      # A hood (45 mm high) for the cables of two positions, and a small
      # block between the two hoods in the middle.
      fronts =
        for {:prism, :y, loop, 0.062, _length, "victron"} <- model,
            do: loop |> Enum.map(&elem(&1, 0)) |> Enum.max()

      hoods = div(ports + 1, 2)
      assert Enum.count(fronts, &(abs(&1 - 0.045) < 1.0e-9)) == hoods

      # A dark port for the cable of each position, at the foot of the
      # front of the hoods: from z = 0, and 12 mm high.
      at_foot = fn corners ->
        {z0, z1} = corners |> Enum.map(&elem(&1, 2)) |> Enum.min_max()
        abs(z0) < 1.0e-9 and abs(z1 - 0.012) < 1.0e-9
      end

      assert Enum.count(model, &match?({:face, c, {0, 1, 0}, "i-black"} when is_list(c), &1)) - 2 ==
               ports

      assert Enum.count(model, fn f ->
               match?({:face, _, {0, 1, 0}, "i-black"}, f) and at_foot.(elem(f, 1))
             end) == ports

      assert Enum.count(fronts, &(abs(&1 - 0.02) < 1.0e-9)) ==
               if(rem(hoods, 2) == 0, do: 1, else: 0)
    end

    assert Shapes.look(%{type: "dc_bus", params: %{"ports" => 7}}) == {"dc_bus", 7}
    assert Shapes.look(%{type: "fridge", params: %{}}) == "fridge"
  end

  # True when a flat face lies on a face of a solid part of its model. It
  # is at most 12 mm out of that face, and inside its edges.
  defp on_part?({:face, corners, normal, _class}, model) do
    {axis, sign} =
      %{
        {0, 1, 0} => {1, 1},
        {1, 0, 0} => {0, 1},
        {0, 0, 1} => {2, 1},
        {0, -1, 0} => {1, -1},
        {-1, 0, 0} => {0, -1}
      }[normal]

    others = [0, 1, 2] -- [axis]
    plane = elem(hd(corners), axis)

    Enum.any?(model, fn
      {:face, _, _, _} ->
        false

      part ->
        {low, high} = Shapes.bounds([part])
        edge = elem(if(sign > 0, do: high, else: low), axis)
        on = (plane - edge) * sign >= -1.0e-9 and (plane - edge) * sign <= 0.012

        on and
          Enum.all?(corners, fn point ->
            Enum.all?(others, fn i ->
              elem(point, i) >= elem(low, i) - 1.0e-9 and elem(point, i) <= elem(high, i) + 1.0e-9
            end)
          end)
    end)
  end

  test "each flat face of the stations and of the busbar lies on a part" do
    looks = ["power_station" | Enum.map(stations(), &elem(&1, 0))]
    models = Enum.map(looks, &Shapes.model/1) ++ Enum.map(1..24, &Shapes.model({"dc_bus", &1}))

    for model <- models, {:face, _corners, normal, _class} = face <- model, normal != nil do
      assert on_part?(face, model), inspect(face)
    end

    # The place of the panel of each station on the stage is on its front.
    for look <- looks do
      {:front, {x, y, z}, {w, h}} = DIYWeb.Stage.region(look)
      face = {:face, [{x, y, z}, {x + w, y, z}, {x + w, y, z + h}, {x, y, z + h}], {0, 1, 0}, ""}
      assert on_part?(face, Shapes.model(look)), inspect(look)
    end
  end

  test "a loop round a rectangle with round corners" do
    near? = fn {a, b}, {c, d} -> abs(a - c) < 1.0e-9 and abs(b - d) < 1.0e-9 end

    no_twice? = fn loop ->
      not Enum.any?(Enum.zip(loop, tl(loop) ++ [hd(loop)]), fn {a, b} -> near?.(a, b) end)
    end

    # Each corner has 5 points.
    loop = Shapes.rounded({0, 0}, {1.0, 0.6}, 0.1)
    assert length(loop) == 20 and no_twice?.(loop)

    # The radius is at most half of the short side. Then the two short
    # sides have no length: at each end, two corners share one point. The
    # last corner and the first corner can also share a point.
    for size <- [{1.0, 0.6}, {0.6, 1.0}] do
      loop = Shapes.rounded({0, 0}, size, 0.5)
      assert length(loop) == 18 and no_twice?.(loop)
    end

    # A circle: the four corners share their ends.
    loop = Shapes.rounded({0, 0}, {0.6, 0.6}, 0.3)
    assert length(loop) == 16 and no_twice?.(loop)

    for {u, v} <- loop do
      assert u > -1.0e-9 and u < 0.6 + 1.0e-9 and v > -1.0e-9 and v < 0.6 + 1.0e-9
      assert_in_delta :math.sqrt((u - 0.3) * (u - 0.3) + (v - 0.3) * (v - 0.3)), 0.3, 1.0e-9
    end
  end

  property "a round shape: its shape, the faces that look to the camera, its edge and its top" do
    check all(
            turn <- integer(0..3),
            camera <- member_of([Camera.house(), Camera.van()]),
            r <- float(min: 0.0, max: 0.4)
          ) do
      model = [{:prism, Shapes.rounded({0, 0}, {1.0, 0.6}, r), 0.0, 0.8, "white"}]
      polys = Shapes.placed_model(model, %{at: {0, 0, 0}, turn: turn, camera: camera})

      # The shape of the faces that show paints first, and its edge paints
      # after the faces. Then the top.
      [{:poly, shape, "i-white-m2"} | rest] = polys

      {body, [{:poly, edge, "i-outline"}, {:poly, top, "i-white-t i-face"}]} =
        Enum.split(rest, -2)

      assert shape == edge

      # Each face that shows looks to the camera, and it is a part of the
      # shape. Its light is one of the five steps.
      corners = MapSet.new(edge)

      for {:poly, [a, b, _c, d] = face, class} <- body do
        assert class =~ ~r/^i-white-(l|m1|m2|m3|r)$/
        assert Enum.all?(face, &(&1 in corners))

        normal =
          cross(Geometry.add(b, Geometry.scale(a, -1)), Geometry.add(d, Geometry.scale(a, -1)))

        assert Camera.shows?(camera, normal)
      end

      # The count of the faces that show: the sides of the top that look to
      # the camera.
      shown =
        Enum.count(Enum.zip(top, tl(top) ++ [hd(top)]), fn {{x1, y1, _}, {x2, y2, _}} ->
          Camera.shows?(camera, {y2 - y1, x1 - x2, 0})
        end)

      assert length(body) == shown
    end
  end

  test "a cylinder has the five steps of the light, for each camera" do
    for camera <- [Camera.house(), Camera.van()] do
      polys =
        Shapes.placed_model([{:cyl, {0, 0, 0}, 0.5, 1.0, "steel"}], %{
          at: {0, 0, 0},
          turn: 0,
          camera: camera
        })

      lights = for {:poly, _corners, "i-steel-" <> light} <- polys, uniq: true, do: light
      assert Enum.sort(lights) == ["l", "m1", "m2", "m3", "r", "t i-face"]
    end
  end

  property "a tube along x or y: its shape, its faces, its edge, and the end that looks to the camera" do
    check all(
            turn <- integer(0..3),
            camera <- member_of([Camera.house(), Camera.van()]),
            axis <- member_of([:x, :y])
          ) do
      loop =
        for k <- 0..23,
            a = 2 * :math.pi() * k / 24,
            do: {0.3 + 0.2 * :math.cos(a), 0.3 + 0.2 * :math.sin(a)}

      model = [{:prism, axis, loop, 0.0, 1.0, "white"}]
      polys = Shapes.placed_model(model, %{at: {0, 0, 0}, turn: turn, camera: camera})

      [{:poly, shape, "i-white-m2"} | rest] = polys
      {body, [{:poly, edge, "i-outline"}, {:poly, cap, cap_class}]} = Enum.split(rest, -2)
      assert shape == edge
      assert cap_class =~ ~r/^i-white-(l|m1|m2|m3|r) i-face$/

      for {:poly, [a, b, _c, d], _class} <- body do
        normal =
          cross(Geometry.add(b, Geometry.scale(a, -1)), Geometry.add(d, Geometry.scale(a, -1)))

        assert Camera.shows?(camera, normal)
      end

      # The end is at the end of the tube that is nearer to the eye.
      {cx, _cy, _cz} = hd(cap)
      along = if Enum.all?(cap, &(abs(elem(&1, 0) - cx) < 1.0e-9)), do: 0, else: 1
      values = Enum.map(edge, &elem(&1, along))
      near = if elem(camera.eye, along) > 0, do: Enum.max(values), else: Enum.min(values)
      for point <- cap, do: assert_in_delta(elem(point, along), near, 1.0e-9)
    end
  end

  test "a loop that is not convex: each face has its edge, and the prism has no shape under its faces" do
    # A loop in the shape of an L. The order of the paint is in the depth
    # check of the cutaway tests.
    loop = [{0, 0}, {1, 0}, {1, 0.3}, {0.3, 0.3}, {0.3, 1}, {0, 1}]

    for turn <- 0..3, camera <- [Camera.house(), Camera.van()] do
      polys =
        Shapes.placed_model([{:prism, loop, 0.0, 0.5, "white"}], %{
          at: {0, 0, 0},
          turn: turn,
          camera: camera
        })

      {body, [{:poly, _top, "i-white-t i-face"}]} = Enum.split(polys, -1)
      assert body != []

      for {:poly, _corners, class} <- body,
          do: assert(class =~ ~r/^i-white-(l|m1|m2|m3|r) i-face$/)
    end
  end

  test "the electric car: the profile of its body, its glass, and its wheels" do
    [{:group, [{:prism, :x, _profile, +0.0, w, "red"} | details]}] = Shapes.model("ev")
    {{_x0, y0, z0}, {_x1, y1, z1}} = Shapes.bounds(Shapes.model("ev"))

    # The size of the kind: 73 by 186 by 57 inches.
    assert_in_delta w, 73 * 0.0254, 0.01
    assert_in_delta y1 - y0, 186 * 0.0254, 0.01
    assert_in_delta z1 - z0, 57 * 0.0254, 0.01

    # The windshield looks to the front and up, and the back window looks to
    # the back and up.
    glass = for {:face, _corners, {0, ny, nz}, "i-glass-dark"} <- details, do: {ny > 0, nz > 0}
    assert Enum.sort(glass) == [{false, true}, {true, true}]

    # The two tail lights are on the back of the body, from 0.36 m to
    # 0.84 m high.
    lights = for {:face, corners, {0, -1, 0}, "i-hot"} <- details, do: corners
    assert length(lights) == 2
    for corners <- lights, {_x, y, z} <- corners, do: assert(y < 0 and z > 0.36 and z < 0.84)

    # A tire is at each axle (0.95 m and 3.85 m from the back), on each
    # side.
    tires =
      for {:face, corners, {sign, 0, 0}, "i-black"} <- details, length(corners) == 24 do
        ys = Enum.map(corners, &elem(&1, 1))
        {sign, Float.round((Enum.min(ys) + Enum.max(ys)) / 2, 6)}
      end

    assert Enum.sort(tires) == [{-1, 0.95}, {-1, 3.85}, {1, 0.95}, {1, 3.85}]
  end

  defp cross({a, b, c}, {d, e, f}), do: {b * f - c * e, c * d - a * f, a * e - b * d}
end
