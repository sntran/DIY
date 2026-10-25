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
  - a balcony on its slab, with its furniture and its items;
  - the pole of the grid, and its wire to the house. A label tells the
    watts of the panels and the kWh of the stations.

  The view also has a text for a screen reader (`label`).
  """
  use DIYWeb, :html

  alias DIY.{Build, Catalog, Layout}
  alias DIYWeb.{Camera, Cutaway, Decor, Format, Geometry}
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
    items = house.items |> Cutaway.stacked() |> Enum.group_by(& &1.room)

    # A yard is on the ground. A room outside on a floor (a balcony) is on
    # its slab, with no wall. A room outside on the roof does not show.
    {outdoor, built} = Enum.split_with(rooms, &(&1.place == :outdoor))
    {yards, decks} = Enum.split_with(outdoor, &(&1.level == "outside"))
    decks = Enum.filter(decks, &String.starts_with?(&1.level, "f"))

    # The attic is in the roof: it does not show. The roof is a room on the
    # roof, on the level of the roof.
    {roofs, inside} =
      built
      |> Enum.reject(&(&1.level == "roof" and &1.place == :indoor))
      |> Enum.split_with(&(&1.place == :roof))

    roofs = Enum.filter(roofs, &(&1.level == "roof"))

    # The roof is on the top floor with rooms.
    top = Enum.max(for(%{level: "f" <> n} <- inside, do: String.to_integer(n)), fn -> 1 end)
    z = &floor_z(&1, top)
    roofs = if roofs == [], do: plain_roof(inside, top), else: roofs

    lot = lot(rooms, house)
    pole = {lot.x + lot.w - 0.8, lot.y + 0.8}
    door = door(inside)
    furnished = &yard(&1, Map.get(items, &1.id, []), z.(&1), camera)

    # The slabs on the ground are under all the objects: they paint first,
    # as in the plan. A slab over a floor is an object.
    {ground, upper} = Enum.split_with(inside ++ decks, &(&1.level in ["f1", "outside"]))
    {low_decks, high_decks} = Enum.split_with(decks, &(&1.level == "f1"))

    objects =
      Enum.flat_map(upper, &slab(&1, z.(&1), camera)) ++
        walls(inside, z, camera) ++
        Enum.flat_map(inside, &front(&1, inside, door, z.(&1), camera)) ++
        Enum.flat_map(roofs, &roof(&1, Map.get(items, &1.id, []), z.(&1), camera)) ++
        garage_roofs(inside, z, camera) ++
        Enum.flat_map(yards ++ decks, furnished) ++
        person(door, z, camera) ++
        [pole(pole, camera)]

    # The floor of a balcony over floor 1 is on its slab.
    objects = Enum.map(objects, &on_deck(&1, high_decks, z, camera))

    level =
      Cutaway.layer(%{id: "outside", name: "The house", z: 0.0, camera: camera}, %{
        ground:
          Camera.faces(camera, Geometry.box({lot.x, lot.y, -0.45}, {lot.w, lot.d, 0.45}), "p-lot"),
        low: Enum.map(yards, &Cutaway.floor(&1, 0.02, Cutaway.material(&1), camera)),
        slabs: Enum.flat_map(ground, &(&1 |> slab(z.(&1), camera) |> hd() |> Map.fetch!(:polys))),
        rooms: Enum.map(low_decks, &Cutaway.floor(&1, z.(&1), Cutaway.material(&1), camera)),
        objects: objects,
        labels: []
      })

    {wire, wire_box, meter, meter_box} = wire(pole, inside, z, camera)
    power = power(house, roofs)
    chips = chips(house, power, pole, roofs, yards ++ decks, inside, lot, z, camera)
    boxes = [level.box, wire_box, meter_box | Enum.map(chips, & &1.box)]
    box = around(Enum.reject(boxes, &is_nil/1), 4.0)
    shown = for %{kind: :item, id: id} <- objects, do: id

    %{
      level: level,
      wire: wire,
      meter: meter,
      chips: chips,
      box: box,
      camera: camera,
      label: label(house, power, inside, shown, wire, door)
    }
  end

  # The height of the floor of a room (meters). Floor 1 is on its slab, and
  # each floor is on the floor under it. A garage is on a lower slab. The
  # roof is on the walls of the top floor (`top`). A yard is on the ground.
  defp floor_z(%{level: "f" <> n}, _top),
    do: @slab + (String.to_integer(n) - 1) * (@full + @slab)

  defp floor_z(%{level: "roof"}, top), do: @slab + (top - 1) * (@full + @slab) + @full
  defp floor_z(%{place: :outdoor}, _top), do: 0.02
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

  # The slab of a balcony over floor 1 also has the floor of the balcony.
  defp on_deck(%{id: "slab-" <> id} = object, decks, z, camera) do
    case Enum.find(decks, &(&1.id == id)) do
      nil ->
        object

      deck ->
        floor = Cutaway.floor(deck, z.(deck), Cutaway.material(deck), camera)
        %{object | polys: object.polys ++ floor.polys}
    end
  end

  defp on_deck(object, _decks, _z, _camera), do: object

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

  # The doors at the front. A garage has a wide door, and the door of the
  # house is on its room (`door/1`).
  defp front(room, rooms, door, z, camera) do
    parts = outside_parts(room, "y1", rooms)
    face = front_face(room)
    plane = &plane("y1", face, &1, &2, z)

    cond do
      room.level == "outside" and parts != [] ->
        {a, b} = Enum.max_by(parts, fn {a, b} -> b - a end)
        middle = (a + b) / 2
        half = min(96, (b - a) / 2 - 12)

        lines =
          for k <- 1..3,
              do: {plane.({middle - half, middle + half}, {0.5 * k, 0.5 * k + 0.03}), "p-line"}

        door = [{plane.({middle - half, middle + half}, {0.0, 2.1}), "p-garage"} | lines]
        [object("door-" <> room.id, door_box(room, face, z), door, camera)]

      match?(%{room: ^room}, door) ->
        middle = door.middle

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

  # The outer face of the wall at the front of a room (meters).
  defp front_face(room) do
    {line, _range} = edge(room.plan, "y1")
    (line + @thick / @m) * @m
  end

  # The box of a door: just in front of the wall, so the door paints after
  # it.
  defp door_box(room, face, z) do
    p = meters(room.plan)
    {p.x, face, z, p.x + p.w, face + 0.01, z + 2.2}
  end

  # The door of the house is on the largest room of floor 1 with a wall at
  # the front. It is at the middle of the longest part of that wall
  # (inches). With no such room, there is no door (`nil`).
  defp door(rooms) do
    fronts =
      for room <- rooms,
          room.level == "f1",
          parts = outside_parts(room, "y1", rooms),
          parts != [],
          do: {room, parts}

    case fronts do
      [] ->
        nil

      fronts ->
        {room, parts} = Enum.max_by(fronts, fn {room, _} -> room.plan.w * room.plan.d end)
        {a, b} = Enum.max_by(parts, fn {a, b} -> b - a end)
        %{room: room, middle: (a + b) / 2, half: (b - a) / 2}
    end
  end

  # You, in front of the door of the house: a body and a head. You stand
  # beside the door, in front of its part of the wall.
  defp person(nil, _z, _camera), do: []

  defp person(%{room: room} = door, z, camera) do
    side = min(0.6, max(door.half * @m - 0.25, 0.0))
    {x, y} = {door.middle * @m + side, front_face(room) + 0.7}

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

  # A yard, the driveway or a balcony: its furniture and its items. An item
  # that is taller than floor 1 has no right order with the floors over it.
  # It paints by its depth only (`loose`), as an item larger than its room.
  defp yard(room, items, z, camera) do
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
  # the ground (a garage too). The wire hangs a little. The boxes of the
  # wire and of the meter are on the screen.
  defp wire(pole, rooms, z, camera) do
    ground = Enum.filter(rooms, &(&1.level in ["f1", "outside"]))

    case Enum.max_by(ground, &(&1.plan.x + &1.plan.w), fn -> nil end) do
      nil ->
        {nil, nil, [], nil}

      room ->
        p = meters(room.plan)
        at = {p.x + p.w + @thick, p.y + 0.6, z.(room) + 2.0}
        {px, py} = pole
        {fx, fy} = from = Camera.at(camera, {0, 0}, {px, py, @pole - 0.4})
        {tx, ty} = to = Camera.at(camera, {0, 0}, at)
        middle = {(fx + tx) / 2, (fy + ty) / 2 + 6}
        d = "M#{pt(from)} Q#{pt(middle)} #{pt(to)}"

        {ax, ay, az} = at

        meter =
          Camera.faces(
            camera,
            Geometry.box({ax, ay - 0.15, az - 0.25}, {0.08, 0.3, 0.4}),
            "p-meter"
          )

        polys = for {corners, class} <- meter, do: {Camera.points(camera, {0, 0}, corners), class}
        corners = for {corners, _class} <- meter, c <- corners, do: Camera.at(camera, {0, 0}, c)

        {d, screen_box([from, middle, to]), polys, screen_box(corners)}
    end
  end

  defp pt({x, y}), do: "#{Camera.round1(x)},#{Camera.round1(y)}"

  defp screen_box(points) do
    {xs, ys} = Enum.unzip(points)
    {x0, x1} = Enum.min_max(xs)
    {y0, y1} = Enum.min_max(ys)
    {x0, y0, x1 - x0, y1 - y0}
  end

  # The power of the house. It has the watts of the panels on the roof of
  # the picture (`roofs`) and of the other panels. It also has the count
  # and the kWh of the stations. A room on the roof of a garage or of a
  # porch does not show: its panels are with the other panels.
  defp power(house, roofs) do
    on_roof = MapSet.new(roofs, & &1.id)
    of = fn type -> Enum.filter(house.items, &(&1.type == type)) end
    {roof, other} = Enum.split_with(of.("solar_panels"), &MapSet.member?(on_roof, &1.room))
    watts = fn panels -> panels |> Enum.map(& &1.params["watts"]) |> Enum.sum() end

    stations = of.("power_station")
    kwh = for(s <- stations, do: s.params["kwh"] + s.params["extra_kwh"]) |> Enum.sum()

    %{
      roof: watts.(roof),
      other: watts.(other),
      stations: length(stations),
      kwh: Format.value(Float.round(kwh / 1, 1))
    }
  end

  # The labels: the grid at the pole, the watts of the panels on the roof,
  # and the watts of the other panels. The kWh of the stations is at the
  # front of the house.
  defp chips(house, power, {px, py}, roofs, outdoor, inside, lot, z, camera) do
    roof_at =
      case roofs do
        [roof | _] ->
          p = meters(roof.plan)
          {p.x + p.w / 2, p.y + p.d / 2, z.(roof) + p.d / 2 * @pitch + 1.2}

        [] ->
          {px, py, @pole}
      end

    [chip({px, py, @pole + 0.9}, "Grid", camera)] ++
      if(power.roof > 0, do: [chip(roof_at, kw(power.roof), camera)], else: []) ++
      if(power.other > 0,
        do: [chip(panels_at(house, outdoor, lot, z), kw(power.other), camera)],
        else: []
      ) ++
      if(power.stations > 0,
        do: [chip(front_at(inside, lot), "#{power.kwh} kWh", camera)],
        else: []
      )
  end

  # The label of the other panels: over the first yard or balcony with
  # panels, else over the middle of the lot.
  defp panels_at(house, outdoor, lot, z) do
    rooms =
      for item <- house.items, item.type == "solar_panels", into: MapSet.new(), do: item.room

    case Enum.find(outdoor, &MapSet.member?(rooms, &1.id)) do
      nil ->
        {lot.x + lot.w / 2, lot.y + lot.d / 2, 2.0}

      room ->
        p = meters(room.plan)
        {p.x + p.w / 2, p.y + p.d / 2, z.(room) + 2.0}
    end
  end

  # The label of the stations is in front of the room at the front of
  # floor 1, else of any floor. With no room, it is at the front of the lot.
  defp front_at(inside, lot) do
    plans = for room <- inside, do: {room.level == "f1", meters(room.plan)}

    case plans do
      [] ->
        {lot.x + lot.w / 2, lot.y + lot.d - 1.0, 1.5}

      plans ->
        {_f1, p} = Enum.max_by(plans, fn {f1, p} -> {f1, p.y + p.d} end)
        {p.x + p.w / 2, p.y + p.d + 1.0, 3.2}
    end
  end

  defp kw(watts) when watts >= 1000, do: "#{Format.value(Float.round(watts / 1000, 1))} kW"
  defp kw(watts), do: "#{watts} W"

  # A text for a screen reader: what the picture shows.
  defp label(house, power, inside, shown, wire, door) do
    floors = inside |> Enum.map(& &1.level) |> Enum.filter(&String.starts_with?(&1, "f"))
    floors = floors |> Enum.uniq() |> length()
    types = Map.new(house.items, &{&1.id, &1.type})
    names = shown |> Enum.map(&Catalog.kind(types[&1]).name) |> Enum.uniq()

    [
      if(floors > 0, do: "a house with #{Format.count(floors, "floor")}", else: "a lot"),
      Enum.any?(inside, &(&1.level == "outside")) && "a garage",
      power.roof > 0 && "solar panels of #{kw(power.roof)} on the roof",
      power.other > 0 && "other solar panels of #{kw(power.other)}",
      names != [] && "outside: #{Enum.join(names, ", ")}",
      power.stations > 0 && "#{Format.count(power.stations, "power station")} of #{power.kwh} kWh",
      wire && "the wire of the grid",
      door && "you in front of the door"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

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

  ## The sky

  # The places of the stars, in parts of the width and the height of the
  # picture. The sequence fills the top of the sky with no clumps.
  @stars (fn ->
            frac = fn n -> n - Float.floor(n) end
            for i <- 1..16, do: {frac.(i * 0.7548776662), frac.(i * 0.5698402910) * 0.4}
          end).()

  defp frac(n), do: n - Float.floor(n)

  @doc """
  The sky of a picture (`view/1`) at a time of day and with a weather
  (`DIY.Sky`). `back` paints before the house: the sky, the sun or the
  moon, the stars and the clouds. `fall` paints after it: the rain or the
  snow, in a group that moves. `glow` paints last: the warm light of a
  sunset, which does not move. Each shape is `{tag, attributes}`.

  The sun and the moon are at the top left: the grid and its label are at
  the right. The rain and the snow cover all the picture.
  """
  def sky({x, y, w, h}, %{time: time, weather: weather}) do
    s = min(w, h)
    dark? = weather in ["rain", "snow"]

    back =
      [{:rect, %{x: x, y: y, w: w, h: h, class: "p-sky"}}] ++
        light(time, weather, x, y, w, h, s) ++
        stars(time, weather, x, y, w, h, s) ++
        clouds(weather, dark?, x, y, w, h, s)

    glow =
      if time == "sunset", do: [{:rect, %{x: x, y: y, w: w, h: h, class: "p-dusk"}}], else: []

    %{back: back, fall: fall(weather, x, y, w, h, s), glow: glow}
  end

  # The sun by day (not in rain or snow), the low sun at a sunset, and the
  # moon at night. The moon is a disc, and a disc of the sky covers a part
  # of it.
  defp light("night", weather, x, y, w, h, s) when weather in ~w(sun clouds) do
    {cx, cy, r} = {x + 0.12 * w, y + 0.14 * h, 0.035 * s}

    [
      {:circle, %{cx: cx, cy: cy, r: r, class: "p-moon"}},
      {:circle, %{cx: cx + 0.45 * r, cy: cy - 0.25 * r, r: r * 0.85, class: "p-sky-cut"}}
    ]
  end

  defp light("sunset", weather, x, y, w, h, s) when weather in ~w(sun clouds),
    do: [{:circle, %{cx: x + 0.1 * w, cy: y + 0.3 * h, r: 0.06 * s, class: "p-sun-low"}}]

  defp light("day", weather, x, y, w, h, s) when weather in ~w(sun clouds),
    do: [{:circle, %{cx: x + 0.12 * w, cy: y + 0.14 * h, r: 0.045 * s, class: "p-sun"}}]

  defp light(_time, _weather, _x, _y, _w, _h, _s), do: []

  # The stars of a night with no rain and no snow: fewer with clouds.
  defp stars("night", weather, x, y, w, h, s) when weather in ~w(sun clouds) do
    count = if weather == "sun", do: 16, else: 6

    for {fx, fy} <- Enum.take(@stars, count),
        do: {:circle, %{cx: x + fx * w, cy: y + 0.02 * h + fy * h, r: 0.004 * s, class: "p-star"}}
  end

  defp stars(_time, _weather, _x, _y, _w, _h, _s), do: []

  # The clouds: a flat base and three round tops. Rain and snow have more
  # clouds, and darker.
  defp clouds("sun", _dark?, _x, _y, _w, _h, _s), do: []

  defp clouds(_weather, dark?, x, y, w, h, s) do
    class = if dark?, do: "p-cloud-dark", else: "p-cloud"
    places = [{0.22, 0.1, 1.0}, {0.52, 0.06, 0.8}, {0.74, 0.16, 1.1}]
    places = if dark?, do: [{0.06, 0.2, 0.9} | places], else: places

    for {fx, fy, size} <- places,
        u = 0.05 * s * size,
        {cx, cy} = {x + fx * w, y + fy * h},
        shape <- [
          {:ellipse, %{cx: cx, cy: cy + 0.5 * u, rx: 2.2 * u, ry: 0.55 * u, class: class}},
          {:circle, %{cx: cx - 1.0 * u, cy: cy + 0.2 * u, r: 0.75 * u, class: class}},
          {:circle, %{cx: cx + 0.1 * u, cy: cy - 0.2 * u, r: 1.0 * u, class: class}},
          {:circle, %{cx: cx + 1.1 * u, cy: cy + 0.25 * u, r: 0.7 * u, class: class}}
        ],
        do: shape
  end

  # The rain: short lines that fall to the left. The snow: small flakes.
  # They are in a group that moves for a short time (app.css).
  defp fall("rain", x, y, w, h, s) do
    d =
      Enum.map_join(1..60, " ", fn i ->
        {px, py} = {x + frac(i * 0.7548776662) * w, y + frac(i * 0.5698402910) * h}

        "M#{Camera.round1(px)} #{Camera.round1(py)}l#{Camera.round1(-0.01 * s)} #{Camera.round1(0.045 * s)}"
      end)

    [{:path, %{d: d, class: "p-rain"}}]
  end

  defp fall("snow", x, y, w, h, s) do
    for i <- 1..70 do
      {px, py} = {x + frac(i * 0.7548776662) * w, y + frac(i * 0.5698402910) * h}
      {:circle, %{cx: px, cy: py, r: 0.006 * s, class: "p-snow"}}
    end
  end

  defp fall(_weather, _x, _y, _w, _h, _s), do: []

  @doc """
  The sky of a picture in words, for a screen reader: for example "a
  night with rain".
  """
  def sky_label(%{time: time, weather: weather}) do
    times = %{"day" => "a day", "sunset" => "a sunset", "night" => "a night"}
    weathers = %{"sun" => "a clear sky", "clouds" => "clouds", "rain" => "rain", "snow" => "snow"}
    "#{times[time]} with #{weathers[weather]}"
  end

  attr :view, :map, required: true, doc: "the picture (`view/1`)"

  attr :sky, :map,
    default: %{time: "day", weather: "sun"},
    doc: "the time of day and the weather (`DIY.Sky.pick/2`)"

  @doc """
  The SVG of the house from the outside, in the look of the plan, with its
  sky. The colors of the house follow the time of day of the sky (app.css,
  `data-scene`), not the theme of the page.
  """
  def house(assigns) do
    assigns =
      assign(assigns,
        box: Cutaway.box_text(assigns.view.box),
        shapes: sky(assigns.view.box, assigns.sky)
      )

    ~H"""
    <svg
      viewBox={@box}
      class="cutaway cutaway-house cutaway-outside block w-full"
      data-scene={@sky.time}
      data-weather={@sky.weather}
      aria-hidden="true"
    >
      <Cutaway.defs camera={@view.camera} />
      <%!-- One group for the shapes of the sky: a new weather adds shapes,
      and the objects after them do not move. --%>
      <g id="outside-back"><.shapes list={@shapes.back} /></g>
      <polygon :for={{points, class} <- @view.level.ground} points={points} class={class} />
      <g :for={room <- @view.level.low}>
        <polygon :for={{points, class} <- room.polys} points={points} class={class} />
      </g>
      <polygon :for={{points, class, _room} <- @view.level.slabs} points={points} class={class} />
      <g :for={room <- @view.level.rooms}>
        <polygon :for={{points, class} <- room.polys} points={points} class={class} />
      </g>
      <%!-- An id for each object: an update of the page (a new weather) keeps
      its polygons, so a loop of an item does not start again. --%>
      <g
        :for={object <- @view.level.objects}
        id={"outside-#{object.id}"}
        class={object.kind == :item && "p-item"}
      >
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
      <g class={"p-fall p-fall-#{@sky.weather}"}><.shapes list={@shapes.fall} /></g>
      <.shapes list={@shapes.glow} />
    </svg>
    """
  end

  attr :id, :string, required: true
  attr :pick, :map, required: true, doc: "the choice: `\"now\"` or a value of `DIY.Sky`"
  attr :now, :map, default: nil, doc: "the sky at the house now (`DIY.Sky.now/3`), or nil"

  @doc """
  The choice of the sky of the picture: a time of day and a weather. The
  first value of each is the sky at the house now. It sends `sky_pick`.
  """
  def sky_form(assigns) do
    ~H"""
    <form id={@id} phx-change="sky_pick" class="space-y-1" lang={Gettext.get_locale(DIY.Gettext)}>
      <div class="grid grid-cols-2 gap-2">
        <label class="text-sm">
          <span class="block font-semibold">{gettext("Time of day")}</span>
          <select name="time" class="select select-sm w-full">
            <option value="now" selected={@pick["time"] == "now"}>
              {now_name(@now && now_time(@now))}
            </option>
            <option :for={time <- DIY.Sky.times()} value={time} selected={@pick["time"] == time}>
              {time_name(time)}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block font-semibold">{gettext("Weather")}</span>
          <select name="weather" class="select select-sm w-full">
            <option value="now" selected={@pick["weather"] == "now"}>
              {now_name(@now && weather_name(@now.weather))}
            </option>
            <option
              :for={weather <- DIY.Sky.weathers()}
              value={weather}
              selected={@pick["weather"] == weather}
            >
              {weather_name(weather)}
            </option>
          </select>
        </label>
      </div>
      <p :if={@now} id={"#{@id}-now"} class="text-xs opacity-70">
        {gettext("Now at the house: %{temp} °F, %{time}, %{weather}.",
          temp: round(@now.temp),
          time: String.downcase(now_time(@now)),
          weather: String.downcase(weather_name(@now.weather))
        )}
      </p>
    </form>
    """
  end

  defp now_name(nil), do: gettext("Now")
  defp now_name(name), do: gettext("Now (%{name})", name: name)

  # Near the sunrise, the sky of now is a sunrise: the picture is the same
  # as at a sunset.
  defp now_time(%{time: "sunset", dawn: true}), do: gettext("Sunrise")
  defp now_time(%{time: time}), do: time_name(time)

  defp time_name("day"), do: gettext("Day")
  defp time_name("sunset"), do: gettext("Sunset")
  defp time_name("night"), do: gettext("Night")

  defp weather_name("sun"), do: gettext("Sun")
  defp weather_name("clouds"), do: gettext("Clouds")
  defp weather_name("rain"), do: gettext("Rain")
  defp weather_name("snow"), do: gettext("Snow")

  attr :list, :list, required: true

  # The shapes of the sky (`sky/2`), in their order.
  defp shapes(assigns) do
    ~H"""
    <%= for {tag, a} <- @list do %>
      <rect :if={tag == :rect} x={r(a.x)} y={r(a.y)} width={r(a.w)} height={r(a.h)} class={a.class} />
      <circle :if={tag == :circle} cx={r(a.cx)} cy={r(a.cy)} r={r(a.r)} class={a.class} />
      <ellipse
        :if={tag == :ellipse}
        cx={r(a.cx)}
        cy={r(a.cy)}
        rx={r(a.rx)}
        ry={r(a.ry)}
        class={a.class}
      />
      <path :if={tag == :path} d={a.d} class={a.class} />
    <% end %>
    """
  end

  defp r(n), do: Camera.round1(n)
end
