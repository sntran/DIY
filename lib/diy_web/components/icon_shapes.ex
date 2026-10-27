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
  - `{:hull, loop, w, shape, material, faces}`: the body of a vehicle
    (`hull/5`). Its loop is its side profile (`{y, z}`, as for a prism
    along `:x`), from x = 0 to x = w. Its sides lean in over the belt, and
    its edges are round (`hull_inset/3`). Its faces are on its front, its
    top and its back (the windshield, the lights): they paint before its
    sides.

  A shape is `{:poly, corners, class}`. `shapes/2` gives the shapes of an
  icon, and `placed/2` the shapes of an item at the scale of the world
  (`DIYWeb.Cutaway`). A camera shows the faces that look to it.
  """

  alias DIYWeb.{Camera, Geometry}
  alias DIYWeb.Icon.{StationShapes, VanShapes}

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
  The look of an item: the kind of its model. A busbar shows its number of
  positions for wires (`{"dc_bus", ports}`). A power station of a model
  with a look of its own shows that model (`{"power_station", model}`,
  `DIYWeb.Icon.StationShapes`). Each other item has the model of its kind.
  """
  def look(%{type: "dc_bus", params: %{"ports" => ports}}), do: {"dc_bus", ports}

  def look(%{type: "power_station", params: %{"model" => model}}) do
    if model in StationShapes.models(), do: {"power_station", model}, else: "power_station"
  end

  def look(%{type: type}), do: type

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

        {:hull, loop, w, _shape, _material, _faces} ->
          Enum.flat_map(loop, fn {y, z} -> [{0.0, y, z}, {w, y, z}] end)
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

  # How far a cell or a face goes over its next one: 4 mm.
  @seam 0.004

  # A hull (`hull/5`). The faces across it come from the edges of its
  # profile, as on a prism. They paint from the far one to the near one
  # (`paint_order/2`). Each face of the hull paints just after the edge
  # that it is on (`nearest_edge/3`). So a nearer part of the hull still
  # hides it. A face of the hull is on one edge: a shape on the front is in
  # pieces, each on one edge. A piece bends over the next edges a little.
  # So it goes over the part of the next face that goes over it. Thus no
  # thin line of the hull shows between two pieces. Then the cells of the
  # side that looks to the camera paint, and the edge of that side. So a
  # side hides the faces behind it. Each face has a smooth light
  # (`smooth/4`), and no edge of its own: so a round part has no lines. A
  # face is a little longer than its edge of the profile, and a cell goes a
  # little over the next cell. So no thin gap shows between them.
  defp draw_one(
         {:hull, loop, w, shape, material, details},
         %{point: point, normal: turn, camera: camera} = view
       ) do
    inset = fn y, z -> hull_inset(shape, y, z) end
    edges = loop |> Enum.zip(tl(loop) ++ [hd(loop)]) |> Enum.with_index()

    across =
      for {{{ya, za}, {yb, zb}}, i} <- edges,
          len = :math.sqrt((yb - ya) ** 2 + (zb - za) ** 2),
          len > 1.0e-9,
          normal = at(turn, {0, zb - za, ya - yb}),
          Camera.shows?(camera, normal) do
        {ey, ez} = {(yb - ya) / len * @seam, (zb - za) / len * @seam}
        {ia, ib} = {inset.(ya, za), inset.(yb, zb)}

        quad = fn e, f ->
          [
            {ia, ya - e, za - f},
            {w - ia, ya - e, za - f},
            {w - ib, yb + e, zb + f},
            {ib, yb + e, zb + f}
          ]
          |> Enum.map(&at(point, &1))
        end

        {i, {quad.(ey, ez), quad.(0, 0)}, normal}
      end

    # The plane of the profile in the world, as for a prism along x.
    {ax, ay, az} = at(turn, {1, 0, 0})
    k = Enum.find_index([ax, ay, az], &(abs(&1) > 1.0e-9))
    plane = &Tuple.delete_at(&1, k)
    by_index = Map.new(across, fn {i, corners, normal} -> {i, {corners, normal}} end)

    sides =
      across
      |> Enum.map(fn {i, {_wide, corners}, _normal} ->
        middle = Geometry.scale(Geometry.add(Enum.at(corners, 0), Enum.at(corners, 2)), 0.5)

        {Camera.depth(camera, middle),
         {i, {plane.(Enum.at(corners, 0)), plane.(Enum.at(corners, 3))}}}
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    order = paint_order(sides, plane.(camera.eye))
    on = Enum.group_by(details, &nearest_edge(&1, edges, order))

    faces =
      for i <- order,
          {corners, normal} = by_index[i],
          poly <-
            smooth(corners, normal, material, camera) ++
              Enum.flat_map(Map.get(on, i, []), &draw_one(&1, view)),
          do: poly

    side =
      for sign <- [-1, 1],
          normal = at(turn, {sign, 0, 0}),
          Camera.shows?(camera, normal) do
        x = fn y, z -> if sign < 0, do: inset.(y, z), else: w - inset.(y, z) end

        place = fn cell -> Enum.map(cell, fn {y, z} -> at(point, {x.(y, z), y, z}) end) end

        cells =
          for {wide, cell} <- hull_cells(loop, shape),
              normal =
                at(turn, normal(Enum.map(cell, fn {y, z} -> {x.(y, z), y, z} end), {sign, 0, 0})),
              Camera.shows?(camera, normal),
              poly <- smooth({place.(wide), place.(cell)}, normal, material, camera),
              do: poly

        edge = Enum.map(loop, fn {y, z} -> at(point, {x.(y, z), y, z}) end)
        cells ++ [{:poly, edge, "i-outline"}]
      end

    faces ++ List.flatten(side)
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
      # The plane of the loop in the world: the axis is one of x, y and z.
      {ax, ay, az} = at(turn, lift(axis, {0, 0}, 1))
      k = Enum.find_index([ax, ay, az], &(abs(&1) > 1.0e-9))
      plane = &Tuple.delete_at(&1, k)
      middle = fn i -> Geometry.scale(Geometry.add(low.(i), high.(i + 1)), 0.5) end

      sides =
        for {i, true, _normal} <- faces,
            do: {i, {plane.(low.(i)), plane.(low.(i + 1))}}

      sides = Enum.sort_by(sides, fn {i, _side} -> Camera.depth(camera, middle.(i)) end)
      polys = Map.new(body, fn {:poly, [a | _] = corners, class} -> {a, {corners, class}} end)

      for i <- paint_order(sides, plane.(camera.eye)) do
        {corners, class} = polys[low.(i)]
        {:poly, corners, class <> " i-face"}
      end ++ ends
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

  # The light of a face of a hull: the light of its side
  # (`DIYWeb.Camera.side/2`), and over it the light of a top. The more the
  # face looks up, the more of the top it has: none, 1/4, 1/2, 3/4 or all.
  # So a round part goes from its side to its top in steps. The face is a
  # little wide: it goes over the next one. The top over it has its true
  # size: so the top does not paint twice where two faces meet.
  defp smooth({wide, corners}, {nx, ny, nz}, material, camera) do
    up = nz / :math.sqrt(nx * nx + ny * ny + nz * nz)
    step = round(min(max((up - 0.3) / 0.6, 0.0), 1.0) * 4)
    side = "i-#{material}-#{Camera.side(camera, {nx, ny, nz})}"

    case step do
      0 -> [{:poly, wide, side}]
      4 -> [{:poly, wide, "i-#{material}-t"}]
      step -> [{:poly, wide, side}, {:poly, corners, "i-#{material}-t i-o#{step}"}]
    end
  end

  # The edge of the profile of a hull that a face of the hull is on. Of
  # the edges that show, it is the nearest one (in y and z) to the middle
  # of the face. The camera looks down: so the top of a hull always shows.
  defp nearest_edge({:face, corners, _normal, _class}, edges, order) do
    n = length(corners)

    middle =
      {Enum.sum(Enum.map(corners, &elem(&1, 1))) / n,
       Enum.sum(Enum.map(corners, &elem(&1, 2))) / n}

    shown = MapSet.new(order)

    edges
    |> Enum.filter(fn {_edge, i} -> i in shown end)
    |> Enum.min_by(fn {{a, b}, _i} -> distance(middle, a, b) end)
    |> elem(1)
  end

  # The distance from a point to a segment, in a plane.
  defp distance({py, pz}, {ay, az}, {by, bz}) do
    {dy, dz} = {by - ay, bz - az}
    t = min(max(((py - ay) * dy + (pz - az) * dz) / max(dy * dy + dz * dz, 1.0e-12), 0.0), 1.0)
    :math.sqrt((py - ay - t * dy) ** 2 + (pz - az - t * dz) ** 2)
  end

  @doc """
  The normal of a flat shape (Newell), to the side of a direction. So a
  face on a round part looks to where it truly looks.
  """
  def normal(corners, {hx, hy, hz}) do
    {nx, ny, nz} =
      corners
      |> Enum.zip(tl(corners) ++ [hd(corners)])
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {{x1, y1, z1}, {x2, y2, z2}}, {a, b, c} ->
        {a + (y1 - y2) * (z1 + z2), b + (z1 - z2) * (x1 + x2), c + (x1 - x2) * (y1 + y2)}
      end)

    if nx * hx + ny * hy + nz * hz >= 0, do: {nx, ny, nz}, else: {-nx, -ny, -nz}
  end

  # The cells of a side of a hull: its profile cut where the side bends.
  # The cuts in z are at the belt and in the round edge of the roof. The
  # cuts in y are in the round corners at the front and at the back. In a
  # cell, the side is flat, or near it. Each cell comes two times: a little
  # wide (it goes over the next cell), and with its true size.
  defp hull_cells(loop, shape) do
    for {ys, zs} <- hull_boxes(shape),
        cell = band(loop, ys, zs),
        length(cell) >= 3,
        do: {band(loop, wide(ys), wide(zs)), cell}
  end

  defp wide({a, b}), do: {a - @seam, b + @seam}

  # The boxes of y and z of the cells of a side of a hull.
  defp hull_boxes(shape) do
    %{belt: belt, edge: r, nose: n, tail: t, front: f, back: b, top: top} = shape
    zcuts = Enum.uniq([-1.0, belt, top - r, top - r * 0.5, top - r * 0.2, top])
    ycuts = Enum.uniq([b, b + t * 0.25, b + t * 0.5, b + t, f - n, f - n * 0.5, f - n * 0.25, f])

    for {y0, y1} <- Enum.zip(ycuts, tl(ycuts)),
        y1 > y0,
        {z0, z1} <- Enum.zip(zcuts, tl(zcuts)),
        z1 > z0,
        do: {{y0, y1}, {z0, z1}}
  end

  @doc """
  The pieces of a convex shape on a side of a hull (points `{y, z}`).
  They are in the profile of the hull (its loop). The shape is cut where
  the side bends, as the cells of the side: each piece is flat, or near
  it. A piece goes a little over the next one, as a cell.
  """
  def hull_pieces(loop, shape, points) do
    # The turn of the points: counterclockwise is more than 0.
    area =
      points
      |> Enum.zip(tl(points) ++ [hd(points)])
      |> Enum.reduce(0.0, fn {{y1, z1}, {y2, z2}}, sum -> sum + y1 * z2 - y2 * z1 end)

    inside =
      points
      |> Enum.zip(tl(points) ++ [hd(points)])
      |> Enum.reduce(loop, fn {{y1, z1}, {y2, z2}}, part ->
        clip_half(part, fn {y, z} -> -area * ((y2 - y1) * (z - z1) - (z2 - z1) * (y - y1)) end)
      end)

    for {ys, zs} <- hull_boxes(shape),
        piece = band(inside, wide(ys), wide(zs)),
        length(piece) >= 3,
        do: piece
  end

  # The part of a loop in a box of y and z (Sutherland and Hodgman).
  defp band(loop, {y0, y1}, {z0, z1}) do
    loop
    |> clip_half(fn {y, _z} -> y0 - y end)
    |> clip_half(fn {y, _z} -> y - y1 end)
    |> clip_half(fn {_y, z} -> z0 - z end)
    |> clip_half(fn {_y, z} -> z - z1 end)
  end

  # The part of a loop where f is 0 or less.
  defp clip_half([], _f), do: []

  defp clip_half(points, f) do
    points
    |> Enum.zip(tl(points) ++ [hd(points)])
    |> Enum.flat_map(fn {{y1, z1} = a, {y2, z2} = b} ->
      {fa, fb} = {f.(a), f.(b)}
      cut = fn -> {y1 + (y2 - y1) * fa / (fa - fb), z1 + (z2 - z1) * fa / (fa - fb)} end

      cond do
        fa <= 0 and fb <= 0 -> [b]
        fa <= 0 -> [cut.()]
        fb <= 0 -> [cut.(), b]
        true -> []
      end
    end)
  end

  # The order of the paint of the sides of a prism that show: from the far
  # one to the near one. The order is on the plane of the loop, where the
  # eye looks along e. A side is behind a different side when, at a point that
  # both cover (across e), it is farther along e. The sides come in the
  # order of the depth of their middles, and a side that nothing is in
  # front of keeps this order.
  defp paint_order(sides, {ex, ey}) do
    across = fn {x, y} -> ex * y - ey * x end
    along = fn {x, y} -> ex * x + ey * y end

    depth_at = fn {a, b}, c ->
      t = (c - across.(a)) / (across.(b) - across.(a))
      along.(a) + t * (along.(b) - along.(a))
    end

    span = fn {a, b} -> Enum.min_max([across.(a), across.(b)]) end

    # The pairs {far, near}.
    pairs =
      for {i, si} <- sides,
          {j, sj} <- sides,
          i < j,
          {{a0, a1}, {b0, b1}} = {span.(si), span.(sj)},
          {lo, hi} = {max(a0, b0), min(a1, b1)},
          hi - lo > 1.0e-9 do
        c = (lo + hi) / 2
        if depth_at.(si, c) < depth_at.(sj, c), do: {i, j}, else: {j, i}
      end

    sort_far_first(Enum.map(sides, &elem(&1, 0)), pairs)
  end

  # The next side to paint is the first one that has no side behind it
  # that is still to paint. When a number is not exact, each side can have
  # one. Then the next side is the first one with the fewest.
  defp sort_far_first([], _pairs), do: []

  defp sort_far_first(keys, pairs) do
    behind = fn k -> Enum.count(pairs, fn {far, near} -> near == k and far in keys end) end
    next = Enum.min_by(keys, behind)
    [next | sort_far_first(List.delete(keys, next), pairs)]
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

  # The parts of a model. They are public for the models in the modules
  # of the vans and of the stations.

  @doc """
  The hull of a vehicle: its side profile from x = 0 to x = w. The
  profile is a loop of `{y, z}`, counterclockwise when the eye is at the
  large x. The hull has a material, and the faces on its front, its top
  and its back. The shape tells how the hull is round:

  - `belt`: the height where the sides start to lean in;
  - `lean`: how far each side is in at the top of the lean (under the
    round edge of the roof);
  - `edge`: the radius of the round edge of the roof;
  - `nose` and `tail`: the radius of the round corners at the front and at
    the back, seen from above.
  """
  def hull(loop, w, shape, material, faces) do
    {:hull, loop, w, hull_shape(loop, w, shape), material, faces}
  end

  @doc """
  The shape of a hull (`hull/5`) with its box: the front, the back and the
  top of its loop, and its width. `hull_inset/3` takes it.
  """
  def hull_shape(loop, w, shape) do
    {ys, zs} = Enum.unzip(loop)
    Map.merge(shape, %{front: Enum.max(ys), back: Enum.min(ys), top: Enum.max(zs), width: w})
  end

  @doc """
  How far a side of a hull (`hull/5`) is in from its plane, at a point
  `{y, z}` of the side. The plane is x = 0 or x = w. It is the lean over
  the belt, the round edge of the roof and the round corners. It is less
  than half of the width.
  """
  def hull_inset(shape, y, z) do
    %{belt: belt, lean: lean, edge: r, nose: n, tail: t, front: f, back: b, top: top} = shape
    lean = if z > belt, do: lean * min(1.0, (z - belt) / max(top - r - belt, 1.0e-9)), else: 0.0
    plan = max(round_in(n, n - (f - y)), round_in(t, t - (y - b)))
    min(lean + round_in(r, z - (top - r)) + plan, shape.width / 2 - 0.01)
  end

  # How far a round corner of radius r is in, at u into it. It is 0 where
  # it starts (u = 0), and r at its end (u = r).
  defp round_in(r, u) when r <= 0 or u <= 0, do: 0.0
  defp round_in(r, u), do: r - :math.sqrt(r * r - min(u, r) ** 2)

  @doc "A box of a material."
  def box(corner, size, material), do: [{:box, corner, size, material}]

  @doc """
  A rectangle on the front face (y = y) of a box, from x, z. It is a
  little out of the face (1 cm, or less on a small item).
  """
  def front({x, y, z}, {w, h}, class, out \\ 0.01),
    do:
      {:face, Geometry.on_plane({x, y + out, z}, {1, 0, 0}, {0, 0, 1}, {0, 0}, {w, h}), {0, 1, 0},
       class}

  @doc "A rectangle on the side face (x = x) of a box, from y, z."
  def side({x, y, z}, {d, h}, class, out \\ 0.01),
    do:
      {:face, Geometry.on_plane({x + out, y, z}, {0, 1, 0}, {0, 0, 1}, {0, 0}, {d, h}), {1, 0, 0},
       class}

  @doc "A rectangle on a top (z = z), from x, y."
  def top({x, y, z}, {w, d}, class, out \\ 0.01),
    do:
      {:face, Geometry.on_plane({x, y, z + out}, {1, 0, 0}, {0, 1, 0}, {0, 0}, {w, d}), {0, 0, 1},
       class}

  @doc "A disc on the top, on the front or on the side (x)."
  def disc(center, :top, r, class),
    do: {:face, Geometry.circle(center, {1, 0, 0}, {0, 1, 0}, r), {0, 0, 1}, class}

  def disc(center, :front, r, class),
    do: {:face, Geometry.circle(center, {1, 0, 0}, {0, 0, 1}, r), {0, 1, 0}, class}

  def disc(center, :side, r, class),
    do: {:face, Geometry.circle(center, {0, 1, 0}, {0, 0, 1}, r), {1, 0, 0}, class}

  # A cylinder that stands at a center.
  defp cylinder(center, r, h, material), do: [{:cyl, center, r, h, material}]

  @doc "A tube of 24 sides along x or y, from the center of its end near 0."
  def tube({x, y, z}, r, length, axis, material) do
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

  @doc "A box with round corners (a radius r), from a corner and a size."
  def rbox({x, y, z}, {w, d, h}, r, material),
    do: [{:prism, rounded({x, y}, {w, d}, r), z, h, material}]

  @doc """
  A slab with round corners along an axis, from `from` to `from + length`.
  Its corner and its size are in the plane of the two other axes: `{z, x}`
  along y, and `{y, z}` along x.
  """
  def rslab(axis, corner, size, r, from, length, material),
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

  @doc "A polygon with its normal (nil: it always shows)."
  def face(corners, normal, class), do: {:face, corners, normal, class}

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
      box({0.1, d + 0.012, 0.66}, {w - 0.2, 0.038, 0.03}, "steel")
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

  # A washer and dryer in one: the body of a washer, with a wide touch
  # screen in the place of the drawer and the dial.
  def model("washer_dryer") do
    {w, d, h} = {0.71, 0.81, 1.19}
    {cx, cz} = {w / 2, 0.5}

    rbox({0, 0, 0.03}, {w, d, h - 0.03}, 0.03, "white") ++
      box({0.04, d - 0.06, 0}, {w - 0.08, 0.04, 0.03}, "gray") ++
      [
        front({0, d, h - 0.17}, {w, 0.012}, "i-line"),
        front({0.12, d, h - 0.14}, {w - 0.24, 0.09}, "i-black"),
        front({0.16, d + 0.002, h - 0.11}, {0.14, 0.03}, "i-led"),
        disc({cx, d + 0.012, cz}, :front, 0.25, "i-gray-l"),
        disc({cx, d + 0.016, cz}, :front, 0.2, "i-steel-t"),
        disc({cx, d + 0.02, cz}, :front, 0.16, "i-glass"),
        disc({cx - 0.05, d + 0.024, cz + 0.05}, :front, 0.05, "i-shine")
      ]
  end

  # A water heater: a round tank on its foot, with its cap and its label.
  # Two pipes are on its top, and the relief valve is on its side.
  def model("water_heater") do
    {c, r, h} = {0.2795, 0.27, 1.35}

    cylinder({c, c, 0}, 0.24, 0.04, "gray") ++
      cylinder({c, c, 0.04}, r, h, "white") ++
      cylinder({c, c, 0.04 + h}, 0.23, 0.04, "gray") ++
      cylinder({c - 0.1, c, 0.08 + h}, 0.025, 0.14, "copper") ++
      cylinder({c + 0.1, c, 0.08 + h}, 0.025, 0.14, "copper") ++
      [
        face(
          for(
            {x, z} <- [{c - 0.08, 0.7}, {c + 0.08, 0.7}, {c + 0.08, 0.95}, {c - 0.08, 0.95}],
            do: {x, c + r + 0.003, z}
          ),
          {0, 1, 0},
          "i-shade-t i-face"
        )
      ] ++
      box({c + r, c - 0.03, 1.15}, {0.01, 0.06, 0.06}, "copper")
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
    {w, d, h} = {0.46, 0.7, 0.72}

    rbox({0, 0, 0}, {w, d, h}, 0.012, "steel") ++
      cylinder({w / 2, 0.16, h}, 0.07, 0.12, "gray") ++
      [
        front({0.02, d, 0.39}, {w - 0.04, 0.31}, "i-steel-t"),
        front({0.02, d, 0.03}, {w - 0.04, 0.34}, "i-steel-t")
      ] ++
      for(k <- 0..4, do: front({0.08, d + 0.002, 0.47 + k * 0.035}, {w - 0.16, 0.012}, "i-line")) ++
      [
        front({0.17, d + 0.002, 0.2}, {0.12, 0.06}, "i-flame i-fire"),
        front({0.06, d + 0.002, 0.07}, {0.12, 0.07}, "i-white-t")
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
        do: front({0.12 + k * 0.1, d + 0.002, 0.13}, {0.035, 0.35}, "i-hot i-coil")
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
    {w, h, f} = {0.25, 0.36, 0.142}

    rbox({0, 0, 0}, {w, 0.07, h}, 0.02, "gray") ++
      tube({w / 2, 0.07, 0.17}, 0.105, 0.03, :y, "steel") ++
      tube({w / 2, 0.1, 0.17}, 0.09, f - 0.1, :y, "white") ++
      [
        disc({w / 2, f + 0.002, 0.17}, :front, 0.08, "i-glass"),
        front({w / 2 - 0.045, f, 0.17}, {0.09, 0.035}, "i-black", 0.004),
        front({w / 2 - 0.035, f, 0.18}, {0.05, 0.015}, "i-led", 0.006),
        disc({w / 2 - 0.03, f + 0.006, 0.22}, :front, 0.025, "i-shine")
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

    box({0.36, 0.0, 0}, {0.4, 0.25, 0.02}, "dark") ++
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

    box({0.2, 0.0, 0}, {0.21, 0.14, 0.012}, "dark") ++
      box({0.28, 0.04, 0.012}, {0.05, 0.03, 0.14}, "dark") ++
      box({0.005, 0.07, 0.12}, {0.6, 0.025, 0.388}, "dark") ++
      [
        front({0.015, 0.095, 0.135}, {0.58, 0.358}, "i-screen"),
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
      rbox({0.52, d - 0.11, 0}, {0.06, 0.104, 0.03}, 0.025, "white")
  end

  # A CPAP: a body with round corners and a water tank on its side. Its
  # top has a screen and a knob, and its side has the port of its hose.
  def model("cpap") do
    rbox({0.03, 0, 0}, {0.14, 0.152, 0.11}, 0.03, "gray") ++
      rbox({0.17, 0.01, 0}, {0.084, 0.132, 0.085}, 0.025, "blue") ++
      [top({0.06, 0.03, 0.11}, {0.07, 0.05}, "i-screen")] ++
      cylinder({0.14, 0.1, 0.11}, 0.015, 0.017, "dark") ++
      tube({0, 0.076, 0.06}, 0.016, 0.03, :x, "gray")
  end

  # A ceiling fan: four blades under the motor, the bowl of its light under
  # them, and the rod up to the canopy on the ceiling.
  def model("ceiling_fan") do
    {c, z} = {0.66, 0.07}

    blades =
      for k <- 0..3 do
        a = :math.pi() * k / 2

        along = fn t, s ->
          {c + t * :math.cos(a) - s * :math.sin(a), c + t * :math.sin(a) + s * :math.cos(a), z}
        end

        corners = [
          along.(0.12, -0.04),
          along.(0.62, -0.065),
          along.(0.66, 0.0),
          along.(0.62, 0.065),
          along.(0.12, 0.04)
        ]

        face(corners, {0, 0, 1}, "i-wood-t i-face")
      end

    cylinder({c, c, 0}, 0.07, 0.07, "white") ++
      blades ++
      cylinder({c, c, 0.07}, 0.11, 0.1, "steel") ++
      cylinder({c, c, 0.17}, 0.012, 0.09, "steel") ++
      cylinder({c, c, 0.26}, 0.06, 0.045, "steel")
  end

  # A power strip: a white body with round corners, six outlets on its top,
  # and a red switch.
  def model("always_on") do
    {w, d, h} = {0.46, 0.15, 0.064}

    rbox({0, 0, 0}, {w, d, h}, 0.02, "white") ++
      for(
        k <- 0..5,
        part <- [
          top({0.04 + k * 0.062, 0.035, h}, {0.045, 0.08}, "i-gray-t", 0.002),
          top({0.05 + k * 0.062, 0.06, h}, {0.006, 0.025}, "i-black", 0.004),
          top({0.068 + k * 0.062, 0.06, h}, {0.006, 0.025}, "i-black", 0.004)
        ],
        do: part
      ) ++
      box({w - 0.06, 0.045, h}, {0.035, 0.06, 0.012}, "red")
  end

  # A Home Assistant hub (a Home Assistant Green): a dark box with round
  # corners. Its top has the mark of Home Assistant: the outline of a house
  # (a ring), with the dot of its network in the middle. The front has a
  # light. The light shows the state of the link on the plan (`i-ha-light`).
  def model("home_assistant") do
    {w, h} = {0.1016, 0.0254}
    top = h + 0.0005

    # The house: its outside, and its inside (a line of 3.5 mm), as one
    # polygon that goes around the two (a ring).
    outside = [{0.033, 0.07}, {0.069, 0.07}, {0.069, 0.044}, {0.051, 0.029}, {0.033, 0.044}]

    inside = [
      {0.0365, 0.0665},
      {0.0365, 0.0456},
      {0.051, 0.0335},
      {0.0655, 0.0456},
      {0.0655, 0.0665}
    ]

    ring = outside ++ [hd(outside)] ++ inside ++ [hd(inside)]
    dot = [{0.0485, 0.0525}, {0.0535, 0.0525}, {0.0535, 0.0575}, {0.0485, 0.0575}]

    rbox({0, 0, 0}, {w, w, h}, 0.012, "dark") ++
      [
        face(for({x, y} <- ring, do: {x, y, top}), {0, 0, 1}, "i-blue-t"),
        face(for({x, y} <- dot, do: {x, y, top}), {0, 0, 1}, "i-blue-t"),
        front({0.04, w, 0.009}, {0.022, 0.006}, "i-ha-light", 0.0005)
      ]
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
      cylinder({0.35, d / 2, 0.186}, 0.03, 0.09, "white")
  end

  # The heat pump of a pool: a box as the outdoor unit of an AC, but
  # taller. The fan is on its top, and the fins of its coil are on two
  # sides.
  def model("pool_heater") do
    {w, h} = {0.86, 1.0}

    box({0, 0, 0}, {w, w, 0.05}, "dark") ++
      rbox({0.02, 0.02, 0.05}, {w - 0.04, w - 0.04, h - 0.05}, 0.04, "gray") ++
      [
        disc({w / 2, w / 2, h + 0.005}, :top, 0.33, "i-black"),
        disc({w / 2, w / 2, h + 0.01}, :top, 0.08, "i-steel-t"),
        front({0.12, w - 0.02, h - 0.22}, {0.2, 0.08}, "i-glass-dark")
      ] ++
      for(
        k <- 1..7,
        part <- [
          front({0.08, w - 0.02, 0.08 + k * 0.09}, {w - 0.16, 0.012}, "i-line"),
          side({w - 0.02, 0.08, 0.08 + k * 0.09}, {w - 0.16, 0.012}, "i-line")
        ],
        do: part
      )
  end

  # A hot tub: a square shell with round corners, a skirt of wood, and the
  # water in its top.
  def model("hot_tub") do
    {w, h} = {2.13, 0.91}

    rbox({0, 0, 0}, {w, w, h}, 0.2, "wood") ++
      rbox({0.03, 0.03, h}, {w - 0.06, w - 0.06, 0.03}, 0.18, "gray") ++
      rbox({0.16, 0.16, h + 0.03}, {w - 0.32, w - 0.32, 0.01}, 0.12, "blue")
  end

  # A pool: a low coping of stone, and the water in it. On the plan, the
  # water is lower than the floor (`DIYWeb.Cutaway`). This model is for
  # the icon.
  def model("pool") do
    {w, d, h} = {10.36, 5.79, 0.15}

    box({0, 0, 0}, {w, d, h}, "gray") ++
      box({0.6, 0.6, h}, {w - 1.2, d - 1.2, 0.01}, "blue")
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
        do: front({0.06, d - 0.018, 0.12 + k * 0.053}, {w - 0.12, 0.022}, "i-hot i-coil")
      ) ++
      [
        top({0.06, 0.05, h}, {w - 0.12, 0.06}, "i-dark-t"),
        top({0.08, 0.065, h + 0.002}, {0.03, 0.03}, "i-led")
      ]
  end

  # A dehumidifier, as the Midea Cube: a dark box with round corners, with
  # the round grille of its fan on its top. Its front has the strip of its
  # buttons and the window of the water.
  def model("dehumidifier") do
    {w, d, h} = {0.38, 0.355, 0.38}

    rbox({0, 0, 0}, {w, d, h}, 0.03, "dark") ++
      [
        disc({w / 2, d / 2, h + 0.002}, :top, 0.13, "i-gray-t"),
        disc({w / 2, d / 2, h + 0.004}, :top, 0.05, "i-dark-t"),
        front({0.06, d, h - 0.07}, {w - 0.12, 0.03}, "i-black"),
        front({0.08, d + 0.002, h - 0.06}, {0.03, 0.01}, "i-led"),
        front({w / 2 - 0.025, d, 0.06}, {0.05, 0.14}, "i-glass")
      ]
  end

  # A water dispenser with the bottle at the bottom, as the Primo hTrio: a
  # tall dark body on a foot. Its top part has a black recess with a red
  # tap (hot) and a blue tap (cold) over a tray. The door of the bottle is
  # under it. The taps and the tray are flat: a part out of the front
  # paints in the wrong order at some turns.
  def model("water_dispenser") do
    {w, d, h} = {0.31, 0.355, 1.12}

    rbox({0, 0, 0.02}, {w, d, h - 0.02}, 0.03, "dark") ++
      box({0.03, 0.03, 0}, {w - 0.06, d - 0.06, 0.02}, "gray") ++
      [
        front({0.04, d, 0.68}, {w - 0.08, 0.26}, "i-black"),
        front({0, d, 0.6}, {w, 0.012}, "i-line"),
        front({0.03, d, 0.08}, {w - 0.06, 0.48}, "i-glass-dark"),
        front({w / 2 - 0.02, d + 0.002, 1.0}, {0.04, 0.012}, "i-led"),
        front({0.07, d + 0.002, 0.82}, {0.035, 0.06}, "i-red-t"),
        front({w - 0.105, d + 0.002, 0.82}, {0.035, 0.06}, "i-blue-t"),
        front({0.06, d + 0.002, 0.7}, {w - 0.12, 0.02}, "i-gray-l")
      ]
  end

  # A power station on its trolley, as the Pecron F5000LFP. The dark body
  # has round corners, and a grip at each end of its top. Its black front
  # has the inputs at the left, and the screen with its two green buttons.
  # The DC outputs are under the screen, and the AC outputs are at the
  # right. Each group is in an orange frame. The name is under them. Its
  # side has the dust screen and the ports for more batteries. The trolley
  # has a wheel at each corner.
  def model("power_station") do
    {w, d, base, h} = {0.551, 0.381, 0.115, 0.44}
    # The front of the body.
    y = d - 0.006

    # The wheels look to the front. A front wheel shows its gray hub. The
    # tray of the trolley goes up round the foot of the body.
    wheels =
      for {x, wy} <- [
            {0.055, 0.045},
            {w - 0.055, 0.045},
            {0.055, d - 0.071},
            {w - 0.055, d - 0.071}
          ],
          part <-
            tube({x, wy, 0.03}, 0.03, 0.026, :y, "dark") ++
              box({x - 0.022, wy - 0.007, 0.06}, {0.044, 0.04, 0.005}, "gray"),
          do: part

    hubs =
      for x <- [0.055, w - 0.055],
          do: disc({x, d - 0.044, 0.03}, :front, 0.013, "i-gray-t")

    outlet = fn x ->
      [
        front({x, y, 0.34}, {0.04, 0.04}, "i-dark-t", 0.008),
        front({x + 0.011, y, 0.356}, {0.004, 0.012}, "i-black", 0.01),
        front({x + 0.025, y, 0.356}, {0.004, 0.012}, "i-black", 0.01)
      ]
    end

    wheels ++
      hubs ++
      box({0, 0, 0.065}, {w, d, base - 0.065}, "dark") ++
      rbox({0.006, 0.006, base}, {w - 0.012, d - 0.012, h - base}, 0.035, "dark") ++
      [
        top({0.03, 0.08, h}, {0.035, d - 0.16}, "i-dark-r", 0.002),
        top({w - 0.065, 0.08, h}, {0.035, d - 0.16}, "i-dark-r", 0.002),
        front({0.045, y, 0.262}, {0.461, 0.145}, "i-black", 0.002),
        # The DC input and the AC input.
        front({0.056, y, 0.352}, {0.078, 0.045}, "i-orange-l", 0.004),
        front({0.059, y, 0.355}, {0.072, 0.035}, "i-dark-l", 0.006),
        front({0.072, y, 0.366}, {0.012, 0.014}, "i-black", 0.008),
        front({0.106, y, 0.366}, {0.012, 0.014}, "i-black", 0.008),
        front({0.056, y, 0.272}, {0.078, 0.072}, "i-orange-l", 0.004),
        front({0.059, y, 0.275}, {0.072, 0.062}, "i-dark-l", 0.006),
        disc({0.095, y + 0.008, 0.306}, :front, 0.016, "i-black"),
        # The screen and its buttons.
        front({0.146, y, 0.33}, {0.094, 0.068}, "i-dark-l", 0.004),
        front({0.152, y, 0.336}, {0.082, 0.056}, "i-black", 0.006),
        front({0.158, y, 0.344}, {0.016, 0.04}, "i-white-t", 0.008)
      ] ++
      for(k <- 0..2, do: front({0.188, y, 0.376 - k * 0.014}, {0.038, 0.005}, "i-white-t", 0.008)) ++
      [
        disc({0.256, y + 0.006, 0.378}, :front, 0.009, "i-led"),
        disc({0.256, y + 0.006, 0.35}, :front, 0.009, "i-led"),
        # The DC outputs.
        front({0.146, y, 0.272}, {0.126, 0.048}, "i-orange-l", 0.004),
        front({0.149, y, 0.275}, {0.12, 0.036}, "i-black", 0.006)
      ] ++
      for(k <- 0..4, do: front({0.158 + k * 0.021, y, 0.288}, {0.012, 0.008}, "i-steel-t", 0.008)) ++
      [
        # The AC outputs: four outlets, the TT-30 and the L14-30.
        front({0.284, y, 0.272}, {0.216, 0.126}, "i-orange-l", 0.004),
        front({0.287, y, 0.275}, {0.21, 0.114}, "i-black", 0.006)
      ] ++
      Enum.flat_map(0..3, &outlet.(0.296 + &1 * 0.051)) ++
      [
        disc({0.33, y + 0.008, 0.302}, :front, 0.024, "i-dark-t"),
        disc({0.45, y + 0.008, 0.302}, :front, 0.026, "i-orange-l"),
        disc({0.45, y + 0.01, 0.302}, :front, 0.021, "i-dark-t"),
        # The name plate, and the name of the model in orange.
        front({0.2, y, 0.19}, {0.15, 0.04}, "i-dark-r", 0.002),
        front({0.215, y, 0.203}, {0.12, 0.014}, "i-white-t", 0.004),
        front({0.235, y, 0.17}, {0.08, 0.011}, "i-orange-l", 0.002),
        # The dust screen and the ports for more batteries, on the side.
        side({w - 0.006, 0.06, 0.25}, {0.24, 0.15}, "i-black", 0.002)
      ] ++
      for(
        k <- 0..9,
        do: side({w - 0.006, 0.068 + k * 0.023, 0.256}, {0.008, 0.138}, "i-dark-l", 0.004)
      ) ++
      [
        side({w - 0.006, 0.145, 0.135}, {0.04, 0.06}, "i-dark-t", 0.002),
        side({w - 0.006, 0.195, 0.135}, {0.04, 0.06}, "i-dark-t", 0.002)
      ]
  end

  # A power station of a model with a look of its own.
  def model({"power_station", model}), do: StationShapes.model(model)

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
    {w, d, h} = {0.38, 0.13, 0.46}

    cylinder({w / 2, 0.06, h}, 0.025, 0.048, "gray") ++
      rbox({0, 0, 0}, {w, d, h}, 0.02, "gray") ++
      [
        front({0.03, d, 0.03}, {0.24, h - 0.06}, "i-steel-t", 0.003),
        front({0.05, d, 0.18}, {0.2, 0.22}, "i-black", 0.005)
      ] ++
      for(
        row <- 0..1,
        col <- 0..3,
        do: front({0.065 + col * 0.045, d, 0.2 + row * 0.1}, {0.03, 0.06}, "i-steel-l", 0.007)
      ) ++
      [front({0.05, d, 0.06}, {0.14, 0.08}, "i-white-t", 0.005)] ++
      box({0.3, d, 0.2}, {0.045, 0.048, 0.16}, "red")
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
               {x, z} <- [{0.1, 0.62}, {w - 0.1, 0.62}, {w - 0.1, 0.74}, {0.1, 0.74}],
               do: {x, -0.004, z}
             ),
             {0, -1, 0},
             "i-black"
           )
         ] ++
         for(
           x <- [0.12, w - 0.47],
           do:
             face(
               for(
                 {dx, z} <- [{0.0, 0.64}, {0.35, 0.64}, {0.35, 0.72}, {0.0, 0.72}],
                 do: {x + dx, -0.006, z}
               ),
               {0, -1, 0},
               "i-hot"
             )
         ) ++ sides}
    ]
  end

  # The icon of a camper van: the model of the Ford Transit.
  def model("camper_van"), do: VanShapes.van("transit_148")

  # A captain seat on its swivel: the seat and the back have round corners,
  # with a headrest and two armrests.
  def model("swivel_seat") do
    {w, d} = {0.66, 0.66}

    cylinder({w / 2, d / 2 + 0.02, 0}, 0.24, 0.06, "dark") ++
      cylinder({w / 2, d / 2 + 0.02, 0.06}, 0.08, 0.14, "dark") ++
      rbox({0.0, 0.04, 0.2}, {w, d - 0.04, 0.14}, 0.07, "cloth") ++
      rbox({0.04, 0.0, 0.34}, {w - 0.08, 0.15, 0.52}, 0.06, "cloth") ++
      rbox({0.2, 0.02, 0.86}, {0.26, 0.11, 0.156}, 0.05, "cloth") ++
      box({0.06, 0.15, 0.5}, {0.06, 0.36, 0.05}, "dark") ++
      box({w - 0.12, 0.15, 0.5}, {0.06, 0.36, 0.05}, "dark")
  end

  # A DC to DC charger: a dark body with round corners and fins on its top.
  # It has its label, and the red and black cables at its end.
  def model("dc_charger") do
    {w, d, h} = {0.138, 0.073, 0.124}

    rbox({0, 0, 0}, {w, d, h}, 0.008, "dark") ++
      for(
        k <- 0..3,
        do: top({0.012 + k * 0.034, 0.008, h}, {0.012, d - 0.016}, "i-gray-t", 0.002)
      ) ++
      [
        front({0.02, d, 0.035}, {0.1, 0.05}, "i-white-t", 0.002),
        front({0.03, d, 0.07}, {0.02, 0.008}, "i-led", 0.003)
      ] ++
      tube({w, 0.022, 0.03}, 0.007, 0.04, :x, "red") ++
      tube({w, 0.051, 0.03}, 0.007, 0.04, :x, "dark")
  end

  # A fridge of 12 V: a gray chest with round corners, and a dark lid with
  # its handle. The panel with its display is on the front.
  def model("van_fridge") do
    {w, d, h} = {0.41, 0.605, 0.48}

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
      cylinder({w / 2, 0.06, h}, 0.018, 0.2, "steel") ++
      tube({w / 2, 0.078, h + 0.18}, 0.014, 0.09, :y, "steel")
  end

  # A tank of fresh water: a white tank with round corners, the line of the
  # water in it, its cap, and its fittings.
  def model("water_tank") do
    {w, d, h} = {0.57, 0.37, 0.326}

    rbox({0, 0, 0}, {w, d, h}, 0.05, "white") ++
      [
        front({0.04, d, 0.04}, {w - 0.08, 0.22}, "i-glass"),
        front({0.04, d + 0.002, 0.26}, {w - 0.08, 0.008}, "i-line")
      ] ++
      cylinder({0.15, 0.15, h}, 0.05, 0.03, "blue") ++
      tube({w, 0.12, 0.05}, 0.015, 0.04, :x, "white") ++
      tube({w, 0.26, 0.05}, 0.015, 0.04, :x, "white")
  end

  # A water pump: the motor lies along x, and the pump head is black. The
  # fitting of the water in is at its back, and the fitting of the water out
  # is at its front. The two fittings are blue.
  def model("water_pump") do
    {d, c} = {0.127, 0.054}

    box({0.02, 0.02, 0}, {0.16, d - 0.04, 0.004}, "dark") ++
      tube({0.0, d / 2, c}, 0.05, 0.14, :x, "steel") ++
      tube({0.14, d / 2, c}, 0.045, 0.063, :x, "dark") ++
      tube({0.17, 0.0, 0.07}, 0.012, d / 2 - 0.045, :y, "blue") ++
      tube({0.17, d / 2 + 0.045, 0.07}, 0.012, d / 2 - 0.045, :y, "blue")
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
    {w, d, h} = {0.91, 0.043, 0.61}
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
        front({0.2, d, 0.02}, {0.08, 0.02}, "i-gray-l", 0.008),
        front({w - 0.28, d, 0.02}, {0.08, 0.02}, "i-gray-l", 0.008)
      ]
  end

  # Lights of a van: three round lights, each with its bulb.
  def model("van_lights") do
    for(
      x <- [0.052, 0.152, 0.252],
      part <-
        cylinder({x, 0.051, 0}, 0.05, 0.023, "steel") ++
          [disc({x, 0.051, 0.025}, :top, 0.036, "i-bulb")],
      do: part
    )
  end

  # The devices: a laptop with its keyboard, its pad and its screen, and a
  # phone with its screen.
  def model("devices") do
    w = 0.27

    rbox({0, 0.06, 0}, {w, 0.19, 0.015}, 0.01, "gray") ++
      [
        top({0.015, 0.075, 0.015}, {w - 0.03, 0.09}, "i-dark-t", 0.001),
        top({w / 2 - 0.045, 0.18, 0.015}, {0.09, 0.055}, "i-gray-r", 0.001),
        face(
          [{0, 0.06, 0.015}, {w, 0.06, 0.015}, {w, 0.0, 0.25}, {0, 0.0, 0.25}],
          nil,
          "i-dark-l"
        ),
        face(
          [
            {0.012, 0.063, 0.03},
            {w - 0.012, 0.063, 0.03},
            {w - 0.012, 0.006, 0.24},
            {0.012, 0.006, 0.24}
          ],
          {0, 1, 0.26},
          "i-screen"
        )
      ] ++
      rbox({0.29, 0.12, 0}, {0.066, 0.13, 0.01}, 0.012, "dark") ++
      [top({0.295, 0.128, 0.01}, {0.056, 0.114}, "i-screen", 0.001)]
  end

  # A diesel heater: the round body lies along x, with its two end caps and
  # the pipe of its exhaust.
  def model("diesel_heater") do
    r = 0.0635

    tube({0.0, r, r}, r, 0.02, :x, "dark") ++
      tube({0.02, r, r}, r, 0.2, :x, "red") ++
      tube({0.22, r, r}, r, 0.03, :x, "dark") ++
      tube({0.25, r, r}, 0.025, 0.055, :x, "steel")
  end

  # A CO alarm: a round white body with a dome, its vents and its light.
  def model("co_alarm") do
    c = 0.065

    cylinder({c, c, 0}, 0.064, 0.03, "white") ++
      cylinder({c, c, 0.03}, 0.045, 0.02, "white") ++
      for(
        k <- 0..2,
        do: top({c - 0.03, c - 0.012 + k * 0.012, 0.05}, {0.06, 0.005}, "i-line", 0.001)
      ) ++
      [disc({c + 0.052, c, 0.031}, :top, 0.006, "i-led")]
  end

  # A bed on its platform: the platform has drawers, and the mattress has
  # round corners, a duvet and two pillows.
  def model("bed_platform") do
    {w, d} = {1.52, 1.89}

    box({0, 0, 0}, {w, d, 0.36}, "wood") ++
      for(
        k <- 0..1,
        part <- [
          front({0.08 + k * (w / 2), d, 0.06}, {w / 2 - 0.12, 0.24}, "i-wood-t"),
          front({0.28 + k * (w / 2), d + 0.002, 0.2}, {0.2, 0.025}, "i-dark-l")
        ],
        do: part
      ) ++
      rbox({0.02, 0.02, 0.36}, {w - 0.04, d - 0.04, 0.15}, 0.08, "white") ++
      rbox({0.02, 0.6, 0.51}, {w - 0.04, d - 0.62, 0.03}, 0.08, "cloth") ++
      rbox({0.12, 0.08, 0.51}, {0.58, 0.36, 0.1}, 0.08, "white") ++
      rbox({w - 0.7, 0.08, 0.51}, {0.58, 0.36, 0.1}, 0.08, "white")
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
    {w, d, h} = {0.33, 0.166, 0.204}

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

  # A battery switch, as the Victron battery switch: a black body with a
  # red knob and its handle on the top.
  def model("battery_switch") do
    {w, d, h} = {0.076, 0.076, 0.076}

    rbox({0, 0, 0}, {w, d, h * 0.6}, 0.008, "dark") ++
      cylinder({w / 2, d / 2, h * 0.6}, 0.024, h * 0.2, "red") ++
      box({w / 2 - 0.02, d / 2 - 0.006, h * 0.8}, {0.04, 0.012, h * 0.2}, "red")
  end

  # A battery monitor, as the Victron SmartShunt: a long blue body, a bolt
  # for a cable at each end, and its label in front.
  def model("battery_monitor") do
    {w, d, h} = {0.127, 0.041, 0.051}

    rbox({0.018, 0, 0}, {w - 0.036, d, h}, 0.006, "blue") ++
      box({0, 0.008, 0}, {0.018, d - 0.016, h * 0.4}, "steel") ++
      box({w - 0.018, 0.008, 0}, {0.018, d - 0.016, h * 0.4}, "steel") ++
      cylinder({0.009, d / 2, h * 0.4}, 0.005, 0.014, "steel") ++
      cylinder({w - 0.009, d / 2, h * 0.4}, 0.005, 0.014, "steel") ++
      [front({0.03, d, h * 0.35}, {w - 0.06, h * 0.4}, "i-white-t")]
  end

  # An inverter and charger: a blue body with round corners, its window with
  # a display and lights, its switch, and the fins on its side.
  def model("inverter") do
    {w, d, h} = {0.244, 0.217, 0.356}

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

  # A busbar with fuse holders, as the Victron Lynx Distributor, on a
  # wall: a blue case with an end cap at each side. The red cap (+) and
  # the black cap (-) of its busbars come out at the left. The front has
  # the orange line of Victron, and a row of lights. Each position has a
  # gray light, and the green light of the power is in the middle. The white
  # lines of its label are under the lights. A hood for the cables of two
  # positions is at the bottom, with a dark port for the cable of each
  # position. A small block is between the two hoods in the middle. The
  # black base shows at the right side. The positions share the width of
  # the case, so each number of positions has the same size.
  def model("dc_bus"), do: model({"dc_bus", 4})

  def model({"dc_bus", ports}) do
    {w, d, h} = {0.29, 0.078, 0.17}
    # The front of the middle part, and the front of the end caps.
    {y, cap} = {0.062, 0.07}
    {x0, x1} = {0.082, 0.234}
    # The green light is in the middle, with half of the gray lights at
    # each side of it.
    middle = (x0 + x1) / 2
    {left, right} = {div(ports, 2), ports - div(ports, 2)}
    pitch = min((middle - x0) / max(left, 1), (x1 - middle) / right)
    r = min(0.0035, pitch * 0.3)
    light = fn x -> disc({x, y + 0.002, 0.1}, :front, r, "i-off") end

    lights =
      [disc({middle, y + 0.002, 0.1}, :front, 0.0035, "i-led")] ++
        for(k <- 0..(left - 1)//1, do: light.(x0 + (middle - x0) * k / left)) ++
        for(k <- 1..right//1, do: light.(middle + (x1 - middle) * k / right))

    hoods = div(ports + 1, 2)
    span = (x1 - x0 + 0.01) / hoods
    # The small block in the gap between the two hoods in the middle.
    gap = min(0.012, span * 0.16)

    block =
      if rem(hoods, 2) == 0,
        do: rslab(:y, {0, middle - gap / 2}, {0.02, gap}, gap / 4, y, 0.008, "victron"),
        else: []

    arrow = fn tip, back ->
      face(
        [{tip, y + 0.002, 0.1}, {back, y + 0.002, 0.096}, {back, y + 0.002, 0.104}],
        {0, 1, 0},
        "i-white-t"
      )
    end

    box({0, 0.018, 0.1}, {0.024, 0.04, 0.042}, "red") ++
      box({0, 0.018, 0.028}, {0.024, 0.04, 0.042}, "dark") ++
      rslab(:y, {0.008, 0.024}, {h - 0.008, 0.036}, 0.01, 0, cap, "victron") ++
      rslab(:y, {0.018, 0.06}, {h - 0.026, w - 0.096}, 0.006, 0, y, "victron") ++
      rslab(:y, {0.008, w - 0.036}, {h - 0.008, 0.036}, 0.01, 0, cap, "victron") ++
      Enum.flat_map(0..(hoods - 1), fn k ->
        x = x0 - 0.005 + k * span + span * 0.1
        rslab(:y, {0, x}, {0.045, span * 0.8}, min(0.012, span * 0.25), y, d - y, "victron")
      end) ++
      block ++
      ports(ports, hoods, x0 - 0.005 + span * 0.1, span, d) ++
      [
        front({0.074, y, 0.136}, {0.042, 0.005}, "i-white-t", 0.002),
        front({0.07, y, 0.112}, {0.174, 0.008}, "i-stripe", 0.002),
        arrow.(0.067, 0.073),
        arrow.(0.249, 0.243)
      ] ++
      lights ++
      [
        front({0.07, y, 0.09}, {0.174, 0.0015}, "i-white-t", 0.002),
        front({0.072, y, 0.076}, {0.06, 0.006}, "i-white-t", 0.002),
        front({0.072, y, 0.058}, {0.028, 0.01}, "i-white-t", 0.002),
        front({0.07, y, 0.05}, {0.174, 0.0015}, "i-white-t", 0.002),
        disc({0.042, cap + 0.001, 0.1}, :front, 0.004, "i-black"),
        disc({w - 0.018, cap + 0.001, 0.1}, :front, 0.004, "i-black"),
        side({w, 0.006, 0.03}, {0.058, 0.12}, "i-black", 0.001)
      ]
  end

  # A shore power inlet: a square plate with round corners, and the round
  # socket in its yellow ring, with its three pins.
  def model("shore_power") do
    {w, d, h} = {0.15, 0.08, 0.15}

    rslab(:y, {0, 0}, {h, w}, 0.02, 0, 0.02, "gray") ++
      tube({w / 2, 0.02, 0.07}, 0.05, d - 0.03, :y, "gray") ++
      [
        disc({w / 2, d - 0.009, 0.07}, :front, 0.047, "i-flame"),
        disc({w / 2, d - 0.008, 0.07}, :front, 0.038, "i-black")
      ] ++
      for(
        {x, z} <- [{-0.015, 0.08}, {0.015, 0.08}, {0.0, 0.055}],
        do: disc({w / 2 + x, d - 0.006, z}, :front, 0.006, "i-steel-t")
      )
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
    {w, d, h} = {1.22, 0.046, 0.91}

    box({0, 0, 0}, {w, d, h}, "light-wood") ++
      for(k <- 1..5, do: front({0, d, k * h / 6}, {w, 0.01}, "i-line", 0.004)) ++
      for(
        k <- 0..5,
        do:
          front(
            {if(rem(k, 2) == 0, do: 0.4, else: 0.8), d, k * h / 6},
            {0.008, h / 6},
            "i-line",
            0.004
          )
      )
  end

  # The floor of a van: planks of light wood with their joints, in a
  # pattern of bricks.
  def model("van_floor") do
    {w, d, h} = {1.22, 1.22, 0.025}

    box({0, 0, 0}, {w, d, h}, "light-wood") ++
      for(k <- 1..7, do: top({0, k * d / 8, h}, {w, 0.008}, "i-line", 0.001)) ++
      for(
        k <- 0..7,
        do:
          top(
            {if(rem(k, 2) == 0, do: 0.4, else: 0.8), k * d / 8, h},
            {0.008, d / 8},
            "i-line",
            0.001
          )
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

  # The ports of a busbar: a dark opening for the cable of each position,
  # at the foot of the front of its hood. The cables come in from under
  # the hood. A hood has the cables of two positions (the last hood has
  # one when the count is odd).
  defp ports(ports, hoods, x0, span, d) do
    for k <- 0..(hoods - 1),
        count = min(2, ports - 2 * k),
        j <- 0..(count - 1) do
      width = span * 0.8 / count
      {cx, w} = {x0 + k * span + width * (j + 0.5), width * 0.55}
      loop = rounded({cx - w / 2, 0.0}, {w, 0.012}, 0.004)
      face(for({u, v} <- loop, do: {u, d + 0.001, v}), {0, 1, 0}, "i-black")
    end
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
