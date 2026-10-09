defmodule DIYWeb.VanCutaway do
  @moduledoc """
  The inside of a camper van at scale, cut open as the house is
  (`DIYWeb.Cutaway`). The van has two layers: its floor, and its roof over
  it with a gap. The same component draws it (`DIYWeb.Cutaway.cutaway/1`),
  and the same hook moves the items and the zones.

  The plan of the van is `DIY.Layout.van_box/1`. `x` goes across the van,
  from its left side (the side of the driver). `y` goes along it, from the
  doors at the back to the cab. The zones (`DIY.Catalog.zones/0`) are the
  rooms of the van. The cab and the roof of the van are fixed: they have
  no handles.

  The floor shows the parts of the model of the van
  (`DIY.Catalog.van_size/1`). The walls on the left side and at the back
  are cut at the height of a table. The wall on the right side is cut near
  the floor.
  The floor also shows the sliding door, the wheel wells, the wheels, the seats, the
  dash, the steering wheel and the hood. The shell of the build gives the
  materials: the floor of wood, the walls with panels, and the insulation
  in the cut of the walls.
  """

  alias DIY.{Build, Catalog, Layout}
  alias DIYWeb.Cutaway
  alias DIYWeb.Icon.Shapes
  alias DIYWeb.Iso

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

  # The cut of a wall at the back and at the front (meters).
  @high 1.1
  @low 0.25

  @doc """
  The two layers of a van (its floor and its roof), and the box of the
  SVG, as `DIYWeb.Cutaway.view/1` gives them.
  """
  def view(build, van) do
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
    roof_z = (size.cargo_width + size.cargo_length + Layout.cab()) * @m / 2 + 1.5

    Cutaway.frame([
      floor_layer(van, size, on_floor, items, shell),
      roof_layer(size, on_roof, items, roof_z)
    ])
  end

  ## The floor

  defp floor_layer(van, size, zones, items, shell) do
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
          do: Cutaway.item_view(item, zone, 0.0)

    Cutaway.layer(%{id: "floor", name: "Floor of the van", z: 0.0}, %{
      ground: ground(size, t, axles.nose) ++ wheels(size, t, axles),
      low: [],
      slabs:
        solid({-t * @m, -t * @m, -0.16}, {(cw + 2 * t) * @m, (cab_end + t) * @m, 0.16}, "white"),
      rooms:
        for(
          zone <- zones,
          do:
            Cutaway.floor(
              zone,
              0.0,
              if(zone.place == :cab, do: "vmat", else: floor),
              zone.place == :cab
            )
        ),
      objects:
        walls(size, t, shell) ++
          wells(size, axles.rear) ++
          seats(size, swivels) ++ cab(size, t, axles.nose, van) ++ item_views,
      labels: Enum.map(zones, &Cutaway.label(&1, 0.0))
    })
  end

  # The thickness of a side of the van, in inches: the body is wider than
  # the cargo floor.
  defp side(size), do: max(2, div(size.width - size.cargo_width, 2))

  # A tile of the ground under the van, with a pad of asphalt.
  defp ground(size, t, front) do
    {x0, y0, w, d} = {-t - 30, -t - 40, size.cargo_width + 2 * t + 60, front + t + 70}
    z = -@floor * @m

    Cutaway.faces(Iso.box({x0 * @m, y0 * @m, z - 0.45}, {w * @m, d * @m, 0.45}), "p-lot") ++
      [
        {[
           {(x0 + 12) * @m, (y0 + 12) * @m, z},
           {(x0 + w - 12) * @m, (y0 + 12) * @m, z},
           {(x0 + w - 12) * @m, (y0 + d - 12) * @m, z},
           {(x0 + 12) * @m, (y0 + d - 12) * @m, z}
         ], "p-floor p-asphalt"}
      ]
  end

  # The four wheels at the axles of the model, under the body: a tire and
  # its hub on the right side of each.
  defp wheels(size, t, axles) do
    {r, z} = {@tire * @m, (-@floor + @tire) * @m}

    for y <- [axles.rear, axles.front],
        x <- [-t + 1, size.cargo_width + t - 10],
        part <- tire({x * @m, y * @m, z}, r),
        do: part
  end

  defp tire({x, y, z}, r) do
    w = 9 * @m
    outer = {x + w, y, z}

    solid({x, y - r * 0.9, z - r}, {w, 1.8 * r, 2 * r}, "dark") ++
      [
        {Iso.circle(outer, {0, 1, 0}, {0, 0, 1}, r), "i-black"},
        {Iso.circle(Iso.add(outer, {0.005, 0, 0}), {0, 1, 0}, {0, 0, 1}, r * 0.5), "i-steel-r"}
      ]
  end

  # The walls of the van. The right side (x = 0) has the opening of the
  # sliding door. It is cut at the height of a table, as the doors at the
  # back. The left side (the side of the driver) is cut near the floor.
  # Panels and insulation of the shell show on the walls and in their cut.
  # The wall at the back fills the two corners.
  defp walls(size, t, shell) do
    {cw, cargo, cab_end} = {size.cargo_width, size.cargo_length, size.cargo_length + Layout.cab()}
    material = if "walls" in shell, do: "p-vpanel", else: "p-vwall"
    top = if "insulation" in shell, do: "p-vinsul-t", else: material <> "-t"
    opening = {cargo - @door - 2, cargo - 2}

    {door0, door1} = opening

    [
      wall("back", {-t, -t}, {cw + 2 * t, t}, {0, 0, cw, 0}, @high, {material, top}),
      wall("right-back", {-t, 0}, {t, door0}, {0, 0, 0, door0}, @high, {material, top}),
      wall(
        "right-front",
        {-t, door1},
        {t, cab_end - door1},
        {0, door1, 0, cab_end},
        @high,
        {material, top}
      ),
      wall("left", {cw, 0}, {t, cab_end}, {cw, 0, cw, cab_end}, @low, {material, top})
    ]
  end

  # A wall: its box (inches), its line for the order of the paint (as the
  # walls of the house), its height (meters) and its classes.
  defp wall(id, {x, y}, {w, d}, {lx0, ly0, lx1, ly1}, height, {material, top}) do
    box = Iso.box({x * @m, y * @m, 0}, {w * @m, d * @m, height})

    %{
      id: "van-wall-" <> id,
      kind: :wall,
      loose: false,
      box: {lx0 * @m, ly0 * @m, 0, lx1 * @m, ly1 * @m, height},
      key: (lx0 + lx1 + ly0 + ly1) / 2 * @m,
      polys: [{box.left, material <> "-l"}, {box.right, material <> "-r"}, {box.top, top}]
    }
  end

  # The wheel wells over the rear axle, on each side of the cargo floor. They
  # paint before the items over them (a bed on the wells).
  defp wells(size, rear) do
    w = div(size.cargo_width - size.wells, 2)
    y = rear - div(@well_d, 2)

    for {id, x} <- [{"right", 0}, {"left", size.cargo_width - w}] do
      fixture(
        "well-" <> id,
        solid({x * @m, y * @m, 0}, {w * @m, @well_d * @m, @well_h * @m}, "white"),
        -1.0
      )
    end
  end

  # The seats of the driver (on the left side, near x = w) and of the
  # passenger, in the cab. A swivel seat (an item) takes the place of the
  # seat that it is on.
  defp seats(size, swivels) do
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

      polys = Shapes.placed_model(model, %{at: {x * @m, (cargo + 6) * @m, 0}, turn: 0})
      fixture("seat-" <> id, for({:poly, corners, class} <- polys, do: {corners, class}), nil)
    end
  end

  # The front of the cab: the dash, and the steering wheel in front of the
  # driver. Then the hood, with its lights and its bumper.
  defp cab(size, t, front, van) do
    {cw, dash} = {size.cargo_width, size.cargo_length + Layout.cab()}
    hood = max(0.25, Shapes.hood_height(van.params["model"]) - @floor * @m)
    wheel = {(cw - 13) * @m, (dash - 3) * @m, 0.62}
    tilt = {0, -0.5, 0.866}

    [
      fixture("dash", solid({0, dash * @m, 0}, {cw * @m, @dash * @m, 0.5}, "dark"), nil),
      fixture(
        "wheel",
        [
          {Iso.circle(wheel, {1, 0, 0}, tilt, 0.19), "i-black"},
          {Iso.circle(Iso.add(wheel, {0, -0.01, 0.01}), {1, 0, 0}, tilt, 0.06), "i-gray-t"}
        ],
        nil
      ),
      fixture(
        "hood",
        solid(
          {(-t + 1) * @m, (dash + @dash) * @m, -0.16},
          {(cw + 2 * t - 2) * @m, (front - dash - @dash) * @m, hood + 0.16},
          "white"
        ) ++
          for(
            x <- [0, cw - 10],
            do:
              {Iso.on_plane(
                 {x * @m, front * @m + 0.002, hood - 0.12},
                 {1, 0, 0},
                 {0, 0, 1},
                 {0, 0},
                 {10 * @m, 0.08}
               ), "i-bulb"}
          ),
        nil
      ),
      fixture(
        "bumper",
        solid({-t * @m, front * @m, -0.3}, {(cw + 2 * t) * @m, 4 * @m, 0.16}, "dark"),
        nil
      )
    ]
  end

  # A fixed part of the van as an object of the order of the paint. Its box
  # comes from its polygons. Its key is the middle of its box, or a key.
  defp fixture(id, polys, key) do
    points = Enum.flat_map(polys, &elem(&1, 0))
    {x0, x1} = points |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
    {y0, y1} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    {z0, z1} = points |> Enum.map(&elem(&1, 2)) |> Enum.min_max()

    %{
      id: "van-" <> id,
      kind: :fixture,
      loose: false,
      box: {x0, y0, z0, x1, y1, z1},
      key: key || (x0 + x1 + y0 + y1) / 2,
      polys: polys
    }
  end

  # The faces of a box (meters) of a material of the icons.
  defp solid(corner, size, material) do
    box = Iso.box(corner, size)

    [
      {box.left, "i-#{material}-l i-face"},
      {box.right, "i-#{material}-r i-face"},
      {box.top, "i-#{material}-t i-face"}
    ]
  end

  ## The roof

  # The roof of the van over its floor: the zone of the roof on it, with its
  # items (the fan and the panels).
  defp roof_layer(size, zones, items, z) do
    t = side(size)
    cab_end = size.cargo_length + Layout.cab()

    Cutaway.layer(%{id: "roof", name: "Roof of the van", z: z}, %{
      ground: [],
      low: [],
      slabs:
        solid(
          {-t * @m, -t * @m, z - 0.08},
          {(size.cargo_width + 2 * t) * @m, (cab_end + t) * @m, 0.08},
          "white"
        ),
      rooms: Enum.map(zones, &Cutaway.floor(&1, z, "vroof", true)),
      objects:
        for(
          zone <- zones,
          item <- Map.get(items, zone.id, []),
          do: Cutaway.item_view(item, zone, z)
        ),
      labels: Enum.map(zones, &Cutaway.label(&1, z))
    })
  end
end
