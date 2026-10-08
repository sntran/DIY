defmodule DIYWeb.Icon do
  @moduledoc """
  The isometric icon of each kind of item (`DIY.Catalog`), in SVG, in the
  style of the pictures (`DIYWeb.Scene`): a few boxes, discs and details,
  with a light top, a lit left face and a right face in the shade.

  An icon is for the eyes only (`aria-hidden`): the name of the item is
  next to it. The colors are classes of `assets/css/app.css` (`i-*`). A
  material class has three faces: `-t` (the top), `-l` and `-r`.
  """
  use DIYWeb, :html

  alias DIYWeb.Iso

  attr :type, :string, required: true, doc: "the kind of the item"
  attr :class, :string, default: "size-10"

  @doc "The icon of a kind of item."
  def item(assigns) do
    shapes = shapes(assigns.type)
    assigns = assign(assigns, shapes: shapes, view: view(shapes))

    ~H"""
    <svg viewBox={@view} class={["shrink-0", @class]} aria-hidden="true">
      <%= for shape <- @shapes do %>
        <%= case shape do %>
          <% {:poly, corners, class} -> %>
            <polygon points={Iso.points({0, 0}, corners)} class={class} />
          <% {:circle, point, r, class} -> %>
            <circle
              cx={Iso.round1(elem(Iso.at({0, 0}, point), 0))}
              cy={Iso.round1(elem(Iso.at({0, 0}, point), 1))}
              r={r}
              class={class}
            />
        <% end %>
      <% end %>
    </svg>
    """
  end

  # A square box of the SVG around the shapes, with a margin.
  defp view(shapes) do
    points =
      Enum.flat_map(shapes, fn
        {:poly, corners, _class} ->
          Enum.map(corners, &Iso.at({0, 0}, &1))

        {:circle, point, r, _class} ->
          {x, y} = Iso.at({0, 0}, point)
          [{x - r, y - r}, {x + r, y + r}]
      end)

    {xs, ys} = Enum.unzip(points)
    {x0, x1} = Enum.min_max(xs)
    {y0, y1} = Enum.min_max(ys)
    size = max(x1 - x0, y1 - y0) + 2
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2
    Enum.map_join([cx - size / 2, cy - size / 2, size, size], " ", &Iso.round1/1)
  end

  # A box of a material: its left, its right and its top.
  defp box(corner, size, material) do
    box = Iso.box(corner, size)

    [
      {:poly, box.left, "i-#{material}-l"},
      {:poly, box.right, "i-#{material}-r"},
      {:poly, box.top, "i-#{material}-t"}
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

  # A cylinder that stands at a center: its body, and its top.
  defp cylinder({x, y, z}, r, h, material) do
    ring = fn zz -> Iso.circle({x, y, zz}, {1, 0, 0}, {0, 1, 0}, r, 24) end
    # The half of the ring to the front: the points with x - y over the
    # line of the view, from the left to the right.
    near = fn zz -> Enum.filter(ring.(zz), fn {px, py, _} -> px - x + (py - y) >= 0 end) end
    lower = Enum.sort_by(near.(z), fn {px, py, _} -> px - py end)
    upper = Enum.sort_by(near.(z + h), fn {px, py, _} -> py - px end)
    [{:poly, lower ++ upper, "i-#{material}-l"}, {:poly, ring.(z + h), "i-#{material}-t"}]
  end

  # The wheels of a car or a van, on the side at x.
  defp wheels(x, ys, r) do
    for y <- ys,
        {radius, class} <- [{r, "i-black"}, {r * 0.5, "i-steel-r"}],
        do: disc({x + 0.02, y, r}, :side, radius, class)
  end

  # The shapes of each kind. The unit is near a meter, and the front of an
  # item looks to the left (y).
  @doc false
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
    box({0, 0, 0}, {1.1, 0.25, 0.32}, "white") ++
      [front({0.1, 0.25, 0.06}, {0.9, 0.04}, "i-line")]
  end

  def shapes("furnace") do
    box({0, 0, 0}, {0.6, 0.7, 1.3}, "steel") ++
      for(k <- 1..5, do: front({0.1, 0.7, 0.75 + k * 0.08}, {0.4, 0.03}, "i-line")) ++
      [front({0.2, 0.7, 0.2}, {0.2, 0.15}, "i-flame")]
  end

  def shapes("heat_strips") do
    box({0, 0, 0}, {0.8, 0.3, 0.5}, "steel") ++
      for(k <- 1..3, do: front({0.08, 0.3, k * 0.12}, {0.64, 0.04}, "i-hot"))
  end

  def shapes("smart_meter") do
    box({0, 0, 0}, {0.4, 0.25, 0.55}, "gray") ++
      [
        disc({0.2, 0.26, 0.3}, :front, 0.15, "i-glass"),
        front({0.12, 0.25, 0.25}, {0.16, 0.06}, "i-black")
      ]
  end

  def shapes("lights") do
    box({0.12, 0.12, 0}, {0.16, 0.16, 0.18}, "steel") ++
      [{:circle, {0.2, 0.2, 0.36}, 2.2, "i-bulb"}]
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
    box({0.47, 0.47, 0.3}, {0.06, 0.06, 0.4}, "steel") ++
      [
        {:poly, [{0.5, 0.42, 0.3}, {1.1, 0.42, 0.3}, {1.1, 0.58, 0.3}, {0.5, 0.58, 0.3}],
         "i-wood-t"},
        {:poly, [{0.42, 0.5, 0.3}, {0.42, 1.1, 0.3}, {0.58, 1.1, 0.3}, {0.58, 0.5, 0.3}],
         "i-wood-t"},
        {:poly, [{0.5, 0.42, 0.3}, {-0.1, 0.42, 0.3}, {-0.1, 0.58, 0.3}, {0.5, 0.58, 0.3}],
         "i-wood-t"},
        {:poly, [{0.42, 0.5, 0.3}, {0.42, -0.1, 0.3}, {0.58, -0.1, 0.3}, {0.58, 0.5, 0.3}],
         "i-wood-t"}
      ] ++ [disc({0.5, 0.5, 0.31}, :top, 0.13, "i-steel-t")]
  end

  def shapes("always_on") do
    box({0, 0, 0}, {1.0, 0.3, 0.12}, "white") ++
      for(x <- [0.15, 0.4, 0.65], do: top({x, 0.08, 0.12}, {0.14, 0.14}, "i-black")) ++
      [top({0.88, 0.12, 0.12}, {0.06, 0.06}, "i-led")]
  end

  def shapes("pool_pump") do
    cylinder({0.25, 0.3, 0}, 0.25, 0.45, "blue") ++ box({0.55, 0.1, 0}, {0.5, 0.4, 0.35}, "gray")
  end

  def shapes("space_heater") do
    box({0, 0, 0}, {0.5, 0.3, 0.65}, "white") ++
      for(k <- 1..4, do: front({0.08, 0.3, 0.1 + k * 0.1}, {0.34, 0.04}, "i-hot"))
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
      [{:poly, [{0, 0.8, 0.45}, {1.0, 0.8, 0.45}, {1.0, -0.4, 1.3}, {0, -0.4, 1.3}], "i-pv"}] ++
      [
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

    wheels(w, [0.45, l - 0.5], 0.2) ++
      box({0, 0, 0.15}, {w, l, 0.4}, "red") ++
      [
        {:poly,
         [{0.08, 0.6, 0.55}, {w - 0.08, 0.6, 0.55}, {w - 0.15, 0.85, 0.85}, {0.15, 0.85, 0.85}],
         "i-red-t"},
        {:poly, [{w, 0.6, 0.55}, {w, 1.9, 0.55}, {w - 0.15, 1.65, 0.85}, {w - 0.15, 0.85, 0.85}],
         "i-glass-dark"},
        {:poly, [{0.08, 1.9, 0.55}, {w, 1.9, 0.55}, {w - 0.15, 1.65, 0.85}, {0.15, 1.65, 0.85}],
         "i-glass-dark"},
        {:poly,
         [{0.15, 0.85, 0.85}, {w - 0.15, 0.85, 0.85}, {w - 0.15, 1.65, 0.85}, {0.15, 1.65, 0.85}],
         "i-red-t"}
      ] ++
      [
        front({0.1, l, 0.35}, {0.18, 0.08}, "i-led"),
        front({w - 0.28, l, 0.35}, {0.18, 0.08}, "i-led")
      ]
  end

  def shapes("camper_van") do
    {l, w, h} = {2.6, 1.0, 1.25}

    side =
      Enum.map([{0, 0.2}, {l, 0.2}, {l, 0.65}, {2.3, 0.72}, {2.1, 1.12}, {2.0, h}, {0, h}], fn {y,
                                                                                                z} ->
        {w, y, z}
      end)

    wheels(w, [0.5, 2.25], 0.2) ++
      [
        {:poly, side, "i-white-r"},
        {:poly, [{0, 0, h}, {w, 0, h}, {w, 2.0, h}, {0, 2.0, h}], "i-white-t"},
        {:poly, [{0, 2.0, h}, {w, 2.0, h}, {w, 2.1, 1.12}, {0, 2.1, 1.12}], "i-white-t"},
        {:poly, [{0, 2.3, 0.72}, {w, 2.3, 0.72}, {w, 2.1, 1.12}, {0, 2.1, 1.12}], "i-glass-dark"},
        {:poly, [{0, l, 0.65}, {w, l, 0.65}, {w, 2.3, 0.72}, {0, 2.3, 0.72}], "i-white-t"},
        front({0, l, 0.2}, {w, 0.45}, "i-white-l"),
        side({w, 0.75, 0.6}, {0.6, 0.35}, "i-glass-dark"),
        side({w, 1.45, 0.2}, {0.55, 0.85}, "i-steel-l")
      ]
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
    box({0, 0, 0}, {0.8, 0.5, 0.45}, "blue") ++ [disc({0.4, 0.25, 0.46}, :top, 0.08, "i-white-t")]
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
      box({0, 0, 0.4}, {1.0, 0.5, 0.1}, "cloth") ++ box({0, 0, 0.5}, {1.0, 0.12, 0.4}, "cloth")
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
      [{:poly, [{0, 0, 0.03}, {0.7, 0, 0.03}, {0.7, -0.12, 0.45}, {0, -0.12, 0.45}], "i-dark-l"}] ++
      [
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
        front({0.35, 0.6, 0.4}, {0.2, 0.04}, "i-steel-r")
      ] ++
      [front({0.35, 0.6, 0.12}, {0.2, 0.04}, "i-steel-r")]
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

  def shapes("shore_power") do
    box({0, 0, 0}, {0.4, 0.15, 0.4}, "gray") ++
      [
        disc({0.2, 0.16, 0.2}, :front, 0.13, "i-black"),
        disc({0.2, 0.17, 0.2}, :front, 0.05, "i-hot")
      ]
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

  def shapes(_type) do
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
