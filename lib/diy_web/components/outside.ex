defmodule DIYWeb.Outside do
  @moduledoc """
  The house from the outside, as the first picture of the page House. It
  uses the rooms, the camera and the look of the plan (`DIYWeb.Cutaway`):
  the plan is the same house, cut open. A tap on the picture goes in.

  The picture shows the house that is there today (no planned item):

  - the lot, the yards and the driveway, with their furniture
    (`DIYWeb.Decor`) and their items (an AC, panels, a car, a van);
  - each floor of the house, on the floor under it: the slab, then walls
    of full height on the outside of the rooms. The front and the right
    end have windows. The front of floor 1 has the door, and you in front
    of it;
  - the roof, with its panels, on the top floor;
  - a room outside of the house that is not a yard (a garage), with a
    flat roof and a wide door;
  - the pole of the grid, and its wire to the house. A label tells the
    watts of the panels and the kWh of the stations.
  """
  use DIYWeb, :html

  alias DIY.{Build, Layout}
  alias DIYWeb.{Camera, Cutaway, Decor, Geometry}
  alias DIYWeb.Icon.Shapes

  # One inch in meters. Then, in meters: the height of a wall, the depth of
  # a floor, the thickness of a wall, and the overhang of a roof. The pole
  # of the grid is 6 m high. The pitch of a roof is 5 in 12.
  @m 0.0254
  @full 2.4
  @slab 0.3
  @thick 0.16
  @eave 0.35
  @pole 6.0
  @pitch 5 / 12

  @doc """
  The picture of the house from the outside. It has the polygons of the
  SVG in the order of the paint, the wire of the grid, and the labels. It
  also has the box of the SVG.
  """
  def view(build) do
    camera = Camera.house()
    house = build |> Build.house_view() |> Build.today()
    rooms = Enum.filter(house.rooms, & &1.plan)
    items = Enum.group_by(house.items, & &1.room)

    {yards, built} = Enum.split_with(rooms, &(&1.place == :outdoor))
    # The attic is in the roof: it does not show.
    {roofs, inside} =
      built
      |> Enum.reject(&(&1.level == "roof" and &1.place == :indoor))
      |> Enum.split_with(&(&1.place == :roof))

    # The roof is on the top floor with rooms.
    top = Enum.max(for(%{level: "f" <> n} <- inside, do: String.to_integer(n)), fn -> 1 end)
    z = &floor_z(&1, top)
    roofs = if roofs == [], do: plain_roof(inside, top), else: roofs

    lot = lot(rooms, house)
    pole = {lot.x + lot.w - 0.8, lot.y + 0.8}

    # The slabs on the ground are under all the objects: they paint first,
    # as in the plan. A slab over a floor is an object.
    {ground, upper} = Enum.split_with(inside, &(&1.level in ["f1", "outside"]))

    objects =
      Enum.flat_map(upper, &slab(&1, z.(&1), camera)) ++
        walls(inside, z, camera) ++
        Enum.flat_map(inside, &front(&1, inside, z.(&1), camera)) ++
        Enum.flat_map(roofs, &roof(&1, Map.get(items, &1.id, []), z.(&1), camera)) ++
        garage_roofs(inside, z, camera) ++
        Enum.flat_map(yards, &yard(&1, Map.get(items, &1.id, []), camera)) ++
        door_person(inside, z, camera) ++
        [pole(pole, camera)]

    level =
      Cutaway.layer(%{id: "outside", name: "The house", z: 0.0, camera: camera}, %{
        ground:
          Camera.faces(camera, Geometry.box({lot.x, lot.y, -0.45}, {lot.w, lot.d, 0.45}), "p-lot"),
        low: Enum.map(yards, &Cutaway.floor(&1, 0.02, Cutaway.material(&1), camera)),
        slabs: Enum.flat_map(ground, &(&1 |> slab(z.(&1), camera) |> hd() |> Map.fetch!(:polys))),
        rooms: [],
        objects: objects,
        labels: []
      })

    {wire, meter} = wire(pole, inside, z, camera)
    chips = chips(house, pole, roofs, z, camera)
    box = around([level.box | Enum.map(chips, & &1.box)], 4.0)

    %{level: level, wire: wire, meter: meter, chips: chips, box: box, camera: camera}
  end

  # The height of the floor of a room (meters). Floor 1 is on its slab, and
  # each floor is on the floor under it. A garage is on a lower slab. The
  # roof is on the walls of the top floor (`top`). A yard is on the ground
  # (`yard/3`).
  defp floor_z(%{level: "f" <> n}, _top),
    do: @slab + (String.to_integer(n) - 1) * (@full + @slab)

  defp floor_z(%{level: "roof"}, top), do: @slab + (top - 1) * (@full + @slab) + @full
  defp floor_z(_garage, _top), do: 0.1

  defp meters(%{x: x, y: y, w: w, d: d}), do: %{x: x * @m, y: y * @m, w: w * @m, d: d * @m}

  # The lot: the box of all the rooms, 1.6 m larger on each side. With no
  # room, the box of the draft floor (`DIY.Layout.house_box/1`).
  defp lot(rooms, house) do
    box =
      case rooms do
        [] -> Layout.house_box(house)
        rooms -> Layout.box(Enum.map(rooms, & &1.plan))
      end

    p = meters(box)
    %{x: p.x - 1.6, y: p.y - 1.6, w: p.w + 3.2, d: p.d + 3.2}
  end

  # A house with no room on the roof gets a roof with no item, on the box
  # of its top floor.
  defp plain_roof(inside, top) do
    case for(room <- inside, room.level == "f#{top}", do: room.plan) do
      [] -> []
      plans -> [%{id: "roof", level: "roof", place: :roof, plan: Layout.box(plans)}]
    end
  end

  # An object of the picture: its box in the world for the order of the
  # paint, and its polygons.
  defp object(id, {x0, y0, z0, x1, y1, z1}, polys, camera) do
    %{
      id: id,
      kind: :fixture,
      loose: false,
      box: {x0, y0, z0, x1, y1, z1},
      key: Camera.depth(camera, {(x0 + x1) / 2, (y0 + y1) / 2, 0}),
      polys: polys
    }
  end

  # The slab under a room: from the floor under it (or the ground) up to
  # its floor. It is larger than the room: the walls stand on it.
  defp slab(room, z, camera) do
    p = meters(room.plan)
    t = @thick
    low = max(z - @slab, 0.0)
    shape = Geometry.box({p.x - t, p.y - t, low}, {p.w + 2 * t, p.d + 2 * t, z - low})
    box = {p.x - t, p.y - t, low, p.x + p.w + t, p.y + p.d + t, z}
    [object("slab-" <> room.id, box, Camera.faces(camera, shape, "p-slab"), camera)]
  end

  # The walls on the outside of the rooms of each floor. A wall is on each
  # side of a room where no room of the same floor touches it. A wall
  # stands just out of its room, and a wall on x fills the corners.
  defp walls(rooms, z, camera) do
    for room <- rooms,
        side <- ~w(x0 y0 x1 y1),
        {{a, b}, i} <- Enum.with_index(outside_parts(room, side, rooms)) do
      wall("#{room.id}-#{side}-#{i}", room, side, {a, b}, z.(room), camera)
    end
  end

  # The parts of a side of a room (inches, along the side) with no room of
  # the same floor on the other side.
  defp outside_parts(room, side, rooms) do
    {line, range} = edge(room.plan, side)

    touch =
      for o <- rooms,
          o.id != room.id,
          o.level == room.level,
          across(o.plan, side) == line,
          do: along(o.plan, side)

    free(range, Enum.sort(touch))
  end

  # The parts of {a, b} out of the ranges of `touch`, in their order.
  defp free({a, b}, _touch) when a >= b, do: []
  defp free(range, []), do: [range]

  defp free({a, b}, [{c, d} | rest]) do
    cond do
      d <= a -> free({a, b}, rest)
      c >= b -> [{a, b}]
      c <= a -> free({d, b}, rest)
      true -> [{a, c} | free({d, b}, rest)]
    end
  end

  defp edge(p, "x0"), do: {p.x, {p.y, p.y + p.d}}
  defp edge(p, "x1"), do: {p.x + p.w, {p.y, p.y + p.d}}
  defp edge(p, "y0"), do: {p.y, {p.x, p.x + p.w}}
  defp edge(p, "y1"), do: {p.y + p.d, {p.x, p.x + p.w}}

  defp across(p, "x0"), do: p.x + p.w
  defp across(p, "x1"), do: p.x
  defp across(p, "y0"), do: p.y + p.d
  defp across(p, "y1"), do: p.y

  defp along(p, side) when side in ~w(x0 x1), do: {p.y, p.y + p.d}
  defp along(p, _side), do: {p.x, p.x + p.w}

  # A wall of full height on a side of a room, from {a, b} along the side
  # (inches). The front (y1) and the right end (x1) have windows on their
  # face out of the house. For the order of the paint, a wall is flat, on
  # its line, with no corner (as in the plan). So an item in a yard is in
  # front of it.
  defp wall(id, room, side, {a0, b0}, z, camera) do
    {line, {r0, r1}} = edge(room.plan, side)
    t = @thick / @m

    {a, b} =
      if side in ~w(x0 x1),
        do: {if(a0 == r0, do: a0 - t, else: a0), if(b0 == r1, do: b0 + t, else: b0)},
        else: {a0, b0}

    near = if side in ~w(x0 y0), do: line - t, else: line

    {corner, size} =
      if side in ~w(x0 x1),
        do: {{near * @m, a * @m}, {@thick, (b - a) * @m}},
        else: {{a * @m, near * @m}, {(b - a) * @m, @thick}}

    {cx, cy} = corner
    {sw, sd} = size
    shape = Geometry.box({cx, cy, z}, {sw, sd, @full})
    windows = if side in ~w(x1 y1), do: windows(side, (near + t) * @m, {a, b}, z, room), else: []

    box =
      if side in ~w(x0 x1),
        do: {line * @m, a0 * @m, z, line * @m, b0 * @m, z + @full},
        else: {a0 * @m, line * @m, z, b0 * @m, line * @m, z + @full}

    object("wall-" <> id, box, Camera.faces(camera, shape, "p-wall") ++ windows, camera)
  end

  # The windows of a wall on its face out of the house (`face`, meters): one
  # for each 8 feet. A garage has one small window on its end, and no window
  # at its front (its door is there).
  defp windows(side, face, {a, b}, z, room) do
    length = b - a
    garage? = room.level == "outside"
    count = if garage?, do: if(side == "x1", do: 1, else: 0), else: div(round(length), 96)
    count = if count == 0 and length >= 48 and not garage?, do: 1, else: count

    for k <- 0..(count - 1)//1,
        middle = a + length * (k + 0.5) / max(count, 1),
        part <- window(side, face, middle, z),
        do: part
  end

  # A window: a frame, two panes and a sill, 3 feet wide, from 3 feet over
  # the floor.
  defp window(side, face, middle, z) do
    plane = &plane(side, face, &1, &2, z)

    [
      {plane.({middle - 18, middle + 18}, {0.9, 2.1}), "p-frame"},
      {plane.({middle - 16, middle - 1}, {0.95, 2.05}), "p-pane"},
      {plane.({middle + 1, middle + 16}, {0.95, 2.05}), "p-pane"},
      {plane.({middle - 20, middle + 20}, {0.86, 0.9}), "p-frame"}
    ]
  end

  # A polygon on the face of a wall: from u0 to u1 along the wall (inches),
  # and from z0 to z1 over the floor (meters).
  defp plane(side, face, {u0, u1}, {z0, z1}, z) do
    for {u, h} <- [{u0, z0}, {u1, z0}, {u1, z1}, {u0, z1}] do
      if side == "x1", do: {face + 0.004, u * @m, z + h}, else: {u * @m, face + 0.004, z + h}
    end
  end

  # The doors at the front. The door of the house is on the largest room of
  # floor 1 with a wall at the front. A garage has a wide door.
  defp front(room, rooms, z, camera) do
    parts = outside_parts(room, "y1", rooms)
    {line, _range} = edge(room.plan, "y1")
    face = (line + @thick / @m) * @m

    cond do
      room.level == "outside" and parts != [] ->
        {a, b} = Enum.max_by(parts, fn {a, b} -> b - a end)
        middle = (a + b) / 2
        half = min(96, (b - a) / 2 - 12)
        plane = &plane("y1", face, &1, &2, z)

        lines =
          for k <- 1..3,
              do: {plane.({middle - half, middle + half}, {0.5 * k, 0.5 * k + 0.03}), "p-line"}

        door = [{plane.({middle - half, middle + half}, {0.0, 2.1}), "p-garage"} | lines]
        [object("door-" <> room.id, door_box(room, face, z), door, camera)]

      room == door_room(rooms) ->
        {a, b} = Enum.max_by(parts, fn {a, b} -> b - a end)
        middle = (a + b) / 2
        plane = &plane("y1", face, &1, &2, z)

        door = [
          {plane.({middle - 22, middle + 22}, {0.0, 2.2}), "p-frame"},
          {plane.({middle - 18, middle + 18}, {0.0, 2.05}), "p-door"},
          {plane.({middle + 11, middle + 14}, {1.0, 1.1}), "p-line"}
        ]

        [object("door-" <> room.id, door_box(room, face, z), door, camera)]

      true ->
        []
    end
  end

  # The box of a door: just in front of the wall, so the door paints after
  # it.
  defp door_box(room, face, z) do
    p = meters(room.plan)
    {p.x, face, z, p.x + p.w, face + 0.01, z + 2.2}
  end

  # The room of the door of the house: the largest room of floor 1 with a
  # wall at the front.
  defp door_room(rooms) do
    rooms
    |> Enum.filter(&(&1.level == "f1" and outside_parts(&1, "y1", rooms) != []))
    |> Enum.max_by(&(&1.plan.w * &1.plan.d), fn -> nil end)
  end

  # You, in front of the door of the house: a body and a head.
  defp door_person(rooms, z, camera) do
    case door_room(rooms) do
      nil ->
        []

      room ->
        p = meters(room.plan)
        {x, y} = {p.x + p.w / 2 + 0.6, p.y + p.d + @thick + 0.7}

        model = [
          {:cyl, {-0.07, 0, 0}, 0.06, 0.8, "dark"},
          {:cyl, {0.07, 0, 0}, 0.06, 0.8, "dark"},
          {:cyl, {0, 0, 0.78}, 0.17, 0.62, "copper"},
          {:cyl, {0, 0, 1.42}, 0.11, 0.22, "pink"},
          {:cyl, {0, 0, 1.6}, 0.115, 0.07, "dark"}
        ]

        polys =
          for {:poly, corners, class} <-
                Shapes.placed_model(model, %{
                  at: {x, y, z.(room) - @slab + 0.02},
                  turn: 0,
                  camera: camera
                }),
              do: {corners, class}

        [object("you", {x - 0.17, y - 0.17, 0.0, x + 0.17, y + 0.17, 1.5}, polys, camera)]
    end
  end

  # The roof on the walls of the top floor. It has two slopes with their
  # shingles, the gable at the right end, and the items on the roof
  # (panels). It goes past the walls (`@eave`).
  defp roof(room, items, z, camera) do
    p = meters(room.plan)
    {o, rise} = {@eave, p.d / 2 * @pitch}
    {x0, x1, y0, y1, yc} = {p.x - o, p.x + p.w + o, p.y - o, p.y + p.d + o, p.y + p.d / 2}
    low = z - o * @pitch
    top = z + rise

    back = [{x0, y0, low}, {x1, y0, low}, {x1, yc, top}, {x0, yc, top}]
    front = [{x0, yc, top}, {x1, yc, top}, {x1, y1, low}, {x0, y1, low}]
    gx = p.x + p.w + @thick

    gable = [
      {gx, p.y - @thick, z},
      {gx, p.y + p.d + @thick, z},
      {gx, yc, top - 0.05}
    ]

    panels = Enum.flat_map(items, &Cutaway.item_view(&1, room, z, camera).polys)

    polys =
      [
        {back, "p-floor p-roof-b"},
        {back, "p-tex p-tex-roof"},
        {gable, "p-gable"},
        {front, "p-floor p-roof-f"},
        {front, "p-tex p-tex-roof"}
      ] ++ panels

    # For the order of the paint, the roof starts at its eaves: the walls
    # under it paint first.
    [object("roof-" <> room.id, {x0, y0, z, x1, y1, top}, polys, camera)]
  end

  # A flat roof on a room outside of the house (a garage). It goes 10 cm
  # past its walls. For the order of the paint, it ends at its walls.
  defp garage_roofs(rooms, z, camera) do
    for room <- rooms, room.level == "outside" do
      p = meters(room.plan)
      {o, t} = {@thick + 0.1, @thick}
      top = z.(room) + @full
      shape = Geometry.box({p.x - o, p.y - o, top}, {p.w + 2 * o, p.d + 2 * o, 0.15})
      box = {p.x - t, p.y - t, top, p.x + p.w + t, p.y + p.d + t, top + 0.15}
      object("top-" <> room.id, box, Camera.faces(camera, shape, "p-slab"), camera)
    end
  end

  # A yard (or the driveway): its furniture and its items. An item that is
  # taller than floor 1 has no right order with the floors over it. It
  # paints by its depth only (`loose`), as an item larger than its room.
  defp yard(room, items, camera) do
    z = 0.02

    decor =
      for {piece, i} <- Enum.with_index(Decor.pieces(room, items)),
          do: Cutaway.decor_view("#{room.id}-#{i}", piece, room, z, camera)

    decor ++
      for item <- items do
        %{box: {_, _, z0, _, _, z1}} = view = Cutaway.item_view(item, room, z, camera)
        %{view | loose: view.loose or z1 - z0 > @slab + @full}
      end
  end

  # The pole of the grid, at the back right of the lot.
  defp pole({x, y}, camera) do
    post = Geometry.box({x - 0.09, y - 0.09, 0.0}, {0.18, 0.18, @pole})
    arm = Geometry.box({x - 0.6, y - 0.06, @pole - 0.5}, {1.2, 0.12, 0.12})
    polys = Camera.faces(camera, post, "p-pole") ++ Camera.faces(camera, arm, "p-pole")
    object("pole", {x - 0.6, y - 0.09, 0.0, x + 0.6, y + 0.09, @pole}, polys, camera)
  end

  # The wire of the grid goes from the top of the pole to the meter of the
  # house. The meter is on the right end of the room most to the right on
  # the ground (a garage too). The wire hangs a little.
  defp wire(pole, rooms, z, camera) do
    ground = Enum.filter(rooms, &(&1.level in ["f1", "outside"]))

    case Enum.max_by(ground, &(&1.plan.x + &1.plan.w), fn -> nil end) do
      nil ->
        {nil, []}

      room ->
        p = meters(room.plan)
        at = {p.x + p.w + @thick, p.y + 0.6, z.(room) + 2.0}
        {px, py} = pole
        from = Camera.at(camera, {0, 0}, {px, py, @pole - 0.4})
        to = Camera.at(camera, {0, 0}, at)
        {mx, my} = {(elem(from, 0) + elem(to, 0)) / 2, (elem(from, 1) + elem(to, 1)) / 2 + 6}

        d =
          "M#{pt(from)} Q#{Camera.round1(mx)},#{Camera.round1(my)} #{pt(to)}"

        {ax, ay, az} = at
        meter = Geometry.box({ax, ay - 0.15, az - 0.25}, {0.08, 0.3, 0.4})

        polys =
          for {corners, class} <- Camera.faces(camera, meter, "p-meter"),
              do: {Camera.points(camera, {0, 0}, corners), class}

        {d, polys}
    end
  end

  defp pt({x, y}), do: "#{Camera.round1(x)},#{Camera.round1(y)}"

  # The labels: the grid at the pole, and the watts of the panels on the
  # roof and in the yards. The kWh of the stations is at the front of the
  # house.
  defp chips(house, {px, py}, roofs, z, camera) do
    of = fn type -> Enum.filter(house.items, &(&1.type == type)) end
    places = Map.new(house.rooms, &{&1.id, &1.place})
    panels = of.("solar_panels")

    watts = fn place ->
      panels
      |> Enum.filter(&(places[&1.room] == place))
      |> Enum.map(& &1.params["watts"])
      |> Enum.sum()
    end

    stations = of.("power_station")
    kwh = stations |> Enum.map(&(&1.params["kwh"] + &1.params["extra_kwh"])) |> Enum.sum()

    roof_at =
      case roofs do
        [roof | _] ->
          p = meters(roof.plan)
          {p.x + p.w / 2, p.y + p.d / 2, z.(roof) + p.d / 2 * @pitch + 1.2}

        [] ->
          {px, py, @pole}
      end

    [chip({px, py, @pole + 0.9}, "Grid", camera)] ++
      if(watts.(:roof) > 0, do: [chip(roof_at, kw(watts.(:roof)), camera)], else: []) ++
      if(watts.(:outdoor) > 0, do: [chip(yard_at(house), kw(watts.(:outdoor)), camera)], else: []) ++
      if(kwh > 0,
        do: [chip(front_at(house), "#{DIYWeb.Format.value(kwh / 1)} kWh", camera)],
        else: []
      )
  end

  defp yard_at(house) do
    room = Enum.find(house.rooms, &(&1.place == :outdoor and &1.plan))
    p = meters(room.plan)
    {p.x + p.w / 2, p.y + p.d / 2, 2.0}
  end

  defp front_at(house) do
    rooms = Enum.filter(house.rooms, &(&1.level == "f1" and &1.plan))
    p = rooms |> Enum.map(&meters(&1.plan)) |> Enum.max_by(&(&1.y + &1.d))
    {p.x + p.w / 2, p.y + p.d + 1.0, 3.2}
  end

  defp kw(watts) when watts >= 1000, do: "#{DIYWeb.Format.value(Float.round(watts / 1000, 1))} kW"
  defp kw(watts), do: "#{watts} W"

  # A label at a point of the world: a pill with its text. The width of the
  # pill comes from the count of the letters.
  defp chip(point, text, camera) do
    {x, y} = Camera.at(camera, {0, 0}, point)
    w = String.length(text) * 4.2 + 8
    h = 11.0

    %{
      x: Camera.round1(x),
      y: Camera.round1(y + 2.5),
      left: Camera.round1(x - w / 2),
      top: Camera.round1(y - h / 2),
      w: Camera.round1(w),
      h: h,
      text: text,
      box: {x - w / 2, y - h / 2, w, h}
    }
  end

  defp around(boxes, margin) do
    x0 = boxes |> Enum.map(&elem(&1, 0)) |> Enum.min()
    y0 = boxes |> Enum.map(&elem(&1, 1)) |> Enum.min()
    x1 = boxes |> Enum.map(&(elem(&1, 0) + elem(&1, 2))) |> Enum.max()
    y1 = boxes |> Enum.map(&(elem(&1, 1) + elem(&1, 3))) |> Enum.max()
    {x0 - margin, y0 - margin, x1 - x0 + 2 * margin, y1 - y0 + 2 * margin}
  end

  attr :view, :map, required: true, doc: "the picture (`view/1`)"

  @doc "The SVG of the house from the outside, in the look of the plan."
  def house(assigns) do
    assigns = assign(assigns, :box, Cutaway.box_text(assigns.view.box))

    ~H"""
    <svg viewBox={@box} class="cutaway cutaway-house cutaway-outside block w-full" aria-hidden="true">
      <Cutaway.defs camera={@view.camera} />
      <polygon :for={{points, class} <- @view.level.ground} points={points} class={class} />
      <g :for={room <- @view.level.low}>
        <polygon :for={{points, class} <- room.polys} points={points} class={class} />
      </g>
      <polygon :for={{points, class, _room} <- @view.level.slabs} points={points} class={class} />
      <g :for={object <- @view.level.objects} class={object.kind == :item && "p-item"}>
        <polygon :for={{points, class} <- object.polys} points={points} class={class} />
      </g>
      <polygon :for={{points, class} <- @view.meter} points={points} class={class} />
      <path :if={@view.wire} d={@view.wire} class="p-wire" />
      <path :if={@view.wire} d={@view.wire} class="p-flow" />
      <g :for={chip <- @view.chips}>
        <rect
          x={chip.left}
          y={chip.top}
          width={chip.w}
          height={chip.h}
          rx={chip.h / 2}
          class="p-chip"
        />
        <text x={chip.x} y={chip.y} text-anchor="middle" class="p-chip-text">{chip.text}</text>
      </g>
    </svg>
    """
  end
end
