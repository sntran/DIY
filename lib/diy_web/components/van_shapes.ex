defmodule DIYWeb.Icon.VanShapes do
  @moduledoc """
  The models of the three vans (`DIY.Catalog.van_models/0`), at their real
  size in meters, as parts of `DIYWeb.Icon.Shapes`.

  The front of a van looks to y, and its right side (the side of the
  sliding door) is at x = 0 (`DIYWeb.Geometry`). A body is the side
  profile of its model, across the width of the van. The profile goes
  from the back along the bottom to the bumper at the front. Then it goes
  up the nose, the hood, the windshield and the high roof, and back along
  the roof. Over its belt (the bottom of the windows), a body is narrower
  at the top: its sides lean in.

  The profile, the grille and the lights follow photos of each model: they
  are for the picture only. The length, the width, the height and the
  axles come from `DIY.Catalog.van_size/1`.

  - Ford Transit: a hood that slopes into the windshield, and a high roof
    that rises behind the windshield. A wide grille in the shape of a
    trapezoid, with three bars, and lights that sweep back.
  - Mercedes-Benz Sprinter: a long, low hood, and a high roof that rises
    in a curve from the top of the windshield. A tall grille with the
    star, and long lights.
  - Ram ProMaster: a short nose that is almost vertical, a large black
    grille and bumper, and lights high on the front. A very flat body.
  """

  alias DIY.Catalog

  # The radius of a tire.
  @tire 0.37

  # The profile of the front of each model: points `{d, z}`, where d is the
  # distance from the front of the van (meters). The points go up from the
  # top of the bumper. The nose is from the first point to the second one.
  # The hood goes to the bottom of the windshield (the first point of
  # `glass`). Then the points go to the top of the windshield, and over the
  # roof of the cab and its cap, up to the roof.
  # `belt` is the bottom of the windows of the doors, and `lean` is how far
  # each side leans in at the roof. `grille` is the kind of the front.
  @models %{
    "transit_148" => %{
      front: [{0.06, 0.6}, {0.08, 1.0}, {0.22, 1.08}, {0.8, 1.21}],
      glass: [{0.86, 1.24}, {1.5, 1.92}],
      roof: [{1.62, 1.98}, {1.74, 2.12}, {1.94, 2.56}, {2.14, 2.73}, {2.4, :top}],
      belt: 1.2,
      lean: 0.1,
      wrap: {0.08, 0.42, 0.84, 1.0, 1.08},
      grille: :transit
    },
    "sprinter_170" => %{
      front: [{0.05, 0.6}, {0.07, 0.98}, {0.28, 1.07}, {1.0, 1.18}],
      glass: [{1.06, 1.22}, {1.7, 1.95}],
      roof: [{1.8, 2.02}, {2.02, 2.36}, {2.32, 2.62}, {2.7, :top}],
      belt: 1.18,
      lean: 0.06,
      wrap: {0.07, 0.5, 0.8, 0.98, 1.08},
      grille: :sprinter
    },
    "promaster_159" => %{
      front: [{0.04, 0.6}, {0.06, 1.0}, {0.44, 1.12}],
      glass: [{0.5, 1.15}, {1.18, 1.98}],
      roof: [{1.28, 2.05}, {1.4, 2.42}, {1.58, :top}],
      belt: 1.15,
      lean: 0.03,
      wrap: {0.06, 0.3, 0.84, 1.0, 1.08},
      grille: :promaster
    }
  }

  @doc "The height of the hood of a model of a van over the ground, in meters."
  def hood_height(model) do
    {_d, z} = List.last(spec(model).front)
    z
  end

  defp spec(model), do: Map.get(@models, model, @models["transit_148"])

  @doc """
  The model of a van of a model, at its real size: a list of parts
  (`DIYWeb.Icon.Shapes`). The mirrors are parts of their own, out of the
  body. The body paints as one part, with its bumpers, its wheels, its
  doors, its windows and its lights. Its faces paint in an order that is
  right for each camera and each turn.
  """
  def van(model) do
    size = Catalog.van_size(model)
    spec = spec(model)
    {l, w, h} = {size.length * 0.0254, size.width * 0.0254, size.height * 0.0254}
    front_axle = l - size.front * 0.0254
    rear_axle = front_axle - size.wheelbase * 0.0254
    body = body(spec, {l, w, h})

    # The faces of the body paint first. Then the details on the faces
    # paint: the black strip at the bottom of the sides and the wheels.
    # Then the windows and the doors, the back, and the front.
    details =
      trim(l, w) ++
        wheels(rear_axle, front_axle, w) ++
        sides(spec, {l, w, h}) ++ back({w, h}) ++ front(spec, {l, w, h})

    # The mirrors are parts of their own: the order of the paint puts each
    # of their boxes at its place.
    mirror(spec, l, {-0.26, -0.12}, -0.02) ++
      [{:group, body ++ details}] ++ mirror(spec, l, {w + 0.12, w + 0.26}, w + 0.02)
  end

  # The profile of the body, counterclockwise in the plane of y (to the
  # right) and z (up). It starts at the back of the bumper at the back, and
  # goes along the bottom and up the bumper at the front. It goes over the
  # top of the bumper to the nose, and up the nose. Then it goes over the
  # hood, the windshield and the roof, and down the back.
  defp profile(spec, {l, _w, h}) do
    point = fn {d, z} -> {l - d, if(z == :top, do: h, else: z)} end

    [{0.0, 0.34}, {l, 0.34}, {l, 0.6}] ++
      Enum.map(spec.front ++ spec.glass ++ spec.roof, point) ++
      [{0.08, h}, {0.08, 0.6}, {0.0, 0.6}]
  end

  # The faces of the body. First, the faces across the van: one for each
  # edge of the profile. Then each side, in two parts: under the belt, and
  # over it, where the side leans in.
  defp body(spec, {l, w, h} = size) do
    profile = profile(spec, size)
    {belt, lean} = {spec.belt, spec.lean}
    # How far a side is in from its place at the bottom, at a height z.
    inset = fn z -> if z <= belt, do: 0.0, else: lean * (z - belt) / (h - belt) end
    edges = Enum.zip(profile, tl(profile) ++ [hd(profile)])

    # The faces of the bumper at the back paint first: from the front, the
    # body hides them.
    count = length(edges)
    order = [count - 2, count - 1] ++ Enum.to_list(1..(count - 3))
    edges = Enum.with_index(edges)

    across =
      for i <- order, {{{y1, z1}, {y2, z2}}, ^i} = Enum.at(edges, i) do
        {dy, dz} = {y2 - y1, z2 - z1}
        {a, b} = {inset.(z1), inset.(z2)}
        corners = [{a, y1, z1}, {w - a, y1, z1}, {w - b, y2, z2}, {b, y2, z2}]
        face = {:face, corners, {0, dz, -dy}, across_class(i, count, spec, l)}

        # The shine on the windshield paints with it: the roof paints over
        # the two when the van looks away.
        if i == 3 + length(spec.front), do: [face | shine(spec, {l, w, h})], else: [face]
      end

    {low, high} = split(profile, belt)
    slope = lean / (h - belt)

    side = fn x, sign, points, lean? ->
      corners =
        for {y, z} <- points do
          {if(sign > 0, do: x - inset.(z), else: x + inset.(z)), y, z}
        end

      normal = if lean?, do: {sign, 0, slope}, else: {sign, 0, 0}
      {:face, corners, normal, "i-white-~ i-face"}
    end

    List.flatten(across) ++
      [side.(0, -1, low, false), side.(0, -1, high, true)] ++
      [side.(w, 1, low, false), side.(w, 1, high, true)]
  end

  # The class of an edge of the profile (`profile/2`). The bumpers are
  # dark: the two edges after the bottom, and the two last edges. The
  # windshield is glass, and the rest is the white of the body.
  defp across_class(i, count, spec, _l) do
    glass = 3 + length(spec.front)

    cond do
      i in [1, 2] -> "i-dark-~ i-face"
      i in [count - 2, count - 1] -> "i-dark-~ i-face"
      i == glass -> "i-glass-dark"
      true -> "i-white-~ i-face"
    end
  end

  # A polygon of the profile in two parts: under a height z, and over it.
  defp split(points, z) do
    {clip(points, &(&1 <= z), z), clip(points, &(&1 >= z), z)}
  end

  # Sutherland and Hodgman: the part of a polygon where its height is in a
  # half of the plane.
  defp clip(points, inside?, z) do
    edges = Enum.zip(points, tl(points) ++ [hd(points)])

    Enum.flat_map(edges, fn {{y1, z1} = a, {y2, z2} = b} ->
      cut = fn -> {y1 + (y2 - y1) * (z - z1) / (z2 - z1), z} end

      case {inside?.(z1), inside?.(z2)} do
        {true, true} -> [b]
        {true, false} -> [cut.()]
        {false, true} -> [cut.(), b]
        {false, false} -> []
      end
      |> then(fn list -> if a == b, do: [], else: list end)
    end)
  end

  # The wheels on the two sides: a dark arch in the body, a tire, a rim and
  # its hub.
  defp wheels(rear, front, w) do
    for {x, normal, dx} <- [{0, {-1, 0, 0}, -1}, {w, {1, 0, 0}, 1}],
        y <- [rear, front],
        {r, class, off} <- [
          {@tire + 0.06, :arch, 0.004},
          {@tire, "i-black", 0.01},
          {@tire * 0.62, "i-steel-~", 0.014},
          {@tire * 0.2, "i-gray-~", 0.018}
        ] do
      center = {x + dx * off, y, @tire}
      {:face, circle(center, r, class), normal, if(class == :arch, do: "i-black", else: class)}
    end
  end

  # A circle on a side (an arch is its top half).
  defp circle({x, y, z}, r, :arch) do
    for k <- 0..12, a = :math.pi() * k / 12, do: {x, y + r * :math.cos(a), z + r * :math.sin(a)}
  end

  defp circle({x, y, z}, r, _class) do
    for k <- 0..23,
        a = 2 * :math.pi() * k / 24,
        do: {x, y + r * :math.cos(a), z + r * :math.sin(a)}
  end

  # A mirror (from x0 to x1) on its arm, next to the bottom of the
  # windshield. The arm starts at `side`: out of the body, the wheels and
  # the details on the side. The arm and the mirror do not go into each
  # other.
  defp mirror(spec, l, {x0, x1}, side) do
    [{d, z} | _] = spec.glass
    y = l - d - 0.05
    arm = if side < 0, do: {x1, side}, else: {side, x0}
    {a0, a1} = arm

    [
      {:box, {a0, y, z + 0.1}, {a1 - a0, 0.04, 0.04}, "dark"},
      {:box, {x0, y - 0.04, z}, {x1 - x0, 0.08, 0.3}, "dark"}
    ]
  end

  # The black strip at the bottom of each side.
  defp trim(l, w) do
    for {x, sign} <- [{-0.006, -1}, {w + 0.006, 1}] do
      corners = for {y, z} <- [{0.0, 0.42}, {l, 0.42}, {l, 0.56}, {0.0, 0.56}], do: {x, y, z}
      {:face, corners, {sign, 0, 0}, "i-dark-~"}
    end
  end

  # The window of the door of the cab, with its front along the
  # windshield. The line of the door, the handle, and a window of the cargo
  # area. On the right side, the sliding door has its window and its rail.
  defp sides(spec, {l, w, h}) do
    [{d0, z0}, {d1, z1}] = spec.glass
    {belt, lean} = {spec.belt, spec.lean}
    cab = l - d0 - 0.98
    top = z1 - 0.12
    on_glass = fn z -> l - d0 - (z - z0) / (z1 - z0) * (d1 - d0) - 0.08 end
    slope = lean / (h - belt)

    for {x, sign} <- [{0, -1}, {w, 1}],
        {corners, class} <-
          [
            {[
               {cab + 0.08, belt + 0.04},
               {on_glass.(belt + 0.04), belt + 0.04},
               {on_glass.(top), top},
               {cab + 0.08, top}
             ], "i-glass-dark"},
            {[{cab, 0.56}, {cab + 0.02, 0.56}, {cab + 0.02, top + 0.05}, {cab, top + 0.05}],
             "i-line"},
            {[
               {cab + 0.14, belt - 0.12},
               {cab + 0.3, belt - 0.12},
               {cab + 0.3, belt - 0.08},
               {cab + 0.14, belt - 0.08}
             ], "i-dark-~"}
          ] ++ cargo(x, cab) do
      at = fn {y, z} ->
        inset = if z <= belt, do: 0.0, else: slope * (z - belt)
        {x + sign * (0.006 - inset), y, z}
      end

      # A part that goes over the belt is two parts: under the belt, the
      # side is upright, and over it, the side leans in.
      for part <- Tuple.to_list(split(corners, belt)), part != [] do
        {:face, Enum.map(part, at), {sign, 0, 0}, class}
      end
    end
    |> List.flatten()
  end

  # The sliding door on the right side (x = 0): its line, its rail and its
  # window. A window of the cargo area on the left side.
  defp cargo(0, cab) do
    {y0, y1} = {cab - 1.3, cab - 0.02}

    [
      {[{y0, 0.56}, {y0 + 0.02, 0.56}, {y0 + 0.02, 1.9}, {y0, 1.9}], "i-line"},
      {[{y0 - 0.6, 1.94}, {y1, 1.94}, {y1, 1.96}, {y0 - 0.6, 1.96}], "i-line"},
      {[{y0 + 0.2, 1.22}, {y1 - 0.2, 1.22}, {y1 - 0.2, 1.72}, {y0 + 0.2, 1.72}], "i-glass-dark"},
      {[{y0 + 0.08, 1.05}, {y0 + 0.22, 1.05}, {y0 + 0.22, 1.09}, {y0 + 0.08, 1.09}], "i-dark-~"}
    ]
  end

  defp cargo(_x, cab) do
    [
      {[{cab - 1.4, 1.22}, {cab - 0.3, 1.22}, {cab - 0.3, 1.72}, {cab - 1.4, 1.72}],
       "i-glass-dark"}
    ]
  end

  # The doors at the back (y = 0.08): the line between them, their windows
  # and the lights at the two corners.
  defp back({w, h}) do
    y = 0.074
    at = fn {x, z} -> {x, y, z} end

    for {corners, class} <- [
          {[
             {w / 2 - 0.01, 0.62},
             {w / 2 + 0.01, 0.62},
             {w / 2 + 0.01, h - 0.2},
             {w / 2 - 0.01, h - 0.2}
           ], "i-line"},
          {[{0.22, 1.25}, {w / 2 - 0.1, 1.25}, {w / 2 - 0.1, 1.75}, {0.22, 1.75}],
           "i-glass-dark"},
          {[{w / 2 + 0.1, 1.25}, {w - 0.22, 1.25}, {w - 0.22, 1.75}, {w / 2 + 0.1, 1.75}],
           "i-glass-dark"},
          {[{0.03, 0.75}, {0.14, 0.75}, {0.14, 1.3}, {0.03, 1.3}], "i-hot"},
          {[{w - 0.14, 0.75}, {w - 0.03, 0.75}, {w - 0.03, 1.3}, {w - 0.14, 1.3}], "i-hot"}
        ],
        do: {:face, Enum.map(corners, at), {0, -1, 0}, class}
  end

  # The front of a model: the grille and the lights of the brand on the
  # nose, and a plate on the bumper. The nose is the face from the first
  # point of the front to the second one.
  defp front(spec, {l, w, _h}) do
    [{d0, z0}, {d1, z1} | _] = spec.front
    # A point on the nose: x across, and t from 0 (its bottom) to 1 (its
    # top). It is a little out of the face, to the front.
    nose = fn {x, t} -> {x, l - (d0 + (d1 - d0) * t) + 0.006, z0 + (z1 - z0) * t} end
    normal = {0, z1 - z0, d1 - d0}

    plate =
      for {x, z} <- [
            {w / 2 - 0.15, 0.4},
            {w / 2 + 0.15, 0.4},
            {w / 2 + 0.15, 0.55},
            {w / 2 - 0.15, 0.55}
          ],
          do: {x, l + 0.006, z}

    for(
      {corners, class} <- grille(spec.grille, w),
      do: {:face, Enum.map(corners, nose), normal, class}
    ) ++
      [{:face, plate, {0, 1, 0}, "i-white-t"}] ++
      wraps(spec, l, w)
  end

  # The lights go round the corners of the nose: a part of each light is
  # on the side, behind the nose. In `wrap`, this part is from d0 to d1
  # back from the front. It is from z0 to z1 at its front end, and it goes
  # up to z2 at its back end.
  defp wraps(spec, l, w) do
    {d0, d1, z0, z1, z2} = spec.wrap

    for {x, sign} <- [{-0.006, -1}, {w + 0.006, 1}] do
      corners = [{x, l - d0, z0}, {x, l - d0, z1}, {x, l - d1, z2}, {x, l - d1, z2 - 0.06}]
      {:face, corners, {sign, 0, 0}, "i-glass"}
    end
  end

  # A shine on the windshield: a band of light from its bottom to its top.
  defp shine(spec, {l, w, h}) do
    [{d0, z0}, {d1, z1}] = spec.glass
    {belt, lean} = {spec.belt, spec.lean}
    inset = fn z -> if z <= belt, do: 0.0, else: lean * (z - belt) / (h - belt) end
    # A point on the windshield. The number u goes across, from its left
    # edge (0) to its right edge (1) at the height. The number t goes from
    # its bottom (0) to its top (1).
    point = fn u, t ->
      z = z0 + (z1 - z0) * t
      x = inset.(z) + u * (w - 2 * inset.(z))
      {x, l - (d0 + (d1 - d0) * t) + 0.004, z + 0.004}
    end

    corners = [point.(0.3, 0.0), point.(0.42, 0.0), point.(0.6, 1.0), point.(0.48, 1.0)]
    [{:face, corners, {0, d1 - d0, z1 - z0}, "i-shine"}]
  end

  # The grille and the lights of each brand, as points `{x, t}` on the
  # nose. The number t goes from 0 at its bottom to 1 at its top.
  defp grille(:transit, w) do
    m = w / 2

    [
      {[{m - 0.42, 0.05}, {m + 0.42, 0.05}, {m + 0.55, 0.95}, {m - 0.55, 0.95}], "i-black"}
    ] ++
      for(
        t <- [0.28, 0.5, 0.72],
        do:
          {[
             {m - 0.5 + t * 0.1, t},
             {m + 0.5 - t * 0.1, t},
             {m + 0.5 - t * 0.1, t + 0.05},
             {m - 0.5 + t * 0.1, t + 0.05}
           ], "i-steel-t"}
      ) ++
      [
        {[{0.0, 0.5}, {m - 0.58, 0.62}, {m - 0.56, 1.0}, {0.0, 1.0}], "i-steel-t"},
        {[{0.04, 0.58}, {m - 0.62, 0.68}, {m - 0.6, 0.94}, {0.04, 0.94}], "i-glass"},
        {[{0.06, 0.62}, {m - 0.64, 0.7}, {m - 0.64, 0.74}, {0.06, 0.66}], "i-bulb"},
        {[{m + 0.58, 0.62}, {w, 0.5}, {w, 1.0}, {m + 0.56, 1.0}], "i-steel-t"},
        {[{m + 0.62, 0.68}, {w - 0.04, 0.58}, {w - 0.04, 0.94}, {m + 0.6, 0.94}], "i-glass"},
        {[{m + 0.64, 0.7}, {w - 0.06, 0.62}, {w - 0.06, 0.66}, {m + 0.64, 0.74}], "i-bulb"}
      ]
  end

  defp grille(:sprinter, w) do
    m = w / 2

    [
      {[{m - 0.38, 0.0}, {m + 0.38, 0.0}, {m + 0.4, 0.98}, {m - 0.4, 0.98}], "i-black"}
    ] ++
      for(
        t <- [0.25, 0.5, 0.75],
        do:
          {[{m - 0.36, t}, {m + 0.36, t}, {m + 0.36, t + 0.04}, {m - 0.36, t + 0.04}],
           "i-steel-t"}
      ) ++
      [
        {for(
           k <- 0..11,
           a = 2 * :math.pi() * k / 12,
           do: {m + 0.09 * :math.cos(a), 0.52 + 0.24 * :math.sin(a)}
         ), "i-steel-t"},
        {[{0.0, 0.42}, {m - 0.44, 0.5}, {m - 0.44, 1.0}, {0.0, 1.0}], "i-steel-t"},
        {[{0.04, 0.5}, {m - 0.48, 0.56}, {m - 0.48, 0.94}, {0.04, 0.94}], "i-glass"},
        {[{0.06, 0.56}, {m - 0.5, 0.6}, {m - 0.5, 0.64}, {0.06, 0.6}], "i-bulb"},
        {[{m + 0.44, 0.5}, {w, 0.42}, {w, 1.0}, {m + 0.44, 1.0}], "i-steel-t"},
        {[{m + 0.48, 0.56}, {w - 0.04, 0.5}, {w - 0.04, 0.94}, {m + 0.48, 0.94}], "i-glass"},
        {[{m + 0.5, 0.6}, {w - 0.06, 0.56}, {w - 0.06, 0.6}, {m + 0.5, 0.64}], "i-bulb"}
      ]
  end

  defp grille(:promaster, w) do
    m = w / 2

    [
      {[{m - 0.62, 0.0}, {m + 0.62, 0.0}, {m + 0.62, 0.55}, {m - 0.62, 0.55}], "i-black"},
      {[{m - 0.5, 0.62}, {m + 0.5, 0.62}, {m + 0.5, 0.86}, {m - 0.5, 0.86}], "i-dark-t"}
    ] ++
      for(
        x <- [-0.3, 0.0, 0.3],
        do:
          {[
             {m + x - 0.02, 0.64},
             {m + x + 0.02, 0.64},
             {m + x + 0.02, 0.84},
             {m + x - 0.02, 0.84}
           ], "i-steel-t"}
      ) ++
      [
        {[{0.0, 0.56}, {0.42, 0.68}, {0.34, 1.0}, {0.0, 1.0}], "i-steel-t"},
        {[{0.04, 0.62}, {0.36, 0.72}, {0.3, 0.95}, {0.04, 0.95}], "i-glass"},
        {[{w - 0.42, 0.68}, {w, 0.56}, {w, 1.0}, {w - 0.34, 1.0}], "i-steel-t"},
        {[{w - 0.36, 0.72}, {w - 0.04, 0.62}, {w - 0.04, 0.95}, {w - 0.3, 0.95}], "i-glass"}
      ]
  end
end
