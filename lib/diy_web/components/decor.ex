defmodule DIYWeb.Decor do
  @moduledoc """
  The furniture of a room on the plan (`DIYWeb.Cutaway`): a bed in a
  bedroom, a sofa in a living room, a table in a kitchen. The furniture is
  for the eyes only. It uses no power, it is not an item, and a tap goes
  through it to the floor of the room.

  The name of a room gives its furniture. Each piece has its place in the
  room (against the back wall, in the middle, at the front). A piece that
  touches an item, or a piece before it, or that is larger than the room,
  does not show. So the items always show.

  The models use the parts of `DIYWeb.Icon.Shapes`, in meters. The front
  of a model looks to y.
  """

  alias DIY.Layout
  alias DIYWeb.Icon.Shapes

  @m 0.0254
  # The space between a piece and a wall, or an item (inches).
  @gap 4

  @doc """
  The pieces of a room: `{model, x, y, turn}`, with `x` and `y` the back
  corner of the piece on the plan of the room (inches).
  """
  def pieces(room, items) do
    # An item on the ceiling (a fan) leaves the floor under it free.
    taken = for item <- items, DIY.Catalog.lift(item.type) < 60, do: Layout.item_box(item)

    room
    |> plan()
    |> Enum.reduce({[], taken}, fn {name, anchor, turn}, {done, taken} ->
      model = model(name)
      {w, d} = footprint(model, turn)

      # A rug is flat: the other pieces and the items stand on it.
      flat? = name == "rug"

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

  # The pieces of a room, from its name: the name of a model, its place,
  # and its turn (0: it looks to the front; 2: to the back).
  defp plan(%{place: :outdoor, name: name}) do
    if String.contains?(String.downcase(name), "yard"),
      do: [{"patio", :center, 0}, {"plant", :back_left, 0}, {"plant", :back_right, 0}],
      else: []
  end

  defp plan(%{place: :indoor, name: name}) do
    name = String.downcase(name)

    cond do
      String.contains?(name, "bed") ->
        [
          {"rug", :center, 0},
          {"bed", :back_center, 0},
          {"nightstand", :back_left_of_center, 0},
          {"nightstand", :back_right_of_center, 0},
          {"plant", :front_left, 0}
        ]

      String.contains?(name, "living") ->
        [
          {"rug", :center, 0},
          {"sofa", :front_center, 2},
          {"coffee_table", :center, 0},
          {"armchair", :left_center, 0},
          {"plant", :back_left, 0},
          {"plant", :front_right, 0}
        ]

      String.contains?(name, "kitchen") ->
        [{"dining", :front_center, 0}, {"plant", :front_left, 0}]

      String.contains?(name, "bath") ->
        [{"tub", :back_left, 0}, {"toilet", :back_right, 0}, {"vanity", :front_right, 2}]

      String.contains?(name, "garage") ->
        [{"bench", :back_right, 0}, {"shelf", :back_left, 0}]

      String.contains?(name, "laundry") ->
        [{"shelf", :back_right, 0}]

      String.contains?(name, "attic") ->
        [{"boxes", :back_left, 0}, {"boxes", :back_right, 0}]

      true ->
        []
    end
  end

  defp plan(_room), do: []

  # The place of a piece in a room (inches), or nil when it does not fit.
  defp place(anchor, {w, d}, %{w: rw, d: rd}) do
    if w + 2 * @gap > rw or d + 2 * @gap > rd do
      nil
    else
      {cx, cy} = {(rw - w) / 2, (rd - d) / 2}
      {left, right, back, front} = {@gap, rw - w - @gap, @gap, rd - d - @gap}

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
        :back_left_of_center -> {rw / 2 - 36 - w, back}
        :back_right_of_center -> {rw / 2 + 36, back}
      end
      |> then(fn {x, y} -> if x < 0 or x + w > rw, do: nil, else: {round(x), round(y)} end)
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

  ## The models (meters)

  @doc "The model of a piece of furniture."
  def model("bed") do
    [
      {:box, {0, 0, 0}, {1.6, 0.08, 1.0}, "wood"},
      {:box, {0, 0.08, 0}, {1.6, 2.0, 0.3}, "wood"},
      {:box, {0.05, 0.1, 0.3}, {1.5, 1.95, 0.2}, "linen"},
      {:box, {0.2, 0.18, 0.5}, {0.5, 0.32, 0.12}, "white"},
      {:box, {0.9, 0.18, 0.5}, {0.5, 0.32, 0.12}, "white"},
      {:box, {0.02, 0.8, 0.5}, {1.56, 1.27, 0.08}, "sage"}
    ]
  end

  def model("nightstand") do
    [
      {:box, {0, 0, 0}, {0.45, 0.4, 0.55}, "wood"},
      {:cyl, {0.22, 0.2, 0.55}, 0.03, 0.25, "dark"},
      {:cyl, {0.22, 0.2, 0.75}, 0.12, 0.18, "shade"}
    ]
  end

  def model("rug"), do: [{:box, {0, 0, 0}, {2.0, 1.5, 0.012}, "rug"}]

  def model("sofa") do
    [
      {:box, {0, 0, 0}, {2.1, 0.9, 0.42}, "sage"},
      {:box, {0, 0, 0.42}, {0.2, 0.9, 0.22}, "sage"},
      {:box, {1.9, 0, 0.42}, {0.2, 0.9, 0.22}, "sage"},
      {:box, {0.2, 0, 0.42}, {1.7, 0.25, 0.42}, "sage"},
      {:box, {0.25, 0.27, 0.42}, {0.8, 0.6, 0.1}, "linen"},
      {:box, {1.05, 0.27, 0.42}, {0.8, 0.6, 0.1}, "linen"}
    ]
  end

  def model("armchair") do
    [
      {:box, {0, 0, 0}, {0.85, 0.85, 0.4}, "rug"},
      {:box, {0, 0, 0.4}, {0.85, 0.2, 0.45}, "rug"},
      {:box, {0, 0.2, 0.4}, {0.15, 0.65, 0.2}, "rug"},
      {:box, {0.7, 0.2, 0.4}, {0.15, 0.65, 0.2}, "rug"}
    ]
  end

  def model("coffee_table") do
    legs(1.0, 0.55, 0.36, "wood") ++ [{:box, {0, 0, 0.36}, {1.0, 0.55, 0.05}, "wood"}]
  end

  def model("dining") do
    chairs =
      for x <- [0.35, 1.05], y <- [0, 1.25] do
        chair({x, y, 0}, if(y == 0, do: :back, else: :front))
      end

    [{:group, legs(1.4, 0.8, 0.72, "wood", {0.15, 0.4})}] ++
      List.flatten(chairs) ++ [{:box, {0.15, 0.4, 0.72}, {1.4, 0.8, 0.05}, "wood"}]
  end

  def model("plant") do
    [
      {:cyl, {0.2, 0.2, 0}, 0.14, 0.3, "clay"},
      {:cyl, {0.2, 0.2, 0.3}, 0.2, 0.25, "leaf"},
      {:cyl, {0.2, 0.2, 0.55}, 0.15, 0.2, "leaf"},
      {:cyl, {0.2, 0.2, 0.75}, 0.08, 0.15, "leaf"}
    ]
  end

  def model("tub") do
    [
      {:box, {0, 0, 0}, {1.6, 0.75, 0.55}, "white"},
      {:box, {0.08, 0.08, 0.55}, {1.44, 0.59, 0.005}, "blue"}
    ]
  end

  def model("toilet") do
    [
      {:box, {0.05, 0, 0}, {0.4, 0.18, 0.8}, "white"},
      {:cyl, {0.25, 0.4, 0}, 0.2, 0.42, "white"}
    ]
  end

  def model("vanity") do
    [
      {:box, {0, 0, 0}, {0.8, 0.5, 0.82}, "wood"},
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
    [{:box, {0, 0, 0}, {1.2, 0.45, 0.05}, "gray"}] ++
      for z <- [0.6, 1.2, 1.8] do
        {:box, {0, 0, z}, {1.2, 0.45, 0.04}, "gray"}
      end ++
      [
        {:box, {0, 0, 0}, {0.04, 0.45, 1.84}, "gray"},
        {:box, {1.16, 0, 0}, {0.04, 0.45, 1.84}, "gray"},
        {:box, {0.1, 0.05, 0.05}, {0.45, 0.35, 0.3}, "light-wood"},
        {:box, {0.6, 0.05, 0.64}, {0.45, 0.35, 0.3}, "light-wood"},
        {:box, {0.15, 0.05, 1.24}, {0.4, 0.35, 0.25}, "blue"}
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
    ] ++
      List.flatten([chair({0.55, 0, 0}, :back), chair({0.55, 1.15, 0}, :front)])
  end

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
end
