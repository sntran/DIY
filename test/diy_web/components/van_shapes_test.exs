defmodule DIYWeb.VanShapesTest do
  use ExUnit.Case, async: true

  alias DIY.Catalog
  alias DIYWeb.Icon.VanShapes

  @m 0.0254

  defp models, do: Enum.map(Catalog.van_models(), &elem(&1, 0))

  # The size of a model in meters: its length, its width and its height.
  defp size(model) do
    size = Catalog.van_size(model)
    {size.length * @m, size.width * @m, size.height * @m}
  end

  defp body(model) do
    [_arm, _mirror, {:group, body}, _other_arm, _other_mirror] = VanShapes.van(model)
    body
  end

  defp points(parts), do: for({:face, corners, _normal, _class} <- parts, p <- corners, do: p)

  defp range(points, axis), do: points |> Enum.map(&elem(&1, axis)) |> Enum.min_max()

  test "the body of each model has the real length, width and height of the model" do
    for model <- models() do
      {l, w, h} = size(model)
      points = points(body(model))

      # The details are a little out of the faces (less than 2 cm).
      {x0, x1} = range(points, 0)
      {y0, y1} = range(points, 1)
      {z0, z1} = range(points, 2)
      assert_in_delta x0, 0.0, 0.02
      assert_in_delta x1, w, 0.02
      assert_in_delta y0, 0.0, 0.02
      assert_in_delta y1, l, 0.02
      assert_in_delta z0, 0.0, 0.02
      assert_in_delta z1, h, 0.02
    end
  end

  test "the tires are at the axles of the model, on the two sides" do
    for model <- models() do
      size = Catalog.van_size(model)
      front = (size.length - size.front) * @m
      rear = front - size.wheelbase * @m

      centers =
        for {:face, corners, {sign, 0, 0}, "i-black"} <- body(model),
            length(corners) == 24 do
          {low, high} = range(corners, 1)
          {sign, Float.round((low + high) / 2, 6)}
        end

      assert Enum.sort(centers) ==
               Enum.sort(for sign <- [-1, 1], y <- [rear, front], do: {sign, Float.round(y, 6)})
    end
  end

  test "each model has the nose of its brand" do
    # The length of the hood: from the front of the van to the bottom of
    # the windshield. The windshield is the glass that looks up and to the
    # front.
    hood = fn model ->
      {l, _w, _h} = size(model)

      [windshield] =
        for {:face, corners, {0, dy, dz}, "i-glass-dark"} <- body(model),
            dy > 0 and dz > 0,
            do: corners

      l - elem(range(windshield, 1), 1)
    end

    # The Sprinter has a long hood, and the ProMaster has a short nose that
    # is almost upright.
    assert hood.("sprinter_170") > hood.("transit_148")
    assert hood.("transit_148") > hood.("promaster_159")
    assert hood.("promaster_159") < 0.6

    # The top of the hood is from 1.1 to 1.25 meters over the ground.
    for model <- models() do
      assert VanShapes.hood_height(model) > 1.1 and VanShapes.hood_height(model) < 1.25
    end

    # The Sprinter has the star of its brand on the grille: a ring of 12
    # points.
    rings = fn model ->
      for {:face, corners, _n, "i-steel-t"} <- body(model), length(corners) == 12, do: 1
    end

    assert rings.("sprinter_170") == [1]
    assert rings.("transit_148") == [] and rings.("promaster_159") == []
  end

  test "the mirrors stand out of the two sides, next to the windshield" do
    for model <- models() do
      {_l, w, _h} = size(model)
      [arm, mirror, _body, other_arm, other_mirror] = VanShapes.van(model)

      for {:box, {x, _y, _z}, {dx, _dy, _dz}, "dark"} <- [arm, mirror],
          do: assert(x + dx <= 0.0)

      for {:box, {x, _y, _z}, _size, "dark"} <- [other_arm, other_mirror],
          do: assert(x >= w)
    end
  end

  test "a model that the app does not know has the shape and the size of the Transit" do
    assert VanShapes.van("other") == VanShapes.van("transit_148")
    assert VanShapes.hood_height("other") == VanShapes.hood_height("transit_148")
  end

  test "the sides lean in over the belt, and the windows follow them" do
    for model <- models() do
      {_l, w, h} = size(model)

      # Each point of a side is in the width of the van at its height: the
      # roof is narrower than the bottom.
      tops =
        for {:face, corners, {sign, 0, _}, "i-white-~ i-face"} <- body(model),
            {x, _y, z} <- corners,
            z >= h - 0.01,
            do: {sign, x}

      assert tops != []
      for {-1, x} <- tops, do: assert(x > 0.0)
      for {1, x} <- tops, do: assert(x < w)
    end
  end
end
