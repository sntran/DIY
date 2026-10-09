defmodule DIYWeb.IconTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.Catalog
  alias DIYWeb.{Camera, Geometry, Icon}
  alias DIYWeb.Icon.Shapes

  test "each kind has shapes of its own" do
    shapes = for kind <- Catalog.kinds(), do: Shapes.shapes(kind.type)
    assert length(Enum.uniq(shapes)) == length(Catalog.kinds())
  end

  test "each class of the icons has a rule in app.css" do
    css = File.read!("assets/css/app.css")

    classes =
      for kind <- Catalog.kinds(),
          {:poly, _corners, class} <- Shapes.shapes(kind.type),
          name <- String.split(class),
          uniq: true,
          do: name

    for class <- classes, do: assert(css =~ "." <> class <> " {", "no rule for #{class}")
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
    [{:group, [{:prism, :x, _profile, 0.0, w, "red"} | details]}] = Shapes.model("ev")
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
