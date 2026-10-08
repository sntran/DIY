defmodule DIYWeb.Icon.Shapes do
  @moduledoc """
  The shapes of the icon of each kind of item (`DIYWeb.Icon`), in the
  style of the pictures (`DIYWeb.Scene`). An icon is a few boxes, discs and
  details of a material, with a light top, a lit left face and a right
  face in the shade.

  Each material has three classes: `i-NAME-t` (the top), `i-NAME-l` and
  `i-NAME-r`. The faces of a material also have the class `i-face`: a thin
  edge, so that a white item shows on a light page.

  The unit is near a meter, and the front of an item looks to the left (y).
  A shape is `{:poly, corners, class}`.
  """

  alias DIYWeb.Iso

  # A box of a material: its left, its right and its top.
  defp box(corner, size, material) do
    box = Iso.box(corner, size)

    [
      {:poly, box.left, "i-#{material}-l i-face"},
      {:poly, box.right, "i-#{material}-r i-face"},
      {:poly, box.top, "i-#{material}-t i-face"}
    ]
  end

  # A rectangle on the front face (y = y) of a box, from x, z.
  defp front({x, y, z}, {w, h}, class),
    do: {:poly, Iso.on_plane({x, y + 0.01, z}, {1, 0, 0}, {0, 0, 1}, {0, 0}, {w, h}), class}

  # A rectangle on the side face (x = x) of a box, from y, z.
  defp side({x, y, z}, {d, h}, class),
    do: {:poly, Iso.on_plane({x + 0.01, y, z}, {0, 1, 0}, {0, 0, 1}, {0, 0}, {d, h}), class}

  # A rectangle on a top (z = z), from x, y.
  defp top({x, y, z}, {w, d}, class),
    do: {:poly, Iso.on_plane({x, y, z + 0.01}, {1, 0, 0}, {0, 1, 0}, {0, 0}, {w, d}), class}

  # A disc on the top, on the front, or on the side.
  defp disc(center, :top, r, class),
    do: {:poly, Iso.circle(center, {1, 0, 0}, {0, 1, 0}, r), class}

  defp disc(center, :front, r, class),
    do: {:poly, Iso.circle(center, {1, 0, 0}, {0, 0, 1}, r), class}

  defp disc(center, :side, r, class),
    do: {:poly, Iso.circle(center, {0, 1, 0}, {0, 0, 1}, r), class}

  # A cylinder that stands at a center: the near half of its body (the lit
  # left part and the right part in the shade), and its top. A point of the
  # ring is on the near half when its dx + dy is 0 or more; the screen shows
  # dx - dy to the side.
  defp cylinder({x, y, z}, r, h, material) do
    ring = fn zz -> Iso.circle({x, y, zz}, {1, 0, 0}, {0, 1, 0}, r, 16) end

    half = fn sign, face ->
      near = fn zz ->
        Enum.filter(ring.(zz), fn {px, py, _} ->
          px - x + (py - y) >= -1.0e-9 and sign * (px - x - (py - y)) >= -1.0e-9
        end)
      end

      lower = Enum.sort_by(near.(z), fn {px, py, _} -> px - py end)
      upper = Enum.sort_by(near.(z + h), fn {px, py, _} -> py - px end)
      {:poly, lower ++ upper, "i-#{material}-#{face} i-face"}
    end

    [half.(-1, "l"), half.(1, "r"), {:poly, ring.(z + h), "i-#{material}-t i-face"}]
  end

  # The wheels of a car or a van, on the side at x.
  defp wheels(x, ys, r) do
    for y <- ys,
        {radius, class} <- [{r, "i-black"}, {r * 0.5, "i-steel-r"}],
        do: disc({x + 0.02, y, r}, :side, radius, class)
  end

  @doc "The shapes of the icon of a kind, in the order of the paint."
  def shapes("fridge") do
    box({0, 0, 0}, {0.8, 0.7, 1.8}, "white") ++
      [
        front({0, 0.7, 1.2}, {0.8, 0.02}, "i-line"),
        front({0.62, 0.7, 1.3}, {0.05, 0.35}, "i-steel-r"),
        front({0.62, 0.7, 0.75}, {0.05, 0.35}, "i-steel-r")
      ]
  end

  def shapes("freezer") do
    box({0, 0, 0}, {1.2, 0.7, 0.85}, "white") ++
      [
        front({0, 0.7, 0.72}, {1.2, 0.02}, "i-line"),
        front({0.45, 0.7, 0.6}, {0.3, 0.05}, "i-steel-r")
      ]
  end

  def shapes("range") do
    box({0, 0, 0}, {0.8, 0.7, 0.9}, "steel") ++
      box({0, 0, 0.9}, {0.8, 0.12, 0.25}, "steel") ++
      [top({0.04, 0.16, 0.9}, {0.72, 0.5}, "i-black")] ++
      for(
        {x, y} <- [{0.22, 0.3}, {0.58, 0.3}, {0.22, 0.54}, {0.58, 0.54}],
        do: disc({x, y, 0.92}, :top, 0.11, "i-burner")
      ) ++
      [
        front({0.12, 0.7, 0.15}, {0.56, 0.45}, "i-glass-dark"),
        front({0.12, 0.7, 0.68}, {0.56, 0.05}, "i-steel-r")
      ]
  end

  def shapes("microwave") do
    box({0, 0, 0}, {0.8, 0.5, 0.45}, "steel") ++
      [
        front({0.06, 0.5, 0.07}, {0.5, 0.31}, "i-glass-dark"),
        front({0.62, 0.5, 0.1}, {0.12, 0.25}, "i-black")
      ]
  end

  def shapes("dishwasher") do
    box({0, 0, 0}, {0.7, 0.7, 0.85}, "steel") ++
      [
        front({0, 0.7, 0.72}, {0.7, 0.13}, "i-black"),
        front({0.2, 0.7, 0.62}, {0.3, 0.04}, "i-steel-t")
      ]
  end

  def shapes("washer"), do: laundry("i-glass")
  def shapes("dryer"), do: laundry("i-glass-dark")

  def shapes("water_heater") do
    cylinder({0.35, 0.35, 0}, 0.35, 1.4, "white") ++
      box({0.2, 0.3, 1.4}, {0.07, 0.07, 0.25}, "copper") ++
      box({0.45, 0.3, 1.4}, {0.07, 0.07, 0.25}, "copper")
  end

  def shapes("ac") do
    box({0, 0, 0}, {1.0, 1.0, 0.8}, "steel") ++
      [
        disc({0.5, 0.5, 0.81}, :top, 0.36, "i-black"),
        disc({0.5, 0.5, 0.82}, :top, 0.08, "i-steel-t")
      ] ++
      for(k <- 1..4, do: side({1.0, 0.1, k * 0.15}, {0.8, 0.03}, "i-line"))
  end

  def shapes("mini_split") do
    box({0, 0, 0}, {1.1, 0.3, 0.38}, "white") ++
      [
        front({0.08, 0.3, 0.05}, {0.94, 0.08}, "i-glass-dark"),
        front({0.9, 0.3, 0.24}, {0.06, 0.04}, "i-led")
      ]
  end

  def shapes("furnace") do
    box({0, 0, 0}, {0.6, 0.7, 1.3}, "steel") ++
      for(k <- 1..5, do: front({0.1, 0.7, 0.75 + k * 0.08}, {0.4, 0.03}, "i-line")) ++
      [front({0.2, 0.7, 0.2}, {0.2, 0.15}, "i-flame")]
  end

  # The strips of an air handler: a duct with a coil that glows in it.
  def shapes("heat_strips") do
    box({0, 0, 0}, {1.0, 0.5, 0.5}, "steel") ++
      [front({0.1, 0.5, 0.08}, {0.8, 0.34}, "i-black")] ++
      for(k <- 0..5, do: front({0.16 + k * 0.13, 0.5, 0.12}, {0.04, 0.26}, "i-hot"))
  end

  def shapes("smart_meter") do
    box({0, 0, 0}, {0.4, 0.25, 0.55}, "gray") ++
      [
        disc({0.2, 0.26, 0.3}, :front, 0.15, "i-glass"),
        front({0.12, 0.25, 0.25}, {0.16, 0.06}, "i-black")
      ]
  end

  # A lamp: a base, a stem, and a shade that glows.
  def shapes("lights") do
    cylinder({0.25, 0.25, 0}, 0.2, 0.05, "steel") ++
      box({0.23, 0.23, 0.05}, {0.04, 0.04, 0.5}, "steel") ++
      cylinder({0.25, 0.25, 0.45}, 0.24, 0.28, "shade")
  end

  def shapes("tv") do
    box({0.5, 0.2, 0}, {0.3, 0.2, 0.05}, "dark") ++
      box({0.62, 0.27, 0.05}, {0.06, 0.06, 0.15}, "dark") ++
      box({0, 0.28, 0.2}, {1.3, 0.05, 0.75}, "dark") ++
      [front({0.04, 0.33, 0.24}, {1.22, 0.67}, "i-screen")]
  end

  def shapes("computer") do
    box({0.3, 0.1, 0}, {0.2, 0.15, 0.05}, "dark") ++
      box({0.37, 0.15, 0.05}, {0.06, 0.04, 0.15}, "dark") ++
      box({0, 0.2, 0.2}, {0.8, 0.04, 0.5}, "dark") ++
      [front({0.03, 0.24, 0.23}, {0.74, 0.44}, "i-screen")] ++
      box({0.1, 0.45, 0}, {0.6, 0.22, 0.03}, "gray")
  end

  def shapes("ceiling_fan") do
    blade = fn corners -> {:poly, corners, "i-wood-t i-face"} end

    box({0.47, 0.47, 0.3}, {0.06, 0.06, 0.4}, "steel") ++
      [
        blade.([{0.5, 0.42, 0.3}, {1.1, 0.42, 0.3}, {1.1, 0.58, 0.3}, {0.5, 0.58, 0.3}]),
        blade.([{0.42, 0.5, 0.3}, {0.42, 1.1, 0.3}, {0.58, 1.1, 0.3}, {0.58, 0.5, 0.3}]),
        blade.([{0.5, 0.42, 0.3}, {-0.1, 0.42, 0.3}, {-0.1, 0.58, 0.3}, {0.5, 0.58, 0.3}]),
        blade.([{0.42, 0.5, 0.3}, {0.42, -0.1, 0.3}, {0.58, -0.1, 0.3}, {0.58, 0.5, 0.3}]),
        disc({0.5, 0.5, 0.31}, :top, 0.13, "i-steel-t")
      ]
  end

  def shapes("always_on") do
    box({0, 0, 0}, {1.0, 0.3, 0.12}, "white") ++
      for(x <- [0.15, 0.4, 0.65], do: top({x, 0.08, 0.12}, {0.14, 0.14}, "i-black")) ++
      [top({0.88, 0.12, 0.12}, {0.06, 0.06}, "i-led")]
  end

  def shapes("pool_pump") do
    cylinder({0.25, 0.3, 0}, 0.25, 0.45, "blue") ++ box({0.55, 0.1, 0}, {0.5, 0.4, 0.35}, "gray")
  end

  # A space heater: a small tower with a handle and a grille that glows.
  def shapes("space_heater") do
    box({0, 0, 0}, {0.45, 0.3, 0.8}, "white") ++
      box({0.12, 0.1, 0.8}, {0.21, 0.1, 0.06}, "gray") ++
      [front({0.07, 0.3, 0.12}, {0.31, 0.5}, "i-black")] ++
      for(k <- 1..4, do: front({0.1, 0.3, 0.06 + k * 0.11}, {0.25, 0.04}, "i-hot"))
  end

  def shapes("power_station") do
    box({0, 0, 0}, {0.8, 0.5, 0.62}, "dark") ++
      [
        front({0.12, 0.5, 0.34}, {0.56, 0.12}, "i-led"),
        front({0.1, 0.5, 0.1}, {0.6, 0.06}, "i-steel-r")
      ] ++
      box({0.15, 0.2, 0.62}, {0.5, 0.1, 0.06}, "gray")
  end

  def shapes("solar_panels") do
    box({0.45, 0.1, 0}, {0.08, 0.08, 1.0}, "gray") ++
      [
        {:poly, [{0, 0.8, 0.45}, {1.0, 0.8, 0.45}, {1.0, -0.4, 1.3}, {0, -0.4, 1.3}], "i-pv"},
        {:poly, [{0.5, 0.8, 0.45}, {0.53, 0.8, 0.45}, {0.53, -0.4, 1.3}, {0.5, -0.4, 1.3}],
         "i-pv-line"}
      ]
  end

  def shapes("transfer_switch") do
    box({0, 0, 0}, {0.6, 0.2, 0.8}, "gray") ++
      [
        front({0.06, 0.2, 0.06}, {0.48, 0.68}, "i-steel-t"),
        front({0.4, 0.2, 0.35}, {0.06, 0.15}, "i-black")
      ] ++
      box({0.25, 0.2, 0.6}, {0.1, 0.12, 0.05}, "red")
  end

  def shapes("ev") do
    {l, w} = {2.4, 1.0}
    cabin = fn corners, class -> {:poly, corners, class} end

    box({0, 0, 0.15}, {w, l, 0.4}, "red") ++
      [
        cabin.(
          [{0.08, 0.6, 0.55}, {w - 0.08, 0.6, 0.55}, {w - 0.15, 0.85, 0.85}, {0.15, 0.85, 0.85}],
          "i-red-t"
        ),
        cabin.(
          [{w, 0.6, 0.55}, {w, 1.9, 0.55}, {w - 0.15, 1.65, 0.85}, {w - 0.15, 0.85, 0.85}],
          "i-glass-dark"
        ),
        cabin.(
          [{0.08, 1.9, 0.55}, {w, 1.9, 0.55}, {w - 0.15, 1.65, 0.85}, {0.15, 1.65, 0.85}],
          "i-glass-dark"
        ),
        cabin.(
          [
            {0.15, 0.85, 0.85},
            {w - 0.15, 0.85, 0.85},
            {w - 0.15, 1.65, 0.85},
            {0.15, 1.65, 0.85}
          ],
          "i-red-t"
        ),
        front({0.1, l, 0.35}, {0.18, 0.08}, "i-bulb"),
        front({w - 0.28, l, 0.35}, {0.18, 0.08}, "i-bulb")
      ] ++ wheels(w, [0.45, l - 0.5], 0.2)
  end

  def shapes("camper_van") do
    {l, w, h} = {2.6, 1.0, 1.25}
    profile = [{0, 0.2}, {l, 0.2}, {l, 0.65}, {2.3, 0.72}, {2.1, 1.12}, {2.0, h}, {0, h}]
    across = fn {y1, z1}, {y2, z2} -> [{0, y1, z1}, {w, y1, z1}, {w, y2, z2}, {0, y2, z2}] end

    [
      {:poly, Enum.map(profile, fn {y, z} -> {w, y, z} end), "i-white-r i-face"},
      {:poly, across.({0, h}, {2.0, h}), "i-white-t i-face"},
      {:poly, across.({2.0, h}, {2.1, 1.12}), "i-white-t i-face"},
      {:poly, across.({2.3, 0.72}, {2.1, 1.12}), "i-glass-dark"},
      {:poly, across.({l, 0.65}, {2.3, 0.72}), "i-white-t i-face"},
      front({0, l, 0.2}, {w, 0.45}, "i-white-l i-face"),
      side({w, 0.75, 0.6}, {0.6, 0.35}, "i-glass-dark"),
      side({w, 1.45, 0.2}, {0.55, 0.85}, "i-steel-l")
    ] ++ wheels(w, [0.5, 2.25], 0.2)
  end

  def shapes("swivel_seat") do
    cylinder({0.35, 0.35, 0}, 0.3, 0.12, "dark") ++
      box({0.05, 0.05, 0.12}, {0.6, 0.6, 0.18}, "cloth") ++
      box({0.05, 0.05, 0.3}, {0.6, 0.14, 0.6}, "cloth")
  end

  def shapes("dc_charger") do
    box({0, 0, 0}, {0.6, 0.4, 0.18}, "steel") ++
      for(k <- 1..3, do: top({0.08, k * 0.1, 0.18}, {0.44, 0.03}, "i-line")) ++
      box({0.62, 0.1, 0.05}, {0.15, 0.06, 0.06}, "red") ++
      box({0.62, 0.25, 0.05}, {0.15, 0.06, 0.06}, "dark")
  end

  def shapes("van_fridge") do
    box({0, 0, 0}, {0.75, 0.45, 0.5}, "white") ++
      box({0, 0, 0.5}, {0.75, 0.45, 0.06}, "dark") ++
      [front({0.3, 0.45, 0.35}, {0.15, 0.06}, "i-led")]
  end

  def shapes("stove") do
    box({0, 0, 0}, {0.6, 0.45, 0.1}, "steel") ++
      [
        disc({0.17, 0.22, 0.11}, :top, 0.11, "i-burner"),
        disc({0.43, 0.22, 0.11}, :top, 0.11, "i-burner")
      ]
  end

  def shapes("sink") do
    box({0, 0, 0}, {0.8, 0.55, 0.6}, "wood") ++
      [top({0.15, 0.12, 0.6}, {0.5, 0.33}, "i-steel-r")] ++
      box({0.37, 0.02, 0.6}, {0.06, 0.06, 0.25}, "steel")
  end

  def shapes("water_tank") do
    box({0, 0, 0}, {0.8, 0.5, 0.45}, "blue") ++
      [
        disc({0.4, 0.25, 0.46}, :top, 0.08, "i-white-t"),
        front({0.05, 0.5, 0.05}, {0.7, 0.04}, "i-line"),
        side({0.8, 0.05, 0.05}, {0.4, 0.04}, "i-line")
      ]
  end

  def shapes("water_pump") do
    cylinder({0.2, 0.2, 0}, 0.18, 0.3, "steel") ++
      box({0.38, 0.12, 0.05}, {0.3, 0.16, 0.16}, "dark") ++
      box({0.68, 0.16, 0.08}, {0.2, 0.08, 0.08}, "blue")
  end

  def shapes("counter") do
    box({0, 0, 0}, {1.2, 0.55, 0.85}, "wood") ++
      box({-0.02, -0.02, 0.85}, {1.24, 0.59, 0.05}, "light-wood") ++
      [front({0.6, 0.55, 0.05}, {0.02, 0.75}, "i-line")]
  end

  def shapes("bench") do
    box({0, 0, 0}, {1.0, 0.5, 0.4}, "wood") ++
      box({0, 0, 0.4}, {1.0, 0.5, 0.1}, "cloth") ++
      box({0, 0, 0.5}, {1.0, 0.12, 0.4}, "cloth")
  end

  def shapes("van_table") do
    box({0.32, 0.22, 0}, {0.06, 0.06, 0.65}, "steel") ++
      box({0, 0, 0.65}, {0.7, 0.5, 0.05}, "light-wood")
  end

  def shapes("van_fan") do
    box({0, 0, 0}, {0.6, 0.6, 0.08}, "white") ++
      [
        {:poly, [{0.06, 0.54, 0.08}, {0.54, 0.54, 0.08}, {0.54, 0.06, 0.3}, {0.06, 0.06, 0.3}],
         "i-glass"}
      ]
  end

  def shapes("window") do
    box({0, 0, 0}, {0.9, 0.06, 0.6}, "dark") ++ [front({0.05, 0.06, 0.05}, {0.8, 0.5}, "i-glass")]
  end

  def shapes("van_lights") do
    box({0, 0, 0}, {1.0, 0.2, 0.03}, "white") ++
      for(x <- [0.15, 0.5, 0.85], do: disc({x, 0.1, 0.04}, :top, 0.07, "i-bulb"))
  end

  def shapes("devices") do
    box({0, 0, 0}, {0.7, 0.45, 0.03}, "gray") ++
      [
        {:poly, [{0, 0, 0.03}, {0.7, 0, 0.03}, {0.7, -0.12, 0.45}, {0, -0.12, 0.45}], "i-dark-l"},
        {:poly,
         [{0.04, 0.005, 0.07}, {0.66, 0.005, 0.07}, {0.66, -0.1, 0.41}, {0.04, -0.1, 0.41}],
         "i-screen"}
      ] ++
      box({0.8, 0.2, 0}, {0.16, 0.3, 0.02}, "dark")
  end

  def shapes("diesel_heater") do
    box({0, 0, 0}, {0.6, 0.35, 0.3}, "red") ++
      box({0, 0, 0.3}, {0.6, 0.35, 0.04}, "dark") ++
      box({0.62, 0.12, 0.1}, {0.25, 0.1, 0.1}, "steel")
  end

  def shapes("co_alarm") do
    cylinder({0.3, 0.3, 0}, 0.3, 0.08, "white") ++ [disc({0.3, 0.3, 0.09}, :top, 0.05, "i-hot")]
  end

  def shapes("bed_platform") do
    box({0, 0, 0}, {1.4, 1.9, 0.5}, "wood") ++
      box({0.03, 0.03, 0.5}, {1.34, 1.84, 0.18}, "cloth") ++
      box({0.15, 0.1, 0.68}, {1.1, 0.35, 0.1}, "white")
  end

  def shapes("storage") do
    box({0, 0, 0}, {0.9, 0.6, 0.6}, "wood") ++
      [
        front({0.05, 0.6, 0.3}, {0.8, 0.02}, "i-line"),
        front({0.35, 0.6, 0.4}, {0.2, 0.04}, "i-steel-r"),
        front({0.35, 0.6, 0.12}, {0.2, 0.04}, "i-steel-r")
      ]
  end

  def shapes("van_battery") do
    box({0, 0, 0}, {0.6, 0.35, 0.4}, "blue") ++
      box({0.08, 0.1, 0.4}, {0.1, 0.1, 0.06}, "red") ++
      box({0.42, 0.1, 0.4}, {0.1, 0.1, 0.06}, "dark") ++
      [front({0.1, 0.35, 0.15}, {0.4, 0.08}, "i-white-t")]
  end

  def shapes("inverter") do
    box({0, 0, 0}, {0.8, 0.4, 0.25}, "steel") ++
      for(k <- 1..4, do: top({0.08, k * 0.07, 0.25}, {0.64, 0.025}, "i-line")) ++
      [front({0.3, 0.4, 0.06}, {0.2, 0.12}, "i-black")]
  end

  # A shore power inlet: a box with a round socket and its yellow lid, and
  # a cable that bends to the side.
  def shapes("shore_power") do
    box({0, 0, 0}, {0.4, 0.15, 0.4}, "gray") ++
      [
        disc({0.2, 0.16, 0.2}, :front, 0.13, "i-black"),
        disc({0.2, 0.17, 0.2}, :front, 0.05, "i-flame")
      ] ++
      box({0.17, 0.15, -0.12}, {0.06, 0.25, 0.06}, "dark") ++
      box({0.17, 0.4, -0.12}, {0.45, 0.06, 0.06}, "dark")
  end

  def shapes("van_solar") do
    box({0, 0, 0}, {0.8, 1.2, 0.04}, "gray") ++ [top({0.03, 0.03, 0.04}, {0.74, 1.14}, "i-pv")]
  end

  def shapes("insulation") do
    box({0, 0, 0}, {1.0, 0.6, 0.15}, "pink") ++ box({0, 0, 0.15}, {1.0, 0.6, 0.15}, "pink")
  end

  def shapes("walls") do
    box({0, 0, 0}, {1.0, 0.05, 0.9}, "light-wood") ++
      for(k <- 1..3, do: front({0, 0.05, k * 0.22}, {1.0, 0.015}, "i-line"))
  end

  def shapes("van_floor") do
    box({0, 0, 0}, {1.0, 1.0, 0.05}, "light-wood") ++
      for(k <- 1..3, do: top({0, k * 0.25, 0.05}, {1.0, 0.015}, "i-line"))
  end

  # The kind "other": a box.
  def shapes("other") do
    box({0, 0, 0}, {0.6, 0.6, 0.6}, "gray") ++ [front({0.2, 0.6, 0.2}, {0.2, 0.2}, "i-steel-t")]
  end

  # A washer or a dryer: a box with a round door.
  defp laundry(glass) do
    box({0, 0, 0}, {0.7, 0.7, 0.9}, "white") ++
      [
        front({0, 0.7, 0.75}, {0.7, 0.02}, "i-line"),
        disc({0.35, 0.71, 0.38}, :front, 0.24, "i-steel-l"),
        disc({0.35, 0.72, 0.38}, :front, 0.18, glass)
      ]
  end
end
