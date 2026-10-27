defmodule DIYWeb.VanShapesTest do
  use ExUnit.Case, async: true

  alias DIY.Catalog
  alias DIYWeb.Icon.{Shapes, VanShapes}

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

  # The hull of a model, and the faces on its front, its top and its back.
  defp hull(model) do
    [{:hull, loop, w, shape, "white", faces} | _details] = body(model)
    %{loop: loop, w: w, shape: shape, faces: faces}
  end

  defp range(points, axis), do: points |> Enum.map(&elem(&1, axis)) |> Enum.min_max()

  # The height of the profile where it reaches the roof, back from the
  # front (in meters).
  defp roof_starts(model) do
    {l, _w, h} = size(model)
    {y, _z} = Enum.find(VanShapes.profile(model), fn {_y, z} -> z >= h - 1.0e-9 end)
    l - y
  end

  test "the body of each model has the real length, width and height of the model" do
    for model <- models() do
      {l, w, h} = size(model)
      {{x0, y0, z0}, {x1, y1, z1}} = Shapes.bounds(body(model))

      # The wheels and the details are a little out of the hull (less than
      # 3 cm).
      assert_in_delta x0, 0.0, 0.03
      assert_in_delta x1, w, 0.03
      assert_in_delta y0, 0.0, 0.003
      assert_in_delta y1, l, 0.003
      assert_in_delta z0, 0.0, 1.0e-9
      assert_in_delta z1, h, 1.0e-9
    end
  end

  test "the profile of each make is the trace of its drawing" do
    for model <- models() do
      {l, _w, h} = size(model)
      loop = VanShapes.profile(model)
      {ys, zs} = Enum.unzip(loop)

      # The profile is in the length and the height of the model, and it
      # reaches the front, the back and the roof.
      assert Enum.max(zs) == h
      assert Enum.max(ys) == l
      assert Enum.min(ys) == 0.0

      # The bottom of the windshield is from 1.35 to 1.55 meters over the
      # ground.
      assert VanShapes.hood_height(model) > 1.35 and VanShapes.hood_height(model) < 1.55
    end

    # The ProMaster has the shortest nose, and its roof rises first. The
    # roof of the Transit rises in the longest curve. The windshield of the
    # Sprinter starts the highest.
    assert roof_starts("promaster_136") < roof_starts("sprinter_144")
    assert roof_starts("sprinter_144") < roof_starts("transit_148")
    assert VanShapes.hood_height("sprinter_144") > VanShapes.hood_height("transit_148")
    assert VanShapes.hood_height("transit_148") > VanShapes.hood_height("promaster_136")

    # The points of a trace over 2 m stretch to the roof of the model. So
    # the same make with a higher roof has the same cab.
    low = VanShapes.profile("transit_148_medium")
    high = VanShapes.profile("transit_148")
    assert Enum.filter(low, &(elem(&1, 1) < 1.5)) != Enum.filter(high, &(elem(&1, 1) < 1.5))
    assert VanShapes.hood_height("transit_148_medium") > 1.4
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

  test "each make has the grille of its brand" do
    # The classes of the faces on the front. Then the steel near the middle
    # of the front, at the height of the star of the Sprinter.
    ahead = fn {nx, ny, nz} -> ny / :math.sqrt(nx * nx + ny * ny + nz * nz) > 0.5 end

    front = fn model ->
      for {:face, _corners, normal, class} <- hull(model).faces, ahead.(normal), do: class
    end

    star = fn model ->
      {_l, w, _h} = size(model)

      for {:face, corners, normal, "i-steel-t"} <- hull(model).faces,
          ahead.(normal),
          {x0, x1} = range(corners, 0),
          {z0, z1} = range(corners, 2),
          abs((x0 + x1) / 2 - w / 2) < 0.12 and z0 > 0.85 and z1 < 1.15,
          do: 1
    end

    # The Transit has the blue oval, the ProMaster has the low dark grille,
    # and the Sprinter has the star in its bars.
    assert "i-screen" in front.("transit_148")
    refute "i-screen" in front.("sprinter_144") or "i-screen" in front.("promaster_136")
    assert "i-dark-t" in front.("promaster_136")
    refute "i-dark-t" in front.("transit_148") or "i-dark-t" in front.("sprinter_144")
    assert length(star.("sprinter_144")) > length(star.("transit_148"))
  end

  test "the faces on the front and the back stay on the profile" do
    for model <- models() do
      %{loop: loop, faces: faces} = hull(model)
      {ys, _zs} = Enum.unzip(loop)
      {back, front} = Enum.min_max(ys)

      for {:face, corners, _normal, _class} <- faces, {_x, y, _z} <- corners do
        assert y >= back - 0.01 and y <= front + 0.01
      end
    end
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

  test "the van with its mirrors fills the space of its item on the plan" do
    for model <- models() do
      {{x0, y0, _z0}, {x1, y1, _z1}} = Shapes.bounds(VanShapes.van(model))
      {w, d, _h} = DIY.Layout.size(%{type: "camper_van", params: %{"model" => model}})

      # So the plan of the house does not make the van smaller. The scale
      # is 1, and the body has the real width of the model.
      assert_in_delta x1 - x0, w * @m, 1.0e-9
      assert_in_delta y1 - y0, d * @m, 0.003
    end
  end

  test "a model that the app does not know has the shape and the size of the Transit" do
    assert VanShapes.van("other") == VanShapes.van("transit_148")
    assert VanShapes.hood_height("other") == VanShapes.hood_height("transit_148")
    assert VanShapes.profile("other") == VanShapes.profile("transit_148")
  end

  test "the sides lean in over the belt, the roof has a round edge, and the windows follow them" do
    for model <- models() do
      {l, w, h} = size(model)
      %{shape: shape} = hull(model)

      # Under the belt, a side is upright. At the roof, it is in by the lean
      # and the round edge.
      assert Shapes.hull_inset(shape, l / 2, 0.8) == 0.0
      assert_in_delta Shapes.hull_inset(shape, l / 2, h), shape.lean + shape.edge, 1.0e-6

      # The window of the door of the cab is on the side, in from it.
      windows =
        for {:face, corners, {nx, _ny, _nz}, "i-glass-dark"} <- body(model),
            {x, _y, z} <- corners,
            z > shape.belt + 0.2,
            do: if(nx < 0, do: x > 0.0, else: x < w)

      assert windows != [] and Enum.all?(windows)
    end
  end
end
