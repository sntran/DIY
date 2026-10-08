defmodule DIYWeb.Cutaway do
  @moduledoc """
  The plan of the house at scale, as a house that is cut open: each floor
  is a layer, with a gap between the layers, from the ground (the lot,
  outside and floor 1) up to the attic and the roof. Each room shows at
  its place and its size, and each item at its place, its size and its
  turn (`DIY.Layout`). The walls at the back are cut at the height of a
  table, and the walls at the front are cut near the floor.

  The page moves the items and the rooms with a script (the hook Plan,
  `assets/js/plan.js`). The SVG gives the script what it needs:

  - the SVG: `data-k`, the SVG units of one inch along `x`, along `y`, and
    up (`z`); and `data-fit`, the box of all the layers;
  - each surface of a room: `data-room`, `data-plan` (`x y w d`, inches)
    and `data-origin` (the SVG point of the plan point 0, 0 on the surface
    of the room). A roof also has `data-rise`: the height of its ridge
    over its eaves, in inches;
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
  # The pitch of a roof (5 in 12), the height of the cut of a wall at the
  # back and at the front, the thickness of a wall and of a floor (meters).
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
  (meters), then its parts in the order of the paint: the lot (`ground`),
  the surfaces of the rooms outside (`low`), the slabs, the surfaces of
  the other rooms (`rooms`), the walls and the items (`objects`, from the
  back to the front), and the names of the rooms (`labels`).
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
    sheds = for r <- indoor, r.level == "outside", do: meters(r.plan)
    {ground, slabs, walls} = shell(id, z, rooms, house, sheds)

    item_views =
      for room <- rooms,
          item <- Map.get(items, room.id, []),
          do: item_view(item, room, floor_z.(room))

    objects = order(walls ++ item_views)

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

  # The height of the floor of a room over its layer: floor 1 is on its
  # slab, a garage on a lower slab, and a yard on the ground.
  defp floor_height("ground", %{level: "f1"}), do: @slab
  defp floor_height("ground", %{place: :outdoor}), do: 0.02
  defp floor_height("ground", _room), do: 0.1
  defp floor_height(_layer, _room), do: 0.0

  defp svg({corners, class}), do: {Iso.points({0, 0}, corners), class}
  defp svg_polys(part), do: %{part | polys: Enum.map(part.polys, &svg/1)}

  ## The shell: the lot, the slabs and the walls

  # The lot (on the ground), the slabs, and the walls (as objects): at the
  # back, cut at the height of a table; at the front, cut near the floor.
  # A room outside that is not a yard (a garage) has its slab and walls.
  defp shell("ground", _z, rooms, house, sheds) do
    lot = rooms |> Enum.map(&meters(&1.plan)) |> Kernel.++([house]) |> box_of() |> grow(1.6)

    slabs =
      slab(house, 0.0, @slab) ++ Enum.flat_map(sheds, &slab(&1, 0.0, 0.1))

    walls =
      walls("ground-house", house, @slab, @wall) ++
        Enum.flat_map(Enum.with_index(sheds), fn {shed, i} ->
          walls("ground-shed#{i}", shed, 0.1, @wall)
        end)

    {faces(Iso.box({lot.x, lot.y, -0.45}, {lot.w, lot.d, 0.45}), "p-lot"), slabs, walls}
  end

  defp shell("roof", _z, _rooms, _house, _sheds), do: {[], [], []}

  defp shell(id, z, _rooms, house, _sheds) do
    height = if id == "attic", do: 0.5, else: @wall
    {[], slab(house, z - @slab, @slab), walls("#{id}-house", house, z, height)}
  end

  # A slab under a box and its walls.
  defp slab(b, z, h),
    do:
      faces(
        Iso.box({b.x - @thick, b.y - @thick, z}, {b.w + 2 * @thick, b.d + 2 * @thick, h}),
        "p-slab"
      )

  # The four walls of a box: two at the back (high), two at the front (low).
  # A wall stands just out of the box. For the order of the paint, a wall
  # is flat, on the side of the box: so an item in the box is in front of
  # a wall at the back, and behind a wall at the front.
  defp walls(id, b, z, height) do
    {x1, y1, t} = {b.x + b.w, b.y + b.d, @thick}

    [
      {"x0", {b.x - t, b.y - t, z}, {t, b.d + t, height}, {b.x, b.y, b.x, y1}},
      {"y0", {b.x, b.y - t, z}, {b.w, t, height}, {b.x, b.y, x1, b.y}},
      {"y1", {b.x - t, y1, z}, {b.w + t, t, @low}, {b.x, y1, x1, y1}},
      {"x1", {x1, b.y - t, z}, {t, b.d + 2 * t, @low}, {x1, b.y, x1, y1}}
    ]
    |> Enum.map(fn {side, corner, {_w, _d, h} = size, {ox0, oy0, ox1, oy1}} ->
      %{
        id: "#{id}-#{side}",
        kind: :wall,
        loose: false,
        box: {ox0, oy0, z, ox1, oy1, z + h},
        key: (ox0 + ox1 + oy0 + oy1) / 2,
        polys: faces(Iso.box(corner, size), "p-wall")
      }
    end)
  end

  defp faces(box, class),
    do: [{box.left, class <> "-l"}, {box.right, class <> "-r"}, {box.top, class <> "-t"}]

  ## The order of the paint

  @doc """
  The walls and the items, from the back to the front. Where two of them
  cover the same part of the screen, the one at the back comes first: its
  box (`{x0, y0, z0, x1, y1, z1}`) is on the far side of the other box
  along x, y or z, and the other box is not on the far side of it. Else
  the one with the smaller key (x + y of its center) comes first. An item
  that is larger than its room (`loose`) goes through walls: it comes by
  its key only. Three boxes can each be behind the next one (a cycle):
  then the box with the fewest boxes before it comes first.
  """
  def order(objects) do
    screens = Map.new(objects, &{&1.id, screen(&1.polys)})

    after_ =
      Map.new(objects, fn a ->
        {a.id,
         for(
           b <- objects,
           b.id != a.id,
           not a.loose and not b.loose,
           cover?(screens[a.id], screens[b.id]),
           behind?(a.box, b.box) and not behind?(b.box, a.box),
           do: b.id
         )}
      end)

    # The count of the objects before each object.
    count = after_ |> Map.values() |> List.flatten() |> Enum.frequencies()
    paint(Enum.sort_by(objects, &{&1.key, &1.id}), count, after_, [])
  end

  # Kahn: the next object is the first one (by key) with no object before
  # it. With none (a cycle), the one with the fewest objects before it.
  defp paint([], _count, _after, done), do: Enum.reverse(done)

  defp paint(todo, count, after_, done) do
    next =
      Enum.find(todo, &(Map.get(count, &1.id, 0) == 0)) ||
        Enum.min_by(todo, &Map.get(count, &1.id, 0))

    count = Enum.reduce(after_[next.id], count, &Map.update!(&2, &1, fn n -> n - 1 end))
    paint(List.delete(todo, next), count, after_, [next | done])
  end

  defp behind?({_, _, _, ax1, ay1, az1}, {bx0, by0, bz0, _, _, _}),
    do: ax1 <= bx0 + 1.0e-6 or ay1 <= by0 + 1.0e-6 or az1 <= bz0 + 1.0e-6

  defp screen(polys) do
    {xs, ys} =
      polys |> Enum.flat_map(&elem(&1, 0)) |> Enum.map(&Iso.at({0, 0}, &1)) |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp cover?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01

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
    {pw, pd} = if rem(item.turn, 2) == 0, do: {41, 69}, else: {69, 41}
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
    {w, d} = {cols * 41 * @m, rows * 69 * @m}

    pad = {:face, [{0, 0, 0.01}, {w, 0, 0.01}, {w, d, 0.01}, {0, d, 0.01}], {0, 0, 1}, "p-pad"}

    panels =
      for k <- 0..(count - 1),
          {col, row} = {rem(k, cols), div(k, cols)},
          {x0, y1} = {col * 41 * @m + 0.03, (row + 1) * 69 * @m - 0.1},
          {x1, y0} = {x0 + 41 * @m - 0.06, y1 - 1.5},
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
  # of each wall: x0 and y0 (the walls at the back), x1 and y1.
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
