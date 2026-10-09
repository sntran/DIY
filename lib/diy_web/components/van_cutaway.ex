defmodule DIYWeb.VanCutaway do
  @moduledoc """
  The inside of a camper van at scale, cut open as the house is
  (`DIYWeb.Cutaway`). The van has two layers: its floor, and its roof over
  it with a gap. The same component draws it (`DIYWeb.Cutaway.cutaway/1`),
  and the same hook moves the items and the zones.

  The plan of the van is `DIY.Layout.van_box/1`. `x` goes across the van,
  from its right side (the side of the sliding door). `y` goes along it,
  from the doors at the back to the cab. The zones (`DIY.Catalog.zones/0`)
  are the rooms of the van. The cab and the roof of the van are fixed:
  they have no handles.

  The camera of a van (`DIYWeb.Camera.van/0`) is at its left side (the
  side of the driver). The cab is at the left of the screen. The floor
  shows the parts of the model of the van (`DIY.Catalog.van_size/1`). The
  wall on the right side has the full height of the cargo area, with the
  opening of the sliding door. The doors at the back are cut on a slope:
  full at the right side, and near the floor at the left side. The wall on
  the left side is cut near the floor. The floor also shows the wheel
  wells, the wheels, the seats, the dash, the steering wheel and the hood.
  The shell of the build gives the materials: the floor of wood, the walls
  with panels, and the insulation in the cut of the walls.
  """

  alias DIY.{Build, Catalog, Layout}
  alias DIYWeb.{Camera, Cutaway, Geometry}
  alias DIYWeb.Icon.Shapes

  # One inch in meters.
  @m 0.0254

  # The numbers of the picture, in inches. They are near the real vans, but
  # they are for the picture only. They are the cargo floor over the
  # ground, the radius of a tire, and the length and the height of a wheel
  # well. Then the depth of the dash, and the opening of the sliding door.
  @floor 24
  @tire 15
  @well_d 34
  @well_h 11
  @dash 14
  @door 48

  # The cut of a wall near the floor (meters).
  @low 0.25

  @doc """
  The two layers of a van (its floor and its roof), and the box of the
  SVG, as `DIYWeb.Cutaway.view/1` gives them.
  """
  def view(build, van) do
    camera = Camera.van()
    size = Catalog.van_size(van.params["model"])
    zones = Build.zones(build, van.id)

    shell =
      for zone <- zones,
          zone.place == :shell,
          item <- Build.items_in(build, zone.id),
          do: item.type

    {on_roof, on_floor} =
      zones |> Enum.filter(& &1.plan) |> Enum.split_with(&(&1.place == :van_roof))

    items = Enum.group_by(build.items, & &1.room)
    # The roof is high over the floor, so that the two do not overlap on
    # the screen (as the floors of the house).
    box = %{w: size.cargo_width * @m, d: (size.cargo_length + Layout.cab()) * @m}
    roof_z = Cutaway.gap(camera, box, size.cargo_height * @m)

    Cutaway.frame(
      [
        floor_layer(van, size, on_floor, items, shell, camera),
        roof_layer(size, on_roof, items, roof_z, camera)
      ],
      camera
    )
  end

  ## The floor

  defp floor_layer(van, size, zones, items, shell, camera) do
    t = side(size)
    {cw, cab_end} = {size.cargo_width, size.cargo_length + Layout.cab()}
    axles = DIY.Van.axles(van)
    floor = if "van_floor" in shell, do: "wood", else: "vmetal"

    swivels =
      for zone <- zones,
          zone.place == :cab,
          item <- Map.get(items, zone.id, []),
          item.type == "swivel_seat",
          do: {zone, item}

    item_views =
      for zone <- zones,
          item <- Map.get(items, zone.id, []),
          do: Cutaway.item_view(item, zone, 0.0, camera)

    Cutaway.layer(%{id: "floor", name: "Floor of the van", z: 0.0, camera: camera}, %{
      ground: ground(size, t, axles.nose, camera) ++ wheels(size, t, axles, camera),
      low: [],
      slabs:
        solid(
          camera,
          {-t * @m, -t * @m, -0.16},
          {(cw + 2 * t) * @m, (cab_end + t) * @m, 0.16},
          "white"
        ),
      rooms:
        for(
          zone <- zones,
          do:
            Cutaway.floor(
              zone,
              0.0,
              if(zone.place == :cab, do: "vmat", else: floor),
              camera,
              zone.place == :cab
            )
        ),
      objects:
        walls(size, t, shell, camera) ++
          wells(size, axles.rear, camera) ++
          seats(size, swivels, camera) ++ cab(size, t, axles.nose, van, camera) ++ item_views,
      labels: Enum.map(zones, &Cutaway.label(&1, 0.0, camera))
    })
  end

  # The thickness of a side of the van, in inches: the body is wider than
  # the cargo floor.
  defp side(size), do: max(2, div(size.width - size.cargo_width, 2))

  # A tile of the ground under the van, with a pad of asphalt.
  defp ground(size, t, front, camera) do
    {x0, y0, w, d} = {-t - 30, -t - 40, size.cargo_width + 2 * t + 60, front + t + 70}
    z = -@floor * @m
    lot = Geometry.box({x0 * @m, y0 * @m, z - 0.45}, {w * @m, d * @m, 0.45})

    Camera.faces(camera, lot, "p-lot") ++
      [
        {[
           {(x0 + 12) * @m, (y0 + 12) * @m, z},
           {(x0 + w - 12) * @m, (y0 + 12) * @m, z},
           {(x0 + w - 12) * @m, (y0 + d - 12) * @m, z},
           {(x0 + 12) * @m, (y0 + d - 12) * @m, z}
         ], "p-floor p-asphalt"}
      ]
  end

  # The four wheels at the axles of the model, under the body. Each is a
  # tire with its hub on its outer face (x + w), to the camera.
  defp wheels(size, t, axles, camera) do
    {r, z} = {@tire * @m, (-@floor + @tire) * @m}

    for y <- [axles.rear, axles.front],
        x <- [-t + 1, size.cargo_width + t - 10],
        part <- tire({x * @m, y * @m, z}, r, camera),
        do: part
  end

  defp tire({x, y, z}, r, camera) do
    w = 9 * @m
    outer = {x + w, y, z}
    hub = Geometry.add(outer, {0.005, 0, 0})

    solid(camera, {x, y - r * 0.9, z - r}, {w, 1.8 * r, 2 * r}, "dark") ++
      [
        {Geometry.circle(outer, {0, 1, 0}, {0, 0, 1}, r), "i-black"},
        {Geometry.circle(hub, {0, 1, 0}, {0, 0, 1}, r * 0.5), "i-steel-r"}
      ]
  end

  # The walls of the van. The right side (x = 0, far from the camera) has
  # the full height of the cargo area, and the opening of the sliding door.
  # The doors at the back are cut on a slope (`DIYWeb.Cutaway.slope/3`):
  # full at the right side, and near the floor at the left side. The left
  # side (the side of the driver, near the camera) is cut near the floor.
  # Panels and insulation of the shell show on the walls and in their cut.
  # The wall at the back fills the two corners.
  defp walls(size, t, shell, camera) do
    {cw, cargo, cab_end} = {size.cargo_width, size.cargo_length, size.cargo_length + Layout.cab()}
    material = if "walls" in shell, do: "p-vpanel", else: "p-vwall"
    top = if "insulation" in shell, do: "p-vinsul-t", else: material <> "-t"
    full = size.cargo_height * @m
    {door0, door1} = {cargo - @door - 2, cargo - 2}
    slope = &Cutaway.slope(&1, {0, cw}, {full, @low})
    classes = {material, top, camera}

    [
      wall(
        "back",
        {-t, -t},
        {cw + 2 * t, t},
        {0, 0, cw, 0},
        {slope.(-t), slope.(cw + t)},
        classes
      ),
      wall("right-back", {-t, 0}, {t, door0}, {0, 0, 0, door0}, {full, full}, classes),
      wall(
        "right-front",
        {-t, door1},
        {t, cab_end - door1},
        {0, door1, 0, cab_end},
        {full, full},
        classes
      ),
      wall("left", {cw, 0}, {t, cab_end}, {cw, 0, cw, cab_end}, {@low, @low}, classes)
    ]
  end

  # A wall: its box (inches), and its line for the order of the paint (as
  # the walls of the house). Then its height at its two ends along x
  # (meters), and its classes.
  defp wall(id, {x, y}, {w, d}, {lx0, ly0, lx1, ly1}, {h0, h1}, {material, top, camera}) do
    shape = Geometry.wedge({x * @m, y * @m, 0}, {w * @m, d * @m}, {h0, h1}, :x)
    [shade, lit, {corners, _top}] = Camera.faces(camera, shape, material)

    %{
      id: "van-wall-" <> id,
      kind: :wall,
      loose: false,
      box: {lx0 * @m, ly0 * @m, 0, lx1 * @m, ly1 * @m, max(h0, h1)},
      key: Camera.depth(camera, {(lx0 + lx1) / 2 * @m, (ly0 + ly1) / 2 * @m, 0}),
      polys: [shade, lit, {corners, top}]
    }
  end

  # The wheel wells over the rear axle, on each side of the cargo floor. They
  # paint before the items over them (a bed on the wells).
  defp wells(size, rear, camera) do
    w = div(size.cargo_width - size.wells, 2)
    y = rear - div(@well_d, 2)

    for {id, x} <- [{"right", 0}, {"left", size.cargo_width - w}] do
      fixture(
        "well-" <> id,
        solid(camera, {x * @m, y * @m, 0}, {w * @m, @well_d * @m, @well_h * @m}, "white"),
        -1.0,
        camera
      )
    end
  end

  # The seats of the driver (on the left side, near x = w) and of the
  # passenger, in the cab. A swivel seat (an item) takes the place of the
  # seat that it is on.
  defp seats(size, swivels, camera) do
    cargo = size.cargo_length

    for {id, x} <- [{"driver", size.cargo_width - 23}, {"passenger", 3}],
        plan = %{x: x, y: cargo + 6, w: 20, d: 22},
        not Enum.any?(swivels, fn {zone, item} ->
          Layout.overlap?(
            plan,
            Layout.item_box(%{
              item
              | at: %{x: zone.plan.x + item.at.x, y: zone.plan.y + item.at.y}
            })
          )
        end) do
      model = [
        {:box, {0, 0, 0}, {20 * @m, 22 * @m, 0.3}, "dark"},
        {:box, {0, 0, 0.3}, {20 * @m, 22 * @m, 0.12}, "gray"},
        {:box, {0, 0, 0.42}, {20 * @m, 5 * @m, 0.6}, "gray"}
      ]

      frame = %{at: {x * @m, (cargo + 6) * @m, 0}, turn: 0, camera: camera}
      polys = Shapes.placed_model(model, frame)

      fixture(
        "seat-" <> id,
        for({:poly, corners, class} <- polys, do: {corners, class}),
        nil,
        camera
      )
    end
  end

  # The front of the cab: the dash, and the steering wheel in front of the
  # driver. Then the hood, with its lights and its bumper.
  defp cab(size, t, front, van, camera) do
    {cw, dash} = {size.cargo_width, size.cargo_length + Layout.cab()}
    hood = max(0.25, Shapes.hood_height(van.params["model"]) - @floor * @m)
    wheel = {(cw - 13) * @m, (dash - 4) * @m, 0.67}
    tilt = {0, -0.5, 0.866}

    [
      fixture(
        "dash",
        solid(camera, {0, dash * @m, 0}, {cw * @m, @dash * @m, 0.5}, "dark"),
        nil,
        camera
      ),
      fixture(
        "wheel",
        [
          {Geometry.circle(wheel, {1, 0, 0}, tilt, 0.19), "i-black"},
          {Geometry.circle(Geometry.add(wheel, {0, -0.01, 0.01}), {1, 0, 0}, tilt, 0.06),
           "i-gray-t"}
        ],
        nil,
        camera
      ),
      fixture(
        "hood",
        solid(
          camera,
          {(-t + 1) * @m, (dash + @dash) * @m, -0.16},
          {(cw + 2 * t - 2) * @m, (front - dash - @dash) * @m, hood + 0.16},
          "white"
        ) ++
          for(
            x <- [0, cw - 10],
            do:
              {Geometry.on_plane(
                 {x * @m, front * @m + 0.002, hood - 0.12},
                 {1, 0, 0},
                 {0, 0, 1},
                 {0, 0},
                 {10 * @m, 0.08}
               ), "i-bulb"}
          ),
        nil,
        camera
      ),
      fixture(
        "bumper",
        solid(camera, {-t * @m, front * @m, -0.3}, {(cw + 2 * t) * @m, 4 * @m, 0.16}, "dark"),
        nil,
        camera
      )
    ]
  end

  # A fixed part of the van as an object of the order of the paint. Its box
  # comes from its polygons. Its key is the depth of the middle of its box,
  # or a key.
  defp fixture(id, polys, key, camera) do
    points = Enum.flat_map(polys, &elem(&1, 0))
    {x0, x1} = points |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
    {y0, y1} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    {z0, z1} = points |> Enum.map(&elem(&1, 2)) |> Enum.min_max()

    %{
      id: "van-" <> id,
      kind: :fixture,
      loose: false,
      box: {x0, y0, z0, x1, y1, z1},
      key: key || Camera.depth(camera, {(x0 + x1) / 2, (y0 + y1) / 2, 0}),
      polys: polys
    }
  end

  # The faces of a box (meters) of a material of the icons.
  defp solid(camera, corner, size, material) do
    for {corners, class} <- Camera.faces(camera, Geometry.box(corner, size), "i-" <> material),
        do: {corners, class <> " i-face"}
  end

  ## The roof

  # The roof of the van over its floor: the zone of the roof on it, with its
  # items (the fan and the panels).
  defp roof_layer(size, zones, items, z, camera) do
    t = side(size)
    cab_end = size.cargo_length + Layout.cab()

    Cutaway.layer(%{id: "roof", name: "Roof of the van", z: z, camera: camera}, %{
      ground: [],
      low: [],
      slabs:
        solid(
          camera,
          {-t * @m, -t * @m, z - 0.08},
          {(size.cargo_width + 2 * t) * @m, (cab_end + t) * @m, 0.08},
          "white"
        ),
      rooms: Enum.map(zones, &Cutaway.floor(&1, z, "vroof", camera, true)),
      objects:
        for(
          zone <- zones,
          item <- Map.get(items, zone.id, []),
          do: Cutaway.item_view(item, zone, z, camera)
        ),
      labels: Enum.map(zones, &Cutaway.label(&1, z, camera))
    })
  end
end
