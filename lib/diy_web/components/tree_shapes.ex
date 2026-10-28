defmodule DIYWeb.Icon.TreeShapes do
  @moduledoc """
  The models of the kinds of a tree (`DIY.Catalog.tree_kinds/0`) at a size
  in meters, as parts of `DIYWeb.Icon.Shapes`. The crown of a model fills
  its size. The trunk and the bed of mulch have their real size: they do
  not get larger with the crown.

  The leaves are flat shapes that look to the camera of the house (`ball/3`).
  So a tree looks the same at each turn.

  - Live oak: a thick trunk, and a wide round crown of five balls.
  - Pine: a tall thin trunk, and five cones of branches, one over the other.
  - Palm: a tall thin trunk, and long leaves that hang from its top.
  - Crape myrtle: three thin trunks, and a crown of leaves with pink
    flowers.

  The view of the rooms cuts a tree (`cut/3`): it shows the trunk to a low
  height, and the shadow of the crown on the ground. So the tree does not
  hide the rooms.
  """

  alias DIYWeb.{Camera, Geometry}

  # The radius of the bed of mulch at most, in meters.
  @mulch 1.0

  @doc """
  The model of a kind of tree at a size `{w, d, h}` in meters. The bed of
  mulch paints first. Then the trunk, and then the crown from the back to
  the front.
  """
  def model(kind, {w, d, h}) do
    %{at: {x, y, z}, trunk: r, crown: crown} = fit(kind, {w, d, h})
    trunks = kind |> trunks({x, y}, z, r) |> Enum.sort_by(&depth(elem(&1, 1)))
    [mulch({w / 2, d / 2}, min(w, d)), {:group, trunks ++ in_front(crown, trunks)}]
  end

  @doc """
  The model of a tree in the view of the rooms, cut at a height (meters):
  the bed of mulch, the trunk to that height, and the shadow of the crown
  on the ground.
  """
  def cut(kind, {w, d, h}, height) do
    %{at: {x, y, z}, trunk: trunk} = fit(kind, {w, d, h})
    {u, v} = {{w / 2, 0.0, 0.0}, {0.0, d / 2, 0.0}}

    [
      {:face, Geometry.circle({w / 2, d / 2, 0.005}, u, v, 1.0, 24), {0, 0, 1}, "p-shadow"},
      mulch({w / 2, d / 2}, min(w, d)),
      {:group, trunks(kind, {x, y}, min(z, height), trunk)}
    ]
  end

  @doc """
  A ball of leaves (or of flowers) that looks to the camera of the house: a
  disc in the shade of the material, with two lighter discs on it.
  """
  def ball(center, r, material) do
    {u, v} = billboard()

    at = fn du, dv ->
      Geometry.add(center, Geometry.add(Geometry.scale(u, du), Geometry.scale(v, dv)))
    end

    [
      {:face, Geometry.circle(center, u, v, r), nil, "i-#{material}-r i-face"},
      {:face, Geometry.circle(at.(-0.12 * r, 0.12 * r), u, v, 0.78 * r), nil, "i-#{material}-l"},
      {:face, Geometry.circle(at.(-0.25 * r, 0.3 * r), u, v, 0.42 * r), nil, "i-#{material}-t"}
    ]
  end

  # How near a point is to the camera of the house.
  defp depth(point), do: Camera.depth(Camera.house(), point)

  # The crown in front of the trunks, from the back to the front. The leaves
  # are flat shapes on planes that look to the camera. So the crown moves
  # to the camera, until no part of it is behind a trunk: the picture does
  # not change. Then no part of the crown goes through a trunk.
  defp in_front(crown, trunks) do
    {ex, ey, _ez} = eye = Camera.house().eye
    side = :math.sqrt(ex * ex + ey * ey)
    back = for {:cyl, {x, y, _}, r, h, _} <- trunks, do: depth({x, y, h}) + r * side
    front = for {:face, corners, _, _} <- crown, point <- corners, do: depth(point)
    shift = Geometry.scale(eye, max(0.0, Enum.max(back) - Enum.min(front) + 0.02))

    crown
    |> Enum.map(fn {:face, corners, normal, class} ->
      {:face, Enum.map(corners, &Geometry.add(&1, shift)), normal, class}
    end)
    |> Enum.sort_by(fn {:face, corners, _, _} ->
      Enum.sum(Enum.map(corners, &depth/1)) / length(corners)
    end)
  end

  # Two vectors of length 1 on the plane that looks to the camera of the
  # house: u is level, and v goes up.
  defp billboard do
    {ex, ey, ez} = Camera.house().eye
    n = :math.sqrt(ex * ex + ey * ey)
    {ux, uy} = {-ey / n, ex / n}
    {{ux, uy, 0.0}, {-ez * uy, ez * ux, ex * uy - ey * ux}}
  end

  # A round bed of mulch under the tree.
  defp mulch({cx, cy}, side),
    do:
      {:face, Geometry.circle({cx, cy, 0.01}, {1, 0, 0}, {0, 1, 0}, min(@mulch, side / 2)),
       {0, 0, 1}, "i-wood-t"}

  # The crown of a kind at the size of the tree. The crown is the shapes of
  # `crown/1`, with one scale. The crown is as large as it can be in the
  # size, with its top at the top of the tree, and its middle over the
  # middle of the tree. `at` is the point of the crown where the trunk
  # ends (the point {0, 0} of `crown/1`). `trunk` is the radius of the
  # trunk: a tall tree has a thicker trunk.
  defp fit(kind, {w, d, h}) do
    {shapes, share, {r0, r1}} = crown(kind)
    {{x0, y0, z0}, {x1, y1, z1}} = DIYWeb.Icon.Shapes.bounds(shapes)
    k = Enum.min([w / (x1 - x0), d / (y1 - y0), share * h / (z1 - z0)])
    {dx, dy, dz} = {(w - k * (x0 + x1)) / 2, (d - k * (y0 + y1)) / 2, h - k * z1}
    point = fn {x, y, z} -> {dx + k * x, dy + k * y, dz + k * z} end

    crown =
      for {:face, corners, normal, class} <- shapes,
          do: {:face, Enum.map(corners, point), normal, class}

    %{at: {dx, dy, dz}, trunk: min(r1, max(r0, 0.025 * h)), crown: crown}
  end

  # The shapes of the crown of a kind, around the end of the trunk at
  # {0, 0, 0}, in units of any size. Also the most of the height of the
  # tree that the crown can take, and the least and the most radius of the
  # trunk in meters. The shapes are in the order of the paint: the back
  # first.
  defp crown("pine") do
    {u, _v} = billboard()
    up = {0.0, 0.0, 1.0}
    on = fn du, dz -> Geometry.add(Geometry.scale(u, du), Geometry.scale(up, dz)) end

    tiers =
      for i <- 0..4 do
        {z, half} = {i * 0.8, 1.0 - i * 0.17}
        top = z + 1.6

        [
          {:face, [on.(-half, z), on.(0.0, z - 0.2), on.(0.0, top)], nil, "i-leaf-l"},
          {:face, [on.(0.0, z - 0.2), on.(half, z), on.(0.0, top)], nil, "i-leaf-r"}
        ]
      end

    {List.flatten(tiers), 0.88, {0.08, 0.3}}
  end

  defp crown("palm") do
    {u, _v} = billboard()
    up = {0.0, 0.0, 1.0}
    on = fn du, dz -> Geometry.add(Geometry.scale(u, du), Geometry.scale(up, dz)) end

    # Each leaf goes out from the top of the trunk at an angle (degrees from
    # the right, up), and hangs down to its tip. The leaves at the back are
    # darker.
    leaves =
      for {a, class} <- [
            {150, "i-leaf-r"},
            {30, "i-leaf-r"},
            {110, "i-leaf-r"},
            {195, "i-leaf-l"},
            {-15, "i-leaf-l"},
            {170, "i-leaf-l"},
            {10, "i-leaf-l"},
            {80, "i-leaf-l"}
          ] do
        t = a * :math.pi() / 180
        {tx, tz} = {:math.cos(t), 0.5 * :math.sin(t) - 0.45}
        {mx, mz} = {0.5 * tx, 0.5 * :math.sin(t) * 0.8 + 0.05}
        {px, pz} = {-0.18 * :math.sin(t), 0.18 * :math.cos(t)}

        {:face, [on.(0.0, 0.0), on.(mx + px, mz + pz), on.(tx, tz), on.(mx - px, mz - pz)], nil,
         class}
      end

    {leaves, 0.45, {0.1, 0.2}}
  end

  defp crown("crape_myrtle") do
    leaves =
      ball({-0.5, 0.3, 0.1}, 0.55, "leaf") ++
        ball({0.5, 0.3, 0.15}, 0.55, "leaf") ++
        ball({0.0, 0.0, 0.45}, 0.6, "leaf") ++ ball({0.0, -0.3, 0.0}, 0.5, "leaf")

    # The flowers are in front of the leaves.
    {ex, ey, ez} = Camera.house().eye

    flowers =
      for {x, y, z} <- [
            {-0.55, -0.1, 0.35},
            {0.4, -0.2, 0.55},
            {-0.1, -0.5, 0.75},
            {0.6, -0.4, 0.1}
          ],
          part <- ball({x + 0.7 * ex, y + 0.7 * ey, z + 0.7 * ez}, 0.2, "pink"),
          do: part

    {leaves ++ flowers, 0.65, {0.05, 0.12}}
  end

  defp crown(_live_oak) do
    shapes =
      for {center, r} <- [
            {{-0.6, 0.3, 0.1}, 0.55},
            {{0.6, 0.3, 0.15}, 0.55},
            {{0.0, 0.35, 0.55}, 0.6},
            {{-0.3, 0.0, 0.55}, 0.55},
            {{0.35, 0.0, 0.45}, 0.55},
            {{-0.55, -0.35, 0.0}, 0.45},
            {{0.5, -0.35, 0.05}, 0.45},
            {{0.0, -0.4, 0.2}, 0.5}
          ],
          part <- ball(center, r, "leaf"),
          do: part

    {shapes, 0.72, {0.12, 0.45}}
  end

  # The trunk of a tree from the ground to a height. A crape myrtle has
  # three thin trunks.
  defp trunks("crape_myrtle", {x, y}, z, r),
    do:
      for(
        {dx, dy} <- [{-2.5, 0.0}, {2.5, 0.0}, {0.0, 2.5}],
        do: {:cyl, {x + dx * r, y + dy * r, 0}, r, z, "wood"}
      )

  defp trunks(_kind, {x, y}, z, r), do: [{:cyl, {x, y, 0}, r, z, "wood"}]
end
