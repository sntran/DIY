defmodule DIYWeb.CameraTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIYWeb.{Camera, Geometry}

  defp number, do: float(min: -50.0, max: 50.0)
  defp point, do: tuple({number(), number(), number()})
  defp camera, do: member_of([Camera.house(), Camera.van()])

  # Any camera that looks down, from the large x and y.
  defp any_camera do
    gen(all(yaw <- integer(1..89), pitch <- integer(1..89)),
      do: Camera.new(:test, yaw, pitch)
    )
  end

  property "a step along the eye goes to the same point: the camera has no vanishing point" do
    check all(c <- any_camera(), p <- point(), t <- number()) do
      {x1, y1} = Camera.at(c, {0, 0}, p)
      {x2, y2} = Camera.at(c, {0, 0}, Geometry.add(p, Geometry.scale(c.eye, t)))
      assert_in_delta x1, x2, 1.0e-6
      assert_in_delta y1, y2, 1.0e-6

      # The point nearer to the eye has the larger depth.
      if t > 0.01,
        do:
          assert(Camera.depth(c, Geometry.add(p, Geometry.scale(c.eye, t))) > Camera.depth(c, p))
    end
  end

  property "the points of the world go to the SVG with a sum (a linear map)" do
    check all(
            c <- any_camera(),
            a <- point(),
            b <- point(),
            {ox, oy} <- tuple({number(), number()})
          ) do
      {ax, ay} = Camera.at(c, {0, 0}, a)
      {bx, by} = Camera.at(c, {0, 0}, b)
      {sx, sy} = Camera.at(c, {ox, oy}, Geometry.add(a, b))
      assert_in_delta sx, ax + bx + ox, 1.0e-6
      assert_in_delta sy, ay + by + oy, 1.0e-6
    end
  end

  property "the axes of the hook are the SVG vectors of one inch" do
    check all(c <- any_camera()) do
      {{ax, ay}, {bx, by}, {cx, cy}} = Camera.axes(c)

      for {{u, v}, p} <- [
            {{ax, ay}, {0.0254, 0, 0}},
            {{bx, by}, {0, 0.0254, 0}},
            {{cx, cy}, {0, 0, 0.0254}}
          ] do
        {sx, sy} = Camera.at(c, {0, 0}, p)
        assert_in_delta u, sx, 1.0e-9
        assert_in_delta v, sy, 1.0e-9
      end
    end
  end

  test "up is up; the house goes along the screen, and the van too" do
    for c <- [Camera.house(), Camera.van()] do
      {sx, sy} = Camera.at(c, {0, 0}, {0, 0, 1})
      assert sx == 0.0 and sy < 0
    end

    # The house: x goes to the right, and y (to its front) down the screen.
    house = Camera.house()
    {hx, hy} = Camera.at(house, {0, 0}, {1, 0, 0})
    {fx, fy} = Camera.at(house, {0, 0}, {0, 1, 0})
    assert hx > abs(hy) and fy > abs(fx)
    assert Camera.depth_axis(house) == :y
    assert Camera.arrows(house) == {{1, 0}, {0, 1}}

    # The van: y (to its cab) goes to the left, and x (to its left side, the
    # side of the driver) down the screen.
    van = Camera.van()
    {lx, ly} = Camera.at(van, {0, 0}, {0, 1, 0})
    {sx, sy} = Camera.at(van, {0, 0}, {1, 0, 0})
    assert -lx > abs(ly) and sy > abs(sx)
    assert Camera.depth_axis(van) == :x
    assert Camera.arrows(van) == {{0, -1}, {1, 0}}
  end

  test "a camera has a yaw and a pitch between 0 and 90 degrees" do
    for {yaw, pitch} <- [{0, 30}, {90, 30}, {45, 0}, {45, 90}] do
      assert_raise FunctionClauseError, fn -> Camera.new(:bad, yaw, pitch) end
    end
  end

  property "a box shows its top, its front and its side; the face that looks more to the camera is in the light" do
    check all(c <- camera()) do
      assert Camera.shows?(c, {0, 0, 1})
      assert Camera.shows?(c, {0, 1, 0})
      assert Camera.shows?(c, {1, 0, 0})
      refute Camera.shows?(c, {0, 0, -1})
      refute Camera.shows?(c, {0, -1, 0})
      refute Camera.shows?(c, {-1, 0, 0})
      assert Camera.light(c, {0, 0, 1}) == "t"
      assert Camera.light(c, {0, 0.6, 0.8}) == "t"

      box = Geometry.box({1, 2, 3}, {4, 5, 6})
      [{shade, "m-r"}, {lit, "m-l"}, {top, "m-t"}] = Camera.faces(c, box, "m")
      assert top == box.top

      if c.name == :house do
        assert {lit, shade} == {box.front, box.side}
        assert {Camera.light(c, {0, 1, 0}), Camera.light(c, {1, 0, 0})} == {"l", "r"}
      else
        assert {lit, shade} == {box.side, box.front}
        assert {Camera.light(c, {0, 1, 0}), Camera.light(c, {1, 0, 0})} == {"r", "l"}
      end
    end
  end

  property "the face in the light looks more to the eye than the face in the shade" do
    # Any camera, and the cameras at a yaw of 45 degrees. At 45 degrees, the
    # two faces of a box look to the eye by the same amount (but for a
    # rounding).
    cameras = one_of([any_camera(), map(integer(1..89), &Camera.new(:half, 45, &1))])

    check all(c <- cameras) do
      box = Geometry.box({0, 0, 0}, {1, 1, 1})
      [{shade, "m-r"}, {lit, "m-l"}, _top] = Camera.faces(c, box, "m")
      normal = fn face -> if face == box.front, do: {0, 1, 0}, else: {1, 0, 0} end
      assert Geometry.dot(c.eye, normal.(lit)) >= Geometry.dot(c.eye, normal.(shade))
      assert Camera.light(c, normal.(lit)) == "l"
      assert Camera.light(c, normal.(shade)) == "r"
    end
  end

  property "a round shape goes from the light to the shade in steps" do
    steps = ~w(l m1 m2 m3 r)

    check all(c <- camera(), a <- float(min: 0.0, max: 90.0), b <- float(min: 0.0, max: 90.0)) do
      # Two normals on the ground, from the side in the light (0 degrees) to
      # the other side (90 degrees). The normal nearer to the side in the
      # light has the same light or more light.
      normal = fn degrees ->
        {s, t} = {:math.sin(degrees * :math.pi() / 180), :math.cos(degrees * :math.pi() / 180)}
        if c.lit == :front, do: {s, t, 0}, else: {t, s, 0}
      end

      [near, far] = Enum.sort([a, b])
      rank = &Enum.find_index(steps, fn step -> step == Camera.light(c, normal.(&1)) end)
      assert rank.(near) <= rank.(far)
    end
  end

  test "the steps of the light, and a normal that looks straight down" do
    house = Camera.house()

    for {degrees, light} <- [{0, "l"}, {30, "m1"}, {55, "m2"}, {70, "m3"}, {85, "r"}] do
      a = degrees * :math.pi() / 180
      assert Camera.light(house, {:math.sin(a), :math.cos(a), 0}) == light
    end

    assert Camera.light(house, {0, 0, -1}) == "r"
  end

  test "a box and a cylinder have their part in the light on the same side of the screen" do
    model = [{:box, {0, 0, 0}, {1, 1, 1}, "white"}, {:cyl, {2.5, 0.5, 0}, 0.5, 1, "white"}]

    for c <- [Camera.house(), Camera.van()] do
      polys = DIYWeb.Icon.Shapes.placed_model(model, %{at: {0, 0, 0}, turn: 0, camera: c})

      # The middle of the screen x of the polygons of a light (l or r). The
      # box is at x < 2 in the world, and the cylinder is at x >= 2.
      middle = fn light, part? ->
        xs =
          for {:poly, corners, class} <- polys,
              hd(String.split(class)) == "i-white-#{light}",
              Enum.all?(corners, fn {x, _y, _z} -> part?.(x) end),
              {x, y, z} <- corners,
              do: elem(Camera.at(c, {0, 0}, {x, y, z}), 0)

        Enum.sum(xs) / length(xs)
      end

      box = fn x -> x <= 1.0 end
      cylinder = fn x -> x >= 2.0 end

      assert middle.("l", box) < middle.("r", box) ==
               middle.("l", cylinder) < middle.("r", cylinder),
             "#{c.name}: the light of the cylinder"
    end
  end

  test "the three faces of a box, and a box with a top on a slope" do
    box = Geometry.box({1, 2, 3}, {4, 5, 6})
    assert {1, 2, 9} in box.top and {5, 7, 9} in box.top
    assert Enum.all?(box.front, fn {_x, y, _z} -> y == 7 end)
    assert Enum.all?(box.side, fn {x, _y, _z} -> x == 5 end)

    # Along y: the height goes from 2 at y = 0 to 1 at y = 4.
    along_y = Geometry.wedge({0, 0, 0}, {1, 4}, {2, 1}, :y)
    assert {0, 0, 2} in along_y.top and {1, 4, 1} in along_y.top
    assert Enum.all?(along_y.front, fn {_x, y, z} -> y == 4 and z <= 1 end)
    assert {1, 0, 2} in along_y.side

    # Along x: the height goes from 2 at x = 0 to 1 at x = 4.
    along_x = Geometry.wedge({0, 0, 0}, {4, 1}, {2, 1}, :x)
    assert {0, 0, 2} in along_x.top and {4, 1, 1} in along_x.top
    assert Enum.all?(along_x.side, fn {x, _y, z} -> x == 4 and z <= 1 end)
    assert {0, 1, 2} in along_x.front
    assert Geometry.dot({1, 2, 3}, {4, 5, 6}) == 32
  end

  property "a rectangle and a circle stay on their plane" do
    check all(a <- point(), s <- number(), t <- number(), r <- float(min: 0.1, max: 9.0)) do
      for {_x, _y, z} <- Geometry.on_plane(a, {1, 0, 0}, {0, 1, 0}, {s, t}, {1.0, 2.0}),
          do: assert_in_delta(z, elem(a, 2), 1.0e-9)

      for p <- Geometry.circle(a, {1, 0, 0}, {0, 0, 1}, r) do
        {dx, dy, dz} = Geometry.add(p, Geometry.scale(a, -1))
        assert_in_delta dy, 0, 1.0e-9
        assert_in_delta :math.sqrt(dx * dx + dz * dz), r, 1.0e-6
      end
    end
  end

  test "the numbers of the SVG have one decimal" do
    assert Camera.round1(2.0) == "2"
    assert Camera.round1(2.25) == "2.3"
    assert Camera.round1(-0.04) == "0"
    assert Camera.points(Camera.house(), {0, 0}, [{0, 0, 0}, {0, 0, 1}]) == "0,0 0,-10.8"
  end
end
