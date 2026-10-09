defmodule DIYWeb.Cutaway do
  @moduledoc """
  The plan of the house at scale, as a house that is cut open. Each floor
  is a layer, with a gap between the layers. The layers go from the ground
  (the lot, outside and floor 1) up to the attic and the roof. Each room shows at
  its place and its size. Each item shows at its place, its size and its
  turn (`DIY.Layout`). The walls on the outside at the back are cut at
  the height of a table. The other walls are cut near the floor.

  The page moves the items and the rooms with a script (the hook Plan,
  `assets/js/plan.js`). The SVG gives the script what it needs:

  - the SVG: `data-k`, the SVG units of one inch along `x`, along `y`, and
    up (`z`); and `data-fit`, the box of all the layers;
  - each surface of a room: `data-room`, `data-plan` (`x y w d`, inches)
    and `data-origin`. The origin is the SVG point of the plan point 0, 0
    on the surface of the room. A roof also has `data-rise`: the height of
    its ridge over its eaves, in inches;
  - each item: `data-item`, `data-in` (its room) and `data-at` (the
    center of the item on the plan, in inches);
  - each layer: `data-box` (its box in the SVG), for a zoom to the layer.

  The math of the points is in `DIYWeb.Iso` (one unit is a meter), and
  the models of the items in `DIYWeb.Icon.Shapes`.
  """
  use DIYWeb, :html

  alias DIY.{Catalog, Layout}
  alias DIYWeb.Icon.Shapes
  alias DIYWeb.Iso

  # One inch in meters.
  @m 0.0254
  # The SVG units of one inch along x, along y and up (`DIYWeb.Iso`).
  @k {8.66 * @m, 5.0 * @m, 10.0 * @m}
  # The pitch of a roof (5 in 12). Then, in meters: the height of the cut
  # of a wall at the back and at the front. Then the thickness of a wall
  # and of a floor.
  @pitch 5 / 12
  @wall 1.1
  @low 0.25
  @thick 0.12
  @slab 0.2

  @doc "The SVG units of one inch: along x, along y, and up."
  def k, do: @k

  @doc """
  The layers of the cut-open house, from the bottom to the top, and the
  box of the SVG. A layer has its `id`, its `name` and its height `z`
  (meters). Then it has its parts in the order of the paint:

  - the lot (`ground`), and the surfaces of the rooms outside (`low`);
  - the slabs, and the surfaces of the other rooms (`rooms`);
  - the walls and the items (`objects`, from the back to the front);
  - the names of the rooms (`labels`).
  """
  def view(build) do
    house = build |> Layout.house_box() |> meters()
    gap = (house.w + house.d) / 2 + 2.0
    by_layer = build.rooms |> Enum.filter(& &1.plan) |> Enum.group_by(&Layout.layer/1)
    items = Enum.group_by(build.items, & &1.room)
    floors = build.house.floors

    layers =
      [{"ground", "Floor 1 and outside", 0.0}] ++
        for(f <- 2..floors//1, do: {"f#{f}", "Floor #{f}", (f - 1) * gap}) ++
        [{"attic", "Attic", floors * gap}, {"roof", "Roof", (floors + 1) * gap}]

    levels =
      for {id, name, z} <- layers,
          rooms = Map.get(by_layer, id, []),
          id in ["ground", "f2", "f3"] or rooms != [] do
        level(id, name, z, rooms, items, house)
      end

    %{levels: levels, box: around(Enum.map(levels, & &1.box), 4.0)}
  end

  defp meters(%{x: x, y: y, w: w, d: d}), do: %{x: x * @m, y: y * @m, w: w * @m, d: d * @m}

  defp level(id, name, z, rooms, items, house) do
    floor_z = fn room -> z + floor_height(id, room) end
    {outdoor, indoor} = Enum.split_with(rooms, &(id == "ground" and &1.place == :outdoor))
    low = Enum.map(outdoor, &room_view(&1, floor_z.(&1)))
    others = Enum.map(indoor, &room_view(&1, floor_z.(&1)))
    {ground, slabs, walls} = shell(id, z, rooms, house, floor_z)

    item_views =
      for room <- rooms,
          item <- Map.get(items, room.id, []),
          do: item_view(item, room, floor_z.(room))

    objects = Iso.order(walls ++ item_views)

    polys =
      Enum.map(ground ++ slabs, &elem(&1, 0)) ++
        Enum.flat_map(low ++ others ++ objects, fn part ->
          Enum.map(part.polys, fn {corners, _class} -> corners end)
        end)

    %{
      id: id,
      name: name,
      z: z,
      ground: Enum.map(ground, &svg/1),
      low: Enum.map(low, &svg_polys/1),
      slabs: Enum.map(slabs, &svg/1),
      rooms: Enum.map(others, &svg_polys/1),
      objects: Enum.map(objects, &svg_polys/1),
      labels: Enum.map(rooms, &label(&1, floor_z.(&1))),
      box: bounds(polys)
    }
  end

  # The height of the floor of a room over its layer. Floor 1 is on its
  # slab, a garage is on a lower slab, and a yard is on the ground.
  defp floor_height("ground", %{level: "f1"}), do: @slab
  defp floor_height("ground", %{place: :outdoor}), do: 0.02
  defp floor_height("ground", _room), do: 0.1
  defp floor_height(_layer, _room), do: 0.0

  defp svg({corners, class}), do: {Iso.points({0, 0}, corners), class}
  defp svg_polys(part), do: %{part | polys: Enum.map(part.polys, &svg/1)}

  ## The shell: the lot, the slabs and the walls

  # The lot (on the ground), a slab under each room, and the walls of the
  # rooms inside (as objects, `walls/3`). A yard is on the ground: it has
  # no slab. A floor with no room has the slab of the house.
  defp shell("roof", _z, _rooms, _house, _floor_z), do: {[], [], []}

  defp shell(id, z, rooms, house, floor_z) do
    on_slab = Enum.reject(rooms, &(id == "ground" and &1.place == :outdoor))

    slabs =
      if on_slab == [] and id != "ground",
        do: slab(house, z - @slab, z),
        else:
          on_slab
          |> Enum.map(&slab_object(&1, id, z, floor_z.(&1)))
          |> Iso.order()
          |> Enum.flat_map(& &1.polys)

    high = if id == "attic", do: 0.5, else: @wall
    inside = Enum.filter(rooms, &(&1.place == :indoor))
    walls = walls(id, inside, fn room -> {floor_z.(room), high} end)
    {lot(id, rooms, house), slabs, walls}
  end

  defp lot("ground", rooms, house) do
    lot = rooms |> Enum.map(&meters(&1.plan)) |> Kernel.++([house]) |> box_of() |> grow(1.6)
    faces(Iso.box({lot.x, lot.y, -0.45}, {lot.w, lot.d, 0.45}), "p-lot")
  end

  defp lot(_id, _rooms, _house), do: []

  # The slab under a room: on the ground, up to the floor of the room; on a
  # floor, under it. The slab is larger than the room: the walls stand on it.
  defp slab_object(room, id, z, floor) do
    p = meters(room.plan)
    low = if id == "ground", do: z, else: floor - @slab
    polys = slab(p, low, floor)
    {cx, cy} = {p.x + p.w / 2, p.y + p.d / 2}

    %{
      id: room.id,
      box: {p.x - @thick, p.y - @thick, low, p.x + p.w + @thick, p.y + p.d + @thick, floor},
      key: cx + cy,
      loose: false,
      polys: polys
    }
  end

  defp slab(b, low, high),
    do:
      faces(
        Iso.box(
          {b.x - @thick, b.y - @thick, low},
          {b.w + 2 * @thick, b.d + 2 * @thick, high - low}
        ),
        "p-slab"
      )

  # The walls of the rooms of a layer: on each side of each room. A wall
  # between two rooms is low, and only the room in front of it draws it. A
  # wall on the outside is low at the front (x1 and y1). At the back (x0
  # and y0), it is high where no room of the layer is behind it. `base`
  # gives the floor of a room and the height of a high wall (meters).
  defp walls(id, rooms, base) do
    for room <- rooms,
        side <- ~w(x0 y0 x1 y1),
        {{a, b, kind}, i} <- Enum.with_index(spans(room, side, rooms)) do
      {floor, high} = base.(room)
      height = if kind == :high, do: high, else: @low
      wall("#{id}-#{room.id}-#{side}-#{i}", room, side, {a, b, kind}, floor, height)
    end
  end

  # The parts of a side of a room, in inches along the side. Each part has
  # its kind: :high, :low, or :shared (a low wall between two rooms).
  defp spans(room, side, rooms) do
    others = Enum.reject(rooms, &(&1.id == room.id))
    {line, range} = edge(room.plan, side)
    touch = for o <- others, across(o.plan, side) == line, do: along(o.plan, side)
    back? = side in ~w(x0 y0)

    for {a, b, shared?} <- split(range, touch),
        part <- span(a, b, shared?, back?, behind(others, side, line)),
        do: part
  end

  defp span(a, b, true, true, _behind), do: [{a, b, :shared}]
  defp span(_a, _b, true, false, _behind), do: []
  defp span(a, b, false, false, _behind), do: [{a, b, :low}]

  defp span(a, b, false, true, behind) do
    for {p, q, hidden?} <- split({a, b}, behind),
        do: {p, q, if(hidden?, do: :low, else: :high)}
  end

  # The line of a side of a plan, and its range along the side.
  defp edge(p, "x0"), do: {p.x, {p.y, p.y + p.d}}
  defp edge(p, "x1"), do: {p.x + p.w, {p.y, p.y + p.d}}
  defp edge(p, "y0"), do: {p.y, {p.x, p.x + p.w}}
  defp edge(p, "y1"), do: {p.y + p.d, {p.x, p.x + p.w}}

  # The line of the side of a different plan that can touch this side.
  defp across(p, "x0"), do: p.x + p.w
  defp across(p, "x1"), do: p.x
  defp across(p, "y0"), do: p.y + p.d
  defp across(p, "y1"), do: p.y

  defp along(p, side) when side in ~w(x0 x1), do: {p.y, p.y + p.d}
  defp along(p, _side), do: {p.x, p.x + p.w}

  # The ranges of the rooms behind the line of a side at the back.
  defp behind(others, side, line),
    do: for(o <- others, across(o.plan, side) <= line, do: along(o.plan, side))

  # A range in parts: each part is in the ranges `by`, or out of all of
  # them. The parts that are next to each other and of the same kind join.
  defp split({a, b}, by) do
    [a, b | Enum.flat_map(by, &Tuple.to_list/1)]
    |> Enum.filter(&(&1 >= a and &1 <= b))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [p, q] -> {p, q, Enum.any?(by, fn {c, d} -> c < q and p < d end)} end)
    |> Enum.chunk_by(&elem(&1, 2))
    |> Enum.map(fn parts ->
      {elem(hd(parts), 0), elem(List.last(parts), 1), elem(hd(parts), 2)}
    end)
  end

  # A wall on a side of a room. A wall on the outside stands just out of
  # the room, and fills the corner. A wall between two rooms stands on the
  # line between them. For the order of the paint, a wall is flat, on its
  # line. So an item in the room is in front of a wall at the back, and
  # behind a wall at the front.
  defp wall(id, room, side, {a, b, kind}, z, height) do
    {line, {r0, r1}} = edge(room.plan, side)
    t = @thick / @m
    # The ends of an outside wall on x go past the corners of the room.
    {a, b} =
      if side in ~w(x0 x1) and kind != :shared,
        do: {if(a == r0, do: a - t, else: a), if(b == r1, do: b + t, else: b)},
        else: {a, b}

    near =
      case {side, kind} do
        {_side, :shared} -> line - t / 2
        {side, _kind} when side in ~w(x0 y0) -> line - t
        _front -> line
      end

    {corner, size, flat} =
      if side in ~w(x0 x1),
        do: {{near, a, 0}, {t, b - a, 0}, {line, a, line, b}},
        else: {{a, near, 0}, {b - a, t, 0}, {a, line, b, line}}

    {cx, cy, _} = corner
    {sw, sd, _} = size
    {ox0, oy0, ox1, oy1} = flat

    %{
      id: id,
      kind: :wall,
      loose: false,
      box: {ox0 * @m, oy0 * @m, z, ox1 * @m, oy1 * @m, z + height},
      key: (ox0 + ox1 + oy0 + oy1) / 2 * @m,
      polys: faces(Iso.box({cx * @m, cy * @m, z}, {sw * @m, sd * @m, height}), "p-wall")
    }
  end

  defp faces(box, class),
    do: [{box.left, class <> "-l"}, {box.right, class <> "-r"}, {box.top, class <> "-t"}]

  ## The rooms

  # A room: its floor (or, for a roof, its two slopes and its gable end),
  # with the data of its surface.
  defp room_view(%{place: :roof, level: "roof"} = room, z) do
    p = meters(room.plan)
    rise = p.d / 2 * @pitch
    {x1, y1, yc} = {p.x + p.w, p.y + p.d, p.y + p.d / 2}

    polys = [
      {[{p.x, p.y, z}, {x1, p.y, z}, {x1, yc, z + rise}, {p.x, yc, z + rise}],
       "p-floor p-roof-b"},
      {[{p.x, yc, z + rise}, {x1, yc, z + rise}, {x1, y1, z}, {p.x, y1, z}], "p-floor p-roof-f"},
      {[{x1, p.y, z}, {x1, y1, z}, {x1, yc, z + rise}], "p-gable"}
    ]

    %{surface(room, z) | polys: polys, rise: round(rise / @m)}
  end

  defp room_view(room, z) do
    p = meters(room.plan)
    {x1, y1} = {p.x + p.w, p.y + p.d}
    corners = [{p.x, p.y, z}, {x1, p.y, z}, {x1, y1, z}, {p.x, y1, z}]
    %{surface(room, z) | polys: [{corners, "p-floor p-" <> material(room)}]}
  end

  defp surface(room, z) do
    {ox, oy} = Iso.at({0, 0}, {0, 0, z})

    %{
      id: room.id,
      name: room.name,
      z: z,
      meters: meters(room.plan),
      plan: "#{room.plan.x} #{room.plan.y} #{room.plan.w} #{room.plan.d}",
      origin: "#{Iso.round1(ox)} #{Iso.round1(oy)}",
      rise: nil,
      polys: []
    }
  end

  @materials [
    {"tile", ~w(kitchen bath laundry toilet mud)},
    {"carpet", ~w(bed master guest nursery)},
    {"concrete", ~w(garage shed workshop utility storage)},
    {"ply", ~w(attic)}
  ]

  @doc "The material of the floor of a room, from its place and its name."
  def material(%{place: :outdoor, name: name}) do
    name = String.downcase(name)

    cond do
      Enum.any?(~w(drive park), &String.contains?(name, &1)) -> "asphalt"
      Enum.any?(~w(patio deck porch), &String.contains?(name, &1)) -> "deck"
      true -> "grass"
    end
  end

  def material(%{place: :roof}), do: "membrane"

  def material(%{name: name}) do
    name = String.downcase(name)

    Enum.find_value(@materials, "wood", fn {material, words} ->
      if Enum.any?(words, &String.contains?(name, &1)), do: material
    end)
  end

  # The label of a room: its name, at its center.
  defp label(room, z) do
    p = meters(room.plan)

    z =
      if room.place == :roof and room.level == "roof",
        do: z + p.d / 2 * @pitch / 2,
        else: z

    {sx, sy} = Iso.at({0, 0}, {p.x + p.w / 2, p.y + p.d * 0.75, z})
    %{id: room.id, x: Iso.round1(sx), y: Iso.round1(sy), text: room.name}
  end

  ## The items

  # An item: its shapes at its place, size and turn, with its box in the
  # world (for the order of the paint).
  defp item_view(item, room, z) do
    {w, d, h} = Layout.size(item)
    {ew, ed} = Layout.extent(item)
    {x, y} = {room.plan.x + item.at.x, room.plan.y + item.at.y}
    {cx, cy} = {x + ew / 2, y + ed / 2}
    roof = if room.place == :roof and room.level == "roof", do: room
    size = {w * @m, d * @m, h * @m}

    polys =
      case {item.type, roof} do
        {"solar_panels", nil} ->
          Shapes.placed_model(rack(item), %{at: {x * @m, y * @m, z}, turn: item.turn})

        {"solar_panels", roof} ->
          on_roof(item, roof, z)

        {type, nil} ->
          base = z + Catalog.lift(type) * @m
          Shapes.placed(type, %{at: {x * @m, y * @m, base}, size: size, turn: item.turn})

        {type, roof} ->
          base = roof_z(roof, z, cy)
          Shapes.placed(type, %{at: {x * @m, y * @m, base}, size: size, turn: item.turn})
      end

    # The box of the item: its space on the plan, and the height of its
    # shapes.
    {low, high} = polys |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(&elem(&1, 2)) |> Enum.min_max()

    %{
      id: item.id,
      kind: :item,
      loose: ew > room.plan.w or ed > room.plan.d,
      room: room.id,
      name: Catalog.name(item),
      at: "#{round(cx)} #{round(cy)}",
      planned: item.planned,
      box: {x * @m, y * @m, low, (x + ew) * @m, (y + ed) * @m, high},
      key: (cx + cy) * @m,
      polys: Enum.map(polys, fn {:poly, corners, class} -> {corners, class} end)
    }
  end

  # The height of a roof over a point of the plan (y in inches), in meters:
  # its eaves are at z.
  defp roof_z(roof, z, y) do
    half = roof.plan.d / 2
    z + half * @pitch * @m * (1 - abs(y - (roof.plan.y + half)) / half)
  end

  # The panels on a roof: on its surface, in rows. A panel over the ridge
  # has two parts.
  defp on_roof(item, roof, z) do
    {cols, rows} = Layout.panel_grid(item.params["watts"])
    {w, d} = Layout.panel()
    {pw, pd} = if rem(item.turn, 2) == 0, do: {w, d}, else: {d, w}
    {cols, rows} = if rem(item.turn, 2) == 0, do: {cols, rows}, else: {rows, cols}
    {ax, ay} = {roof.plan.x + item.at.x, roof.plan.y + item.at.y}
    ridge = roof.plan.y + roof.plan.d / 2
    count = Layout.panels(item.params["watts"])

    for k <- 0..(count - 1),
        {col, row} = panel_cell(k, cols, rows, item.turn),
        {x0, y0} = {ax + col * pw + 1, ay + row * pd + 1},
        {x1, y1} = {x0 + pw - 2, y0 + pd - 2},
        {ya, yb} <-
          if(y0 < ridge and y1 > ridge, do: [{y0, ridge}, {ridge, y1}], else: [{y0, y1}]) do
      point = fn x, y -> {x * @m, y * @m, roof_z(roof, z, y) + 0.04} end
      {:poly, [point.(x0, ya), point.(x1, ya), point.(x1, yb), point.(x0, yb)], "i-pv"}
    end
  end

  # The column and the row of panel k: the first row of the array is full.
  defp panel_cell(k, cols, _rows, turn) when rem(turn, 2) == 0, do: {rem(k, cols), div(k, cols)}
  defp panel_cell(k, _cols, rows, _turn), do: {div(k, rows), rem(k, rows)}

  # The panels in a yard: rows on a rack, on a pad of gravel. A panel faces
  # the front of the item (y), up at 30°.
  defp rack(item) do
    {cols, rows} = Layout.panel_grid(item.params["watts"])
    count = Layout.panels(item.params["watts"])
    {pw, pd} = Layout.panel()
    {w, d} = {cols * pw * @m, rows * pd * @m}

    pad = {:face, [{0, 0, 0.01}, {w, 0, 0.01}, {w, d, 0.01}, {0, d, 0.01}], {0, 0, 1}, "p-pad"}

    panels =
      for k <- 0..(count - 1),
          {col, row} = {rem(k, cols), div(k, cols)},
          {x0, y1} = {col * pw * @m + 0.03, (row + 1) * pd * @m - 0.1},
          {x1, y0} = {x0 + pw * @m - 0.06, y1 - 1.5},
          part <- [
            {:box, {(x0 + x1) / 2 - 0.03, y0 + 0.1, 0}, {0.06, 0.06, 1.2}, "steel"},
            {:face, [{x0, y1, 0.4}, {x1, y1, 0.4}, {x1, y0, 1.27}, {x0, y0, 1.27}], nil, "i-pv"}
          ],
          do: part

    [pad | panels]
  end

  ## The box

  defp box_of(plans) do
    {x0, x1} = plans |> Enum.flat_map(&[&1.x, &1.x + &1.w]) |> Enum.min_max()
    {y0, y1} = plans |> Enum.flat_map(&[&1.y, &1.y + &1.d]) |> Enum.min_max()
    %{x: x0, y: y0, w: x1 - x0, d: y1 - y0}
  end

  defp grow(box, by), do: %{x: box.x - by, y: box.y - by, w: box.w + 2 * by, d: box.d + 2 * by}

  # The box of polygons in the SVG: {x, y, w, h}.
  defp bounds(polys) do
    {xs, ys} = polys |> Enum.concat() |> Enum.map(&Iso.at({0, 0}, &1)) |> Enum.unzip()
    {x0, x1} = Enum.min_max(xs)
    {y0, y1} = Enum.min_max(ys)
    {x0, y0, x1 - x0, y1 - y0}
  end

  defp around(boxes, margin) do
    x0 = boxes |> Enum.map(&elem(&1, 0)) |> Enum.min()
    y0 = boxes |> Enum.map(&elem(&1, 1)) |> Enum.min()
    x1 = boxes |> Enum.map(&(elem(&1, 0) + elem(&1, 2))) |> Enum.max()
    y1 = boxes |> Enum.map(&(elem(&1, 1) + elem(&1, 3))) |> Enum.max()
    {x0 - margin, y0 - margin, x1 - x0 + 2 * margin, y1 - y0 + 2 * margin}
  end

  @doc "A box of the SVG as the text of an attribute."
  def box_text({x, y, w, h}), do: Enum.map_join([x, y, w, h], " ", &Iso.round1/1)

  ## The component

  attr :view, :map, required: true, doc: "the layers (`view/1`)"
  attr :selected, :string, default: nil, doc: "the id of the room that the user chose"

  @doc """
  The SVG of the cut-open house. The hook Plan moves, zooms, and sends the
  changes to the page. The SVG is for the eyes: the list of the rooms on
  the page gives the same facts.
  """
  def cutaway(assigns) do
    {kx, ky, kz} = @k

    assigns =
      assign(assigns,
        k: "#{Float.round(kx, 6)} #{Float.round(ky, 6)} #{Float.round(kz, 6)}",
        fit: box_text(assigns.view.box),
        selection: selection(assigns.view, assigns.selected)
      )

    ~H"""
    <svg
      id="plan-svg"
      viewBox={@fit}
      data-fit={@fit}
      data-k={@k}
      class="cutaway block w-full h-full touch-none select-none"
      aria-hidden="true"
      phx-mounted={JS.ignore_attributes(["viewBox", "style"])}
    >
      <g :for={level <- @view.levels} id={"plan-#{level.id}"} data-box={box_text(level.box)}>
        <polygon :for={{points, class} <- level.ground} points={points} class={class} />
        <.surface :for={room <- level.low} :key={room.id} room={room} selected={@selected} />
        <polygon :for={{points, class} <- level.slabs} points={points} class={class} />
        <.surface :for={room <- level.rooms} :key={room.id} room={room} selected={@selected} />
        <g
          :for={object <- level.objects}
          :key={object.id}
          id={"plan-#{object.kind}-#{object.id}"}
          class={if object.kind == :item, do: ["p-item", object.planned && "p-planned"]}
          data-item={object.kind == :item && object.id}
          data-in={object.kind == :item && object.room}
          data-at={object.kind == :item && object.at}
        >
          <title :if={object.kind == :item}>{object.name}</title>
          <polygon :for={{points, class} <- object.polys} points={points} class={class} />
        </g>
        <text
          :for={label <- level.labels}
          :key={label.id}
          x={label.x}
          y={label.y}
          text-anchor="middle"
          class="p-label"
        >
          {label.text}
        </text>
      </g>
      <g :if={@selection} id="plan-selection">
        <polygon
          points={@selection.outline}
          class="p-outline"
          data-outline={@selection.id}
          data-plan={@selection.plan}
          data-origin={@selection.origin}
        />
        <circle
          :for={{edge, x, y} <- @selection.handles}
          cx={x}
          cy={y}
          class="p-handle"
          data-handle={edge}
          data-room-id={@selection.id}
        />
      </g>
    </svg>
    """
  end

  attr :room, :map, required: true
  attr :selected, :string, default: nil

  # The surface of a room, with the data of its plan for the hook.
  defp surface(assigns) do
    ~H"""
    <g id={"plan-room-#{@room.id}"}>
      <polygon
        :for={{points, class} <- @room.polys}
        points={points}
        class={[class, @room.id == @selected && "p-chosen"]}
        data-room={@room.id}
        data-plan={@room.plan}
        data-origin={@room.origin}
        data-rise={@room.rise}
      />
    </g>
    """
  end

  # The outline of the room that the user chose, and a handle in the middle
  # of each wall. x0 and y0 are the walls at the back.
  defp selection(view, id) do
    case view.levels |> Enum.flat_map(&(&1.low ++ &1.rooms)) |> Enum.find(&(&1.id == id)) do
      nil ->
        nil

      room ->
        %{x: x0, y: y0, w: w, d: d} = room.meters
        {x1, y1, z} = {x0 + w, y0 + d, room.z}
        {cx, cy} = {x0 + w / 2, y0 + d / 2}

        handles =
          for {edge, x, y} <- [{"x0", x0, cy}, {"x1", x1, cy}, {"y0", cx, y0}, {"y1", cx, y1}] do
            {sx, sy} = Iso.at({0, 0}, {x, y, z})
            {edge, Iso.round1(sx), Iso.round1(sy)}
          end

        %{
          id: room.id,
          plan: room.plan,
          origin: room.origin,
          outline: Iso.points({0, 0}, [{x0, y0, z}, {x1, y0, z}, {x1, y1, z}, {x0, y1, z}]),
          handles: handles
        }
    end
  end
end
