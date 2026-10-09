defmodule DIY.Layout do
  @moduledoc """
  The plan of the house at scale: where each room is, and where each item
  is in its room. A length is in inches (an integer).

  - A room of the house has a `plan`: `%{x, y, w, d}`. The point `x`, `y`
    is the back corner of the room: the corner far from a person who looks
    at the picture. `w` goes along `x` (to the right and to the front), and
    `d` along `y` (to the left and to the front). All the levels use the
    same `x` and `y`: a room on floor 2 is above the room on floor 1 at the
    same point.
  - An item in a room of the house has `at`: `%{x, y}`, the back corner of
    the item in its room. It has `turn`: 0 to 3, a quarter turn each time.
    It has `size`: `%{w, d, h}`, or `nil` for the typical size of its kind
    (`DIY.Catalog.size/1`).
  - A zone of a van and an item in a van have no plan and no `at` (`nil`).

  The app makes a draft of the plan (`draft/2`). The size of the house
  gives the size of its floors, and the rooms of a floor are in rows. The
  rooms outside are around the house. The garage is 24 by 24 feet, and the
  driveway is 24 by 25 feet: a camper van (274 inches long) fits in each.
  The user then moves the rooms and the items.

  The rules (`fill/1` keeps them after each change; `specs/Plan.tla`
  checks them on a small grid):

  - Two rooms of the same layer do not overlap. A layer is a surface: the
    ground (outside and floor 1), floor 2, floor 3, the attic and the roof
    (`layer/1`).
  - An item is in its room: `0 <= x <= w(room) - w(item)`, and the same
    for `y`. An item that is larger than its room is at 0. It goes
    through the walls of the room, and the picture can paint a wall over
    it.
  """

  alias DIY.Catalog

  # The smallest and the largest side of a room, the largest size of an
  # item, and the largest distance from the origin, in inches.
  @min_room 24
  @max_room 2_400
  @max_size 1_200
  @max_at 12_000

  # The size of one solar panel (on its side, the long side down the
  # roof), and its watts. It is a module of 108 half cells, 1134 by 1722
  # mm, of 400 W: for example STAR-400W-M54H-M10 (Greentech Renewables).
  @panel_w 45
  @panel_d 68
  @panel_watts 400

  @doc "The smallest side of a room, in inches."
  def min_room, do: @min_room

  @doc "The largest side of a room, in inches."
  def max_room, do: @max_room

  @doc "The largest side of an item, in inches."
  def max_size, do: @max_size

  @doc "The largest distance of a room from the origin, in inches."
  def max_at, do: @max_at

  @doc """
  The layer of a room: the rooms of a layer are on the same surface, and
  they do not overlap.
  """
  def layer(%{level: level}) when level in ["outside", "f1"], do: "ground"
  def layer(%{level: "roof", place: :roof}), do: "roof"
  def layer(%{level: "roof"}), do: "attic"
  def layer(%{level: level}), do: level

  @doc """
  The floor of a house of a size, before the user changes it: `{w, d}`. It
  is a rectangle of 3 by 2 with the area of one floor.
  """
  def footprint(%{size: size, floors: floors}) do
    area = size * 144 / floors
    w = round6(:math.sqrt(area * 1.5))
    {w, round6(area / w)}
  end

  @doc """
  The box of the house: the box of the rooms of the floors, of the attic
  and of the roof. With no such room, the draft floor at the origin.
  """
  def house_box(build) do
    case for(r <- build.rooms, r.plan, r.level != "outside", do: r.plan) do
      [] ->
        {w, d} = footprint(build.house)
        %{x: 0, y: 0, w: w, d: d}

      plans ->
        box(plans)
    end
  end

  @doc "The box around plans: `%{x, y, w, d}`."
  def box(plans) do
    {x0, x1} = plans |> Enum.flat_map(&[&1.x, &1.x + &1.w]) |> Enum.min_max()
    {y0, y1} = plans |> Enum.flat_map(&[&1.y, &1.y + &1.d]) |> Enum.min_max()
    %{x: x0, y: y0, w: x1 - x0, d: y1 - y0}
  end

  @doc "True when two boxes overlap (a common side is not an overlap)."
  def overlap?(a, b),
    do: a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.d and b.y < a.y + a.d

  @doc """
  The size of an item in inches, `{w, d, h}`: the size that the user gave,
  else the typical size of its kind. Solar panels are an array: about 400 W
  for each panel.
  """
  def size(%{size: %{w: w, d: d, h: h}}), do: {w, d, h}

  def size(%{type: "solar_panels", params: %{"watts" => watts}}) do
    {cols, rows} = panel_grid(watts)
    {cols * @panel_w, rows * @panel_d, 2}
  end

  def size(%{type: type}), do: Catalog.size(type)

  @doc """
  The columns and the rows of an array of solar panels with a power. The
  array is near a square; the last row can have fewer panels.
  """
  def panel_grid(watts) do
    n = panels(watts)
    cols = n |> Kernel.*(2) |> :math.sqrt() |> Float.ceil() |> trunc() |> min(n)
    {cols, div(n + cols - 1, cols)}
  end

  @doc "The count of panels for a power: about 400 W each."
  def panels(watts), do: max(1, round(watts / @panel_watts))

  @doc "The size of one solar panel on the plan, in inches: `{w, d}`."
  def panel, do: {@panel_w, @panel_d}

  @doc "The space of an item on its floor, after its turn: `{w, d}`."
  def extent(item) do
    {w, d, _h} = size(item)
    if rem(item.turn, 2) == 0, do: {w, d}, else: {d, w}
  end

  @doc "The box of an item in its room: `%{x, y, w, d}`."
  def item_box(%{at: %{x: x, y: y}} = item) do
    {w, d} = extent(item)
    %{x: x, y: y, w: w, d: d}
  end

  @doc "A place in a room that keeps the item in the room (`at`)."
  def clamp(%{x: x, y: y}, item, %{w: rw, d: rd}) do
    {w, d} = extent(item)
    %{x: x |> min(rw - w) |> max(0), y: y |> min(rd - d) |> max(0)}
  end

  @doc """
  True for a valid plan of a room: integers, with sides from `min_room/0`
  to `max_room/0` and a corner at most `max_at/0` from the origin.
  """
  def valid_plan?(%{x: x, y: y, w: w, d: d})
      when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(d),
      do:
        abs(x) <= @max_at and abs(y) <= @max_at and w in @min_room..@max_room and
          d in @min_room..@max_room

  def valid_plan?(_plan), do: false

  @doc "True for a valid size of an item: integers from 1 to `max_size/0`."
  def valid_size?(%{w: w, d: d, h: h}),
    do: Enum.all?([w, d, h], &(is_integer(&1) and &1 in 1..@max_size))

  def valid_size?(_size), do: false

  @doc "True when a plan of a room does not overlap a different room of its layer."
  def free?(build, room, plan) do
    not Enum.any?(build.rooms, fn other ->
      other.id != room.id and other.plan != nil and layer(other) == layer(room) and
        overlap?(other.plan, plan)
    end)
  end

  ## The draft

  @doc """
  The draft plans of the rooms of a house, in the order of the rooms. The
  rooms of a floor (and of the attic, and of the roof) fill the floor of
  the house in rows. Outside, a garage is on the right of the house. A
  driveway is in front of the garage, and a yard is in front of the house.
  """
  def draft(house, rooms) do
    {w, d} = footprint(house)
    indexed = Enum.with_index(rooms)
    groups = Enum.group_by(indexed, fn {room, _i} -> group(room) end)

    # The house is large enough for each row of rooms.
    {w, d} =
      for {{:strips, _layer}, list} <- groups, reduce: {w, d} do
        {w, d} ->
          {rows, per} = rows(length(list))
          {max(w, 90 * per), max(d, 90 * rows)}
      end

    garages = Map.get(groups, :garage, [])
    drives = Map.get(groups, :drive, [])
    yards = Map.get(groups, :yard, [])
    {yard_rows, yard_per} = rows(length(yards))
    # The yard is as wide as the house, or wider for many yards; the garage
    # and the driveway are on the right of both.
    yard_w = max(w, 90 * yard_per)

    plans =
      Enum.flat_map(groups, fn
        {{:strips, _layer}, list} -> strips(list, {0, 0, w, d})
        _other -> []
      end) ++
        column(garages, yard_w, 0, {288, 288}) ++
        column(drives, yard_w, 288 * length(garages), {288, 300}) ++
        strips(yards, {0, d, yard_w, max(300, 90 * yard_rows)})

    by_index = Map.new(plans)
    Enum.map(indexed, fn {_room, i} -> Map.fetch!(by_index, i) end)
  end

  # The group of a room in the draft.
  defp group(%{level: "outside", place: :outdoor, name: name}) do
    if String.contains?(String.downcase(name), "drive"), do: :drive, else: :yard
  end

  defp group(%{level: "outside"}), do: :garage
  defp group(room), do: {:strips, layer(room)}

  # The rows of n rooms, and the most rooms in a row.
  defp rows(0), do: {1, 1}

  defp rows(n) do
    rows = n |> Kernel./(3) |> :math.sqrt() |> Float.ceil() |> trunc()
    {rows, div(n + rows - 1, rows)}
  end

  # Rooms in a column, from a corner, each of one size.
  defp column(list, x, y, {w, d}) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {{_room, i}, k} -> {i, %{x: x, y: y + k * d, w: w, d: d}} end)
  end

  # The rooms fill a rectangle in rows. A large room (a living room) gets
  # more space than a small room (a bathroom).
  defp strips([], _rect), do: []

  defp strips(list, {x, y, w, d}) do
    {_rows, per} = rows(length(list))
    chunks = Enum.chunk_every(list, per)

    depths =
      split(d, Enum.map(chunks, fn chunk -> chunk |> Enum.map(&weight/1) |> Enum.sum() end))

    for {chunk, {dy, depth}} <- Enum.zip(chunks, depths),
        {{_room, i}, {dx, width}} <- Enum.zip(chunk, split(w, Enum.map(chunk, &weight/1))),
        do: {i, %{x: x + dx, y: y + dy, w: width, d: depth}}
  end

  # A length in parts by weight, in steps of 6 inches: {offset, length}.
  # A part goes down to a step, and the last part takes the rest: so no
  # part is much smaller than its share.
  defp split(total, weights) do
    sum = Enum.sum(weights)

    {parts, used} =
      Enum.map_reduce(Enum.drop(weights, -1), 0, fn weight, used ->
        part = floor6(total * weight / sum)
        {{used, part}, used + part}
      end)

    parts ++ [{used, total - used}]
  end

  @weights [
    {~w(living family great), 3},
    {~w(bath laundry closet utility hall pantry toilet mud), 1}
  ]

  defp weight({%{name: name}, _i}) do
    name = String.downcase(name)

    Enum.find_value(@weights, 2, fn {words, weight} ->
      if Enum.any?(words, &String.contains?(name, &1)), do: weight
    end)
  end

  defp round6(n), do: round(n / 6) * 6
  defp floor6(n), do: trunc(n / 6) * 6

  ## The fill

  @doc """
  Makes the plan whole. Each room of the house has a plan, and each item
  in a room of the house has a place in its room. A room with no plan, or
  with a plan that overlaps a room before it in its layer, goes to a free
  place. An item with no place goes to a free place in its room, and an
  item out of its room comes back in. When no room of the house has a
  plan (a new house, or a build of an older version), the app makes the
  draft. A zone of a van and an item in a van have no plan.
  """
  def fill(%{house: nil} = build), do: build

  def fill(build) do
    van? = fn room -> String.starts_with?(room.level, "van:") end
    house = Enum.reject(build.rooms, van?)

    rooms =
      if house != [] and Enum.all?(house, &(&1.plan == nil)),
        do: drafted(build.rooms, house, build.house),
        else: placed(build, van?)

    build = %{build | rooms: rooms}
    %{build | items: items(build, van?)}
  end

  defp drafted(rooms, house, numbers) do
    plans = Map.new(Enum.zip(Enum.map(house, & &1.id), draft(numbers, house)))
    Enum.map(rooms, &Map.put(&1, :plan, plans[&1.id]))
  end

  # The rooms with a good plan keep it. Then each other room of the house
  # goes to a free place, in order.
  defp placed(build, van?) do
    {kept, _seen} =
      Enum.map_reduce(build.rooms, [], fn room, seen ->
        good =
          not van?.(room) and valid_plan?(room.plan) and
            not Enum.any?(seen, &(layer(&1) == layer(room) and overlap?(&1.plan, room.plan)))

        if good, do: {room, [room | seen]}, else: {%{room | plan: nil}, seen}
      end)

    Enum.reduce(kept, kept, fn
      %{plan: nil} = room, rooms ->
        if van?.(room),
          do: rooms,
          else: put_plan(rooms, room, free_plan(%{build | rooms: rooms}, room))

      _room, rooms ->
        rooms
    end)
  end

  defp put_plan(rooms, room, plan),
    do: Enum.map(rooms, &if(&1.id == room.id, do: %{&1 | plan: plan}, else: &1))

  # A free place for a new room. A room of a floor goes in the house where
  # no room is, else at the back of the house. A room outside goes next to
  # the rooms of its layer, on their right (also when no place is free).
  defp free_plan(build, room) do
    {w, d} = new_size(room, build)
    others = for r <- build.rooms, r.plan, layer(r) == layer(room), do: r.plan
    house = house_box(build)

    inside =
      if room.level != "outside" do
        step = max(12, round6(max(house.w, house.d) / 40))

        Enum.find_value(
          for(
            y <- range(house.y, house.y + house.d - d, step),
            x <- range(house.x, house.x + house.w - w, step),
            do: {x, y}
          ),
          fn {x, y} ->
            plan = %{x: x, y: y, w: w, d: d}
            if not Enum.any?(others, &overlap?(&1, plan)), do: plan
          end
        )
      end

    inside || back(room, others, house, w, d) || beside(others, house, w, d)
  end

  # A free place for a new room of a floor at the back of the house (y less
  # than the house), row by row. So the room is next to the house, not past
  # the garage or the yard.
  defp back(%{level: "outside"}, _others, _house, _w, _d), do: nil

  defp back(_room, others, house, w, d) do
    step = max(12, round6(house.w / 40))

    Enum.find_value(1..20, fn row ->
      Enum.find_value(range(house.x, house.x + max(house.w - w, 0), step), fn x ->
        plan = %{x: x, y: house.y - row * d, w: w, d: d}
        if not Enum.any?(others, &overlap?(&1, plan)), do: plan
      end)
    end)
  end

  defp beside([], house, w, d), do: %{x: house.x + house.w, y: house.y, w: w, d: d}

  defp beside(others, _house, w, d) do
    box = box(others)
    %{x: box.x + box.w, y: box.y, w: w, d: d}
  end

  # The size of a new room: a roof covers the house; a room outside is
  # larger than a room inside.
  defp new_size(%{place: :roof, level: "roof"}, build) do
    case for(r <- build.rooms, r.plan, layer(r) == "roof", do: r) do
      [] -> build |> house_box() |> then(&{&1.w, &1.d})
      _roofs -> {144, 144}
    end
  end

  defp new_size(%{place: :outdoor}, _build), do: {240, 240}
  defp new_size(_room, _build), do: {144, 144}

  # The points from a to b in steps (none when b < a).
  defp range(a, b, _step) when b < a, do: []
  defp range(a, b, step), do: a..b//step

  # The items: an item in the house has a place in its room. The items with
  # a place come first: an item with no place goes where no item is.
  defp items(build, van?) do
    rooms = Map.new(build.rooms, &{&1.id, &1})

    {kept, todo} =
      Enum.map_reduce(build.items, [], fn item, todo ->
        room = rooms[item.room]

        cond do
          room == nil or van?.(room) -> {%{item | at: nil}, todo}
          item.at == nil -> {item, [item.id | todo]}
          true -> {%{item | at: clamp(item.at, item, room.plan)}, todo}
        end
      end)

    todo = MapSet.new(todo)

    Enum.reduce(kept, kept, fn item, items ->
      if MapSet.member?(todo, item.id) do
        room = rooms[item.room]
        others = for o <- items, o.room == room.id, o.at != nil, do: item_box(o)
        at = free_at(item, room.plan, others)
        Enum.map(items, &if(&1.id == item.id, do: %{&1 | at: at}, else: &1))
      else
        items
      end
    end)
  end

  @doc """
  A free place for an item in a room, where it does not overlap the boxes
  of the other items. It is the first place from the back corner, row by
  row. With no free place, it is the back corner.
  """
  def free_at(item, room, others) do
    {w, d} = extent(item)
    step = max(6, round6(max(room.w, room.d) / 60))

    Enum.find_value(
      for(y <- range(0, room.d - d, step), x <- range(0, room.w - w, step), do: {x, y}),
      %{x: 0, y: 0},
      fn {x, y} ->
        box = %{x: x, y: y, w: w, d: d}
        if not Enum.any?(others, &overlap?(&1, box)), do: %{x: x, y: y}
      end
    )
  end
end
