defmodule DIYWeb.HullTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIYWeb.Camera
  alias DIYWeb.Icon.Shapes

  # A hull 4 m long, 2 m wide and 2 m high, with an upright nose and a
  # windshield at 45 degrees. The loop goes along the bottom from the back
  # to the front, up the nose, over the top and down the back.
  @loop [{0.0, 0.3}, {4.0, 0.3}, {4.0, 1.0}, {3.0, 2.0}, {0.0, 2.0}]
  @round %{belt: 1.0, lean: 0.1, edge: 0.2, nose: 0.3, tail: 0.1}

  defp hull(faces \\ []), do: Shapes.hull(@loop, 2.0, @round, "white", faces)

  # The polygons of a model for a camera, at its place (no frame).
  defp polys(model, camera \\ Camera.van(), frame \\ nil) do
    for object <- Shapes.parts(model, frame, camera), poly <- object.polys, do: poly
  end

  defp all?(corners, axis, value),
    do: Enum.all?(corners, &(abs(elem(&1, axis) - value) < 0.01))

  test "a side of a hull leans in over the belt, with a round edge of the roof and round corners" do
    shape = Shapes.hull_shape(@loop, 2.0, @round)
    assert {shape.front, shape.back, shape.top, shape.width} == {4.0, 0.0, 2.0, 2.0}

    # Under the belt, in the middle, the side is upright.
    assert Shapes.hull_inset(shape, 2.0, 0.8) == 0.0
    # The lean is all there under the round edge, and the edge adds its
    # radius at the top.
    assert_in_delta Shapes.hull_inset(shape, 2.0, 1.8), 0.1, 1.0e-6
    assert_in_delta Shapes.hull_inset(shape, 2.0, 2.0), 0.3, 1.0e-6
    # The corners at the front and at the back are round.
    assert_in_delta Shapes.hull_inset(shape, 4.0, 0.5), 0.3, 1.0e-6
    assert_in_delta Shapes.hull_inset(shape, 0.0, 0.5), 0.1, 1.0e-6
    assert Shapes.hull_inset(shape, 3.85, 0.5) > 0.0 and Shapes.hull_inset(shape, 3.85, 0.5) < 0.3

    # A side is never in by half of the width.
    wide = Shapes.hull_shape(@loop, 2.0, %{@round | lean: 5.0})
    assert_in_delta Shapes.hull_inset(wide, 2.0, 2.0), 0.99, 1.0e-6
  end

  test "the box of a hull is its profile across its width" do
    assert Shapes.bounds([hull()]) == {{0.0, 0.0, 0.3}, {2.0, 4.0, 2.0}}
  end

  test "a face that looks up has the light of a top, a side has its light, and a slope has steps" do
    polys = polys([hull()])

    # The top is a top, and the nose is in the shade of the camera of a van.
    assert Enum.any?(polys, fn {corners, class} ->
             all?(corners, 2, 2.0) and class == "i-white-t"
           end)

    assert Enum.any?(polys, fn {corners, class} ->
             all?(corners, 1, 4.0) and class == "i-white-r"
           end)

    # The windshield looks up at 45 degrees: its side light, and over it
    # 3/4 of the light of a top, with its true size. The face under it is a
    # little longer (2 mm at each end).
    on_slope = fn corners ->
      Enum.all?(corners, fn {_x, y, z} -> abs(y + z - 5.0) < 1.0e-6 end)
    end

    slope = for {corners, class} <- polys, on_slope.(corners), do: {corners, class}
    assert [{under, "i-white-r"}, {over, "i-white-t i-o3"}] = slope
    assert Enum.max(Enum.map(under, &elem(&1, 2))) > Enum.max(Enum.map(over, &elem(&1, 2)))

    # The side that looks to the camera (x = 2) paints in cells, then its
    # edge. The other side does not paint.
    [{edge, "i-outline"}] = for {corners, "i-outline"} = poly <- polys, do: poly
    assert length(edge) == length(@loop)
    assert Enum.all?(edge, fn {x, _y, _z} -> x > 1.5 end)
    refute Enum.any?(polys, fn {corners, _class} -> all?(corners, 0, 0.0) end)
  end

  test "a hull that turns shows its other side" do
    frame = %{at: {0, 0, 0}, size: {2.0, 4.0, 1.7}, turn: 2}
    polys = polys([hull()], Camera.van(), frame)

    # After the turn, the side at x = 0 of the hull is at the large x, near
    # the eye: its cells and its edge paint.
    assert [_edge] = for({_corners, "i-outline"} <- polys, do: 1)
    assert Enum.count(polys, fn {_corners, class} -> class =~ "i-white" end) > 4
  end

  test "a face of a hull paints just after the edge that it is on" do
    # A red face on the top, and a blue face on the nose.
    top =
      {:face, [{0.5, 1.0, 2.02}, {1.5, 1.0, 2.02}, {1.5, 2.0, 2.02}, {0.5, 2.0, 2.02}], {0, 0, 1},
       "i-red-t"}

    nose =
      {:face, [{0.5, 4.02, 0.5}, {1.5, 4.02, 0.5}, {1.5, 4.02, 0.8}, {0.5, 4.02, 0.8}], {0, 1, 0},
       "i-blue-l"}

    polys = polys([hull([top, nose])])
    classes = Enum.map(polys, &elem(&1, 1))

    index = fn class -> Enum.find_index(classes, &(&1 == class)) end

    last = fn axis, value ->
      polys
      |> Enum.with_index()
      |> Enum.filter(fn {{c, _}, _} -> all?(c, axis, value) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.max()
    end

    # Each face paints after the faces of its edge, and before the side.
    assert index.("i-red-t") == last.(2, 2.0) + 1
    assert index.("i-blue-l") == last.(1, 4.0) + 1
    assert index.("i-red-t") < index.("i-outline") and index.("i-blue-l") < index.("i-outline")
  end

  test "a shape on a side is cut to the profile and where the side bends" do
    shape = Shapes.hull_shape(@loop, 2.0, @round)

    # A rectangle larger than the profile, in the two turns of its points.
    rect = [{-1.0, 0.0}, {5.0, 0.0}, {5.0, 1.5}, {-1.0, 1.5}]

    for points <- [rect, Enum.reverse(rect)] do
      pieces = Shapes.hull_pieces(@loop, shape, points)
      all = List.flatten(pieces)

      # The pieces stay in the profile (and 4 mm more, to go over the next
      # piece).
      assert Enum.all?(all, fn {y, z} ->
               y >= -0.005 and y <= 4.005 and z >= 0.295 and z <= 1.505
             end)

      # The belt cuts them: a piece is under it, and a piece is over it.
      assert Enum.any?(pieces, fn p -> Enum.all?(p, &(elem(&1, 1) <= 1.005)) end)
      assert Enum.any?(pieces, fn p -> Enum.all?(p, &(elem(&1, 1) >= 0.995)) end)
    end

    # A shape out of the profile has no piece.
    assert Shapes.hull_pieces(@loop, shape, [{5.0, 0.5}, {6.0, 0.5}, {6.0, 0.6}]) == []
  end

  test "the normal of a flat shape looks to the side of its hint" do
    square = [{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}]
    {_x, _y, up} = Shapes.normal(square, {0, 0, 1})
    {_x, _y, down} = Shapes.normal(square, {0, 0, -1})
    assert up > 0 and down < 0
  end

  ## The properties

  # A random round shape of a hull: its belt, its lean, and the radius of
  # its edge and of its corners.
  defp rounds do
    gen all(
          belt <- float(min: 0.2, max: 1.9),
          lean <- float(min: 0.0, max: 1.5),
          edge <- float(min: 0.0, max: 0.6),
          nose <- float(min: 0.0, max: 1.0),
          tail <- float(min: 0.0, max: 1.0)
        ) do
      %{belt: belt, lean: lean, edge: edge, nose: nose, tail: tail}
    end
  end

  property "a side of a hull is in by 0 to less than half of its width, and more as it goes up" do
    check all(
            round <- rounds(),
            y <- float(min: 0.0, max: 4.0),
            z0 <- float(min: 0.3, max: 2.0),
            z1 <- float(min: 0.3, max: 2.0)
          ) do
      shape = Shapes.hull_shape(@loop, 2.0, round)

      {low, high} =
        {Shapes.hull_inset(shape, y, min(z0, z1)), Shapes.hull_inset(shape, y, max(z0, z1))}

      assert low >= 0.0 and high <= 0.99
      assert high >= low - 1.0e-9
    end
  end

  property "the pieces of a shape on a side stay in the profile" do
    check all(
            round <- rounds(),
            y0 <- float(min: -1.0, max: 5.0),
            dy <- float(min: 0.05, max: 3.0),
            z0 <- float(min: 0.0, max: 2.2),
            dz <- float(min: 0.05, max: 1.0)
          ) do
      shape = Shapes.hull_shape(@loop, 2.0, round)
      rect = [{y0, z0}, {y0 + dy, z0}, {y0 + dy, z0 + dz}, {y0, z0 + dz}]

      for piece <- Shapes.hull_pieces(@loop, shape, rect), {y, z} <- piece do
        assert y >= -0.005 and y <= 4.005 and z >= 0.295 and z <= 2.005

        assert y >= y0 - 0.005 and y <= y0 + dy + 0.005 and z >= z0 - 0.005 and
                 z <= z0 + dz + 0.005
      end
    end
  end
end
