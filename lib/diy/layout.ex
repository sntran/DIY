defmodule DIY.Layout do
  @moduledoc """
  The plan of the house at scale: where each room is, and where each item
  is in its room. A length is in inches (an integer).

  - A room of the house has a `plan`: `%{x, y, w, d}`. The point `x`, `y`
    is the back corner of the room: the corner far from a person who looks
    at the picture. `w` goes along `x` (to the right), and `d` along `y`
    (to the front). All the levels use the same `x` and `y`: a room on
    floor 2 is above the room on floor 1 at the same point.
  - An item in a room of the house has `at`: `%{x, y}`, the back corner of
    the item in its room. It has `turn`: 0 to 3, a quarter turn each time.
    It has `size`: `%{w, d, h}`, or `nil` for the typical size of its kind
    (`DIY.Catalog.size/1`).
  - A zone of a van has a plan in the van. `x` goes across the van (from
    its right side), and `y` along it, from the doors at the back. The cab
    is the zone at the front of the cargo area (`van_box/1`). The roof of
    the van is a layer of its own. The shell (the insulation, the walls
    and the floor) has no plan: its items are the materials of the van,
    with no place.

  The app makes a draft of the plan (`draft/2`). The size of the house
  gives the size of its floors, and the rooms of a floor are in rows. The
  rooms outside are around the house. The garage and the driveway are 24
  by 25 feet: the longest camper van (290 inches) fits in each.
  The user then moves the rooms and the items.

  The rules (`fill/1` keeps them after each change; `specs/Plan.tla`
  checks them on a small grid):

  - Two rooms of the same layer do not overlap. A layer is a surface
    (`layer/1`): the ground (outside and floor 1), floor 2, floor 3, the
    attic and the roof. Each van has two layers: its floor and its roof.
  - A zone of a van is in the van (`van_box/1`), and the cab and the roof
    are at their places for the model. A different model, or a stored text
    that a person changed, can break this rule. Then all the zones of the
    van get the draft again (`van_draft/2`).
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
  def layer(%{level: "van:" <> _ = level, place: :van_roof}), do: level <> ":roof"
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
    case for(r <- build.rooms, r.plan, r.level != "outside", not van?(r), do: r.plan) do
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
  The size of an item in inches, `{w, d, h}`. It is the size that the
  user gave, else the typical size of its kind or of its model. Solar
  panels are an array: about 400 W for each panel.
  """
  # The watts of solar panels give their size, also when a stored build
  # gives them a size.
  def size(%{type: "solar_panels"} = item) do
    %{cols: cols, rows: rows, panel: {w, d}} = array(item)
    {cols * w, rows * d, 2}
  end

  # A camper van: the size of its model, and its space has the mirrors too
  # (7 in on each side). A size that a stored build gives has no effect.
  def size(%{type: "camper_van", params: %{"model" => model}}) do
    van = Catalog.van_size(model)
    {van.width + 14, van.length, van.height}
  end

  def size(%{size: %{w: w, d: d, h: h}}), do: {w, d, h}

  # A power station has the size of its model, when the user gave no size.
  def size(%{type: "power_station", params: %{"model" => model}}),
    do: Catalog.station_size(model)

  def size(%{type: type}), do: Catalog.size(type)

  @doc """
  The columns and the rows of an array of solar panels with a power. The
  array is near a square; the last row can have fewer panels.
  """
  def panel_grid(watts) do
    %{cols: cols, rows: rows} = array(%{params: %{"watts" => watts}})
    {cols, rows}
  end

  @doc "The watts of one solar panel."
  def panel_watts, do: @panel_watts

  @doc "The count of panels for a power: about 400 W each."
  def panels(watts), do: array(%{params: %{"watts" => watts}}).count

  @doc "The size of one solar panel on the plan, in inches: `{w, d}`."
  def panel, do: {@panel_w, @panel_d}

  @doc """
  The array of a solar panel item: the count of its panels, its columns,
  its rows, and the size of one panel (`{w, d}`, inches). The watts of one
  panel (`panel_watts`, 400 W with no number) give the count. A panel of
  more watts is longer: its side of 68 in grows with its watts. For
  example, a panel of 550 W is 45 by 94 in. The panels of the market are
  near this: a panel of 550 W is near 45 by 90 in.
  """
  def array(%{params: %{"watts" => watts} = p}) do
    one = Map.get(p, "panel_watts", @panel_watts)
    n = max(1, round(watts / one))
    cols = n |> Kernel.*(2) |> :math.sqrt() |> Float.ceil() |> trunc() |> min(n)

    %{
      count: n,
      cols: cols,
      rows: div(n + cols - 1, cols),
      panel: {@panel_w, round(@panel_d * one / @panel_watts)}
    }
  end

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

  @doc """
  The water of a pool item (`DIY.Catalog`, the kind `"pool"`) in its box
  `%{w, d}`. It is `%{x, y, w, d}` from the corner of the box, in inches. A
  coping of 2 ft goes around the water. The coping of a small pool is
  narrower: an eighth of its short side.
  """
  def water(%{w: w, d: d}) do
    c = min(24, div(min(w, d), 8))
    %{x: c, y: c, w: w - 2 * c, d: d - 2 * c}
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
  def valid_size?(%{w: w, d: d, h: h}), do: Enum.all?([w, d, h], &valid_side?/1)

  def valid_size?(_size), do: false

  @doc "True when one side of a size is whole inches, from 1 to `max_size/0`."
  def valid_side?(inches), do: is_integer(inches) and inches in 1..@max_size

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
        column(garages, yard_w, 0, {288, 300}) ++
        column(drives, yard_w, 300 * length(garages), {288, 300}) ++
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

  ## The van

  # The depth of the cab zone: the seats in front of the cargo area. A guess
  # of the app (no source): a seat and the space for the legs.
  @cab 36

  @doc "True for a zone of a van."
  def van?(%{level: level}), do: String.starts_with?(level, "van:")

  @doc """
  The box of the floor of a van, from the size of its model
  (`DIY.Catalog.van_size/1`): the cargo area, and the cab in front of it.
  """
  def van_box(van) do
    size = Catalog.van_size(van.params["model"])
    %{x: 0, y: 0, w: size.cargo_width, d: size.cargo_length + @cab}
  end

  @doc "The depth of the cab zone of a van, in inches."
  def cab, do: @cab

  @doc "True when a plan is in a box."
  def inside?(plan, box),
    do:
      plan.x >= box.x and plan.y >= box.y and plan.x + plan.w <= box.x + box.w and
        plan.y + plan.d <= box.y + box.d

  @doc """
  The draft plans of the zones of a van, in the order of the zones. From
  the doors at the back: the bed, the electrical bay, the living area and
  the galley, each across the van. The cab is at the front, and the roof
  of the van is over all of it. The shell has no plan.
  """
  def van_draft(van, zones) do
    %{w: w, d: d} = van_box(van)
    cargo = d - @cab
    bay = @min_room
    # A short van gives the bed less, so that the living area and the
    # galley keep the smallest size of a zone.
    bed = Enum.min([72, round(cargo * 0.42), cargo - bay - 2 * @min_room])
    living = div(cargo - bed - bay, 2)

    plans = %{
      bed: %{x: 0, y: 0, w: w, d: bed},
      bay: %{x: 0, y: bed, w: w, d: bay},
      living: %{x: 0, y: bed + bay, w: w, d: living},
      galley: %{x: 0, y: bed + bay + living, w: w, d: cargo - bed - bay - living},
      cab: %{x: 0, y: cargo, w: w, d: @cab},
      van_roof: %{x: 0, y: 0, w: w, d: d}
    }

    Enum.map(zones, &plans[&1.place])
  end

  ## The fill

  @doc """
  Makes the plan whole. Each room of the house has a plan, and each item
  in a room of the house has a place in its room. A room with no plan, or
  with a plan that overlaps a room before it in its layer, goes to a free
  place. An item with no place goes to a free place in its room, and an
  item out of its room comes back in. When no room of the house has a
  plan (a new house, or a build of an older version), the app makes the
  draft. The zones of a van keep their plans when the plans are good,
  else they get the draft of the van (`van_draft/2`). The shell of a van
  and its items have no plan.
  """
  def fill(%{house: nil} = build), do: build

  def fill(build) do
    house = Enum.reject(build.rooms, &van?/1)

    rooms =
      if house != [] and Enum.all?(house, &(&1.plan == nil)),
        do: drafted(build.rooms, house, build.house),
        else: placed(build)

    build = %{build | rooms: vans(rooms, build.items)}
    %{build | items: items(build)}
  end

  defp drafted(rooms, house, numbers) do
    plans = Map.new(Enum.zip(Enum.map(house, & &1.id), draft(numbers, house)))
    Enum.map(rooms, &if(van?(&1), do: &1, else: Map.put(&1, :plan, plans[&1.id])))
  end

  # The rooms of the house with a good plan keep it. Then each other room
  # of the house goes to a free place, in order.
  defp placed(build) do
    {kept, _seen} =
      Enum.map_reduce(build.rooms, [], fn room, seen ->
        cond do
          van?(room) ->
            {room, seen}

          valid_plan?(room.plan) and
              not Enum.any?(seen, &(layer(&1) == layer(room) and overlap?(&1.plan, room.plan))) ->
            {room, [room | seen]}

          true ->
            {%{room | plan: nil}, seen}
        end
      end)

    Enum.reduce(kept, kept, fn
      %{plan: nil} = room, rooms ->
        if van?(room),
          do: rooms,
          else: put_plan(rooms, room, free_plan(%{build | rooms: rooms}, room))

      _room, rooms ->
        rooms
    end)
  end

  # The zones of each van keep their plans when each plan is valid, in the
  # van, and not over a different zone of its layer. The cab and the roof
  # must be at their places for the model (a new model moves them). Else all
  # the zones get the draft again. The shell has no plan.
  defp vans(rooms, items) do
    vans = Map.new(for(i <- items, i.type == "camper_van", do: {"van:" <> i.id, i}))

    zones =
      rooms
      |> Enum.filter(&(van?(&1) and &1.place != :shell))
      |> Enum.group_by(& &1.level)

    plans =
      for {level, list} <- zones, van = vans[level], van != nil, reduce: %{} do
        plans ->
          box = van_box(van)
          draft = van_draft(van, list)

          # The cab and the roof are fixed: at their places for the model.
          fixed? =
            Enum.all?(Enum.zip(list, draft), fn {zone, plan} ->
              zone.place not in [:cab, :van_roof] or zone.plan == plan
            end)

          good =
            fixed? and Enum.all?(list, &(valid_plan?(&1.plan) and inside?(&1.plan, box))) and
              not Enum.any?(pairs(list), fn {a, b} ->
                layer(a) == layer(b) and overlap?(a.plan, b.plan)
              end)

          new = if good, do: Enum.map(list, & &1.plan), else: draft

          Enum.zip(list, new)
          |> Enum.reduce(plans, fn {z, p}, plans -> Map.put(plans, z.id, p) end)
      end

    Enum.map(rooms, &if(van?(&1), do: %{&1 | plan: Map.get(plans, &1.id)}, else: &1))
  end

  defp pairs(list) do
    for {a, i} <- Enum.with_index(list), {b, j} <- Enum.with_index(list), i < j, do: {a, b}
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
  defp items(build) do
    rooms = Map.new(build.rooms, &{&1.id, &1})

    {kept, todo} =
      Enum.map_reduce(build.items, [], fn item, todo ->
        room = rooms[item.room]

        cond do
          room == nil or room.plan == nil -> {%{item | at: nil}, todo}
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
