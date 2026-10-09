defmodule DIYWeb.Decor do
  @moduledoc """
  The furniture of a room on the plan (`DIYWeb.Cutaway`). For example, a
  bedroom has a bed, and a kitchen has counters and a table. The furniture
  is for the eyes only, as in a drawn picture of a house. It uses
  no power, it is not an item, and a tap goes through it to the floor of
  the room.

  The name of a room gives its furniture. Each piece has its place in the
  room: against the back wall, in the middle, or at the front. In a
  kitchen, counters fill the back wall between the items. A piece that
  touches an item or a piece before it, or that is larger than the room,
  does not show. So the items always show. A rug is flat: the other
  pieces and the items can stand on it.

  The models use the parts of `DIYWeb.Icon.Shapes`, in meters, with round
  corners where the real piece has them. The front of a model looks to y.
  """

  alias DIY.{Catalog, Layout}
  alias DIYWeb.{Camera, Geometry}
  alias DIYWeb.Icon.Shapes

  @m 0.0254
  # The space between a piece and a wall, or an item (inches).
  @gap 4
  # An item on a wall or a ceiling (a fan) leaves the floor under it free:
  # its lift is this many inches or more.
  @ceiling 60
  # The depth of a kitchen counter (inches), and its least length.
  @counter 25
  @least 18

  @doc """
  The pieces of a room: `{model, x, y, turn}`. `x` and `y` are the back
  corner of the piece on the plan of the room (inches). The turn is 0 (the
  front of the piece looks to the front of the room) or 2 (to the back).
  """
  def pieces(room, items) do
    taken =
      for item <- items, Catalog.lift(item.type) < @ceiling, do: Layout.item_box(item)

    room
    |> plan(taken)
    |> Enum.reduce({[], taken}, fn {model, anchor, turn}, {done, taken} ->
      {w, d} = footprint(model, turn)
      flat? = flat?(model)

      with {x, y} <- place(anchor, {w, d}, room.plan),
           box = %{x: x, y: y, w: w, d: d},
           false <- not flat? and Enum.any?(taken, &Layout.overlap?(grow(box), &1)) do
        {[{model, x, y, turn} | done], if(flat?, do: taken, else: [box | taken])}
      else
        _ -> {done, taken}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # The pieces of a room, from its name: a model, its place, and its turn.
  defp plan(%{place: :outdoor, name: name}, _taken) do
    if String.contains?(String.downcase(name), "yard"),
      do: [
        {model("patio"), :center, 0},
        {model("tree"), :back_left, 0},
        {model("tree"), :front_right, 0},
        {model("bush"), :back_right, 0},
        {model("bush"), :front_left, 0}
      ],
      else: []
  end

  defp plan(%{place: :indoor, name: name} = room, taken) do
    name = String.downcase(name)

    cond do
      String.contains?(name, "bed") ->
        [
          {model("rug"), :center, 0},
          {model("bed"), :back_center, 0},
          {model("nightstand"), :beside_left, 0},
          {model("nightstand"), :beside_right, 0},
          {model("dresser"), :left_center, 0},
          {model("plant"), :front_right, 0}
        ]

      String.contains?(name, "living") ->
        [
          {model("rug"), :center, 0},
          {model("sofa"), :front_center, 2},
          {model("coffee_table"), :center, 0},
          {model("armchair"), :left_center, 0},
          {model("shelf_books"), :back_right, 0},
          {model("plant"), :back_left, 0},
          {model("plant"), :front_right, 0}
        ]

      String.contains?(name, "kitchen") ->
        counters(room, taken) ++
          [{model("dining"), :front_center, 0}, {model("plant"), :front_left, 0}]

      String.contains?(name, "bath") ->
        [
          {model("bath_mat"), :center, 0},
          {model("tub"), :back_left, 0},
          {model("toilet"), :back_right, 0},
          {model("vanity"), :front_right, 2}
        ]

      String.contains?(name, "garage") ->
        [{model("bench"), :back_right, 0}, {model("shelf"), :back_left, 0}]

      String.contains?(name, "laundry") ->
        [{model("shelf"), :back_right, 0}, {model("basket"), :front_left, 0}]

      String.contains?(name, "attic") ->
        [{model("boxes"), :back_left, 0}, {model("boxes"), :back_right, 0}]

      true ->
        [{model("plant"), :back_left, 0}]
    end
  end

  defp plan(_room, _taken), do: []

  # The counters of a kitchen: they fill the back wall where no item is,
  # from the left wall to the right wall. A part shorter than 18 inches
  # stays empty.
  defp counters(room, taken) do
    band = %{x: 0, y: 0, w: room.plan.w, d: @counter + @gap}

    cuts =
      for box <- taken, Layout.overlap?(box, band), do: {box.x - @gap, box.x + box.w + @gap}

    {0, room.plan.w}
    |> free(Enum.sort(cuts))
    |> Enum.filter(fn {a, b} -> b - a >= @least end)
    |> Enum.map(fn {a, b} -> {model({"counter", b - a}), {:at, a, 1}, 0} end)
  end

  # The parts of a range that no cut covers. Each cut starts in the range
  # (the cuts are of the items on the back wall).
  defp free({a, b}, []), do: [{a, b}]

  defp free({a, b}, [{c, d} | rest]) do
    cond do
      d <= a -> free({a, b}, rest)
      c <= a -> free({max(a, d), b}, rest)
      true -> [{a, c} | free({max(a, d), b}, rest)]
    end
    |> Enum.filter(fn {p, q} -> q > p end)
  end

  # The place of a piece in a room (inches), or nil when it does not fit.
  defp place({:at, x, y}, {w, d}, %{w: rw, d: rd}),
    do: if(x < 0 or y < 0 or x + w > rw or y + d > rd, do: nil, else: {round(x), round(y)})

  defp place(anchor, {w, d}, %{w: rw, d: rd}) do
    if w + 2 * @gap > rw or d + 2 * @gap > rd do
      nil
    else
      {cx, cy} = {(rw - w) / 2, (rd - d) / 2}
      {left, right, back, front} = {@gap, rw - w - @gap, @gap, rd - d - @gap}

      {x, y} =
        case anchor do
          :center -> {cx, cy}
          :back_center -> {cx, back}
          :front_center -> {cx, front}
          :left_center -> {left, cy}
          :back_left -> {left, back}
          :back_right -> {right, back}
          :front_left -> {left, front}
          :front_right -> {right, front}
          # Next to a bed (63 inches wide) in the middle of the back wall.
          :beside_left -> {rw / 2 - 36 - w, back}
          :beside_right -> {rw / 2 + 36, back}
        end

      if x < 0 or x + w > rw, do: nil, else: {round(x), round(y)}
    end
  end

  defp grow(%{x: x, y: y, w: w, d: d}),
    do: %{x: x - @gap, y: y - @gap, w: w + 2 * @gap, d: d + 2 * @gap}

  # The size of a model on the plan (inches), after its turn.
  defp footprint(model, turn) do
    {{x0, y0, _}, {x1, y1, _}} = Shapes.bounds(model)
    {w, d} = {round((x1 - x0) / @m), round((y1 - y0) / @m)}
    if rem(turn, 2) == 0, do: {w, d}, else: {d, w}
  end

  # A model that is flat on the floor: a rug or a mat.
  defp flat?(model) do
    {{_, _, z0}, {_, _, z1}} = Shapes.bounds(model)
    z1 - z0 < 0.02
  end

  ## The models (meters)

  @doc "The model of a piece of furniture, from its name."
  def model("bed") do
    [
      {:box, {0, 0, 0}, {1.6, 0.08, 1.0}, "wood"},
      {:box, {0, 0.08, 0}, {1.6, 2.0, 0.28}, "wood"},
      round_box({0.04, 0.1, 0.28}, {1.52, 1.96, 0.2}, 0.06, "linen"),
      round_box({0.16, 0.16, 0.48}, {0.56, 0.34, 0.12}, 0.08, "white"),
      round_box({0.88, 0.16, 0.48}, {0.56, 0.34, 0.12}, 0.08, "white"),
      round_box({0.02, 0.78, 0.48}, {1.56, 1.3, 0.07}, 0.05, "sage")
    ]
  end

  def model("nightstand") do
    [
      round_box({0, 0, 0}, {0.45, 0.4, 0.55}, 0.03, "wood"),
      {:cyl, {0.22, 0.2, 0.55}, 0.03, 0.25, "dark"},
      {:cyl, {0.22, 0.2, 0.75}, 0.12, 0.18, "shade"}
    ]
  end

  def model("dresser") do
    [round_box({0, 0, 0}, {1.0, 0.45, 0.8}, 0.03, "light-wood")] ++
      for(z <- [0.18, 0.42, 0.66], do: {:box, {0.45, 0.45, z}, {0.1, 0.01, 0.02}, "wood"}) ++
      [{:cyl, {0.8, 0.22, 0.8}, 0.07, 0.2, "clay"}] ++ ball({0.8, 0.22, 1.14}, 0.12, "leaf")
  end

  def model("rug"), do: [round_box({0, 0, 0}, {2.0, 1.5, 0.012}, 0.15, "rug")]
  def model("bath_mat"), do: [round_box({0, 0, 0}, {0.8, 0.5, 0.012}, 0.1, "rug")]

  def model("sofa") do
    [
      round_box({0, 0, 0}, {2.1, 0.9, 0.42}, 0.08, "sage"),
      round_box({0, 0, 0.42}, {0.2, 0.9, 0.22}, 0.08, "sage"),
      round_box({1.9, 0, 0.42}, {0.2, 0.9, 0.22}, 0.08, "sage"),
      round_box({0.2, 0, 0.42}, {1.7, 0.25, 0.42}, 0.08, "sage"),
      round_box({0.24, 0.28, 0.42}, {0.8, 0.6, 0.1}, 0.08, "linen"),
      round_box({1.06, 0.28, 0.42}, {0.8, 0.6, 0.1}, 0.08, "linen")
    ]
  end

  def model("armchair") do
    [
      round_box({0, 0, 0}, {0.85, 0.85, 0.4}, 0.08, "clay"),
      round_box({0, 0, 0.4}, {0.85, 0.2, 0.45}, 0.08, "clay"),
      round_box({0, 0.2, 0.4}, {0.15, 0.65, 0.2}, 0.06, "clay"),
      round_box({0.7, 0.2, 0.4}, {0.15, 0.65, 0.2}, 0.06, "clay")
    ]
  end

  def model("coffee_table") do
    legs(1.0, 0.55, 0.36, "wood") ++
      [
        round_box({0, 0, 0.36}, {1.0, 0.55, 0.05}, 0.12, "wood"),
        {:cyl, {0.3, 0.27, 0.41}, 0.08, 0.06, "linen"},
        {:box, {0.55, 0.15, 0.41}, {0.25, 0.18, 0.04}, "red"}
      ]
  end

  def model("shelf_books") do
    shelves =
      for z <- [0.0, 0.5, 1.0, 1.5],
          do: {:box, {0.04, 0, z}, {0.82, 0.35, 0.04}, "wood"}

    books =
      for {z, i} <- Enum.with_index([0.04, 0.54, 1.04]),
          {x, w, h, material} <- [
            {0.06, 0.08, 0.3, "red"},
            {0.15, 0.06, 0.34, "blue"},
            {0.22, 0.09, 0.28, "sage"},
            {0.45 + i * 0.05, 0.1, 0.32, "clay"}
          ],
          do: {:box, {x, 0.05, z}, {w, 0.24, h}, material}

    [
      {:box, {0, 0, 0}, {0.04, 0.35, 1.84}, "wood"},
      {:box, {0.86, 0, 0}, {0.04, 0.35, 1.84}, "wood"}
    ] ++
      shelves ++ books
  end

  def model("dining") do
    chairs =
      for x <- [0.35, 1.05], y <- [0, 1.25] do
        chair({x, y, 0}, if(y == 0, do: :back, else: :front))
      end

    [{:group, legs(1.4, 0.8, 0.72, "wood", {0.15, 0.4})}] ++
      List.flatten(chairs) ++
      [
        round_box({0.15, 0.4, 0.72}, {1.4, 0.8, 0.05}, 0.06, "wood"),
        {:cyl, {0.85, 0.8, 0.77}, 0.1, 0.05, "linen"}
      ]
  end

  def model({"counter", inches}) do
    w = inches * @m

    [
      {:box, {0, 0, 0}, {w, 0.6, 0.86}, "sage"},
      {:box, {0, 0, 0.86}, {w, 0.63, 0.04}, "linen"}
    ] ++
      for k <- 0..max(trunc(w / 0.45) - 1, 0) do
        {:box, {k * 0.45 + 0.2, 0.6, 0.62}, {0.08, 0.01, 0.02}, "dark"}
      end
  end

  def model("plant") do
    [{:cyl, {0.2, 0.2, 0}, 0.14, 0.3, "clay"}] ++
      ball({0.2, 0.2, 0.55}, 0.22, "leaf") ++ ball({0.14, 0.2, 0.8}, 0.14, "leaf")
  end

  def model("tree") do
    [{:cyl, {0.5, 0.5, 0}, 0.07, 0.9, "wood"}] ++
      ball({0.5, 0.5, 1.35}, 0.5, "leaf") ++
      ball({0.35, 0.5, 1.75}, 0.32, "leaf") ++ ball({0.65, 0.55, 1.7}, 0.3, "leaf")
  end

  def model("bush") do
    ball({0.25, 0.3, 0.25}, 0.25, "leaf") ++ ball({0.45, 0.3, 0.3}, 0.25, "leaf")
  end

  def model("tub") do
    [
      round_box({0, 0, 0}, {1.6, 0.75, 0.55}, 0.12, "white"),
      round_box({0.08, 0.08, 0.55}, {1.44, 0.59, 0.005}, 0.1, "blue")
    ]
  end

  def model("toilet") do
    [
      round_box({0.05, 0, 0}, {0.4, 0.18, 0.8}, 0.03, "white"),
      {:cyl, {0.25, 0.4, 0}, 0.2, 0.42, "white"}
    ]
  end

  def model("vanity") do
    [
      round_box({0, 0, 0}, {0.8, 0.5, 0.82}, 0.03, "wood"),
      {:box, {0, 0, 0.82}, {0.8, 0.5, 0.04}, "white"},
      {:cyl, {0.4, 0.25, 0.86}, 0.16, 0.06, "white"}
    ]
  end

  def model("bench") do
    legs(1.8, 0.6, 0.85, "wood") ++
      [
        {:box, {0, 0, 0.85}, {1.8, 0.6, 0.06}, "wood"},
        {:box, {0.2, 0.05, 0.91}, {0.4, 0.3, 0.25}, "red"},
        {:box, {1.0, 0.1, 0.91}, {0.5, 0.3, 0.12}, "gray"}
      ]
  end

  def model("shelf") do
    [{:box, {0.04, 0, 0}, {1.12, 0.45, 0.05}, "gray"}] ++
      for(z <- [0.6, 1.2, 1.8], do: {:box, {0.04, 0, z}, {1.12, 0.45, 0.04}, "gray"}) ++
      [
        {:box, {0, 0, 0}, {0.04, 0.45, 1.84}, "gray"},
        {:box, {1.16, 0, 0}, {0.04, 0.45, 1.84}, "gray"},
        {:box, {0.1, 0.05, 0.05}, {0.45, 0.35, 0.3}, "light-wood"},
        {:box, {0.6, 0.05, 0.64}, {0.45, 0.35, 0.3}, "light-wood"},
        {:box, {0.15, 0.05, 1.24}, {0.4, 0.35, 0.25}, "blue"}
      ]
  end

  def model("basket") do
    [
      {:cyl, {0.25, 0.25, 0}, 0.25, 0.4, "light-wood"},
      {:cyl, {0.25, 0.25, 0.4}, 0.2, 0.06, "linen"}
    ]
  end

  def model("boxes") do
    [
      {:box, {0, 0, 0}, {0.6, 0.5, 0.45}, "light-wood"},
      {:box, {0.65, 0.05, 0}, {0.5, 0.45, 0.4}, "light-wood"},
      {:box, {0.1, 0.05, 0.45}, {0.45, 0.4, 0.35}, "light-wood"}
    ]
  end

  def model("patio") do
    [
      {:cyl, {0.8, 0.8, 0}, 0.05, 0.7, "dark"},
      {:cyl, {0.8, 0.8, 0.7}, 0.5, 0.04, "light-wood"}
    ] ++ List.flatten([chair({0.55, 0, 0}, :back), chair({0.55, 1.15, 0}, :front)])
  end

  # A ball of leaves: a disc in the shade that always looks to the camera of
  # the house. Two smaller discs in the light are over it. A ball does not
  # go into a part under it: it is a flat disc.
  defp ball(center, r, material) do
    {ex, ey, ez} = Camera.house().eye
    n = :math.sqrt(ex * ex + ey * ey)
    u = {-ey / n, ex / n, 0.0}
    {ux, uy, _} = u
    v = {-ez * uy, ez * ux, ex * uy - ey * ux}

    at = fn du, dv ->
      Geometry.add(center, Geometry.add(Geometry.scale(u, du), Geometry.scale(v, dv)))
    end

    [
      {:face, Geometry.circle(center, u, v, r), nil, "i-#{material}-r i-face"},
      {:face, Geometry.circle(at.(-0.12 * r, 0.12 * r), u, v, 0.78 * r), nil, "i-#{material}-l"},
      {:face, Geometry.circle(at.(-0.25 * r, 0.3 * r), u, v, 0.42 * r), nil, "i-#{material}-t"}
    ]
  end

  # A box with round corners (seen from above).
  defp round_box({x, y, z}, {w, d, h}, r, material),
    do: {:prism, Shapes.rounded({x, y}, {w, d}, r), z, h, material}

  # The legs of a table: four thin boxes under a top of w by d.
  defp legs(w, d, h, material, {x, y} \\ {0, 0}) do
    for {lx, ly} <- [{0.04, 0.04}, {w - 0.09, 0.04}, {0.04, d - 0.09}, {w - 0.09, d - 0.09}] do
      {:box, {x + lx, y + ly, 0}, {0.05, 0.05, h}, material}
    end
  end

  # A chair at a corner: its seat, and its back on the side away from the
  # table.
  defp chair({x, y, z}, side) do
    back_y = if side == :back, do: y, else: y + 0.38

    legs(0.42, 0.42, 0.45, "wood", {x, y}) ++
      [
        {:box, {x, y, z + 0.45}, {0.42, 0.42, 0.05}, "wood"},
        {:box, {x, back_y, z + 0.5}, {0.42, 0.04, 0.45}, "wood"}
      ]
  end

  @doc "The names of the models (for the tests of the paint)."
  def names,
    do:
      ~w(bed nightstand dresser rug bath_mat sofa armchair coffee_table shelf_books dining plant tree bush tub toilet vanity bench shelf basket boxes patio)
end
