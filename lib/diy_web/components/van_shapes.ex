defmodule DIYWeb.Icon.VanShapes do
  @moduledoc """
  The models of the vans (`DIY.Catalog.van_models/0`), at their real size
  in meters, as parts of `DIYWeb.Icon.Shapes`. The models of one make have
  the same front.

  The front of a van looks to y, and its right side (the side of the
  sliding door) is at x = 0 (`DIYWeb.Geometry`). The body is a hull
  (`DIYWeb.Icon.Shapes.hull/5`): the side profile of its model across the
  width of the van. Its sides lean in over the belt, the edge of its roof
  is round, and the corners of its nose are round.

  The profiles are traces of the side views of drawings of each make. The
  drawings are the previews of Outlines (getoutlines.com), 2019 to 2023.
  A trace is a line of points `{d, z}` in meters: `d` back from the
  front, and `z` up from the ground. The line goes from the bottom of the
  front bumper, up the nose, over the hood, the windshield and the roof.
  A second line goes from the roof down the back to the bottom of the
  back bumper. Its points are `{e, z}`, with `e` from the back. So a long
  van has the same front and back as a short one. The highest point of
  each line is `:top`: the height of the model. The points over 2 m
  stretch to that height (`stretch/3`): so the cab keeps its height. The
  lean, the edges and the details come from the drawings and from photos.
  The photos are the side photo of the owner (a Transit 148 in, medium
  roof), and the photos of Ram of the 2023 ProMaster.

  The length, the width, the height and the axles come from
  `DIY.Catalog.van_size/1`.

  - Ford Transit: a short hood that slopes up into the windshield in
    nearly one line. Over the windshield, the roof rises in a smooth curve.
    A grille in the shape of a hexagon, with the oval, and lights that
    sweep back along the hood.
  - Mercedes-Benz Sprinter: a long hood, and a roof that rises in a round
    curve from the top of the windshield. The sides lean in the most. A
    grille with three bars and the star, and long lights.
  - Ram ProMaster: a very short nose, and a near straight line from the
    hood to the roof. Its sides are nearly upright, and the edge of its
    roof is round. The lights are high at the corners. The grille is low
    in a large black bumper.
  """

  alias DIY.Catalog
  alias DIYWeb.Icon.Shapes

  @inch 0.0254

  # The points over this height stretch to the height of the model.
  @cab 2.0

  # The traces of the drawings: the front line, the back line, and the
  # height of the roof in the drawing.
  @transit_medium %{
    top: 2.556,
    front: [
      {0.345, 0.358},
      {0.169, 0.386},
      {0.079, 0.424},
      {0.038, 0.486},
      {0.003, 0.654},
      {0.003, 0.752},
      {0.077, 0.831},
      {0.1, 0.885},
      {0.079, 1.084},
      {0.143, 1.148},
      {0.192, 1.253},
      {0.644, 1.414},
      {0.862, 1.452},
      {1.649, 2.045},
      {2.002, 2.28},
      {2.275, 2.416},
      {2.495, 2.477},
      {2.674, 2.503},
      {2.927, :top}
    ],
    back: [
      {0.263, :top},
      {0.225, 2.498},
      {0.182, 2.362},
      {0.128, 1.93},
      {0.102, 1.47},
      {0.077, 1.342},
      {0.051, 0.754},
      {0.005, 0.473},
      {0.02, 0.417},
      {0.049, 0.394},
      {0.243, 0.358}
    ]
  }

  @transit_high %{
    top: 2.753,
    front: [
      {0.344, 0.382},
      {0.219, 0.385},
      {0.115, 0.433},
      {0.066, 0.487},
      {0.008, 0.683},
      {0.015, 0.737},
      {0.12, 0.861},
      {0.104, 1.03},
      {0.161, 1.121},
      {0.161, 1.203},
      {0.178, 1.236},
      {0.26, 1.282},
      {0.668, 1.409},
      {0.859, 1.448},
      {1.975, 2.37},
      {2.25, 2.554},
      {2.523, 2.663},
      {2.742, :top}
    ],
    back: [
      {0.313, :top},
      {0.275, 2.694},
      {0.217, 2.574},
      {0.155, 2.38},
      {0.127, 2.179},
      {0.127, 1.924},
      {0.102, 1.797},
      {0.102, 1.491},
      {0.076, 1.364},
      {0.076, 1.16},
      {0.025, 0.803},
      {0.025, 0.573},
      {0.005, 0.472},
      {0.02, 0.415},
      {0.066, 0.385},
      {0.217, 0.382},
      {0.321, 0.359}
    ]
  }

  @sprinter_high %{
    top: 2.651,
    front: [
      {0.331, 0.341},
      {0.181, 0.371},
      {0.066, 0.418},
      {0.02, 0.452},
      {0.002, 0.494},
      {0.002, 0.57},
      {0.038, 0.655},
      {0.0, 0.793},
      {0.002, 1.012},
      {0.072, 1.203},
      {0.11, 1.245},
      {0.285, 1.331},
      {0.707, 1.472},
      {0.861, 1.498},
      {1.355, 1.988},
      {1.681, 2.265},
      {1.753, 2.354},
      {1.841, 2.386},
      {2.149, 2.58},
      {2.319, :top}
    ],
    back: [
      {0.693, :top},
      {0.592, 2.611},
      {0.293, 2.609},
      {0.181, 2.54},
      {0.11, 2.39},
      {0.082, 2.277},
      {0.04, 1.938},
      {0.04, 1.757},
      {0.02, 1.657},
      {0.02, 1.215},
      {0.0, 1.115},
      {0.0, 0.833},
      {0.02, 0.733},
      {0.0, 0.472},
      {0.012, 0.424},
      {0.036, 0.408},
      {0.291, 0.361}
    ]
  }

  @promaster_high %{
    top: 2.469,
    front: [
      {0.348, 0.299},
      {0.104, 0.313},
      {0.04, 0.348},
      {0.002, 0.43},
      {0.014, 0.693},
      {0.115, 1.009},
      {0.239, 1.204},
      {0.364, 1.298},
      {0.667, 1.394},
      {1.005, 1.732},
      {1.431, 2.082},
      {1.591, 2.281},
      {1.67, 2.301},
      {1.883, :top}
    ],
    back: [
      {0.06, :top},
      {0.012, 2.4},
      {0.02, 2.33},
      {0.06, 2.2},
      {0.06, 1.95},
      {0.04, 1.75},
      {0.04, 0.985},
      {0.0, 0.786},
      {0.02, 0.667},
      {0.0, 0.388},
      {0.018, 0.346},
      {0.05, 0.338}
    ]
  }

  # The make and the trace of each model. A model that the app does not
  # know is a Transit 148 in, high roof.
  @models %{
    "transit_148_medium" => {:transit, @transit_medium},
    "transit_148" => {:transit, @transit_high},
    "transit_148_el" => {:transit, @transit_high},
    "sprinter_144" => {:sprinter, @sprinter_high},
    "sprinter_170" => {:sprinter, @sprinter_high},
    "sprinter_170_ext" => {:sprinter, @sprinter_high},
    "promaster_136" => {:promaster, @promaster_high},
    "promaster_159" => {:promaster, @promaster_high},
    "promaster_159_ext" => {:promaster, @promaster_high}
  }

  # The round shape of the hull of each make (`DIYWeb.Icon.Shapes.hull/5`)
  # comes from the front and back views of the drawings. It has the belt,
  # the lean of each side, and the radius of the edge of the roof. It also
  # has the radius of the corners at the front and at the back.
  # `cowl` is the bottom of the windshield, and `glass` the height of its
  # top. `tire` and `arch` are the radius of a tire and of its arch. The
  # other heights are the bands of the sides. They are the black bumpers
  # at the front and at the back, and the black band between the wheels.
  @makes %{
    transit: %{
      shape: %{belt: 1.25, lean: 0.07, edge: 0.1, nose: 0.25, tail: 0.1},
      cowl: 0.86,
      glass: 2.06,
      tire: 0.36,
      arch: 0.5,
      bumper: {0.36, 0.79},
      back_bumper: {0.46, 0.88},
      band: {0.52, 0.79},
      tail: {0.06, 0.18, 0.88, 1.52},
      mirror: {1.16, 1.2},
      door: 2.28,
      slide: 3.83
    },
    sprinter: %{
      shape: %{belt: 1.2, lean: 0.11, edge: 0.08, nose: 0.22, tail: 0.08},
      cowl: 0.861,
      glass: 2.15,
      tire: 0.37,
      arch: 0.46,
      bumper: {0.4, 0.86},
      back_bumper: {0.4, 0.8},
      band: {0.65, 0.83},
      tail: {0.06, 0.2, 0.8, 1.43},
      mirror: {1.2, 1.32},
      door: 2.42,
      slide: 3.99
    },
    promaster: %{
      shape: %{belt: 1.3, lean: 0.04, edge: 0.13, nose: 0.2, tail: 0.08},
      cowl: 0.667,
      glass: 2.06,
      tire: 0.36,
      arch: 0.48,
      bumper: {0.34, 0.92},
      back_bumper: {0.37, 0.89},
      band: {0.45, 0.6},
      tail: {0.02, 0.14, 0.92, 1.5},
      mirror: {1.02, 1.32},
      door: 2.05,
      slide: 2.97
    }
  }

  defp model_of(model), do: Map.get(@models, model, @models["transit_148"])

  @doc """
  The height of the hood of a model of a van over the ground, in meters:
  the bottom of its windshield.
  """
  def hood_height(model) do
    {make, trace} = model_of(model)
    cowl = @makes[make].cowl
    {_d, z} = Enum.find(trace.front, fn {d, _z} -> d >= cowl - 0.01 end)
    z
  end

  @doc """
  The side profile of a model, at its real size: a loop of `{y, z}`. It
  is counterclockwise when the eye is at the left side (the large x). It
  goes from the bottom of the front bumper, up the nose, over the van,
  down the back, and along the bottom to the front.
  """
  def profile(model) do
    {_make, trace} = model_of(model)
    {l, _w, h} = size(model)
    # A trace starts a few millimeters behind the front, and ends a few
    # millimeters in front of the back. The profile moves its ends there.
    d0 = trace.front |> Enum.map(&elem(&1, 0)) |> Enum.min()
    e0 = trace.back |> Enum.map(&elem(&1, 0)) |> Enum.min()

    Enum.map(trace.front, fn {d, z} -> {l - (d - d0), stretch(z, trace.top, h)} end) ++
      Enum.map(trace.back, fn {e, z} -> {e - e0, stretch(z, trace.top, h)} end)
  end

  # A height of a trace at the height of the model. The cab keeps its
  # height, and the points over it stretch to the roof of the model.
  defp stretch(:top, _top, h), do: h
  defp stretch(z, _top, _h) when z <= @cab, do: z
  defp stretch(z, top, h), do: @cab + (z - @cab) * (h - @cab) / (top - @cab)

  defp size(model) do
    size = Catalog.van_size(model)
    {size.length * @inch, size.width * @inch, size.height * @inch}
  end

  @doc """
  The model of a van of a model, at its real size: a list of parts
  (`DIYWeb.Icon.Shapes`). The mirrors are parts of their own, out of the
  body. The body paints as one part. First the hull paints, with the faces
  of its windshield, its front and its back. Then the details of its
  sides paint: the wheels, the doors, the windows, the lights and the
  bumpers.
  """
  def van(model) do
    {make, _trace} = model_of(model)
    spec = @makes[make]
    {l, w, h} = size(model)
    size = Catalog.van_size(model)
    front_axle = l - size.front * @inch
    rear_axle = front_axle - size.wheelbase * @inch
    loop = profile(model)

    van = %{
      make: make,
      spec: spec,
      size: {l, w, h},
      axles: {rear_axle, front_axle},
      loop: loop,
      shape: Shapes.hull_shape(loop, w, spec.shape)
    }

    hull = Shapes.hull(loop, w, spec.shape, "white", windshield(van) ++ front(van) ++ back(van))
    mirror(van, -1) ++ [{:group, [hull | sides(van) ++ wheels(van)]}] ++ mirror(van, 1)
  end

  ## The sides

  # The faces of a shape on a side of the hull, a little out of it. Its
  # points are `{y, z}`. The sign is the side: -1 is the right side (x = 0),
  # and 1 is the left side. The shape is cut to the profile, and where the
  # side bends: so each piece is on the side.
  defp on_side(%{loop: loop, shape: shape, size: {_l, w, _h}}, sign, points, class) do
    for piece <- Shapes.hull_pieces(loop, shape, points) do
      corners =
        for {y, z} <- piece do
          inset = Shapes.hull_inset(shape, y, z)
          {if(sign < 0, do: inset - 0.006, else: w - inset + 0.006), y, z}
        end

      {:face, corners, Shapes.normal(corners, {sign, 0, 0}), class}
    end
  end

  defp rect(y0, y1, z0, z1), do: [{y0, z0}, {y1, z0}, {y1, z1}, {y0, z1}]

  # The details of the two sides: the black bumpers, the black band
  # between the wheels, and the lights. Then the window of the door of the
  # cab, the lines of the doors and the handle. The right side has the
  # sliding door and its rail. The left side has the line of its panel.
  defp sides(%{spec: spec, size: {l, _w, h}, axles: {rear, front}} = van) do
    y = fn d -> l - d end
    {b0, b1} = spec.bumper
    {k0, k1} = spec.back_bumper
    {n0, n1} = spec.band
    {t0, t1, tz0, tz1} = spec.tail
    top = min(h - 0.25, 2.3)

    both =
      [
        {rect(y.(0.62), l, b0, b1), "i-black"},
        {rect(0.0, 0.62, k0, k1), "i-black"},
        {rect(rear + spec.arch, front - spec.arch, n0, n1), "i-black"},
        {rect(t0, t1, tz0, tz1), "i-hot"},
        {rect(t0, t1, tz0 + (tz1 - tz0) * 0.3, tz0 + (tz1 - tz0) * 0.5), "i-white-t"},
        {rect(y.(spec.door + 0.01), y.(spec.door - 0.01), b1, top), "i-line"}
      ] ++ make_side(van.make, y)

    right = [
      {rect(y.(spec.slide + 0.01), y.(spec.slide - 0.01), n1, top), "i-line"},
      {rect(0.55, y.(spec.door + 0.1), 1.44, 1.47), "i-dark-~"}
    ]

    left = [
      {rect(y.(spec.slide + 0.01), y.(spec.slide - 0.01), n1, top), "i-line"}
    ]

    for(
      sign <- [-1, 1],
      {points, class} <- both,
      face <- on_side(van, sign, points, class),
      do: face
    ) ++
      for({points, class} <- right, face <- on_side(van, -1, points, class), do: face) ++
      for {points, class} <- left, face <- on_side(van, 1, points, class), do: face
  end

  # The lights along the hood, and the window of the door of the cab with
  # its black frame. Points `{d, z}`.
  defp make_side(:transit, y) do
    [
      {[{0.15, 0.99}, {0.18, 1.21}, {0.58, 1.31}, {0.38, 1.1}], "i-glass"},
      {[{0.74, 1.22}, {1.1, 1.5}, {1.1, 1.27}], "i-black"},
      {[{1.08, 1.26}, {2.0, 1.42}, {2.16, 1.56}, {2.16, 2.1}, {1.68, 2.12}], "i-black"},
      {[{1.13, 1.3}, {1.98, 1.46}, {2.12, 1.58}, {2.12, 2.06}, {1.7, 2.08}], "i-glass-dark"},
      {[{1.04, 0.8}, {1.06, 0.8}, {1.06, 1.3}, {1.04, 1.3}], "i-line"},
      {[{1.97, 1.23}, {2.19, 1.23}, {2.19, 1.27}, {1.97, 1.27}], "i-dark-~"}
    ]
    |> Enum.map(fn {points, class} -> {for({d, z} <- points, do: {y.(d), z}), class} end)
  end

  defp make_side(:sprinter, y) do
    [
      {[{0.1, 1.1}, {0.14, 1.25}, {0.62, 1.4}, {0.4, 1.17}], "i-glass"},
      {[{1.1, 1.35}, {2.26, 1.51}, {2.39, 1.6}, {2.39, 2.2}, {1.84, 2.21}], "i-black"},
      {[{1.55, 1.42}, {2.24, 1.54}, {2.36, 1.62}, {2.36, 2.17}, {1.87, 2.18}], "i-glass-dark"},
      {[{1.14, 1.39}, {1.5, 1.44}, {1.5, 1.8}], "i-glass-dark"},
      {[{2.03, 1.3}, {2.25, 1.3}, {2.25, 1.34}, {2.03, 1.34}], "i-dark-~"}
    ]
    |> Enum.map(fn {points, class} -> {for({d, z} <- points, do: {y.(d), z}), class} end)
  end

  defp make_side(:promaster, y) do
    [
      {[{0.12, 1.0}, {0.2, 1.16}, {0.5, 1.28}, {0.36, 1.08}], "i-glass"},
      {[{1.0, 1.26}, {1.95, 1.36}, {2.02, 1.42}, {2.02, 2.07}, {1.55, 2.09}], "i-black"},
      {[{1.05, 1.3}, {1.92, 1.39}, {1.98, 1.44}, {1.98, 2.03}, {1.57, 2.05}], "i-glass-dark"},
      {[{1.82, 1.08}, {1.92, 1.08}, {1.92, 1.2}, {1.82, 1.2}], "i-dark-~"},
      {[{2.1, 1.08}, {2.2, 1.08}, {2.2, 1.2}, {2.1, 1.2}], "i-dark-~"}
    ]
    |> Enum.map(fn {points, class} -> {for({d, z} <- points, do: {y.(d), z}), class} end)
  end

  # The wheels on the two sides: a black arch, its dark inside, a tire, a
  # rim with its ring and its hub.
  defp wheels(%{spec: spec, axles: {rear, front}, size: {_l, w, _h}}) do
    tire = spec.tire

    for {x, normal, dx} <- [{0, {-1, 0, 0}, -1}, {w, {1, 0, 0}, 1}],
        y <- [rear, front],
        {r, class, off} <- [
          {spec.arch, :arch, 0.004},
          {spec.arch - 0.06, :inside, 0.006},
          {tire, "i-black", 0.01},
          {tire * 0.66, "i-steel-~", 0.014},
          {tire * 0.55, "i-gray-~", 0.016},
          {tire * 0.32, "i-dark-~", 0.018},
          {tire * 0.13, "i-steel-~", 0.02}
        ] do
      center = {x + dx * off, y, tire}

      case class do
        :arch -> {:face, arch(center, r), normal, "i-black"}
        :inside -> {:face, arch(center, r), normal, "i-dark-~"}
        class -> {:face, circle(center, r), normal, class}
      end
    end
  end

  # The top half of a circle on a side, and a circle.
  defp arch({x, y, z}, r) do
    for k <- 0..12, a = :math.pi() * k / 12, do: {x, y + r * :math.cos(a), z + r * :math.sin(a)}
  end

  defp circle({x, y, z}, r) do
    for k <- 0..23,
        a = 2 * :math.pi() * k / 24,
        do: {x, y + r * :math.cos(a), z + r * :math.sin(a)}
  end

  # A mirror next to the window of the door, on its arm. The arm starts
  # out of the body, the wheels and the details of the side. So the order
  # of the paint puts the mirror at its place. A mirror reaches 7 inches
  # out of its side. The plan gives a van this space (`DIY.Layout.size/1`).
  defp mirror(%{spec: spec, size: {l, w, _h}}, sign) do
    {d, z} = spec.mirror
    y = l - d - 0.14
    reach = 7 * @inch
    {x0, x1} = if sign < 0, do: {-reach, -0.07}, else: {w + 0.07, w + reach}
    {a0, a1} = if sign < 0, do: {-0.07, -0.025}, else: {w + 0.025, w + 0.07}

    [
      {:box, {a0, y + 0.04, z + 0.12}, {a1 - a0, 0.05, 0.05}, "dark"},
      {:box, {x0, y, z}, {x1 - x0, 0.14, 0.46}, "dark"}
    ]
  end

  ## The front and the back

  # The y of the front of the profile at a height: the place of the nose
  # at that height. The nose is the part in front of the windshield.
  defp front_y(%{loop: loop, spec: spec, size: {l, _w, _h}}, z) do
    nose = Enum.take_while(loop, fn {y, _z} -> y >= l - spec.cowl end)
    at_height(nose, z, &max/2)
  end

  # The y of the back of the profile at a height.
  defp back_y(%{loop: loop, size: {l, _w, _h}}, z) do
    tail = Enum.filter(loop, fn {y, _z} -> y < l / 2 end)
    at_height(tail, z, &min/2)
  end

  # Where a line of points crosses a height: the best of the crossings
  # (the max or the min of y). Under or over the line, it is nil.
  defp at_height(points, z, best) do
    crossings =
      points
      |> Enum.zip(tl(points))
      |> Enum.flat_map(fn {{y1, z1}, {y2, z2}} ->
        if (z1 - z) * (z2 - z) <= 0 and z1 != z2,
          do: [y1 + (y2 - y1) * (z - z1) / (z2 - z1)],
          else: []
      end)

    case crossings do
      [] -> nil
      ys -> Enum.reduce(ys, best)
    end
  end

  # The faces of a shape on the front (or the back) of the van: points
  # `{x, z}`. The shape is cut at the height of each point of the profile.
  # So each piece is on the nose (or the back), on one edge of the profile.
  # A piece goes 3 cm over the next edges under it and over it, at most to
  # their ends. It bends at the edges: it stays on the profile. So it
  # covers the part of the next face that goes over it (the hull of
  # `DIYWeb.Icon.Shapes`), and one piece has no line in it. Each point is
  # 2 mm in front of the profile, and in the round corners.
  defp on_end(van, which, points, class) do
    {_l, w, _h} = van.size
    {_ys, zs} = Enum.unzip(van.loop)
    cuts = zs |> Enum.uniq() |> Enum.sort()
    out = if which == :front, do: 0.002, else: -0.002
    hint = if which == :front, do: {0, 1, 0}, else: {0, -1, 0}
    place = fn z -> if which == :front, do: front_y(van, z), else: back_y(van, z) end

    # The line of the profile in each band, from the height of its bottom
    # to the height of its top. A band with no profile (under or over it)
    # has no line.
    lines =
      for {z0, z1} <- Enum.zip(cuts, tl(cuts)) do
        {y0, y1} = {place.(z0), place.(z1)}
        {{z0, z1}, y0 && y1 && fn z -> y0 + out + (y1 - y0) * (z - z0) / (z1 - z0) end}
      end

    for {{{z0, z1}, line}, k} <- Enum.with_index(lines),
        line,
        length(between(points, z0, z1)) >= 3 do
      {{b0, _}, below} = if k > 0, do: Enum.at(lines, k - 1), else: {{z0, z0}, nil}
      {{_, a1}, above} = Enum.at(lines, k + 1, {{z1, z1}, nil})

      {a, b} =
        {if(below, do: max(z0 - 0.03, b0), else: z0), if(above, do: min(z1 + 0.03, a1), else: z1)}

      # The line of the point: the next band under the piece or over it.
      y = fn z ->
        cond do
          z < z0 -> below.(z)
          z > z1 -> above.(z)
          true -> line.(z)
        end
      end

      corners =
        for {x, z} <- points |> between(a, b) |> split(z0) |> split(z1) do
          inset = Shapes.hull_inset(van.shape, y.(z), z) + 0.01
          {min(max(x, inset), w - inset), y.(z), z}
        end

      {:face, corners, Shapes.normal(corners, hint), class}
    end
  end

  # The part of a shape (points `{x, z}`) between two heights.
  defp between(points, z0, z1) do
    points |> clip(fn {_x, z} -> z0 - z end) |> clip(fn {_x, z} -> z - z1 end)
  end

  # A shape with a point where each of its sides crosses a height: so it
  # can bend there.
  defp split(points, at) do
    points
    |> Enum.zip(tl(points) ++ [hd(points)])
    |> Enum.flat_map(fn {{x1, z1} = a, {x2, z2}} ->
      if (z1 - at) * (z2 - at) < 0,
        do: [a, {x1 + (x2 - x1) * (at - z1) / (z2 - z1), at}],
        else: [a]
    end)
  end

  # Sutherland and Hodgman: the part of a shape where f is 0 or less.
  defp clip([], _f), do: []

  defp clip(points, f) do
    points
    |> Enum.zip(tl(points) ++ [hd(points)])
    |> Enum.flat_map(fn {{x1, z1} = a, {x2, z2} = b} ->
      {fa, fb} = {f.(a), f.(b)}
      cut = fn -> {x1 + (x2 - x1) * fa / (fa - fb), z1 + (z2 - z1) * fa / (fa - fb)} end

      cond do
        fa <= 0 and fb <= 0 -> [b]
        fa <= 0 -> [cut.()]
        fb <= 0 -> [cut.(), b]
        true -> []
      end
    end)
  end

  # The windshield: glass on each edge of the profile from the cowl up to
  # the top of the glass. It is in the width of the hull, 3 mm out of it.
  # The glass of an edge goes 3 cm over the next edges, at most to their
  # ends. It bends at the edges, as a piece of a shape on the front
  # (`on_end/4`): so no line of the hull shows between them. A band of
  # light goes over the glass of the longest edge.
  defp windshield(%{loop: loop, spec: spec, shape: shape, size: {l, w, _h}}) do
    # The points of the profile under the glass, from the cowl up.
    path =
      loop
      |> Enum.zip(tl(loop))
      |> Enum.filter(fn {{y1, z1}, {_y2, z2}} ->
        y1 <= l - spec.cowl + 0.01 and z1 < spec.glass and z2 > z1
      end)
      |> Enum.map(fn {{y1, z1}, {y2, z2}} ->
        if z2 > spec.glass,
          do: {{y1, z1}, {y1 + (y2 - y1) * (spec.glass - z1) / (z2 - z1), spec.glass}},
          else: {{y1, z1}, {y2, z2}}
      end)

    edges = List.to_tuple(path)
    n = tuple_size(edges)

    # A point of the glass: on the profile, 3 mm out of it, at the edge of
    # the glass on the side of the sign.
    point = fn {y, z}, {ny, nz}, sign ->
      inset = Shapes.hull_inset(shape, y, z) + 0.08
      {if(sign < 0, do: inset, else: w - inset), y + ny * 0.003, z + nz * 0.003}
    end

    normal = fn {{y1, z1}, {y2, z2}} ->
      len = :math.sqrt((y2 - y1) ** 2 + (z2 - z1) ** 2)
      {(z2 - z1) / len, (y1 - y2) / len}
    end

    along = fn {{y1, z1}, {y2, z2}}, t -> {y1 + (y2 - y1) * t, z1 + (z2 - z1) * t} end

    reach = fn {{y1, z1}, {y2, z2}} ->
      min(1.0, 0.03 / :math.sqrt((y2 - y1) ** 2 + (z2 - z1) ** 2))
    end

    faces =
      for i <- 0..(n - 1) do
        {a, b} = edge = elem(edges, i)

        # The path of the glass of this edge: from 3 cm on the edge under
        # it to 3 cm on the edge over it.
        under =
          if i > 0,
            do: [{along.(elem(edges, i - 1), 1 - reach.(elem(edges, i - 1))), elem(edges, i - 1)}],
            else: []

        over =
          if i < n - 1,
            do: [{along.(elem(edges, i + 1), reach.(elem(edges, i + 1))), elem(edges, i + 1)}],
            else: []

        line = under ++ [{a, edge}, {b, edge}] ++ over

        corners =
          for({p, e} <- line, do: point.(p, normal.(e), -1)) ++
            for {p, e} <- Enum.reverse(line), do: point.(p, normal.(e), 1)

        {ny, nz} = normal.(edge)

        {{:face, corners, {0, ny, nz}, "i-glass-dark"},
         {point.(a, {ny, nz}, -1), point.(b, {ny, nz}, -1), point.(b, {ny, nz}, 1),
          point.(a, {ny, nz}, 1)}, {0, ny, nz}}
      end

    # The band of light, on the glass of the longest edge.
    {_face, {c0, c3, c2, c1}, normal} =
      Enum.max_by(faces, fn {_face, {a, b, _c, _d}, _n} ->
        :math.sqrt((elem(b, 1) - elem(a, 1)) ** 2 + (elem(b, 2) - elem(a, 2)) ** 2)
      end)

    mix = fn {x1, y1, z1}, {x2, y2, z2}, t ->
      {x1 + (x2 - x1) * t, y1 + (y2 - y1) * t + 0.002 * elem(normal, 1),
       z1 + (z2 - z1) * t + 0.002 * elem(normal, 2)}
    end

    shine = [mix.(c0, c1, 0.3), mix.(c0, c1, 0.42), mix.(c3, c2, 0.6), mix.(c3, c2, 0.48)]
    Enum.map(faces, &elem(&1, 0)) ++ [{:face, shine, normal, "i-shine"}]
  end

  # The front: the bumper with the plate and the fog lights, then the
  # grille and the lights of the make.
  defp front(%{spec: spec, size: {_l, w, _h}} = van) do
    m = w / 2
    {b0, b1} = spec.bumper

    bumper = [
      {[{0.0, b0}, {w, b0}, {w, b1}, {0.0, b1}], "i-black"},
      {[
         {m - 0.26, b0 + 0.13},
         {m + 0.26, b0 + 0.13},
         {m + 0.26, b0 + 0.27},
         {m - 0.26, b0 + 0.27}
       ], "i-white-t"},
      {[{0.14, b0 + 0.11}, {0.32, b0 + 0.11}, {0.32, b0 + 0.18}, {0.14, b0 + 0.18}], "i-bulb"},
      {[
         {w - 0.32, b0 + 0.11},
         {w - 0.14, b0 + 0.11},
         {w - 0.14, b0 + 0.18},
         {w - 0.32, b0 + 0.18}
       ], "i-bulb"}
    ]

    for {points, class} <- bumper ++ grille(van.make, w),
        face <- on_end(van, :front, points, class),
        do: face
  end

  # The grille and the lights of each make: points `{x, z}`.
  defp grille(:transit, w) do
    m = w / 2

    [
      {[
         {m - 0.47, 0.82},
         {m + 0.47, 0.82},
         {m + 0.56, 1.05},
         {m + 0.5, 1.2},
         {m - 0.5, 1.2},
         {m - 0.56, 1.05}
       ], "i-steel-t"},
      {[
         {m - 0.42, 0.85},
         {m + 0.42, 0.85},
         {m + 0.5, 1.05},
         {m + 0.45, 1.17},
         {m - 0.45, 1.17},
         {m - 0.5, 1.05}
       ], "i-black"},
      {oval({m, 1.03}, 0.11, 0.05, 16), "i-steel-t"},
      {oval({m, 1.03}, 0.09, 0.038, 16), "i-screen"}
    ] ++ lights(w, {1.0, 1.24}, 0.58)
  end

  defp grille(:sprinter, w) do
    m = w / 2

    [
      {[
         {m - 0.52, 0.86},
         {m + 0.52, 0.86},
         {m + 0.55, 1.06},
         {m + 0.45, 1.16},
         {m - 0.45, 1.16},
         {m - 0.55, 1.06}
       ], "i-steel-t"},
      {[
         {m - 0.48, 0.89},
         {m + 0.48, 0.89},
         {m + 0.51, 1.05},
         {m + 0.42, 1.13},
         {m - 0.42, 1.13},
         {m - 0.51, 1.05}
       ], "i-black"}
    ] ++
      for(
        z <- [0.94, 1.0, 1.06],
        do:
          {[{m - 0.48, z}, {m + 0.48, z}, {m + 0.48, z + 0.02}, {m - 0.48, z + 0.02}],
           "i-steel-t"}
      ) ++
      [
        {oval({m, 1.0}, 0.1, 0.1, 12), "i-steel-t"},
        {oval({m, 1.0}, 0.075, 0.075, 12), "i-black"}
      ] ++ lights(w, {1.0, 1.22}, 0.56)
  end

  defp grille(:promaster, w) do
    m = w / 2

    [
      {[{m - 0.55, 0.6}, {m + 0.55, 0.6}, {m + 0.5, 0.88}, {m - 0.5, 0.88}], "i-dark-t"},
      {[{m - 0.2, 0.72}, {m + 0.2, 0.72}, {m + 0.2, 0.76}, {m - 0.2, 0.76}], "i-steel-t"}
    ] ++ lights(w, {0.97, 1.17}, 0.42)
  end

  # The head lights at the two corners, from the edge in to `inner` from
  # the middle: they rise to the outer corner. A strip of light is in each.
  defp lights(w, {z0, z1}, inner) do
    m = w / 2
    dz = z1 - z0

    for sign <- [-1, 1],
        {points, class} <- [
          {[{0.0, z0 + dz * 0.2}, {inner, z0}, {inner - 0.04, z1}, {0.0, z1}], "i-glass"},
          {[
             {0.05, z0 + dz * 0.45},
             {inner - 0.04, z0 + dz * 0.3},
             {inner - 0.05, z0 + dz * 0.48},
             {0.05, z0 + dz * 0.62}
           ], "i-bulb"}
        ] do
      {for({u, z} <- points, do: {m - sign * (m - u), z}), class}
    end
  end

  defp oval({cx, cz}, rx, rz, n) do
    for k <- 0..(n - 1),
        a = 2 * :math.pi() * k / n,
        do: {cx + rx * :math.cos(a), cz + rz * :math.sin(a)}
  end

  # The back: the line between the doors, their windows, the lights at
  # the corners, the bumper and the plate.
  defp back(%{spec: spec, size: {_l, w, h}} = van) do
    m = w / 2
    {k0, k1} = spec.back_bumper
    {_t0, _t1, tz0, tz1} = spec.tail
    top = min(h - 0.35, 2.1)

    [
      {[{m - 0.01, k1}, {m + 0.01, k1}, {m + 0.01, h - 0.2}, {m - 0.01, h - 0.2}], "i-line"},
      {[{0.24, 1.5}, {m - 0.08, 1.5}, {m - 0.08, top}, {0.24, top}], "i-glass-dark"},
      {[{m + 0.08, 1.5}, {w - 0.24, 1.5}, {w - 0.24, top}, {m + 0.08, top}], "i-glass-dark"},
      {[{0.0, tz0}, {0.14, tz0}, {0.14, tz1}, {0.0, tz1}], "i-hot"},
      {[{w - 0.14, tz0}, {w, tz0}, {w, tz1}, {w - 0.14, tz1}], "i-hot"},
      {[{0.0, k0}, {w, k0}, {w, k1}, {0.0, k1}], "i-black"},
      {[{m - 0.16, k0 + 0.1}, {m + 0.16, k0 + 0.1}, {m + 0.16, k0 + 0.26}, {m - 0.16, k0 + 0.26}],
       "i-white-t"}
    ]
    |> Enum.flat_map(fn {points, class} -> on_end(van, :back, points, class) end)
  end
end
