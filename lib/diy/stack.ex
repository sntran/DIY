defmodule DIY.Stack do
  @moduledoc """
  Items on other items (docs/design.md, "Items on items"). A dryer stands
  on a washer, a power station on a freezer, a pool pump on the coping of
  a pool. An item has the key `on`: the id of the item under it, or no key
  (the floor). The owner asked for this, with a snap (October 2026).

  The rules (`specs/Stack.tla`):

  - An item is on an item of its room. The center of its space on the
    plan is over the item under it. The item is not larger than the item
    under it, along each side of the plan. On a pool, the center is over
    the coping, not over the water (`DIY.Layout.water/1`).
  - No item is on itself, also through other items.
  - An item is not on the floor in an item that can take it: it is on
    that item.
  - When an item moves, the items on it move with it. When it goes away,
    the items on it come down. When an item no longer holds an item, that
    item comes down. An item that comes down goes on the item under it,
    or on the floor.
  - Some kinds do not go on an item, and do not take an item on them.
    These are solar panels, a camper van, a car, and an item on a wall or
    a ceiling (`DIY.Catalog.lift/1`). A pool takes an item, but it does
    not go on an item.
  - The items of the roof and of a van do not stack.

  A drop on the plan snaps (`place/5`). On an item, the item goes on its
  top, in its space. Near an end or the center of the item under it, it
  goes to that end or to the center. On the floor, it goes to the side of
  an item near it.
  """

  alias DIY.{Catalog, Layout}

  # The distance of a snap, in inches.
  @snap 6

  @doc "The id of the item under an item, or nil."
  def on(item), do: Map.get(item, :on)

  @doc "True when an item of a kind can go on an item."
  def goes_on?(%{type: type}),
    do: type not in ~w(solar_panels camper_van ev pool) and Catalog.lift(type) == 0

  @doc "True when an item of a kind can take an item on it."
  def takes?(%{type: type}),
    do: type not in ~w(solar_panels camper_van ev) and Catalog.lift(type) == 0

  @doc "True when the items of a room can stack: not on the roof, not in a van."
  def stacks?(%{place: place, level: level}),
    do: place != :roof and not String.starts_with?(level, "van:")

  def stacks?(nil), do: false

  @doc """
  The height of the bottom of each item over its floor, in inches, for the
  items on items: the top of the item under it. The top of a pool is the
  floor. An item on the floor has no height here.
  """
  @spec heights([map()]) :: %{String.t() => number()}
  def heights(items) do
    by_id = Map.new(items, &{&1.id, &1})
    memo = Enum.reduce(items, %{}, &elem(height(by_id, &1.id, &2, MapSet.new()), 1))
    for item <- items, on(item) != nil, into: %{}, do: {item.id, memo[item.id]}
  end

  # The height of the bottom of an item: the top of the item under it. The
  # memo keeps each height. In a loop, the item under it is at 0.
  defp height(by_id, id, memo, seen) do
    case memo do
      %{^id => h} ->
        {h, memo}

      _none ->
        base = by_id[on(by_id[id])]

        {h, memo} =
          if base == nil or MapSet.member?(seen, base.id) do
            {0, memo}
          else
            {h, memo} = height(by_id, base.id, memo, MapSet.put(seen, id))
            {h + tall(base), memo}
          end

        {h, Map.put(memo, id, h)}
    end
  end

  # The height of the top of an item over its bottom, in inches. A pool is
  # in the floor: its coping is at the floor.
  defp tall(%{type: "pool"}), do: 0
  defp tall(item), do: elem(Layout.size(item), 2) + Catalog.lift(item.type)

  @doc """
  The items with the rules of a stack, for the rooms in `rooms` (by id).
  First, an `on` that breaks a rule goes away. For example, the item under
  it is not there, or is in a different room. Or it does not hold the
  item (`holds?/2`), or the items make a loop. Then each item on the
  floor goes on the highest item under it that holds it, if there is one.
  """
  @spec normalize([map()], %{String.t() => map()}) :: [map()]
  def normalize(items, rooms), do: items |> drop(rooms) |> seat(rooms)

  defp drop(items, rooms) do
    by_id = Map.new(items, &{&1.id, &1})

    fixed =
      Enum.map(items, fn item ->
        if on(item) != nil and not valid?(by_id, rooms, item),
          do: Map.delete(item, :on),
          else: item
      end)

    if fixed == items, do: items, else: drop(fixed, rooms)
  end

  defp valid?(by_id, rooms, item) do
    base = by_id[on(item)]

    base != nil and base.id != item.id and base.room == item.room and
      stacks?(rooms[item.room]) and goes_on?(item) and takes?(base) and holds?(base, item) and
      not on_it?(by_id, item.id, item.id, map_size(by_id))
  end

  # The last item of the list is the newest: it goes on an older item
  # first. The tops of the items are those before the seat: they only
  # choose between two items that hold the item.
  defp seat(items, rooms) do
    takers = takers(items)

    by_id =
      items
      |> Enum.reverse()
      |> Enum.reduce(Map.new(items, &{&1.id, &1}), fn %{id: id}, by_id ->
        item = by_id[id]

        with nil <- on(item),
             true <- item.at != nil and goes_on?(item) and stacks?(rooms[item.room]),
             %{} = base <- base(by_id, item, takers) do
          Map.put(by_id, id, Map.put(item, :on, base.id))
        else
          _no -> by_id
        end
      end)

    Enum.map(items, &by_id[&1.id])
  end

  # The items that can take an item, by room, each with its box and its
  # top over the floor (inches). The places and the tops are those before
  # a seat. The places do not change. The tops only choose between two
  # items that hold an item.
  defp takers(items) do
    heights = heights(items)

    for(i <- items, i.at != nil and takes?(i), do: i)
    |> Enum.map(&{&1, Layout.item_box(&1), Map.get(heights, &1.id, 0) + tall(&1)})
    |> Enum.group_by(fn {i, _box, _top} -> i.room end)
  end

  # The highest item in the room of an item that holds it, and that is
  # not on it. The items are by id.
  defp base(items, item, takers) do
    box = Layout.item_box(item)

    holders =
      for {base, under, top} <- Map.get(takers, item.room, []),
          base.id != item.id and holds_box?(base.type, under, box),
          do: {base, top}

    holders
    |> Enum.sort_by(fn {_base, top} -> top end, :desc)
    |> Enum.find_value(fn {base, _top} ->
      if not on_it?(items, base.id, item.id, map_size(items)), do: base
    end)
  end

  # The item with the id `top` is on the item with the id `id`, also
  # through other items (`by_id` has the items). The walk stops after `n`
  # steps: so a loop ends.
  defp on_it?(_by_id, _top, _id, 0), do: false

  defp on_it?(by_id, top, id, n) do
    case by_id[top] && on(by_id[top]) do
      nil -> false
      ^id -> true
      under -> on_it?(by_id, under, id, n - 1)
    end
  end

  @doc """
  True when an item can stand on a different item at their places. The
  center of its space is over that item. It is not larger than that item
  along each side. On a pool, the center is over the coping.
  """
  def holds?(%{at: %{}} = base, %{at: %{}} = item),
    do: holds_box?(base.type, Layout.item_box(base), Layout.item_box(item))

  def holds?(_base, _item), do: false

  defp holds_box?(type, under, box) do
    center = {box.x + box.w / 2, box.y + box.d / 2}

    box.w <= under.w and box.d <= under.d and inside?(center, under) and
      not (type == "pool" and water?(center, under))
  end

  defp inside?({x, y}, box),
    do: x >= box.x and x <= box.x + box.w and y >= box.y and y <= box.y + box.d

  defp water?({x, y}, box) do
    water = Layout.water(box)

    x > box.x + water.x and x < box.x + water.x + water.w and y > box.y + water.y and
      y < box.y + water.y + water.d
  end

  @doc """
  The ids of the items on an item, and of the items on them, and so on.
  With `keep`, only the items for which `keep` is true, and the items on
  them.
  """
  @spec above([map()], String.t(), (map() -> boolean())) :: [String.t()]
  def above(items, id, keep \\ fn _item -> true end) do
    children = Enum.group_by(Enum.filter(items, keep), &on/1)
    above(children, [id], MapSet.new([id]), [])
  end

  defp above(_children, [], _seen, found), do: Enum.reverse(found)

  defp above(children, [id | rest], seen, found) do
    new = for item <- Map.get(children, id, []), not MapSet.member?(seen, item.id), do: item.id
    seen = Enum.reduce(new, seen, &MapSet.put(&2, &1))
    above(children, rest ++ new, seen, Enum.reverse(new) ++ found)
  end

  @doc """
  The items when an item moves from its old place (`before`) to its new
  place (`moved`). The items on it go with it, to its room and by the
  same distance. Each stays in its room (`DIY.Layout.clamp/3`, with the
  plan of the room in `rooms`, by id). Some items do not fit the new room
  (`DIY.Catalog.fits?/2`). Such an item stays, with the items on it. A TV
  does not go outside on a pool pump.
  """
  @spec carry([map()], map(), map(), %{String.t() => map()}) :: [map()]
  def carry(items, %{at: %{} = from} = before, %{at: %{} = to} = moved, rooms) do
    room = rooms[moved.room]
    ids = above(items, before.id, &Catalog.fits?(Catalog.kind(&1.type), room))
    {dx, dy} = {to.x - from.x, to.y - from.y}

    Enum.map(items, fn item ->
      cond do
        item.id == moved.id ->
          moved

        item.id in ids and item.at != nil ->
          at = %{x: item.at.x + dx, y: item.at.y + dy}
          at = if room.plan, do: Layout.clamp(at, item, room.plan), else: at
          %{item | room: moved.room, at: at}

        true ->
          item
      end
    end)
  end

  def carry(items, _before, moved, _rooms),
    do: Enum.map(items, &if(&1.id == moved.id, do: moved, else: &1))

  @doc """
  The place of an item that the person drops in a room (`at`, its back
  corner), with a snap: `{at, on}`. With `snap` false (the arrow keys),
  the place does not change, and the item is on the item that holds it
  there.
  """
  @spec place([map()], map(), map(), %{x: integer(), y: integer()}, boolean()) ::
          {%{x: integer(), y: integer()}, String.t() | nil}
  def place(items, item, room, at, snap) do
    moved = Map.delete(%{item | room: room.id, at: at}, :on)
    others = Enum.reject(items, &(&1.id == item.id))

    base =
      if goes_on?(item) and stacks?(room),
        do: base(Map.new(others, &{&1.id, &1}), moved, takers([moved | others]))

    cond do
      not snap ->
        {at, base && base.id}

      base ->
        {onto(moved, base, room.plan), base.id}

      true ->
        ids = above(items, item.id)

        floor =
          for o <- others,
              o.room == room.id and o.at != nil and on(o) == nil and o.id not in ids and
                Catalog.lift(o.type) == 0,
              do: o

        {beside(moved, floor, room.plan), nil}
    end
  end

  # An item on an item: in its space, and at an end or at the center of it
  # when it is near. On a pool, it stays where it is: the center of a pool
  # is water.
  defp onto(item, %{type: "pool"}, _plan), do: item.at

  defp onto(item, base, plan) do
    {w, d} = Layout.extent(item)
    under = Layout.item_box(base)
    x = axis(item.at.x, w, under.x, under.w)
    y = axis(item.at.y, d, under.y, under.d)
    Layout.clamp(%{x: x, y: y}, item, plan)
  end

  defp axis(a, size, from, length) do
    a = a |> max(from) |> min(from + length - size)
    center = from + div(length - size, 2)

    Enum.find([from, from + length - size, center], a, &(abs(a - &1) <= @snap))
  end

  # An item on the floor: next to the side of an item on the floor near
  # it, with no gap, when the gap is a snap or less and the two are side
  # by side. An item on a wall or a ceiling does not snap.
  defp beside(item, others, plan) do
    box = Layout.item_box(item)

    {dx, dy} =
      if Catalog.lift(item.type) > 0,
        do: {nil, nil},
        else: Enum.reduce(others, {nil, nil}, &gap(box, Layout.item_box(&1), &2))

    Layout.clamp(%{x: box.x + (dx || 0), y: box.y + (dy || 0)}, item, plan)
  end

  defp gap(box, o, {dx, dy}) do
    side_y = box.y < o.y + o.d and o.y < box.y + box.d
    side_x = box.x < o.x + o.w and o.x < box.x + box.w

    dx =
      dx ||
        if side_y,
          do: Enum.find([o.x + o.w - box.x, o.x - (box.x + box.w)], &(abs(&1) <= @snap))

    dy =
      dy ||
        if side_x,
          do: Enum.find([o.y + o.d - box.y, o.y - (box.y + box.d)], &(abs(&1) <= @snap))

    {dx, dy}
  end
end
