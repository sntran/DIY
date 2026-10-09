defmodule DIYWeb.Icon.Shapes do
  @moduledoc """
  The shapes of the icon of each kind of item (`DIYWeb.Icon`), in the
  style of the pictures (`DIYWeb.Scene`). An icon is a few boxes, discs and
  details of a material, with a light top, a lit left face and a right
  face in the shade.

  Each material has three classes: `i-NAME-t` (the top), `i-NAME-l` and
  `i-NAME-r`. The faces of a material also have the class `i-face`: a thin
  edge, so that a white item shows on a light page.

  The unit is near a meter, and the front of an item looks to the left (y).
  A model (`model/1`) is a list of parts. A part at the back paints first
  (`parts/2`). Where no part is behind another, the order of the model
  stays. The parts:

  - `{:box, corner, size, material}`: a box.
  - `{:cyl, center, r, h, material}`: a cylinder that stands at a center.
  - `{:face, corners, normal, class}`: a flat part, with the direction
    that it looks to (`nil`: it always shows).

  A shape is `{:poly, corners, class}`. `shapes/1` gives the shapes of an
  icon, and `placed/2` the shapes of an item at the scale of the world
  (`DIYWeb.Cutaway`).
  """

  alias DIYWeb.Iso

  @doc """
  The shapes of the icon of a kind, in the order of the paint: the model
  of the kind (`model/1`), as it is.
  """
  def shapes(type), do: draw(model(type), nil)

  @doc """
  The shapes of an item at the scale of the world. The model of its kind
  has the size of the item (`{w, d, h}` in meters, before the turn). The
  model has a turn (0 to 3 quarter turns), and its back corner is at a
  point of the world (`at`). A face that looks away after the turn does
  not show.
  """
  def placed(type, frame), do: draw(model(type), frame)

  @doc """
  The shapes of a model at the scale of the world, with its own size (in
  meters). The model has a turn, and its back corner is at a point of the
  world (`at`).
  """
  def placed_model(model, %{at: at, turn: turn}) do
    {{x0, y0, z0}, {x1, y1, z1}} = bounds(model)
    draw(model, %{at: at, turn: turn, size: {x1 - x0, y1 - y0, z1 - z0}})
  end

  @doc """
  The box of a model: its two far corners, `{low, high}`.
  """
  def bounds(model) do
    points =
      Enum.flat_map(model, fn
        {:box, corner, size, _material} ->
          [corner, Iso.add(corner, size)]

        {:cyl, {x, y, z}, r, h, _material} ->
          [{x - r, y - r, z}, {x + r, y + r, z + h}]

        {:face, corners, _normal, _class} ->
          corners
      end)

    {xs, ys, zs} = unzip3(points)
    {{Enum.min(xs), Enum.min(ys), Enum.min(zs)}, {Enum.max(xs), Enum.max(ys), Enum.max(zs)}}
  end

  defp unzip3(points) do
    {Enum.map(points, &elem(&1, 0)), Enum.map(points, &elem(&1, 1)),
     Enum.map(points, &elem(&1, 2))}
  end

  # The polygons of a model. With no frame, a point stays as it is.
  defp draw(model, frame) do
    for object <- parts(model, frame),
        {corners, class} <- object.polys,
        do: {:poly, corners, class}
  end

  @doc """
  The parts of a model in the order of the paint (`DIYWeb.Iso.order/1`),
  each with its box in the world and its polygons. After a turn, a part at
  the back paints first. A part that does not show (a face that looks
  away) is not in the list. With no frame, a point stays as it is.
  """
  def parts(model, frame) do
    {point, normal} = transform(model, frame)

    model
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, i} ->
      case for({:poly, corners, class} <- draw_one(part, point, normal), do: {corners, class}) do
        [] -> []
        polys -> [object(i, polys)]
      end
    end)
    |> Iso.order()
  end

  # A part as an object of the order of the paint: its box in the world.
  # Its key is its place in the model: the order of the model stays where
  # no part is behind another.
  defp object(i, polys) do
    {xs, ys, zs} = unzip3(Enum.flat_map(polys, &elem(&1, 0)))
    {{x0, x1}, {y0, y1}, {z0, z1}} = {Enum.min_max(xs), Enum.min_max(ys), Enum.min_max(zs)}
    %{id: i, polys: polys, box: {x0, y0, z0, x1, y1, z1}, key: i, loose: false}
  end

  defp transform(_model, nil), do: {nil, nil}

  defp transform(model, %{at: at, size: {w, d, h}, turn: turn}) do
    {{x0, y0, z0}, {x1, y1, z1}} = bounds(model)
    {kx, ky, kz} = {ratio(w, x1 - x0), ratio(d, y1 - y0), ratio(h, z1 - z0)}

    point = fn {x, y, z} ->
      {rx, ry} = rotate({(x - x0) * kx, (y - y0) * ky}, turn, {w, d})
      Iso.add(at, {rx, ry, (z - z0) * kz})
    end

    # A normal goes with the inverse of the scale, and with the turn.
    normal = fn {x, y, z} ->
      {rx, ry} = rotate({x / kx, y / ky}, turn, {0, 0})
      {rx, ry, z / kz}
    end

    {point, normal}
  end

  # The scale of a side: a flat model (with no height) keeps its height.
  defp ratio(_size, extent) when extent == 0, do: 1.0
  defp ratio(size, extent), do: size / extent

  # A quarter turn takes the front (y) to the right (x): the space of the
  # item is then d by w.
  defp rotate({x, y}, 0, _size), do: {x, y}
  defp rotate({x, y}, 1, {w, _d}), do: {y, w - x}
  defp rotate({x, y}, 2, {w, d}), do: {w - x, d - y}
  defp rotate({x, y}, 3, {_w, d}), do: {d - y, x}

  defp at(nil, point), do: point
  defp at(fun, point), do: fun.(point)

  # A box shows its left, its right and its top in the world.
  defp draw_one({:box, corner, size, material}, point, _normal) do
    box =
      if point do
        {a, b} = {point.(corner), point.(Iso.add(corner, size))}

        low =
          {min(elem(a, 0), elem(b, 0)), min(elem(a, 1), elem(b, 1)), min(elem(a, 2), elem(b, 2))}

        high =
          {max(elem(a, 0), elem(b, 0)), max(elem(a, 1), elem(b, 1)), max(elem(a, 2), elem(b, 2))}

        Iso.box(low, Iso.add(high, Iso.scale(low, -1)))
      else
        Iso.box(corner, size)
      end

    [
      {:poly, box.left, "i-#{material}-l i-face"},
      {:poly, box.right, "i-#{material}-r i-face"},
      {:poly, box.top, "i-#{material}-t i-face"}
    ]
  end

  # A cylinder that stands at a center: the near half of its body (the lit
  # left part and the right part in the shade), and its top. A point of the
  # ring is on the near half when its dx + dy is 0 or more; the screen shows
  # dx - dy to the side.
  defp draw_one({:cyl, {x, y, z} = center, r, h, material}, point, _normal) do
    {cx, cy, _cz} = at(point, center)

    ring = fn zz ->
      Enum.map(Iso.circle({x, y, zz}, {1, 0, 0}, {0, 1, 0}, r, 16), &at(point, &1))
    end

    half = fn sign, face ->
      near = fn zz ->
        Enum.filter(ring.(zz), fn {px, py, _} ->
          px - cx + (py - cy) >= -1.0e-9 and sign * (px - cx - (py - cy)) >= -1.0e-9
        end)
      end

      lower = Enum.sort_by(near.(z), fn {px, py, _} -> px - py end)
      upper = Enum.sort_by(near.(z + h), fn {px, py, _} -> py - px end)
      {:poly, lower ++ upper, "i-#{material}-#{face} i-face"}
    end

    [half.(-1, "l"), half.(1, "r"), {:poly, ring.(z + h), "i-#{material}-t i-face"}]
  end

  # A face shows when it looks to the eye (x, y and z all go to the eye). A
  # face with no normal always shows. A "~" in its class is the light of
  # its side: t (the top), l (the left) or r (the right).
  defp draw_one({:face, corners, normal, class}, point, turn_normal) do
    n = normal && at(turn_normal, normal)

    if n == nil or elem(n, 0) + elem(n, 1) + elem(n, 2) > 1.0e-9,
      do: [{:poly, Enum.map(corners, &at(point, &1)), light(class, n)}],
      else: []
  end

  defp light(class, nil), do: class

  defp light(class, {x, y, z}) do
    side =
      cond do
        z >= max(x, y) -> "t"
        x >= y -> "r"
        true -> "l"
      end

    String.replace(class, "~", side)
  end

  # A box of a material.
  defp box(corner, size, material), do: [{:box, corner, size, material}]

  # A rectangle on the front face (y = y) of a box, from x, z.
  defp front({x, y, z}, {w, h}, class),
    do:
      {:face, Iso.on_plane({x, y + 0.01, z}, {1, 0, 0}, {0, 0, 1}, {0, 0}, {w, h}), {0, 1, 0},
       class}

  # A rectangle on the side face (x = x) of a box, from y, z.
  defp side({x, y, z}, {d, h}, class),
    do:
      {:face, Iso.on_plane({x + 0.01, y, z}, {0, 1, 0}, {0, 0, 1}, {0, 0}, {d, h}), {1, 0, 0},
       class}

  # A rectangle on the far side face (x = x) of a box: it shows after a
  # turn.
  defp far_side({x, y, z}, {d, h}, class),
    do:
      {:face, Iso.on_plane({x - 0.01, y, z}, {0, 1, 0}, {0, 0, 1}, {0, 0}, {d, h}), {-1, 0, 0},
       class}

  # A rectangle on a top (z = z), from x, y.
  defp top({x, y, z}, {w, d}, class),
    do:
      {:face, Iso.on_plane({x, y, z + 0.01}, {1, 0, 0}, {0, 1, 0}, {0, 0}, {w, d}), {0, 0, 1},
       class}

  # A disc on the top, on the front, or on a side.
  defp disc(center, :top, r, class),
    do: {:face, Iso.circle(center, {1, 0, 0}, {0, 1, 0}, r), {0, 0, 1}, class}

  defp disc(center, :front, r, class),
    do: {:face, Iso.circle(center, {1, 0, 0}, {0, 0, 1}, r), {0, 1, 0}, class}

  defp disc(center, :side, r, class),
    do: {:face, Iso.circle(center, {0, 1, 0}, {0, 0, 1}, r), {1, 0, 0}, class}

  defp disc(center, :far_side, r, class),
    do: {:face, Iso.circle(center, {0, 1, 0}, {0, 0, 1}, r), {-1, 0, 0}, class}

  # A cylinder that stands at a center.
  defp cylinder(center, r, h, material), do: [{:cyl, center, r, h, material}]

  # The wheels of a car or a van: on the side at x (x = 0 is the far side).
  defp wheels(x, ys, r) do
    {dx, face} = if x == 0, do: {-0.02, :far_side}, else: {0.02, :side}

    for y <- ys,
        {radius, class} <- [{r, "i-black"}, {r * 0.5, "i-steel-r"}],
        do: disc({x + dx, y, r}, face, radius, class)
  end

  # A polygon with its normal (nil: it always shows).
  defp face(corners, normal, class), do: {:face, corners, normal, class}

  @doc """
  The model of a kind: boxes, cylinders and faces, in the order of the
  paint. The unit is near a meter, and the front looks to y.
  """
  def model("fridge") do
    box({0, 0, 0}, {0.8, 0.7, 1.8}, "white") ++
      [
        front({0, 0.7, 1.2}, {0.8, 0.02}, "i-line"),
        front({0.62, 0.7, 1.3}, {0.05, 0.35}, "i-steel-r"),
        front({0.62, 0.7, 0.75}, {0.05, 0.35}, "i-steel-r")
      ]
  end

  def model("freezer") do
    box({0, 0, 0}, {1.2, 0.7, 0.85}, "white") ++
      [
        front({0, 0.7, 0.72}, {1.2, 0.02}, "i-line"),
        front({0.45, 0.7, 0.6}, {0.3, 0.05}, "i-steel-r")
      ]
  end

  def model("range") do
    box({0, 0, 0}, {0.8, 0.7, 0.9}, "steel") ++
      box({0, 0, 0.9}, {0.8, 0.12, 0.25}, "steel") ++
      [top({0.04, 0.16, 0.9}, {0.72, 0.5}, "i-black")] ++
      for(
        {x, y} <- [{0.22, 0.3}, {0.58, 0.3}, {0.22, 0.54}, {0.58, 0.54}],
        do: disc({x, y, 0.92}, :top, 0.11, "i-burner")
      ) ++
      [
        front({0.12, 0.7, 0.15}, {0.56, 0.45}, "i-glass-dark"),
        front({0.12, 0.7, 0.68}, {0.56, 0.05}, "i-steel-r")
      ]
  end

  def model("microwave") do
    box({0, 0, 0}, {0.8, 0.5, 0.45}, "steel") ++
      [
        front({0.06, 0.5, 0.07}, {0.5, 0.31}, "i-glass-dark"),
        front({0.62, 0.5, 0.1}, {0.12, 0.25}, "i-black")
      ]
  end

  def model("dishwasher") do
    box({0, 0, 0}, {0.7, 0.7, 0.85}, "steel") ++
      [
        front({0, 0.7, 0.72}, {0.7, 0.13}, "i-black"),
        front({0.2, 0.7, 0.62}, {0.3, 0.04}, "i-steel-t")
      ]
  end

  def model("washer"), do: laundry("i-glass")
  def model("dryer"), do: laundry("i-glass-dark")

  def model("water_heater") do
    cylinder({0.35, 0.35, 0}, 0.35, 1.4, "white") ++
      box({0.2, 0.3, 1.4}, {0.07, 0.07, 0.25}, "copper") ++
      box({0.45, 0.3, 1.4}, {0.07, 0.07, 0.25}, "copper")
  end

  def model("ac") do
    box({0, 0, 0}, {1.0, 1.0, 0.8}, "steel") ++
      [
        disc({0.5, 0.5, 0.81}, :top, 0.36, "i-black"),
        disc({0.5, 0.5, 0.82}, :top, 0.08, "i-steel-t")
      ] ++
      for(k <- 1..4, do: side({1.0, 0.1, k * 0.15}, {0.8, 0.03}, "i-line")) ++
      for(k <- 1..4, do: far_side({0.0, 0.1, k * 0.15}, {0.8, 0.03}, "i-line"))
  end

  def model("mini_split") do
    box({0, 0, 0}, {1.1, 0.3, 0.38}, "white") ++
      [
        front({0.08, 0.3, 0.05}, {0.94, 0.08}, "i-glass-dark"),
        front({0.9, 0.3, 0.24}, {0.06, 0.04}, "i-led")
      ]
  end

  def model("furnace") do
    box({0, 0, 0}, {0.6, 0.7, 1.3}, "steel") ++
      for(k <- 1..5, do: front({0.1, 0.7, 0.75 + k * 0.08}, {0.4, 0.03}, "i-line")) ++
      [front({0.2, 0.7, 0.2}, {0.2, 0.15}, "i-flame")]
  end

  # The strips of an air handler: a duct with a coil that glows in it.
  def model("heat_strips") do
    box({0, 0, 0}, {1.0, 0.5, 0.5}, "steel") ++
      [front({0.1, 0.5, 0.08}, {0.8, 0.34}, "i-black")] ++
      for(k <- 0..5, do: front({0.16 + k * 0.13, 0.5, 0.12}, {0.04, 0.26}, "i-hot"))
  end

  def model("smart_meter") do
    box({0, 0, 0}, {0.4, 0.25, 0.55}, "gray") ++
      [
        disc({0.2, 0.26, 0.3}, :front, 0.15, "i-glass"),
        front({0.12, 0.25, 0.25}, {0.16, 0.06}, "i-black")
      ]
  end

  # A lamp: a base, a stem, and a shade that glows.
  def model("lights") do
    cylinder({0.25, 0.25, 0}, 0.2, 0.05, "steel") ++
      box({0.23, 0.23, 0.05}, {0.04, 0.04, 0.5}, "steel") ++
      cylinder({0.25, 0.25, 0.45}, 0.24, 0.28, "shade")
  end

  def model("tv") do
    box({0.5, 0.2, 0}, {0.3, 0.2, 0.05}, "dark") ++
      box({0.62, 0.27, 0.05}, {0.06, 0.06, 0.15}, "dark") ++
      box({0, 0.28, 0.2}, {1.3, 0.05, 0.75}, "dark") ++
      [front({0.04, 0.33, 0.24}, {1.22, 0.67}, "i-screen")]
  end

  def model("computer") do
    box({0.3, 0.1, 0}, {0.2, 0.15, 0.05}, "dark") ++
      box({0.37, 0.15, 0.05}, {0.06, 0.04, 0.15}, "dark") ++
      box({0, 0.2, 0.2}, {0.8, 0.04, 0.5}, "dark") ++
      [front({0.03, 0.24, 0.23}, {0.74, 0.44}, "i-screen")] ++
      box({0.1, 0.45, 0}, {0.6, 0.22, 0.03}, "gray")
  end

  def model("ceiling_fan") do
    blade = fn corners -> face(corners, {0, 0, 1}, "i-wood-t i-face") end

    box({0.47, 0.47, 0.3}, {0.06, 0.06, 0.4}, "steel") ++
      [
        blade.([{0.5, 0.42, 0.3}, {1.1, 0.42, 0.3}, {1.1, 0.58, 0.3}, {0.5, 0.58, 0.3}]),
        blade.([{0.42, 0.5, 0.3}, {0.42, 1.1, 0.3}, {0.58, 1.1, 0.3}, {0.58, 0.5, 0.3}]),
        blade.([{0.5, 0.42, 0.3}, {-0.1, 0.42, 0.3}, {-0.1, 0.58, 0.3}, {0.5, 0.58, 0.3}]),
        blade.([{0.42, 0.5, 0.3}, {0.42, -0.1, 0.3}, {0.58, -0.1, 0.3}, {0.58, 0.5, 0.3}]),
        disc({0.5, 0.5, 0.31}, :top, 0.13, "i-steel-t")
      ]
  end

  def model("always_on") do
    box({0, 0, 0}, {1.0, 0.3, 0.12}, "white") ++
      for(x <- [0.15, 0.4, 0.65], do: top({x, 0.08, 0.12}, {0.14, 0.14}, "i-black")) ++
      [top({0.88, 0.12, 0.12}, {0.06, 0.06}, "i-led")]
  end

  def model("pool_pump") do
    cylinder({0.25, 0.3, 0}, 0.25, 0.45, "blue") ++ box({0.55, 0.1, 0}, {0.5, 0.4, 0.35}, "gray")
  end

  # A space heater: a small tower with a handle and a grille that glows.
  def model("space_heater") do
    box({0, 0, 0}, {0.45, 0.3, 0.8}, "white") ++
      box({0.12, 0.1, 0.8}, {0.21, 0.1, 0.06}, "gray") ++
      [front({0.07, 0.3, 0.12}, {0.31, 0.5}, "i-black")] ++
      for(k <- 1..4, do: front({0.1, 0.3, 0.06 + k * 0.11}, {0.25, 0.04}, "i-hot"))
  end

  def model("power_station") do
    box({0, 0, 0}, {0.8, 0.5, 0.62}, "dark") ++
      [
        front({0.12, 0.5, 0.34}, {0.56, 0.12}, "i-led"),
        front({0.1, 0.5, 0.1}, {0.6, 0.06}, "i-steel-r")
      ] ++
      box({0.15, 0.2, 0.62}, {0.5, 0.1, 0.06}, "gray")
  end

  def model("solar_panels") do
    box({0.45, 0.1, 0}, {0.08, 0.08, 1.0}, "gray") ++
      [
        face([{0, 0.8, 0.45}, {1.0, 0.8, 0.45}, {1.0, -0.4, 1.3}, {0, -0.4, 1.3}], nil, "i-pv"),
        face(
          [{0.5, 0.8, 0.45}, {0.53, 0.8, 0.45}, {0.53, -0.4, 1.3}, {0.5, -0.4, 1.3}],
          nil,
          "i-pv-line"
        )
      ]
  end

  def model("transfer_switch") do
    box({0, 0, 0}, {0.6, 0.2, 0.8}, "gray") ++
      [
        front({0.06, 0.2, 0.06}, {0.48, 0.68}, "i-steel-t"),
        front({0.4, 0.2, 0.35}, {0.06, 0.15}, "i-black")
      ] ++
      box({0.25, 0.2, 0.6}, {0.1, 0.12, 0.05}, "red")
  end

  def model("ev") do
    {l, w} = {2.4, 1.0}
    cabin = fn corners, normal, class -> face(corners, normal, class) end

    box({0, 0, 0.15}, {w, l, 0.4}, "red") ++
      [
        cabin.(
          [{0, 0.6, 0.55}, {0, 1.9, 0.55}, {0.15, 1.65, 0.85}, {0.15, 0.85, 0.85}],
          {-1, 0, 0.5},
          "i-glass-dark"
        ),
        cabin.(
          [{0.08, 0.6, 0.55}, {w - 0.08, 0.6, 0.55}, {w - 0.15, 0.85, 0.85}, {0.15, 0.85, 0.85}],
          nil,
          "i-red-t"
        ),
        cabin.(
          [{w, 0.6, 0.55}, {w, 1.9, 0.55}, {w - 0.15, 1.65, 0.85}, {w - 0.15, 0.85, 0.85}],
          {1, 0, 0.5},
          "i-glass-dark"
        ),
        cabin.(
          [{0.08, 1.9, 0.55}, {w, 1.9, 0.55}, {w - 0.15, 1.65, 0.85}, {0.15, 1.65, 0.85}],
          {0, 1, 0.8},
          "i-glass-dark"
        ),
        cabin.(
          [
            {0.15, 0.85, 0.85},
            {w - 0.15, 0.85, 0.85},
            {w - 0.15, 1.65, 0.85},
            {0.15, 1.65, 0.85}
          ],
          {0, 0, 1},
          "i-red-t"
        ),
        front({0.1, l, 0.35}, {0.18, 0.08}, "i-bulb"),
        front({w - 0.28, l, 0.35}, {0.18, 0.08}, "i-bulb")
      ] ++ wheels(w, [0.45, l - 0.5], 0.2) ++ wheels(0, [0.45, l - 0.5], 0.2)
  end

  def model("camper_van") do
    {l, w, h} = {2.6, 1.0, 1.25}
    profile = [{0, 0.2}, {l, 0.2}, {l, 0.65}, {2.3, 0.72}, {2.1, 1.12}, {2.0, h}, {0, h}]
    across = fn {y1, z1}, {y2, z2} -> [{0, y1, z1}, {w, y1, z1}, {w, y2, z2}, {0, y2, z2}] end

    # The two sides have the profile, and the back has its doors: they
    # show after a turn. A slope of the cab looks to the front and up. The
    # hood is low: when the front looks away, the body is in front of it,
    # so it shows only with the front.
    [
      face(Enum.map(profile, fn {y, z} -> {0, y, z} end), {-1, 0, 0}, "i-white-~ i-face"),
      far_side({0, 0.75, 0.6}, {0.6, 0.35}, "i-glass-dark"),
      face(across.({0, 0.2}, {0, h}), {0, -1, 0}, "i-white-~ i-face"),
      face(Enum.map(profile, fn {y, z} -> {w, y, z} end), {1, 0, 0}, "i-white-~ i-face"),
      face(across.({0, h}, {2.0, h}), {0, 0, 1}, "i-white-t i-face"),
      face(across.({2.0, h}, {2.1, 1.12}), {0, 0.79, 0.61}, "i-white-t i-face"),
      face(across.({2.3, 0.72}, {2.1, 1.12}), {0, 0.89, 0.45}, "i-glass-dark"),
      face(across.({l, 0.65}, {2.3, 0.72}), {0, 1, 0.5}, "i-white-t i-face"),
      front({0, l, 0.2}, {w, 0.45}, "i-white-~ i-face"),
      side({w, 0.75, 0.6}, {0.6, 0.35}, "i-glass-dark"),
      side({w, 1.45, 0.2}, {0.55, 0.85}, "i-steel-l")
    ] ++ wheels(w, [0.5, 2.25], 0.2) ++ wheels(0, [0.5, 2.25], 0.2)
  end

  def model("swivel_seat") do
    cylinder({0.35, 0.35, 0}, 0.3, 0.12, "dark") ++
      box({0.05, 0.05, 0.12}, {0.6, 0.6, 0.18}, "cloth") ++
      box({0.05, 0.05, 0.3}, {0.6, 0.14, 0.6}, "cloth")
  end

  def model("dc_charger") do
    box({0, 0, 0}, {0.6, 0.4, 0.18}, "steel") ++
      for(k <- 1..3, do: top({0.08, k * 0.1, 0.18}, {0.44, 0.03}, "i-line")) ++
      box({0.62, 0.1, 0.05}, {0.15, 0.06, 0.06}, "red") ++
      box({0.62, 0.25, 0.05}, {0.15, 0.06, 0.06}, "dark")
  end

  def model("van_fridge") do
    box({0, 0, 0}, {0.75, 0.45, 0.5}, "white") ++
      box({0, 0, 0.5}, {0.75, 0.45, 0.06}, "dark") ++
      [front({0.3, 0.45, 0.35}, {0.15, 0.06}, "i-led")]
  end

  def model("stove") do
    box({0, 0, 0}, {0.6, 0.45, 0.1}, "steel") ++
      [
        disc({0.17, 0.22, 0.11}, :top, 0.11, "i-burner"),
        disc({0.43, 0.22, 0.11}, :top, 0.11, "i-burner")
      ]
  end

  def model("sink") do
    box({0, 0, 0}, {0.8, 0.55, 0.6}, "wood") ++
      [top({0.15, 0.12, 0.6}, {0.5, 0.33}, "i-steel-r")] ++
      box({0.37, 0.02, 0.6}, {0.06, 0.06, 0.25}, "steel")
  end

  def model("water_tank") do
    box({0, 0, 0}, {0.8, 0.5, 0.45}, "blue") ++
      [
        disc({0.4, 0.25, 0.46}, :top, 0.08, "i-white-t"),
        front({0.05, 0.5, 0.05}, {0.7, 0.04}, "i-line"),
        side({0.8, 0.05, 0.05}, {0.4, 0.04}, "i-line")
      ]
  end

  def model("water_pump") do
    cylinder({0.2, 0.2, 0}, 0.18, 0.3, "steel") ++
      box({0.38, 0.12, 0.05}, {0.3, 0.16, 0.16}, "dark") ++
      box({0.68, 0.16, 0.08}, {0.2, 0.08, 0.08}, "blue")
  end

  def model("counter") do
    box({0, 0, 0}, {1.2, 0.55, 0.85}, "wood") ++
      box({-0.02, -0.02, 0.85}, {1.24, 0.59, 0.05}, "light-wood") ++
      [front({0.6, 0.55, 0.05}, {0.02, 0.75}, "i-line")]
  end

  def model("bench") do
    box({0, 0, 0}, {1.0, 0.5, 0.4}, "wood") ++
      box({0, 0, 0.4}, {1.0, 0.5, 0.1}, "cloth") ++
      box({0, 0, 0.5}, {1.0, 0.12, 0.4}, "cloth")
  end

  def model("van_table") do
    box({0.32, 0.22, 0}, {0.06, 0.06, 0.65}, "steel") ++
      box({0, 0, 0.65}, {0.7, 0.5, 0.05}, "light-wood")
  end

  def model("van_fan") do
    box({0, 0, 0}, {0.6, 0.6, 0.08}, "white") ++
      [
        face(
          [{0.06, 0.54, 0.08}, {0.54, 0.54, 0.08}, {0.54, 0.06, 0.3}, {0.06, 0.06, 0.3}],
          nil,
          "i-glass"
        )
      ]
  end

  def model("window") do
    box({0, 0, 0}, {0.9, 0.06, 0.6}, "dark") ++ [front({0.05, 0.06, 0.05}, {0.8, 0.5}, "i-glass")]
  end

  def model("van_lights") do
    box({0, 0, 0}, {1.0, 0.2, 0.03}, "white") ++
      for(x <- [0.15, 0.5, 0.85], do: disc({x, 0.1, 0.04}, :top, 0.07, "i-bulb"))
  end

  def model("devices") do
    box({0, 0, 0}, {0.7, 0.45, 0.03}, "gray") ++
      [
        face(
          [{0, 0, 0.03}, {0.7, 0, 0.03}, {0.7, -0.12, 0.45}, {0, -0.12, 0.45}],
          nil,
          "i-dark-l"
        ),
        face(
          [{0.04, 0.005, 0.07}, {0.66, 0.005, 0.07}, {0.66, -0.1, 0.41}, {0.04, -0.1, 0.41}],
          {0, 1, 0.3},
          "i-screen"
        )
      ] ++
      box({0.8, 0.2, 0}, {0.16, 0.3, 0.02}, "dark")
  end

  def model("diesel_heater") do
    box({0, 0, 0}, {0.6, 0.35, 0.3}, "red") ++
      box({0, 0, 0.3}, {0.6, 0.35, 0.04}, "dark") ++
      box({0.62, 0.12, 0.1}, {0.25, 0.1, 0.1}, "steel")
  end

  def model("co_alarm") do
    cylinder({0.3, 0.3, 0}, 0.3, 0.08, "white") ++ [disc({0.3, 0.3, 0.09}, :top, 0.05, "i-hot")]
  end

  def model("bed_platform") do
    box({0, 0, 0}, {1.4, 1.9, 0.5}, "wood") ++
      box({0.03, 0.03, 0.5}, {1.34, 1.84, 0.18}, "cloth") ++
      box({0.15, 0.1, 0.68}, {1.1, 0.35, 0.1}, "white")
  end

  def model("storage") do
    box({0, 0, 0}, {0.9, 0.6, 0.6}, "wood") ++
      [
        front({0.05, 0.6, 0.3}, {0.8, 0.02}, "i-line"),
        front({0.35, 0.6, 0.4}, {0.2, 0.04}, "i-steel-r"),
        front({0.35, 0.6, 0.12}, {0.2, 0.04}, "i-steel-r")
      ]
  end

  def model("van_battery") do
    box({0, 0, 0}, {0.6, 0.35, 0.4}, "blue") ++
      box({0.08, 0.1, 0.4}, {0.1, 0.1, 0.06}, "red") ++
      box({0.42, 0.1, 0.4}, {0.1, 0.1, 0.06}, "dark") ++
      [front({0.1, 0.35, 0.15}, {0.4, 0.08}, "i-white-t")]
  end

  def model("inverter") do
    box({0, 0, 0}, {0.8, 0.4, 0.25}, "steel") ++
      for(k <- 1..4, do: top({0.08, k * 0.07, 0.25}, {0.64, 0.025}, "i-line")) ++
      [front({0.3, 0.4, 0.06}, {0.2, 0.12}, "i-black")]
  end

  # A shore power inlet: a box with a round socket and its yellow lid, and
  # a cable that bends to the side.
  def model("shore_power") do
    box({0, 0, 0}, {0.4, 0.15, 0.4}, "gray") ++
      [
        disc({0.2, 0.16, 0.2}, :front, 0.13, "i-black"),
        disc({0.2, 0.17, 0.2}, :front, 0.05, "i-flame")
      ] ++
      box({0.17, 0.15, -0.12}, {0.06, 0.25, 0.06}, "dark") ++
      box({0.17, 0.4, -0.12}, {0.45, 0.06, 0.06}, "dark")
  end

  def model("van_solar") do
    box({0, 0, 0}, {0.8, 1.2, 0.04}, "gray") ++ [top({0.03, 0.03, 0.04}, {0.74, 1.14}, "i-pv")]
  end

  def model("insulation") do
    box({0, 0, 0}, {1.0, 0.6, 0.15}, "pink") ++ box({0, 0, 0.15}, {1.0, 0.6, 0.15}, "pink")
  end

  def model("walls") do
    box({0, 0, 0}, {1.0, 0.05, 0.9}, "light-wood") ++
      for(k <- 1..3, do: front({0, 0.05, k * 0.22}, {1.0, 0.015}, "i-line"))
  end

  def model("van_floor") do
    box({0, 0, 0}, {1.0, 1.0, 0.05}, "light-wood") ++
      for(k <- 1..3, do: top({0, k * 0.25, 0.05}, {1.0, 0.015}, "i-line"))
  end

  # The kind "other": a box.
  def model("other") do
    box({0, 0, 0}, {0.6, 0.6, 0.6}, "gray") ++ [front({0.2, 0.6, 0.2}, {0.2, 0.2}, "i-steel-t")]
  end

  # A washer or a dryer: a box with a round door.
  defp laundry(glass) do
    box({0, 0, 0}, {0.7, 0.7, 0.9}, "white") ++
      [
        front({0, 0.7, 0.75}, {0.7, 0.02}, "i-line"),
        disc({0.35, 0.71, 0.38}, :front, 0.24, "i-steel-l"),
        disc({0.35, 0.72, 0.38}, :front, 0.18, glass)
      ]
  end
end
