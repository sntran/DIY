defmodule DIYWeb.Decor do
  @moduledoc """
  The furniture of a room on the plan (`DIYWeb.Cutaway`). For example, a
  bedroom has a bed, and a kitchen has counters. The furniture
  is for the eyes only, as in a drawn picture of a house. It uses
  no power, it is not an item, and a tap goes through it to the floor of
  the room.

  The name of a room gives its furniture (`plan/2`). Each piece has its
  place in the room: against the back wall, in the middle, or at the
  front. In a kitchen, counters fill the back wall between the items. A
  piece does not show when it is larger than the room, or when it touches
  an item or a piece before it. A piece also does not show when it hides
  an item on the screen (`hides?/3`). This is also true for an item of a
  different room of the layer. So the items show. The stairs are a part of
  the house: they always show, also when they hide an item of a different
  room. A rug is flat: the other
  pieces and the items can stand on it, and it hides nothing.

  The models use the parts of `DIYWeb.Icon.Shapes`, in meters, with round
  corners where the real piece has them. The front of a model looks to y.
  """

  alias DIY.{Catalog, Layout}
  alias DIYWeb.{Camera, Geometry}
  alias DIYWeb.Icon.Shapes

  @m 0.0254
  # The space between a piece and a wall, or an item (inches).
  @gap 4
  # The space between a piece in a yard and the edge of the yard (inches).
  # The walls and the slab of the house go out of the house.
  @yard_gap 8
  # The most steps of stairs, and the depth of a step (inches).
  @steps 13
  @step 11
  # The depth of a kitchen counter (inches), and its least length.
  @counter 25
  @least 18
  # A piece does not show when it hides more than this part of an item.
  @hide 0.25

  @doc """
  The pieces of a room: `{model, x, y, turn}`. `x` and `y` are the back
  corner of the piece on the plan of the room (inches). The turn is 0 (the
  front of the piece looks to the front of the room) or 2 (to the back).
  `items` are the items of the room. `around` are the items of the other
  rooms of the layer, on the plan of this room (`boxes/2`).
  """
  def pieces(room, items, around \\ []) do
    boxes = boxes(items, {0, 0})
    gap = if room.place == :outdoor, do: @yard_gap, else: @gap
    around = if stairs?(room), do: [], else: around

    room
    |> plan(boxes)
    |> Enum.reduce({[], []}, fn {model, anchor, turn}, {done, placed} ->
      {w, d} = footprint(model, turn)
      high = height(model)

      with {x, y} <- place(anchor, {w, d}, room.plan, gap),
           box = %{x: x, y: y, w: w, d: d},
           true <- high < 0.02 or free?(box, high, boxes ++ around, placed) do
        {[{model, x, y, turn} | done], if(high < 0.02, do: placed, else: [box | placed])}
      else
        _ -> {done, placed}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  The boxes of items on the plan of a room, for `pieces/3`. `{dx, dy}` is
  the corner of the room of the items on the plan of that room (inches).
  `dz` is the height of its floor over the floor of that room (meters).
  A box has the height of the bottom and of the top of its item (`low`
  and `high`, meters).
  """
  def boxes(items, {dx, dy}, dz \\ 0.0) do
    for item <- items do
      box = Layout.item_box(item)
      {_w, _d, h} = Layout.size(item)
      low = Catalog.lift(item.type) * @m + dz
      %{box | x: box.x + dx, y: box.y + dy} |> Map.merge(%{low: low, high: low + h * @m})
    end
  end

  # True when a piece (its box, and its height in meters) touches no piece
  # before it, and no item under its top (on the plan). It also does not
  # hide an item on the screen.
  defp free?(box, high, boxes, placed) do
    near = grow(box)

    not Enum.any?(placed, &Layout.overlap?(near, &1)) and
      not Enum.any?(
        boxes,
        &((&1.low < high and Layout.overlap?(near, &1)) or hides?(box, high, &1))
      )
  end

  @doc """
  True when a piece hides more than a quarter of an item at the middle of
  the height of the item. The piece has its box on the plan, and its
  height (meters). The camera of the house
  looks down to the back and to the left. So a piece hides the floor
  behind it and at its left: its shadow. The shadow of the middle of the
  item is a hexagon. The part of the box of the item in it is the part
  that the piece hides.
  """
  def hides?(%{x: x0, y: y0, w: w, d: d}, high, item) do
    {ex, ey, ez} = Camera.house().eye
    rise = high - (item.low + item.high) / 2

    if rise <= 0 or item.w * item.d == 0 do
      false
    else
      {vx, vy} = {-rise * ex / ez / @m, -rise * ey / ez / @m}
      {x1, y1} = {x0 + w, y0 + d}

      shadow = [
        {x0 + vx, y0 + vy},
        {x1 + vx, y0 + vy},
        {x1, y0},
        {x1, y1},
        {x0, y1},
        {x0 + vx, y1 + vy}
      ]

      part =
        shadow
        |> clip(fn {px, _} -> px - item.x end)
        |> clip(fn {px, _} -> item.x + item.w - px end)
        |> clip(fn {_, py} -> py - item.y end)
        |> clip(fn {_, py} -> item.y + item.d - py end)
        |> area()

      part > @hide * item.w * item.d
    end
  end

  # The part of a convex polygon where `inside` is 0 or more (one step of
  # the clip of Sutherland and Hodgman).
  defp clip([], _inside), do: []

  defp clip(points, inside) do
    points
    |> Enum.zip(tl(points) ++ [hd(points)])
    |> Enum.flat_map(fn {{px, py} = p, {qx, qy} = q} ->
      {a, b} = {inside.(p), inside.(q)}
      cut = fn -> {px + (qx - px) * a / (a - b), py + (qy - py) * a / (a - b)} end

      cond do
        a >= 0 and b >= 0 -> [q]
        a >= 0 -> [cut.()]
        b >= 0 -> [cut.(), q]
        true -> []
      end
    end)
  end

  # The area of a polygon (the formula of the shoelace).
  defp area(points) when length(points) < 3, do: 0.0

  defp area(points) do
    points
    |> Enum.zip(tl(points) ++ [hd(points)])
    |> Enum.map(fn {{ax, ay}, {bx, by}} -> ax * by - bx * ay end)
    |> Enum.sum()
    |> abs()
    |> Kernel./(2)
  end

  # The pieces of a room, from its name: a model, its place, and its turn.
  # A yard has a round table with chairs, and one big tree. The tree is at
  # the left, away from the house: at the front of a front yard, and at the
  # back of a different yard. A side yard has no furniture.
  defp plan(%{place: :outdoor, name: name}, _boxes) do
    name = String.downcase(name)
    tree = if String.contains?(name, "front"), do: :front_left, else: :back_left

    if String.contains?(name, "yard") and not String.contains?(name, "side"),
      do: [{model("round_table"), :center, 0}, {model("tree"), tree, 0}],
      else: []
  end

  # A room inside. It has no plant: plants hide the plan. A hall and a
  # closet have no furniture: the way stays open, also in the closet of a
  # bedroom. A name with the word "stairs" gives the stairs first, also
  # with the word "hall".
  defp plan(%{place: :indoor, name: name} = room, boxes) do
    name = String.downcase(name)

    cond do
      # The word "stair" or "stairs" (not "upstairs"). On floor 1, the
      # stairs go up to the back of the room: as many steps as the room
      # has space for. On an upper floor, the room has the opening of the
      # stairs, with a rail.
      stairs?(room) and room.level == "f1" ->
        stairs(room)

      stairs?(room) ->
        [{model("stair_well"), :front_center, 0}]

      String.contains?(name, "hall") or String.contains?(name, "closet") ->
        []

      String.contains?(name, "bed") ->
        [
          {model("rug"), :center, 0},
          {model("bed"), :back_center, 0},
          {model("nightstand"), :beside_left, 0},
          {model("nightstand"), :beside_right, 0},
          {model("dresser"), :left_center, 0}
        ]

      String.contains?(name, "living") ->
        [
          {model("rug"), :center, 0},
          {model("sofa"), :front_center, 2},
          {model("coffee_table"), :center, 0},
          {model("armchair"), :left_center, 0},
          {model("shelf_books"), :back_right, 0}
        ]

      # A kitchen has counters. A table with chairs is in the dining room,
      # and a small round table is in the breakfast room.
      String.contains?(name, "kitchen") and String.contains?(name, "dining") ->
        counters(room, boxes) ++ [{model("dining"), :front_center, 0}]

      String.contains?(name, "kitchen") ->
        counters(room, boxes)

      String.contains?(name, "dining") ->
        [{model("dining"), :center, 0}]

      String.contains?(name, "breakfast") ->
        [{model("round_table"), :center, 0}]

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
        []
    end
  end

  defp plan(_room, _boxes), do: []

  # True when the name of a room has the word "stair" or "stairs" (not
  # "upstairs").
  defp stairs?(%{place: :indoor, name: name}),
    do: Regex.match?(~r/\bstairs?\b/, String.downcase(name))

  defp stairs?(_room), do: false

  # The stairs of a room: 13 steps at most, each 11 inches deep, in the
  # depth of the room. A room with space for less than 4 steps has none.
  defp stairs(room) do
    steps = min(@steps, div(room.plan.d - 2 * @gap, @step))
    if steps >= 4, do: [{model({"stairs", steps}), :back_right, 0}], else: []
  end

  # The counters of a kitchen fill the back wall where no item is. They
  # stop 4 inches from the left wall and from the right wall. An item
  # on the wall over the counters (a meter) does not cut them. A part
  # shorter than 18 inches stays empty.
  defp counters(room, boxes) do
    band = %{x: 0, y: 0, w: room.plan.w, d: 1 + @counter + @gap}

    cuts =
      for box <- boxes,
          box.low < 0.9,
          Layout.overlap?(box, band),
          do: {box.x - @gap, box.x + box.w + @gap}

    {@gap, room.plan.w - @gap}
    |> free(Enum.sort(cuts))
    |> Enum.filter(fn {a, b} -> b - a >= @least end)
    |> Enum.map(fn {a, b} -> {model({"counter", b - a}), {:at, a, 1}, 0} end)
  end

  # The parts of a length of the wall that no cut covers. Each cut starts in
  # the length (the cuts are of the items on the back wall).
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
  defp place({:at, x, y}, {w, d}, %{w: rw, d: rd}, _gap),
    do: if(x < 0 or y < 0 or x + w > rw or y + d > rd, do: nil, else: {round(x), round(y)})

  defp place(anchor, {w, d}, %{w: rw, d: rd}, gap) do
    if w + 2 * gap > rw or d + 2 * gap > rd do
      nil
    else
      {cx, cy} = {(rw - w) / 2, (rd - d) / 2}
      {left, right, back, front} = {gap, rw - w - gap, gap, rd - d - gap}

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

      if x < gap or x + w > rw - gap, do: nil, else: {round(x), round(y)}
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

  # The height of a model (meters). A rug or a mat is flat: under 2 cm.
  defp height(model) do
    {{_, _, z0}, {_, _, z1}} = Shapes.bounds(model)
    z1 - z0
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
      for(z <- [0.18, 0.42, 0.66], do: {:box, {0.45, 0.45, z}, {0.1, 0.01, 0.02}, "wood"})
  end

  # Stairs of a number of steps, each 18.5 cm up and 11 inches deep. With
  # 13 steps, they go up to the top of the walls of floor 1 (2.4 m). The
  # top step is at the back. The side at the right is a panel on the slope
  # of the steps.
  def model({"stairs", steps}) do
    run = @step * @m
    depth = steps * run

    for(
      i <- 0..(steps - 1),
      do: {:box, {0, i * run, 0}, {0.9, run, (steps - i) * 0.185}, "light-wood"}
    ) ++
      [
        {:face, [{0.9, 0, 0}, {0.9, depth, 0}, {0.9, depth, 0.185}, {0.9, 0, steps * 0.185}], nil,
         "i-wood-r i-face"}
      ]
  end

  # The opening of the stairs on an upper floor: a dark well. Two posts
  # stand at its front corners, with a rail over them.
  def model("stair_well") do
    [
      {:face, [{0, 0, 0.01}, {0.9, 0, 0.01}, {0.9, 1.2, 0.01}, {0, 1.2, 0.01}], nil,
       "i-dark-t i-face"},
      {:box, {0, 1.16, 0}, {0.04, 0.04, 0.9}, "wood"},
      {:box, {0.86, 1.16, 0}, {0.04, 0.04, 0.9}, "wood"},
      {:box, {0, 1.16, 0.9}, {0.9, 0.04, 0.04}, "wood"}
    ]
  end

  def model("rug"), do: [mat({2.0, 1.5}, 0.15)]
  def model("bath_mat"), do: [mat({0.8, 0.5}, 0.1)]

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

  # A big tree: about 4 meters high, with a crown 2.4 meters wide.
  def model("tree") do
    [{:cyl, {1.2, 1.2, 0}, 0.14, 2.0, "wood"}] ++
      ball({1.2, 1.2, 2.6}, 1.2, "leaf") ++
      ball({0.85, 1.2, 3.4}, 0.75, "leaf") ++ ball({1.55, 1.3, 3.3}, 0.7, "leaf")
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

  # A small round table with two chairs.
  def model("round_table") do
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
    do: {:prism, soft({x, y}, {w, d}, r), z, h, material}

  # A rug or a mat: only its top, flat on the floor.
  defp mat({w, d}, r),
    do: {:face, for({u, v} <- soft({0, 0}, {w, d}, r), do: {u, v, 0.01}), nil, "i-rug-t i-face"}

  # The loop of a box with round corners, as `DIYWeb.Icon.Shapes.rounded/3`,
  # but with 3 points at each corner. A piece of furniture is small on the
  # screen, and it has many parts.
  # Where two corners meet (a side with no length), they share one point.
  defp soft({u, v}, {du, dv}, r) do
    r = min(r, min(du, dv) / 2)

    loop =
      for {cu, cv, from} <- [
            {u + du - r, v + r, -90},
            {u + du - r, v + dv - r, 0},
            {u + r, v + dv - r, 90},
            {u + r, v + r, 180}
          ],
          k <- 0..2,
          a = (from + k * 45) * :math.pi() / 180,
          do: {cu + r * :math.cos(a), cv + r * :math.sin(a)}

    key = fn {pu, pv} -> {Float.round(pu / 1, 9), Float.round(pv / 1, 9)} end
    loop = Enum.dedup_by(loop, key)
    if key.(hd(loop)) == key.(List.last(loop)), do: Enum.drop(loop, -1), else: loop
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
