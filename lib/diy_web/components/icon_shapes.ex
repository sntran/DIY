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

  # A prism: a loop of points on the ground (counterclockwise from above),
  # from z up to z + h. Each side of the loop is a face, with the light of
  # its normal (`DIYWeb.Camera.light/2`): so a round shape has a soft
  # light. The faces have no edge. Under them is the shape of all the faces
  # that show, and over them its edge (`i-outline`). Then the top.
  defp draw_one({:prism, loop, z, h, material}, %{point: point, normal: turn, camera: camera}) do
    corners = List.to_tuple(loop)
    n = tuple_size(corners)

    lift = fn i, zz ->
      {x, y} = elem(corners, rem(i, n))
      at(point, {x, y, zz})
    end

    low = &lift.(&1, z)
    high = &lift.(&1, z + h)

    faces =
      for i <- 0..(n - 1) do
        {{x1, y1}, {x2, y2}} = {elem(corners, i), elem(corners, rem(i + 1, n))}
        normal = at(turn, {y2 - y1, x1 - x2, 0})
        {i, Camera.shows?(camera, normal), normal}
      end

    run = shown_run(faces, n)
    outline = Enum.map(run, low) ++ Enum.map(Enum.reverse(run), high)
    top = {:poly, Enum.map(0..(n - 1), high), "i-#{material}-t i-face"}

    body =
      for {i, true, normal} <- faces,
          do:
            {:poly, [low.(i), low.(i + 1), high.(i + 1), high.(i)],
             "i-#{material}-#{Camera.light(camera, normal)}"}

    [{:poly, outline, "i-#{material}-m2"}] ++ body ++ [{:poly, outline, "i-outline"}, top]
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

  # A disc on the top, on the front, or on a side.
  defp disc(center, :top, r, class),
    do: {:face, Geometry.circle(center, {1, 0, 0}, {0, 1, 0}, r), {0, 0, 1}, class}

  defp disc(center, :front, r, class),
    do: {:face, Geometry.circle(center, {1, 0, 0}, {0, 0, 1}, r), {0, 1, 0}, class}

  defp disc(center, :side, r, class),
    do: {:face, Geometry.circle(center, {0, 1, 0}, {0, 0, 1}, r), {1, 0, 0}, class}

  defp disc(center, :far_side, r, class),
    do: {:face, Geometry.circle(center, {0, 1, 0}, {0, 0, 1}, r), {-1, 0, 0}, class}

  # A cylinder that stands at a center.
  defp cylinder(center, r, h, material), do: [{:cyl, center, r, h, material}]

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

  def model("computer") do
    box({0.3, 0.1, 0}, {0.2, 0.15, 0.05}, "dark") ++
      box({0.37, 0.15, 0.05}, {0.06, 0.04, 0.15}, "dark") ++
      box({0, 0.2, 0.2}, {0.8, 0.04, 0.5}, "dark") ++
      [front({0.03, 0.24, 0.23}, {0.74, 0.44}, "i-screen")] ++
      box({0.1, 0.45, 0}, {0.6, 0.22, 0.03}, "gray")
  end

  def model("ceiling_fan") do
    blade = fn corners -> face(corners, {0, 0, 1}, "i-wood-t i-face") end

    # The rod goes up from the middle of the disc: it paints last.
    [
      blade.([{0.5, 0.42, 0.3}, {1.1, 0.42, 0.3}, {1.1, 0.58, 0.3}, {0.5, 0.58, 0.3}]),
      blade.([{0.42, 0.5, 0.3}, {0.42, 1.1, 0.3}, {0.58, 1.1, 0.3}, {0.58, 0.5, 0.3}]),
      blade.([{0.5, 0.42, 0.3}, {-0.1, 0.42, 0.3}, {-0.1, 0.58, 0.3}, {0.5, 0.58, 0.3}]),
      blade.([{0.42, 0.5, 0.3}, {0.42, -0.1, 0.3}, {0.58, -0.1, 0.3}, {0.58, 0.5, 0.3}]),
      disc({0.5, 0.5, 0.31}, :top, 0.13, "i-steel-t")
    ] ++ box({0.47, 0.47, 0.3}, {0.06, 0.06, 0.4}, "steel")
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
          {0, -1, 0.83},
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

  # The icon of a camper van: the model of the Ford Transit.
  def model("camper_van"), do: VanShapes.van("transit_148")

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
