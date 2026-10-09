defmodule DIYWeb.Icon.Shapes do
  @moduledoc """
  The shapes of the icon of each kind of item (`DIYWeb.Icon`), in the
  style of the pictures (`DIYWeb.Scene`). An icon is a few boxes, discs and
  details of a material. It has a light top, a face in the light and a
  face in the shade (`DIYWeb.Camera`).

  Each material has three classes: `i-NAME-t` (the top), `i-NAME-l` (in
  the light) and `i-NAME-r` (in the shade). The faces of a material also
  have the class `i-face`: a thin edge, so that a white item shows on a
  light page.

  The unit is near a meter, and the front of an item looks to y.
  A model (`model/1`) is a list of parts. A part at the back paints first
  (`parts/3`). Where no part is behind another, the order of the model
  stays. The parts:

  - `{:box, corner, size, material}`: a box.
  - `{:cyl, center, r, h, material}`: a cylinder that stands at a center.
  - `{:prism, loop, z, h, material}`: a prism that stands on a loop of
    points (`{x, y}`, counterclockwise from above), from z to z + h. A
    box with round corners (`rounded/3`) is a prism.
  - `{:prism, axis, loop, from, length, material}`: a prism along an axis
    (`:x`, `:y` or `:z`). Its loop is in the plane of the two other axes,
    counterclockwise when the eye is at the large end of the axis. For
    `:x`, a point of the loop is `{y, z}`. For `:y`, it is `{z, x}`. For
    `:z`, it is `{x, y}`. A tube (`tube/5`) is a prism along x or y.
  - `{:face, corners, normal, class}`: a flat part, with the direction
    that it looks to (`nil`: it always shows).

  A shape is `{:poly, corners, class}`. `shapes/2` gives the shapes of an
  icon, and `placed/2` the shapes of an item at the scale of the world
  (`DIYWeb.Cutaway`). A camera shows the faces that look to it.
  """

  alias DIYWeb.{Camera, Geometry}
  alias DIYWeb.Icon.VanShapes

  @doc """
  The shapes of the icon of a kind for a camera (the camera of the house
  by default), in the order of the paint. They are the model of the kind
  (`model/1`), as it is.
  """
  def shapes(type, camera \\ Camera.house()), do: draw(model(type), nil, camera)

  @doc """
  The shapes of an item at the scale of the world. The model of its kind
  has the size of the item (`{w, d, h}` in meters, before the turn). The
  model has a turn (0 to 3 quarter turns), and its back corner is at a
  point of the world (`at`). A face that looks away from the `camera`
  after the turn does not show.
  """
  def placed(type, frame), do: draw(model(type), frame, frame.camera)

  @doc """
  The shapes of a model at the scale of the world, with its own size (in
  meters). The model has a turn, and its back corner is at a point of the
  world (`at`). The `camera` shows the faces that look to it.
  """
  def placed_model(model, %{at: at, turn: turn, camera: camera} = frame) do
    {{x0, y0, z0}, {x1, y1, z1}} = bounds(model)
    size = Map.get(frame, :size, {x1 - x0, y1 - y0, z1 - z0})
    draw(model, %{at: at, turn: turn, size: size}, camera)
  end

  @doc "The height of the hood of a model of a van over the ground, in meters."
  defdelegate hood_height(model), to: VanShapes

  @doc "The model of a camper van of a model, at its real size (`DIYWeb.Icon.VanShapes`)."
  defdelegate van(model), to: VanShapes

  @doc """
  The box of a model: its two far corners, `{low, high}`.
  """
  def bounds(model) do
    points =
      model
      |> Enum.flat_map(fn
        {:group, parts} -> parts
        part -> [part]
      end)
      |> Enum.flat_map(fn
        {:box, corner, size, _material} ->
          [corner, Geometry.add(corner, size)]

        {:cyl, {x, y, z}, r, h, _material} ->
          [{x - r, y - r, z}, {x + r, y + r, z + h}]

        {:prism, loop, z, h, _material} ->
          Enum.flat_map(loop, fn {x, y} -> [{x, y, z}, {x, y, z + h}] end)

        {:prism, axis, loop, from, length, _material} ->
          Enum.flat_map(loop, &[lift(axis, &1, from), lift(axis, &1, from + length)])

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
  defp draw(model, frame, camera) do
    for object <- parts(model, frame, camera),
        {corners, class} <- object.polys,
        do: {:poly, corners, class}
  end

  @doc """
  The parts of a model for a camera, in the order of the paint
  (`DIYWeb.Camera.order/2`), each with its box in the world and its
  polygons. After a turn, a part at the back paints first. A part that does
  not show (a face that looks away) is not in the list. With no frame, a
  point stays as it is.
  """
  def parts(model, frame, camera) do
    {point, normal} = transform(model, frame)
    view = %{point: point, normal: normal, camera: camera}

    model
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, i} ->
      case for({:poly, corners, class} <- draw_part(part, view), do: {corners, class}) do
        [] -> []
        polys -> [object(i, polys)]
      end
    end)
    |> Camera.order(camera)
  end

  # A group of parts (`{:group, parts}`) paints as one part.
  defp draw_part({:group, parts}, view), do: Enum.flat_map(parts, &draw_one(&1, view))
  defp draw_part(part, view), do: draw_one(part, view)

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
      Geometry.add(at, {rx, ry, (z - z0) * kz})
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

  # A box shows its top and the two faces that look to the camera
  # (`DIYWeb.Camera.faces/3`).
  defp draw_one({:box, corner, size, material}, %{point: point, camera: camera}) do
    box =
      if point do
        {a, b} = {point.(corner), point.(Geometry.add(corner, size))}

        low =
          {min(elem(a, 0), elem(b, 0)), min(elem(a, 1), elem(b, 1)), min(elem(a, 2), elem(b, 2))}

        high =
          {max(elem(a, 0), elem(b, 0)), max(elem(a, 1), elem(b, 1)), max(elem(a, 2), elem(b, 2))}

        Geometry.box(low, Geometry.add(high, Geometry.scale(low, -1)))
      else
        Geometry.box(corner, size)
      end

    for {corners, class} <- Camera.faces(camera, box, "i-#{material}"),
        do: {:poly, corners, class <> " i-face"}
  end

  # A cylinder that stands at a center: a prism of 24 sides.
  defp draw_one({:cyl, {x, y, z}, r, h, material}, view) do
    loop =
      for {px, py, _pz} <- Geometry.circle({x, y, 0}, {1, 0, 0}, {0, 1, 0}, r, 24), do: {px, py}

    draw_one({:prism, loop, z, h, material}, view)
  end

  # A prism that stands: a prism along z.
  defp draw_one({:prism, loop, z, h, material}, view),
    do: draw_one({:prism, :z, loop, z, h, material}, view)

  # A prism along an axis, from `from` to `from + length`. Each side of the
  # loop is a face, with the light of its normal (`DIYWeb.Camera.light/2`):
  # so a round shape has a soft light. On a convex loop, the faces have no
  # edge. Under them is the shape of all the faces that show, and over them
  # its edge (`i-outline`). A loop that is not convex can hide a part of
  # itself: for example, the profile of a car. Its faces paint from the far
  # one to the near one, each with its edge. Then the end that looks to the
  # camera paints.
  defp draw_one(
         {:prism, axis, loop, from, length, material},
         %{point: point, normal: turn, camera: camera}
       ) do
    corners = List.to_tuple(loop)
    n = tuple_size(corners)
    point_at = fn i, t -> at(point, lift(axis, elem(corners, rem(i, n)), t)) end
    low = &point_at.(&1, from)
    high = &point_at.(&1, from + length)

    faces =
      for i <- 0..(n - 1) do
        {{u1, v1}, {u2, v2}} = {elem(corners, i), elem(corners, rem(i + 1, n))}
        normal = at(turn, lift(axis, {v2 - v1, u1 - u2}, 0))
        {i, Camera.shows?(camera, normal), normal}
      end

    body =
      for {i, true, normal} <- faces,
          do:
            {:poly, [low.(i), low.(i + 1), high.(i + 1), high.(i)],
             "i-#{material}-#{Camera.light(camera, normal)}"}

    ends =
      for {corner, sign} <- [{low, -1}, {high, 1}],
          normal = at(turn, lift(axis, {0, 0}, sign)),
          Camera.shows?(camera, normal),
          do:
            {:poly, Enum.map(0..(n - 1), corner),
             "i-#{material}-#{Camera.light(camera, normal)} i-face"}

    if convex?(loop) do
      run = shown_run(faces, n)
      outline = Enum.map(run, low) ++ Enum.map(Enum.reverse(run), high)
      [{:poly, outline, "i-#{material}-m2"}] ++ body ++ [{:poly, outline, "i-outline"}] ++ ends
    else
      middle = fn corners -> Geometry.scale(Enum.reduce(corners, &Geometry.add/2), 1 / 4) end

      sorted =
        for {:poly, corners, class} <-
              Enum.sort_by(body, &Camera.depth(camera, middle.(elem(&1, 1)))),
            do: {:poly, corners, class <> " i-face"}

      sorted ++ ends
    end
  end

  # A face shows when it looks to the eye of the camera. A face with no
  # normal always shows. A "~" in its class is its light
  # (`DIYWeb.Camera.light/2`): t (the top), l (in the light) or r (in the
  # shade).
  defp draw_one({:face, corners, normal, class}, %{point: point, normal: turn, camera: camera}) do
    n = normal && at(turn, normal)

    if n == nil or Camera.shows?(camera, n),
      do: [{:poly, Enum.map(corners, &at(point, &1)), light(class, n, camera)}],
      else: []
  end

  # A loop (counterclockwise) is convex when each turn from a side to the
  # next one goes to the left.
  defp convex?(loop) do
    corners = Enum.zip([loop, tl(loop) ++ [hd(loop)], tl(tl(loop)) ++ Enum.take(loop, 2)])

    Enum.all?(corners, fn {{u1, v1}, {u2, v2}, {u3, v3}} ->
      (u2 - u1) * (v3 - v2) - (v2 - v1) * (u3 - u2) >= -1.0e-12
    end)
  end

  # The corners of the faces of a prism that show, in the order of the
  # loop. The run starts at the first face that shows after a face that
  # does not show, and it goes on while the faces show. The camera looks
  # down at a slant, so a prism always has the two kinds of faces.
  defp shown_run(faces, n) do
    shown = MapSet.new(for {i, true, _normal} <- faces, do: i)
    first = Enum.find(0..(n - 1), &(&1 in shown and rem(&1 + n - 1, n) not in shown))
    run = Enum.take_while(first..(first + n - 1), &(rem(&1, n) in shown))
    run ++ [List.last(run) + 1]
  end

  # A point of the loop of a prism along an axis, at t along the axis.
  defp lift(:x, {u, v}, t), do: {t, u, v}
  defp lift(:y, {u, v}, t), do: {v, t, u}
  defp lift(:z, {u, v}, t), do: {u, v, t}

  defp light(class, nil, _camera), do: class
  defp light(class, n, camera), do: String.replace(class, "~", Camera.light(camera, n))

  # A box of a material.
  defp box(corner, size, material), do: [{:box, corner, size, material}]

  # A rectangle on the front face (y = y) of a box, from x, z.
  defp front({x, y, z}, {w, h}, class),
    do:
      {:face, Geometry.on_plane({x, y + 0.01, z}, {1, 0, 0}, {0, 0, 1}, {0, 0}, {w, h}),
       {0, 1, 0}, class}

  # A rectangle on the side face (x = x) of a box, from y, z.
  defp side({x, y, z}, {d, h}, class),
    do:
      {:face, Geometry.on_plane({x + 0.01, y, z}, {0, 1, 0}, {0, 0, 1}, {0, 0}, {d, h}),
       {1, 0, 0}, class}

  # A rectangle on a top (z = z), from x, y.
  defp top({x, y, z}, {w, d}, class),
    do:
      {:face, Geometry.on_plane({x, y, z + 0.01}, {1, 0, 0}, {0, 1, 0}, {0, 0}, {w, d}),
       {0, 0, 1}, class}

  # A disc on the top or on the front.
  defp disc(center, :top, r, class),
    do: {:face, Geometry.circle(center, {1, 0, 0}, {0, 1, 0}, r), {0, 0, 1}, class}

  defp disc(center, :front, r, class),
    do: {:face, Geometry.circle(center, {1, 0, 0}, {0, 0, 1}, r), {0, 1, 0}, class}

  # A cylinder that stands at a center.
  defp cylinder(center, r, h, material), do: [{:cyl, center, r, h, material}]

  # A tube of 24 sides along x or y, from the center of its end near 0.
  defp tube({x, y, z}, r, length, axis, material) do
    {from, center} = if axis == :x, do: {x, {y, z}}, else: {y, {z, x}}
    {cu, cv} = center

    loop =
      for k <- 0..23,
          a = 2 * :math.pi() * k / 24,
          do: {cu + r * :math.cos(a), cv + r * :math.sin(a)}

    [{:prism, axis, loop, from, length, material}]
  end

  @doc """
  A loop of points round a rectangle with round corners (a radius r),
  counterclockwise, from a corner and a size. The radius is at most half
  of the shorter side. Each corner has 5 points. Where two corners meet (a
  side with no length), they share one point.
  """
  def rounded({u, v}, {du, dv}, r) do
    r = min(r, min(du, dv) / 2)

    centers = [
      {u + du - r, v + r, -90},
      {u + du - r, v + dv - r, 0},
      {u + r, v + dv - r, 90},
      {u + r, v + r, 180}
    ]

    loop =
      for {cu, cv, from} <- centers,
          k <- 0..4,
          a = (from + k * 22.5) * :math.pi() / 180,
          do: {cu + r * :math.cos(a), cv + r * :math.sin(a)}

    key = fn {pu, pv} -> {Float.round(pu / 1, 9), Float.round(pv / 1, 9)} end
    loop = Enum.dedup_by(loop, key)
    if key.(hd(loop)) == key.(List.last(loop)), do: Enum.drop(loop, -1), else: loop
  end

  # A box with round corners (a radius r), from a corner and a size.
  defp rbox({x, y, z}, {w, d, h}, r, material),
    do: [{:prism, rounded({x, y}, {w, d}, r), z, h, material}]

  # A slab with round corners along an axis, from `from` to `from + length`.
  # Its corner and its size are in the plane of the two other axes
  # (`lift/3`).
  defp rslab(axis, corner, size, r, from, length, material),
    do: [{:prism, axis, rounded(corner, size, r), from, length, material}]

  # The wheels of a car on a side, as points `{y, z}`: the dark arch over
  # each wheel, the tire, the rim and its hub.
  defp wheel_discs(r, ys) do
    ring = fn y, radius, angles ->
      for a <- angles, do: {y + radius * :math.cos(a), r + radius * :math.sin(a)}
    end

    half = for k <- 0..12, do: :math.pi() * k / 12
    full = for k <- 0..23, do: 2 * :math.pi() * k / 24

    for y <- ys,
        part <- [
          {ring.(y, r + 0.05, half), "i-black"},
          {ring.(y, r, full), "i-black"},
          {ring.(y, r * 0.6, full), "i-steel-~"},
          {ring.(y, r * 0.2, full), "i-gray-~"}
        ],
        do: part
  end

  # A polygon with its normal (nil: it always shows).
  defp face(corners, normal, class), do: {:face, corners, normal, class}

  @doc """
  The model of a kind: boxes, cylinders and faces, in the order of the
  paint. The unit is near a meter, and the front looks to y.
  """
  # A fridge with French doors and a drawer. It has a steel body with round
  # corners, the line of each door, the dispenser and the handles. A plate
  # is at its foot.
  def model("fridge") do
    {w, d, h} = {0.84, 0.8, 1.78}

    rbox({0, 0, 0.05}, {w, d, h - 0.05}, 0.035, "steel") ++
      box({0.04, d - 0.08, 0}, {w - 0.08, 0.06, 0.05}, "dark") ++
      [
        front({0, d, 0.7}, {w, 0.012}, "i-line"),
        front({w / 2 - 0.005, d, 0.71}, {0.01, h - 0.74}, "i-line"),
        front({0.1, d, 1.08}, {0.18, 0.3}, "i-black"),
        front({0.13, d + 0.002, 1.32}, {0.12, 0.03}, "i-led")
      ] ++
      box({w / 2 - 0.07, d, 0.95}, {0.025, 0.04, 0.62}, "steel") ++
      box({w / 2 + 0.045, d, 0.95}, {0.025, 0.04, 0.62}, "steel") ++
      box({0.2, d, 0.58}, {w - 0.4, 0.04, 0.03}, "steel")
  end

  # A chest freezer: a white body with round corners, the line of its lid,
  # the handle, and the light of its power.
  def model("freezer") do
    {w, d, h} = {1.42, 0.76, 0.84}

    rbox({0, 0, 0.03}, {w, d, h - 0.03}, 0.04, "white") ++
      box({0.05, 0.05, 0}, {w - 0.1, d - 0.1, 0.03}, "gray") ++
      [
        front({0, d, h - 0.1}, {w, 0.012}, "i-line"),
        front({0.12, d, h - 0.2}, {0.04, 0.02}, "i-led")
      ] ++
      box({w / 2 - 0.15, d, h - 0.16}, {0.3, 0.04, 0.03}, "gray")
  end

  # A range: a steel body, and a cooktop of black glass with four burners.
  # It has a guard at the back and a strip of knobs. The door of the oven
  # has its window and its handle. A drawer is under the door.
  def model("range") do
    {w, d} = {0.76, 0.66}

    rbox({0, 0, 0}, {w, d, 0.92}, 0.02, "steel") ++
      box({0, 0, 0.92}, {w, 0.08, 0.22}, "steel") ++
      [top({0.02, 0.1, 0.92}, {w - 0.04, d - 0.12}, "i-black")] ++
      for(
        {x, y} <- [{0.2, 0.26}, {0.56, 0.26}, {0.2, 0.5}, {0.56, 0.5}],
        do: disc({x, y, 0.94}, :top, 0.1, "i-burner")
      ) ++
      [
        front({0.02, d, 0.8}, {w - 0.04, 0.1}, "i-dark-l"),
        front({0.06, d, 0.12}, {w - 0.12, 0.6}, "i-steel-t"),
        front({0.14, d + 0.002, 0.22}, {w - 0.28, 0.36}, "i-glass-dark"),
        front({0.18, d + 0.004, 0.42}, {0.12, 0.12}, "i-shine"),
        front({0.04, d, 0.03}, {w - 0.08, 0.012}, "i-line")
      ] ++
      for(k <- 0..4, do: disc({0.12 + k * 0.13, d + 0.014, 0.85}, :front, 0.022, "i-steel-t")) ++
      box({0.1, d, 0.66}, {w - 0.2, 0.04, 0.03}, "steel")
  end

  # A microwave: a steel body, the door with its window, and the keys with
  # their display.
  def model("microwave") do
    {w, d, h} = {0.61, 0.46, 0.36}

    rbox({0, 0, 0}, {w, d, h}, 0.02, "steel") ++
      [
        front({0.03, d, 0.04}, {0.42, 0.28}, "i-black"),
        front({0.06, d + 0.002, 0.07}, {0.36, 0.22}, "i-glass-dark"),
        front({0.08, d + 0.004, 0.2}, {0.1, 0.08}, "i-shine"),
        front({0.47, d, 0.04}, {0.11, 0.28}, "i-dark-l"),
        front({0.49, d + 0.002, 0.26}, {0.07, 0.03}, "i-led")
      ] ++
      for(
        row <- 0..2,
        col <- 0..1,
        do: front({0.49 + col * 0.04, d + 0.002, 0.07 + row * 0.055}, {0.028, 0.03}, "i-steel-t")
      )
  end

  # A dishwasher: a steel body, the strip of its keys with a light, the
  # handle, and the plate at its foot.
  def model("dishwasher") do
    {w, d, h} = {0.6, 0.6, 0.86}

    rbox({0, 0, 0.06}, {w, d, h - 0.06}, 0.015, "steel") ++
      box({0.03, d - 0.06, 0}, {w - 0.06, 0.04, 0.06}, "dark") ++
      [
        front({0, d, h - 0.12}, {w, 0.12}, "i-black"),
        front({w - 0.2, d + 0.002, h - 0.07}, {0.12, 0.025}, "i-led")
      ] ++
      box({0.12, d, h - 0.2}, {w - 0.24, 0.04, 0.03}, "steel")
  end

  def model("washer"), do: laundry("i-glass")
  def model("dryer"), do: laundry("i-glass-dark")

  # A water heater: a round tank on its foot, with its cap and its label.
  # Two pipes are on its top, and the relief valve is on its side.
  def model("water_heater") do
    {r, h} = {0.27, 1.42}

    cylinder({0.28, 0.28, 0}, 0.24, 0.05, "gray") ++
      cylinder({0.28, 0.28, 0.05}, r, h, "white") ++
      cylinder({0.28, 0.28, 0.05 + h}, 0.23, 0.04, "gray") ++
      cylinder({0.18, 0.28, 0.09 + h}, 0.025, 0.14, "copper") ++
      cylinder({0.38, 0.28, 0.09 + h}, 0.025, 0.14, "copper") ++
      [
        face(
          for({x, z} <- [{0.2, 0.75}, {0.36, 0.75}, {0.36, 1.0}, {0.2, 1.0}], do: {x, 0.553, z}),
          {0, 1, 0},
          "i-shade-t i-face"
        )
      ] ++
      box({0.55, 0.25, 1.25}, {0.05, 0.06, 0.06}, "copper")
  end

  # The AC outside: a steel box with round corners on a pad. The grille of
  # its fan and its hub are on its top. Its sides have the lines of its
  # coil.
  def model("ac") do
    {w, h} = {0.74, 0.84}

    box({0, 0, 0}, {w, w, 0.05}, "dark") ++
      rbox({0.02, 0.02, 0.05}, {w - 0.04, w - 0.04, h - 0.05}, 0.04, "steel") ++
      [
        disc({w / 2, w / 2, h + 0.005}, :top, 0.29, "i-black"),
        disc({w / 2, w / 2, h + 0.01}, :top, 0.07, "i-steel-t")
      ] ++
      for(
        k <- 1..6,
        part <- [
          front({0.08, w - 0.02, 0.1 + k * 0.1}, {w - 0.16, 0.012}, "i-line"),
          side({w - 0.02, 0.08, 0.1 + k * 0.1}, {w - 0.16, 0.012}, "i-line")
        ],
        do: part
      )
  end

  # The head of a mini split on a wall: a white body with round corners, the
  # slot of its vane, and its light.
  def model("mini_split") do
    {w, d, h} = {0.8, 0.22, 0.3}

    rbox({0, 0, 0}, {w, d, h}, 0.05, "white") ++
      [
        front({0.06, d, 0.04}, {w - 0.12, 0.06}, "i-glass-dark"),
        front({0.08, d, 0.12}, {w - 0.16, 0.01}, "i-line"),
        front({w - 0.12, d, 0.2}, {0.05, 0.02}, "i-led")
      ]
  end

  # A gas furnace: a steel cabinet with two doors. The upper door has
  # louvers, and the lower door has the window of the flame and a label.
  # The flue goes up from the back of its top.
  def model("furnace") do
    {w, d, h} = {0.46, 0.71, 0.84}

    rbox({0, 0, 0}, {w, d, h}, 0.012, "steel") ++
      cylinder({w / 2, 0.16, h}, 0.07, 0.16, "gray") ++
      [
        front({0.02, d, 0.45}, {w - 0.04, 0.37}, "i-steel-t"),
        front({0.02, d, 0.03}, {w - 0.04, 0.4}, "i-steel-t")
      ] ++
      for(k <- 0..5, do: front({0.08, d + 0.002, 0.56 + k * 0.035}, {w - 0.16, 0.012}, "i-line")) ++
      [
        front({0.17, d + 0.002, 0.24}, {0.12, 0.06}, "i-flame"),
        front({0.06, d + 0.002, 0.08}, {0.12, 0.07}, "i-white-t")
      ]
  end

  # The heat strips of an air handler: a steel cabinet with a window. The
  # coils glow in the window. The box of the breakers is at its right.
  def model("heat_strips") do
    {w, d, h} = {1.22, 0.61, 0.61}

    rbox({0, 0, 0}, {w, d, h}, 0.015, "steel") ++
      [
        front({0.06, d, 0.08}, {0.78, 0.45}, "i-black"),
        front({0.9, d, 0.12}, {0.26, 0.38}, "i-gray-l")
      ] ++
      for(
        k <- 0..6,
        do: front({0.12 + k * 0.1, d + 0.002, 0.13}, {0.035, 0.35}, "i-hot")
      ) ++
      for(
        k <- 0..1,
        do: front({0.96 + k * 0.08, d + 0.002, 0.3}, {0.04, 0.09}, "i-black")
      ) ++
      [front({0.94, d + 0.002, 0.16}, {0.18, 0.06}, "i-white-t")]
  end

  # A smart meter: the glass dome of the meter on its base, with its
  # display and its ring.
  def model("smart_meter") do
    {w, d, h} = {0.25, 0.15, 0.36}

    rbox({0, 0, 0}, {w, 0.07, h}, 0.02, "gray") ++
      tube({w / 2, 0.07, 0.17}, 0.105, 0.04, :y, "steel") ++
      tube({w / 2, 0.11, 0.17}, 0.09, d - 0.11, :y, "white") ++
      [
        disc({w / 2, d + 0.002, 0.17}, :front, 0.08, "i-glass"),
        front({w / 2 - 0.045, d + 0.002, 0.17}, {0.09, 0.035}, "i-black"),
        front({w / 2 - 0.035, d + 0.004, 0.18}, {0.05, 0.015}, "i-led"),
        disc({w / 2 - 0.03, d + 0.004, 0.22}, :front, 0.025, "i-shine")
      ]
  end

  # A floor lamp: a round base, a thin stem, and a shade that glows.
  def model("lights") do
    cylinder({0.2, 0.2, 0}, 0.15, 0.03, "steel") ++
      cylinder({0.2, 0.2, 0.03}, 0.012, 1.14, "steel") ++
      cylinder({0.2, 0.2, 1.12}, 0.2, 0.36, "shade") ++
      [disc({0.2, 0.2, 1.485}, :top, 0.05, "i-bulb")]
  end

  # A TV on its stand: the foot, the neck, and the thin panel with its
  # screen and a shine on it.
  def model("tv") do
    {w, h} = {1.12, 0.6}

    box({0.36, 0.0, 0}, {0.4, 0.2, 0.02}, "dark") ++
      box({0.53, 0.06, 0.02}, {0.06, 0.04, 0.1}, "dark") ++
      box({0, 0.1, 0.12}, {w, 0.035, h}, "dark") ++
      [
        front({0.015, 0.125, 0.135}, {w - 0.03, h - 0.03}, "i-screen"),
        face(
          for(
            {x, z} <- [{0.2, 0.135}, {0.4, 0.135}, {0.6, h + 0.105}, {0.4, h + 0.105}],
            do: {x, 0.137, z}
          ),
          {0, 1, 0},
          "i-shine"
        )
      ]
  end

  # A computer: a monitor with a thin edge on its stand, a keyboard with
  # rows of keys, and a mouse.
  def model("computer") do
    d = 0.41

    box({0.2, 0.02, 0}, {0.21, 0.14, 0.012}, "dark") ++
      box({0.28, 0.04, 0.012}, {0.05, 0.03, 0.14}, "dark") ++
      box({0.005, 0.07, 0.12}, {0.6, 0.025, 0.37}, "dark") ++
      [
        front({0.015, 0.095, 0.135}, {0.58, 0.34}, "i-screen"),
        face(
          for(
            {x, z} <- [{0.1, 0.135}, {0.22, 0.135}, {0.36, 0.475}, {0.24, 0.475}],
            do: {x, 0.107, z}
          ),
          {0, 1, 0},
          "i-shine"
        )
      ] ++
      rbox({0.06, 0.22, 0}, {0.42, 0.14, 0.018}, 0.01, "gray") ++
      for(
        k <- 0..3,
        do: top({0.08, 0.235 + k * 0.028, 0.008}, {0.38, 0.016}, "i-dark-t")
      ) ++
      rbox({0.52, d - 0.12, 0}, {0.06, 0.1, 0.03}, 0.025, "white")
  end

  # A ceiling fan: five blades under the motor, the bowl of its light under
  # them, and the rod up to the canopy on the ceiling.
  def model("ceiling_fan") do
    {c, z} = {0.66, 0.07}

    blades =
      for k <- 0..4 do
        a = 2 * :math.pi() * k / 5 + 0.3

        along = fn t, s ->
          {c + t * :math.cos(a) - s * :math.sin(a), c + t * :math.sin(a) + s * :math.cos(a), z}
        end

        corners = [
          along.(0.12, -0.04),
          along.(0.6, -0.065),
          along.(0.64, 0.0),
          along.(0.6, 0.065),
          along.(0.12, 0.04)
        ]

        face(corners, {0, 0, 1}, "i-wood-t i-face")
      end

    cylinder({c, c, 0}, 0.07, 0.07, "white") ++
      blades ++
      cylinder({c, c, 0.07}, 0.11, 0.1, "steel") ++
      cylinder({c, c, 0.17}, 0.012, 0.09, "steel") ++
      cylinder({c, c, 0.26}, 0.06, 0.04, "steel")
  end

  # A power strip: a white body with round corners, six outlets on its top,
  # a red switch, and its cord.
  def model("always_on") do
    {w, d, h} = {0.46, 0.15, 0.06}

    rbox({0, 0, 0}, {w, d, h}, 0.02, "white") ++
      for(
        k <- 0..5,
        part <- [
          top({0.04 + k * 0.062, 0.035, h}, {0.045, 0.08}, "i-gray-t"),
          top({0.05 + k * 0.062, 0.06, h + 0.002}, {0.006, 0.025}, "i-black"),
          top({0.068 + k * 0.062, 0.06, h + 0.002}, {0.006, 0.025}, "i-black")
        ],
        do: part
      ) ++
      box({w - 0.06, 0.045, h}, {0.035, 0.06, 0.012}, "red")
  end

  # A pool pump: the motor lies along x, with the cap of its fan at its
  # back end. The pump and its strainer are at the front end. The strainer
  # has a clear lid, and the pipe goes up from the pump.
  def model("pool_pump") do
    d = 0.2

    box({0.03, 0.01, 0}, {0.58, d - 0.02, 0.025}, "dark") ++
      tube({0.0, d / 2, 0.11}, 0.07, 0.03, :x, "dark") ++
      tube({0.03, d / 2, 0.11}, 0.085, 0.27, :x, "gray") ++
      tube({0.3, d / 2, 0.11}, 0.075, 0.1, :x, "blue") ++
      cylinder({0.5, d / 2, 0.025}, 0.095, 0.2, "blue") ++
      cylinder({0.5, d / 2, 0.225}, 0.1, 0.03, "dark") ++
      [disc({0.5, d / 2, 0.257}, :top, 0.075, "i-glass")] ++
      cylinder({0.35, d / 2, 0.18}, 0.03, 0.1, "white")
  end

  # A tower heater: a white body with round corners on its foot. Its front
  # has a grille that glows, and its top has the keys and a light.
  def model("space_heater") do
    {w, d, h} = {0.25, 0.18, 0.64}

    rbox({0, 0, 0}, {w, d, 0.03}, 0.05, "gray") ++
      rbox({0.02, 0.02, 0.03}, {w - 0.04, d - 0.04, h - 0.03}, 0.05, "white") ++
      [front({0.05, d - 0.02, 0.1}, {w - 0.1, 0.4}, "i-black")] ++
      for(
        k <- 0..6,
        do: front({0.06, d - 0.018, 0.12 + k * 0.053}, {w - 0.12, 0.022}, "i-hot")
      ) ++
      [
        top({0.06, 0.05, h}, {w - 0.12, 0.06}, "i-dark-t"),
        top({0.08, 0.065, h + 0.002}, {0.03, 0.03}, "i-led")
      ]
  end

  # A power station: a body with round corners, with two handles on its
  # top. Its dark front has its screen and its outlets. Its side has vents.
  def model("power_station") do
    {w, d, h} = {0.64, 0.28, 0.41}

    box({0.04, 0.03, 0}, {w - 0.08, d - 0.06, 0.02}, "dark") ++
      rbox({0, 0, 0.02}, {w, d, h - 0.05}, 0.03, "steel") ++
      box({0.05, 0.04, h - 0.03}, {0.07, d - 0.08, 0.03}, "dark") ++
      box({w - 0.12, 0.04, h - 0.03}, {0.07, d - 0.08, 0.03}, "dark") ++
      [
        front({0.03, d, 0.05}, {w - 0.06, h - 0.13}, "i-dark-l"),
        front({0.06, d + 0.002, 0.2}, {0.14, 0.08}, "i-screen"),
        front({0.08, d + 0.004, 0.23}, {0.07, 0.02}, "i-led")
      ] ++
      for(k <- 0..3, do: front({0.26 + k * 0.08, d + 0.002, 0.18}, {0.05, 0.06}, "i-white-t")) ++
      for(k <- 0..3, do: side({w, 0.06, 0.1 + k * 0.05}, {d - 0.12, 0.012}, "i-line"))
  end

  # Solar panels on a post: the frame, the cells in rows of 6, and the lines
  # between the cells. The panel and its post are one group: when the panel
  # looks away, its back paints first and the post paints over it.
  def model("solar_panels") do
    # A point on the panel: s across (0 to 1) and t up its slope (0 to 1).
    at = fn s, t -> {s * 1.0, 0.8 - t * 1.2, 0.45 + t * 0.85} end
    panel = fn {s0, t0}, {s1, t1} -> [at.(s0, t0), at.(s1, t0), at.(s1, t1), at.(s0, t1)] end
    {front, back} = {{0, 0.85, 1.2}, {0, -0.85, -1.2}}

    cells =
      [
        face(panel.({-0.02, -0.02}, {1.02, 1.02}), front, "i-steel-t"),
        face(panel.({0, 0}, {1, 1}), front, "i-pv")
      ] ++
        for(
          k <- 1..5,
          do: face(panel.({k / 6 - 0.004, 0}, {k / 6 + 0.004, 1}), front, "i-pv-line")
        ) ++
        for(
          k <- 1..9,
          do: face(panel.({0, k / 10 - 0.003}, {1, k / 10 + 0.003}), front, "i-pv-line")
        )

    [
      {:group,
       [face(panel.({-0.02, -0.02}, {1.02, 1.02}), back, "i-gray-~ i-face")] ++
         cylinder({0.5, 0.2, 0}, 0.04, 0.86, "gray") ++ cells}
    ]
  end

  # A transfer switch: a gray box with round corners. Its window shows two
  # rows of breakers, and the big red handle is at its right.
  def model("transfer_switch") do
    {w, d, h} = {0.38, 0.18, 0.51}

    cylinder({w / 2, 0.08, h}, 0.025, 0.06, "gray") ++
      rbox({0, 0, 0}, {w, d, h}, 0.02, "gray") ++
      [
        front({0.03, d, 0.03}, {w - 0.04, h - 0.06}, "i-steel-t"),
        front({0.05, d + 0.002, 0.2}, {0.22, 0.25}, "i-black")
      ] ++
      for(
        row <- 0..1,
        col <- 0..3,
        do: front({0.07 + col * 0.05, d + 0.004, 0.24 + row * 0.11}, {0.03, 0.06}, "i-steel-l")
      ) ++
      [front({0.05, d + 0.002, 0.06}, {0.14, 0.08}, "i-white-t")] ++
      box({0.3, d, 0.24}, {0.045, 0.06, 0.16}, "red")
  end

  # An electric car: the side profile of a crossover across its width. The
  # windshield and the back window are glass, and the windows of the doors
  # are on the sides. The tires and the rims, the lights and the handles
  # are on the faces of the body.
  def model("ev") do
    {l, w} = {4.72, 1.85}

    profile = [
      {0.06, 0.2},
      {4.64, 0.2},
      {4.72, 0.36},
      {4.72, 0.56},
      {4.6, 0.78},
      {3.72, 0.94},
      {2.9, 1.42},
      {1.55, 1.45},
      {0.55, 1.12},
      {0.18, 1.02},
      {0.0, 0.84},
      {0.0, 0.36}
    ]

    # A face across the car on the edge of the profile from point i to
    # point i + 1, a little out of the body.
    across = fn i, class ->
      [{y1, z1}, {y2, z2}] = [Enum.at(profile, i), Enum.at(profile, i + 1)]
      {ny, nz} = {z2 - z1, y1 - y2}
      k = 0.006 / :math.sqrt(ny * ny + nz * nz)

      corners =
        for {x, y, z} <- [{0.12, y1, z1}, {w - 0.12, y1, z1}, {w - 0.12, y2, z2}, {0.12, y2, z2}],
            do: {x, y + ny * k, z + nz * k}

      face(corners, {0, ny, nz}, class)
    end

    # The windows of the side, the lines of the doors and the handles, and
    # the tires, the rims and their hubs.
    window = [{0.75, 1.0}, {3.6, 1.0}, {2.88, 1.36}, {1.58, 1.39}, {0.9, 1.18}]

    sides =
      for {x, sign} <- [{-0.006, -1}, {w + 0.006, 1}],
          {points, class} <-
            [
              {window, "i-glass-dark"},
              {[{2.22, 1.0}, {2.3, 1.0}, {2.3, 1.4}, {2.22, 1.4}], "i-red-~"},
              {[{2.26, 0.32}, {2.28, 0.32}, {2.28, 1.0}, {2.26, 1.0}], "i-line"},
              {[{3.5, 0.36}, {3.52, 0.36}, {3.6, 1.0}, {3.58, 1.0}], "i-line"},
              {[{2.5, 0.88}, {2.7, 0.88}, {2.7, 0.91}, {2.5, 0.91}], "i-dark-~"},
              {[{1.45, 0.88}, {1.65, 0.88}, {1.65, 0.91}, {1.45, 0.91}], "i-dark-~"},
              {[{0.0, 0.2}, {4.7, 0.2}, {4.7, 0.3}, {0.0, 0.3}], "i-black"}
            ] ++ wheel_discs(0.33, [0.95, 3.85]),
          do: face(for({y, z} <- points, do: {x, y, z}), {sign, 0, 0}, class)

    [
      {:group,
       [{:prism, :x, profile, 0.0, w, "red"}] ++
         [
           across.(5, "i-glass-dark"),
           across.(7, "i-glass-dark"),
           face(
             for(
               {x, z} <- [{0.12, 0.62}, {0.4, 0.62}, {0.4, 0.7}, {0.12, 0.68}],
               do: {x, l + 0.004, z}
             ),
             {0, 1, 0},
             "i-bulb"
           ),
           face(
             for(
               {x, z} <- [{w - 0.4, 0.62}, {w - 0.12, 0.62}, {w - 0.12, 0.68}, {w - 0.4, 0.7}],
               do: {x, l + 0.004, z}
             ),
             {0, 1, 0},
             "i-bulb"
           ),
           face(
             for(
               {x, z} <- [{0.1, 0.86}, {w - 0.1, 0.86}, {w - 0.1, 0.94}, {0.1, 0.94}],
               do: {x, -0.004, z}
             ),
             {0, -1, 0},
             "i-hot"
           )
         ] ++ sides}
    ]
  end

  # The icon of a camper van: the model of the Ford Transit.
  def model("camper_van"), do: VanShapes.van("transit_148")

  # A captain seat on its swivel: the seat and the back have round corners,
  # with a headrest and two armrests.
  def model("swivel_seat") do
    {w, d} = {0.66, 0.66}

    cylinder({w / 2, d / 2, 0}, 0.24, 0.06, "dark") ++
      cylinder({w / 2, d / 2, 0.06}, 0.08, 0.14, "dark") ++
      rbox({0.06, 0.06, 0.2}, {0.54, 0.58, 0.14}, 0.07, "cloth") ++
      rbox({0.08, 0.04, 0.34}, {0.5, 0.15, 0.52}, 0.06, "cloth") ++
      rbox({0.2, 0.06, 0.86}, {0.26, 0.11, 0.16}, 0.05, "cloth") ++
      box({0.09, 0.19, 0.5}, {0.06, 0.36, 0.05}, "dark") ++
      box({w - 0.15, 0.19, 0.5}, {0.06, 0.36, 0.05}, "dark")
  end

  # A DC to DC charger: a dark body with round corners and fins on its top.
  # It has its label, and the red and black cables at its end.
  def model("dc_charger") do
    {w, d, h} = {0.18, 0.08, 0.13}

    rbox({0, 0, 0}, {w, d, h}, 0.01, "dark") ++
      for(k <- 0..4, do: top({0.015 + k * 0.034, 0.01, h}, {0.012, d - 0.02}, "i-gray-t")) ++
      [
        front({0.03, d, 0.04}, {0.12, 0.05}, "i-white-t"),
        front({0.04, d + 0.002, 0.075}, {0.025, 0.01}, "i-led")
      ] ++
      tube({w, 0.025, 0.03}, 0.008, 0.05, :x, "red") ++
      tube({w, 0.055, 0.03}, 0.008, 0.05, :x, "dark")
  end

  # A fridge of 12 V: a gray chest with round corners, and a dark lid with
  # its handle. The panel with its display is on the front.
  def model("van_fridge") do
    {w, d, h} = {0.41, 0.64, 0.48}

    rbox({0, 0, 0}, {w, d, h - 0.08}, 0.04, "gray") ++
      rbox({0, 0, h - 0.08}, {w, d, 0.08}, 0.04, "dark") ++
      box({0.08, d, h - 0.06}, {w - 0.16, 0.03, 0.03}, "steel") ++
      [
        front({0.1, d, 0.22}, {w - 0.2, 0.1}, "i-black"),
        front({0.13, d + 0.002, 0.25}, {0.08, 0.04}, "i-screen"),
        front({w - 0.15, d + 0.002, 0.26}, {0.02, 0.02}, "i-led")
      ]
  end

  # A cooktop of two burners: a steel body with round corners, with black
  # glass on its top. The burners have their rings and their grates, and
  # the front has two knobs.
  def model("stove") do
    {w, d, h} = {0.56, 0.41, 0.08}

    rbox({0, 0, 0}, {w, d, h}, 0.02, "steel") ++
      [top({0.02, 0.02, h}, {w - 0.04, d - 0.1}, "i-black")] ++
      for(
        x <- [0.15, 0.41],
        part <- [
          disc({x, 0.17, h + 0.012}, :top, 0.09, "i-burner"),
          disc({x, 0.17, h + 0.012}, :top, 0.035, "i-gray-t"),
          top({x - 0.1, 0.165, h + 0.014}, {0.2, 0.01}, "i-gray-t"),
          top({x - 0.005, 0.07, h + 0.014}, {0.01, 0.2}, "i-gray-t")
        ],
        do: part
      ) ++
      for(x <- [0.18, 0.38], do: disc({x, d + 0.004, h / 2}, :front, 0.022, "i-dark-l"))
  end

  # A sink: a cabinet with two doors and their handles, and a top of light
  # wood. The basin has its drain, and the faucet has its spout.
  def model("sink") do
    {w, d, h} = {0.61, 0.46, 0.91}

    box({0.02, 0.02, 0}, {w - 0.04, d - 0.04, 0.08}, "dark") ++
      box({0, 0, 0.08}, {w, d - 0.02, h - 0.12}, "wood") ++
      [
        front({0.03, d - 0.02, 0.11}, {w / 2 - 0.045, h - 0.18}, "i-wood-t"),
        front({w / 2 + 0.015, d - 0.02, 0.11}, {w / 2 - 0.045, h - 0.18}, "i-wood-t"),
        front({w / 2 - 0.05, d - 0.018, 0.6}, {0.015, 0.12}, "i-steel-l"),
        front({w / 2 + 0.035, d - 0.018, 0.6}, {0.015, 0.12}, "i-steel-l")
      ] ++
      box({-0.01, -0.01, h - 0.04}, {w + 0.02, d + 0.01, 0.04}, "light-wood") ++
      [
        top({0.1, 0.12, h}, {w - 0.2, 0.26}, "i-steel-r"),
        top({0.12, 0.14, h + 0.002}, {w - 0.24, 0.22}, "i-steel-l"),
        disc({w / 2, 0.25, h + 0.004}, :top, 0.02, "i-dark-t")
      ] ++
      cylinder({w / 2, 0.06, h}, 0.018, 0.22, "steel") ++
      tube({w / 2, 0.078, h + 0.2}, 0.014, 0.09, :y, "steel")
  end

  # A tank of fresh water: a white tank with round corners, the line of the
  # water in it, its cap, and its fittings.
  def model("water_tank") do
    {w, d, h} = {0.61, 0.38, 0.36}

    rbox({0, 0, 0}, {w, d, h}, 0.05, "white") ++
      [
        front({0.04, d, 0.04}, {w - 0.08, 0.22}, "i-glass"),
        front({0.04, d + 0.002, 0.26}, {w - 0.08, 0.008}, "i-line")
      ] ++
      cylinder({0.15, 0.15, h}, 0.05, 0.03, "blue") ++
      tube({w, 0.12, 0.05}, 0.015, 0.04, :x, "white") ++
      tube({w, 0.26, 0.05}, 0.015, 0.04, :x, "white")
  end

  # A water pump: the motor lies along x, the pump head is black, and the
  # two fittings are blue.
  def model("water_pump") do
    d = 0.13

    box({0.02, 0.02, 0}, {0.16, d - 0.04, 0.01}, "dark") ++
      tube({0.0, d / 2, 0.055}, 0.045, 0.11, :x, "steel") ++
      tube({0.11, d / 2, 0.055}, 0.04, 0.05, :x, "dark") ++
      tube({0.135, 0.0, 0.07}, 0.012, 0.024, :y, "blue") ++
      tube({0.135, d - 0.024, 0.07}, 0.012, 0.024, :y, "blue")
  end

  # A counter: a cabinet with a dark toe kick, two drawers and two doors
  # with their handles, and a thick top of light wood.
  def model("counter") do
    {w, d, h} = {1.22, 0.56, 0.91}

    box({0.03, 0.03, 0}, {w - 0.06, d - 0.08, 0.08}, "dark") ++
      box({0, 0, 0.08}, {w, d - 0.03, h - 0.12}, "wood") ++
      for(
        col <- 0..1,
        x = 0.03 + col * (w / 2),
        part <- [
          front({x, d - 0.03, 0.62}, {w / 2 - 0.06, 0.14}, "i-wood-t"),
          front({x, d - 0.03, 0.11}, {w / 2 - 0.06, 0.48}, "i-wood-t"),
          front({x + 0.2, d - 0.028, 0.68}, {0.16, 0.015}, "i-steel-l"),
          front({x + 0.47, d - 0.028, 0.4}, {0.015, 0.14}, "i-steel-l")
        ],
        do: part
      ) ++
      box({-0.01, -0.01, h - 0.04}, {w + 0.02, d + 0.01, 0.04}, "light-wood")
  end

  # A bench of a dinette: a wooden base with a lid, and a seat and a back of
  # cloth with round corners.
  def model("bench") do
    {w, d} = {1.02, 0.51}

    box({0, 0, 0}, {w, d, 0.4}, "wood") ++
      [
        front({0.04, d, 0.05}, {w - 0.08, 0.3}, "i-wood-t"),
        front({w / 2 - 0.08, d + 0.002, 0.28}, {0.16, 0.03}, "i-dark-l")
      ] ++
      rbox({0.01, 0.12, 0.4}, {w - 0.02, d - 0.13, 0.1}, 0.04, "cloth") ++
      rbox({0.01, 0.0, 0.4}, {w - 0.02, 0.12, 0.41}, 0.04, "cloth")
  end

  # A table of a van: its foot, its pole, and a top of light wood with
  # round corners.
  def model("van_table") do
    {w, d, h} = {0.71, 0.51, 0.71}

    cylinder({w / 2, d / 2, 0}, 0.12, 0.012, "steel") ++
      cylinder({w / 2, d / 2, 0.012}, 0.03, h - 0.04, "steel") ++
      rbox({0, 0, h - 0.03}, {w, d, 0.03}, 0.08, "light-wood")
  end

  # A fan of a roof: the white frame, and a cover with a slope over the fan.
  # The opening of the cover is at its low end, at the front.
  def model("van_fan") do
    {w, d} = {0.43, 0.58}
    cover = [{0.0, 0.03}, {d, 0.03}, {d, 0.06}, {0.12, 0.13}, {0.0, 0.13}]

    rbox({0, 0, 0}, {w, d, 0.03}, 0.03, "white") ++
      [{:prism, :x, cover, 0.02, w - 0.04, "white"}] ++
      [front({0.05, d, 0.032}, {w - 0.1, 0.025}, "i-black")]
  end

  # A window of a van: a black frame with round corners, the glass with a
  # shine, and its two latches.
  def model("window") do
    {w, d, h} = {0.91, 0.05, 0.61}
    glass = for {z, x} <- rounded({0.05, 0.05}, {h - 0.1, w - 0.1}, 0.05), do: {x, d + 0.004, z}

    rslab(:y, {0, 0}, {h, w}, 0.08, 0, d, "dark") ++
      [
        face(glass, {0, 1, 0}, "i-glass-dark"),
        face(
          for(
            {x, z} <- [{0.15, 0.08}, {0.3, 0.08}, {0.45, h - 0.08}, {0.3, h - 0.08}],
            do: {x, d + 0.006, z}
          ),
          {0, 1, 0},
          "i-shine"
        ),
        front({0.2, d, 0.02}, {0.08, 0.02}, "i-gray-l"),
        front({w - 0.28, d, 0.02}, {0.08, 0.02}, "i-gray-l")
      ]
  end

  # Lights of a van: three round lights on a strip, each with its bulb.
  def model("van_lights") do
    {w, d} = {0.3, 0.1}

    rbox({0, 0.03, 0}, {w, d - 0.06, 0.006}, 0.02, "white") ++
      for(
        x <- [0.05, 0.15, 0.25],
        part <-
          cylinder({x, d / 2, 0}, 0.04, 0.018, "steel") ++
            [disc({x, d / 2, 0.02}, :top, 0.03, "i-bulb")],
        do: part
      )
  end

  # The devices: a laptop with its keyboard, its pad and its screen, and a
  # phone with its screen.
  def model("devices") do
    {w, d} = {0.32, 0.22}

    rbox({0, 0.03, 0}, {w, d, 0.015}, 0.01, "gray") ++
      [
        top({0.02, 0.1, 0.015}, {w - 0.04, 0.1}, "i-dark-t"),
        top({w / 2 - 0.05, 0.2, 0.015}, {0.1, 0.045}, "i-gray-r"),
        face(
          [{0, 0.03, 0.015}, {w, 0.03, 0.015}, {w, -0.02, 0.22}, {0, -0.02, 0.22}],
          nil,
          "i-dark-l"
        ),
        face(
          [
            {0.015, 0.032, 0.03},
            {w - 0.015, 0.032, 0.03},
            {w - 0.015, -0.013, 0.21},
            {0.015, -0.013, 0.21}
          ],
          {0, 1, 0.24},
          "i-screen"
        )
      ] ++
      rbox({0.34, 0.14, 0}, {0.07, 0.14, 0.01}, 0.012, "dark") ++
      [top({0.345, 0.148, 0.01}, {0.06, 0.124}, "i-screen")]
  end

  # A diesel heater: the round body lies along x, with its two end caps and
  # the pipe of its exhaust.
  def model("diesel_heater") do
    d = 0.13

    tube({0.0, d / 2, 0.065}, 0.06, 0.02, :x, "dark") ++
      tube({0.02, d / 2, 0.065}, 0.06, 0.2, :x, "red") ++
      tube({0.22, d / 2, 0.065}, 0.06, 0.03, :x, "dark") ++
      tube({0.25, d / 2, 0.065}, 0.025, 0.05, :x, "steel")
  end

  # A CO alarm: a round white body with a dome, its vents and its light.
  def model("co_alarm") do
    c = 0.065

    cylinder({c, c, 0}, 0.064, 0.03, "white") ++
      cylinder({c, c, 0.03}, 0.045, 0.015, "white") ++
      for(k <- 0..2, do: top({c - 0.03, c - 0.012 + k * 0.012, 0.045}, {0.06, 0.005}, "i-line")) ++
      [disc({c + 0.035, c + 0.035, 0.032}, :top, 0.006, "i-led")]
  end

  # A bed on its platform: the platform has drawers, and the mattress has
  # round corners, a duvet and two pillows.
  def model("bed_platform") do
    {w, d, h} = {1.52, 1.91, 0.61}

    box({0, 0, 0}, {w, d, 0.36}, "wood") ++
      for(
        k <- 0..1,
        part <- [
          front({0.08 + k * (w / 2), d, 0.06}, {w / 2 - 0.12, 0.24}, "i-wood-t"),
          front({0.28 + k * (w / 2), d + 0.002, 0.2}, {0.2, 0.025}, "i-dark-l")
        ],
        do: part
      ) ++
      rbox({0.02, 0.02, 0.36}, {w - 0.04, d - 0.04, h - 0.4}, 0.08, "white") ++
      rbox({0.02, 0.6, h - 0.04}, {w - 0.04, d - 0.62, 0.04}, 0.08, "cloth") ++
      rbox({0.12, 0.08, h - 0.04}, {0.58, 0.36, 0.1}, 0.08, "white") ++
      rbox({w - 0.7, 0.08, h - 0.04}, {0.58, 0.36, 0.1}, 0.08, "white")
  end

  # Storage: a cabinet of three drawers, each with a bar for a handle.
  def model("storage") do
    {w, d, h} = {0.91, 0.61, 0.61}

    box({0, 0, 0}, {w, d, h}, "wood") ++
      for(
        k <- 0..2,
        z = 0.03 + k * 0.195,
        part <- [
          front({0.03, d, z}, {w - 0.06, 0.175}, "i-wood-t"),
          front({w / 2 - 0.12, d + 0.002, z + 0.13}, {0.24, 0.02}, "i-steel-l")
        ],
        do: part
      )
  end

  # A battery of lithium: a dark body with round corners. Its label has a
  # light of its charge. Its top has the handle, and the red and black
  # terminals.
  def model("van_battery") do
    {w, d, h} = {0.33, 0.18, 0.23}

    rbox({0, 0, 0}, {w, d, h}, 0.015, "dark") ++
      [
        front({0.03, d, 0.06}, {w - 0.06, 0.08}, "i-blue-l"),
        front({0.05, d + 0.002, 0.08}, {0.12, 0.03}, "i-white-t"),
        front({w - 0.07, d + 0.002, 0.085}, {0.03, 0.02}, "i-led")
      ] ++
      box({w / 2 - 0.06, d / 2 - 0.012, h}, {0.12, 0.024, 0.02}, "gray") ++
      cylinder({0.04, d / 2, h}, 0.018, 0.025, "red") ++
      cylinder({w - 0.04, d / 2, h}, 0.018, 0.025, "dark")
  end

  # An inverter and charger: a blue body with round corners, its window with
  # a display and lights, its switch, and the fins on its side.
  def model("inverter") do
    {w, d, h} = {0.25, 0.23, 0.36}

    rbox({0, 0, 0}, {w, d, h}, 0.02, "blue") ++
      [
        front({0.03, d, 0.2}, {w - 0.06, 0.12}, "i-dark-l"),
        front({0.05, d + 0.002, 0.25}, {0.08, 0.045}, "i-screen"),
        front({0.16, d + 0.002, 0.29}, {0.02, 0.012}, "i-led"),
        front({0.16, d + 0.002, 0.26}, {0.02, 0.012}, "i-flame"),
        front({0.1, d, 0.06}, {0.05, 0.08}, "i-black")
      ] ++
      for(k <- 0..5, do: side({w, 0.03, 0.05 + k * 0.045}, {d - 0.06, 0.012}, "i-line"))
  end

  # A shore power inlet: a square plate with round corners, the round
  # socket with its three pins, and its yellow lid.
  def model("shore_power") do
    {w, d, h} = {0.15, 0.08, 0.15}

    rslab(:y, {0, 0}, {h, w}, 0.02, 0, 0.02, "gray") ++
      tube({w / 2, 0.02, 0.07}, 0.05, d - 0.03, :y, "gray") ++
      [disc({w / 2, d - 0.008, 0.07}, :front, 0.04, "i-black")] ++
      for(
        {x, z} <- [{-0.015, 0.08}, {0.015, 0.08}, {0.0, 0.055}],
        do: disc({w / 2 + x, d - 0.006, z}, :front, 0.006, "i-steel-t")
      ) ++
      [
        face(
          for(
            {x, z} <- [{0.02, 0.12}, {w - 0.02, 0.12}, {w - 0.02, 0.14}, {0.02, 0.14}],
            do: {x, d, z}
          ),
          {0, 1, 0},
          "i-flame"
        )
      ]
  end

  # Solar panels on the roof of a van: the frame with round corners, the
  # cells, and the lines between them.
  def model("van_solar") do
    {w, d, h} = {1.14, 1.73, 0.04}

    rbox({0, 0, 0}, {w, d, h}, 0.02, "steel") ++
      [top({0.025, 0.025, h}, {w - 0.05, d - 0.05}, "i-pv")] ++
      for(
        k <- 1..5,
        do: top({0.025 + k * (w - 0.05) / 6, 0.025, h + 0.002}, {0.006, d - 0.05}, "i-pv-line")
      ) ++
      for(
        k <- 1..9,
        do: top({0.025, 0.025 + k * (d - 0.05) / 10, h + 0.002}, {w - 0.05, 0.006}, "i-pv-line")
      )
  end

  # Insulation: two boards of foam, with the lines of their joints.
  def model("insulation") do
    {w, d} = {1.22, 0.61}

    box({0, 0, 0}, {w, d, 0.075}, "pink") ++
      box({0, 0, 0.075}, {w, d, 0.075}, "pink") ++
      [front({0, d, 0.07}, {w, 0.01}, "i-line"), top({w / 2, 0, 0.15}, {0.01, d}, "i-line")]
  end

  # The walls of a van: boards of light wood (shiplap), with the line of
  # each joint.
  def model("walls") do
    {w, d, h} = {1.22, 0.05, 0.91}

    box({0, 0, 0}, {w, d, h}, "light-wood") ++
      for(k <- 1..5, do: front({0, d, k * h / 6}, {w, 0.01}, "i-line")) ++
      for(
        k <- 0..5,
        do:
          front({if(rem(k, 2) == 0, do: 0.4, else: 0.8), d, k * h / 6}, {0.008, h / 6}, "i-line")
      )
  end

  # The floor of a van: planks of light wood with their joints, in a
  # pattern of bricks.
  def model("van_floor") do
    {w, d, h} = {1.22, 1.22, 0.025}

    box({0, 0, 0}, {w, d, h}, "light-wood") ++
      for(k <- 1..7, do: top({0, k * d / 8, h}, {w, 0.008}, "i-line")) ++
      for(
        k <- 0..7,
        do: top({if(rem(k, 2) == 0, do: 0.4, else: 0.8), k * d / 8, h}, {0.008, d / 8}, "i-line")
      )
  end

  # The kind "other": a box of cardboard with its tape.
  def model("other") do
    {w, d, h} = {0.61, 0.61, 0.61}

    box({0, 0, 0}, {w, d, h}, "light-wood") ++
      [
        top({w / 2 - 0.04, 0, h}, {0.08, d}, "i-light-wood-r"),
        front({w / 2 - 0.04, d, h - 0.12}, {0.08, 0.12}, "i-light-wood-r"),
        front({0.08, d, 0.08}, {0.16, 0.1}, "i-white-t")
      ]
  end

  # A washer or a dryer with a door in front: a white body with round
  # corners. The panel has its drawer, its display and its dial. The door
  # has its ring, and its glass has a shine. A plate is at its foot.
  defp laundry(glass) do
    {w, d, h} = {0.69, 0.72, 0.99}
    {cx, cz} = {w / 2, 0.45}

    rbox({0, 0, 0.03}, {w, d, h - 0.03}, 0.03, "white") ++
      box({0.04, d - 0.06, 0}, {w - 0.08, 0.04, 0.03}, "gray") ++
      [
        front({0, d, h - 0.17}, {w, 0.012}, "i-line"),
        front({0.04, d, h - 0.14}, {0.2, 0.08}, "i-white-t"),
        front({0.4, d, h - 0.13}, {0.12, 0.05}, "i-black"),
        disc({0.6, d + 0.012, h - 0.09}, :front, 0.035, "i-steel-l"),
        disc({cx, d + 0.012, cz}, :front, 0.25, "i-gray-l"),
        disc({cx, d + 0.016, cz}, :front, 0.2, "i-steel-t"),
        disc({cx, d + 0.02, cz}, :front, 0.16, glass),
        disc({cx - 0.05, d + 0.024, cz + 0.05}, :front, 0.05, "i-shine")
      ]
  end
end
