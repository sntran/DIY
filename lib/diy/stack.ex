defmodule DIY.Stack do
  @moduledoc """
  Items on other items (docs/design.md, "Items on items"). A microwave
  stands on a counter, a TV on a stand, a hot tub on the coping of a pool.
  An item has the key `on`: the id of the item under it, or no key (the
  floor). The owner asked for this, with a snap (October 2026).

  The rules (`specs/Stack.tla`):

  - An item is on an item of its room. The center of its space on the
    plan is over the space of the item under it.
  - No item is on itself, also through other items.
  - When an item moves, the items on it move with it. When it goes away,
    or when an item is no longer over it, the items come down to the
    floor.
  - Some kinds do not go on an item, and do not take an item on them:
    solar panels, a camper van, and an item on a wall or a ceiling
    (`DIY.Catalog.lift/1`). A pool and a car take an item, but they do not
    go on an item.

  A drop on the plan snaps (`place/5`). On an item, the item goes on its
  top, in its space. At an edge or at the center of the item under it, it
  snaps to it. On the floor, it snaps to the side of an item near it.
  """

  alias DIY.{Catalog, Layout}

  # The distance of a snap, in inches.
  @snap 6

  @doc "The id of the item under an item, or nil."
  def on(item), do: Map.get(item, :on)

  @doc "True when an item of a kind can go on an item."
  def goes_on?(%{type: type}),
    do: type not in ~w(solar_panels camper_van pool ev) and Catalog.lift(type) == 0

  @doc "True when an item of a kind can take an item on it."
  def takes?(%{type: type}),
    do: type not in ~w(solar_panels camper_van) and Catalog.lift(type) == 0

  @doc """
  The height of the bottom of each item over its floor, in inches, for the
  items on items: the top of the item under it. The top of a pool is the
  floor. An item on the floor has no height here.
  """
  @spec heights([map()]) :: %{String.t() => number()}
  def heights(items) do
    by_id = Map.new(items, &{&1.id, &1})

    for item <- items, on(item) != nil, into: %{} do
      {item.id, height(by_id, item, MapSet.new())}
    end
  end

  # The height of the bottom of an item: the top of the item under it.
  defp height(by_id, item, seen) do
    case by_id[on(item)] do
      nil ->
        0

      base ->
        if MapSet.member?(seen, base.id),
          do: 0,
          else: height(by_id, base, MapSet.put(seen, item.id)) + tall(base)
    end
  end

  # The height of the top of an item over its bottom, in inches. A pool is
  # in the floor: its coping is at the floor.
  defp tall(%{type: "pool"}), do: 0
  defp tall(item), do: elem(Layout.size(item), 2) + Catalog.lift(item.type)

  @doc """
  The items with each `on` that is right, and no other. An `on` goes away
  when the item under it is not there or is in a different room, when one
  of the two kinds cannot stack, when the item is not over it, or when the
  items make a loop.
  """
  @spec normalize([map()]) :: [map()]
  def normalize(items) do
    fixed =
      Enum.map(items, fn item ->
        if on(item) != nil and not valid?(items, item), do: Map.delete(item, :on), else: item
      end)

    if fixed == items, do: items, else: normalize(fixed)
  end

  defp valid?(items, item) do
    base = Enum.find(items, &(&1.id == on(item)))

    base != nil and base.id != item.id and base.room == item.room and goes_on?(item) and
      takes?(base) and over?(item, base) and not loop?(items, item)
  end

  # The center of the space of an item is over the space of a different
  # item.
  defp over?(%{at: %{}} = item, %{at: %{}} = base) do
    box = Layout.item_box(item)
    under = Layout.item_box(base)
    {cx, cy} = {box.x + box.w / 2, box.y + box.d / 2}
    cx >= under.x and cx <= under.x + under.w and cy >= under.y and cy <= under.y + under.d
  end

  defp over?(_item, _base), do: false

  # The items under an item make a loop back to it.
  defp loop?(items, item) do
    by_id = Map.new(items, &{&1.id, &1})

    Stream.iterate(on(item), &(by_id[&1] && on(by_id[&1])))
    |> Enum.take(length(items) + 1)
    |> Enum.member?(item.id)
  end

  @doc """
  The ids of the items on an item, and of the items on them, and so on.
  With `keep`, only the items for which `keep` is true, and the items on
  them.
  """
  @spec above([map()], String.t(), (map() -> boolean())) :: [String.t()]
  def above(items, id, keep \\ fn _item -> true end), do: above(items, keep, [id], [])

  defp above(_items, _keep, [], found), do: Enum.reverse(found)

  defp above(items, keep, [id | rest], found) do
    new = for item <- items, on(item) == id, item.id not in found, keep.(item), do: item.id
    above(items, keep, rest ++ new, Enum.reverse(new) ++ found)
  end

  @doc """
  The items after an item moved (`before` to `after`): the items on it go
  with it, to its room and by the same distance. Each stays in its room
  (`DIY.Layout.clamp/3`, with the plan of the room in `rooms`, by id). An
  item that does not fit the new room (`DIY.Catalog.fits?/2`) stays, with
  the items on it: a TV does not go outside on a pool pump.
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
  the place does not change, and the item is on the item under its center.
  """
  @spec place([map()], map(), map(), %{x: integer(), y: integer()}, boolean()) ::
          {%{x: integer(), y: integer()}, String.t() | nil}
  def place(items, item, room, at, snap) do
    moved = Map.put(%{item | room: room.id, at: at}, :on, nil)
    others = for o <- items, o.room == room.id, o.id != item.id, o.at != nil, do: o
    ids = above(items, item.id)

    base =
      if goes_on?(item),
        do:
          others
          |> Enum.filter(&(takes?(&1) and &1.id not in ids and over?(moved, &1)))
          |> Enum.max_by(&top(items, &1), fn -> nil end)

    cond do
      not snap ->
        {at, base && base.id}

      base ->
        {onto(moved, base, room.plan), base.id}

      true ->
        {beside(moved, Enum.reject(others, &(on(&1) != nil or &1.id in ids)), room.plan), nil}
    end
  end

  # The top of an item over its floor, in inches.
  defp top(items, item) do
    Map.get(heights(items), item.id, 0) + tall(item)
  end

  # An item on an item: in its space, and at an edge or at the center of
  # it when it is near. An item that is larger than the item under it is
  # at its center.
  defp onto(item, base, plan) do
    {w, d} = Layout.extent(item)
    under = Layout.item_box(base)
    x = axis(item.at.x, w, under.x, under.w)
    y = axis(item.at.y, d, under.y, under.d)
    Layout.clamp(%{x: x, y: y}, item, plan)
  end

  defp axis(_a, size, from, length) when size >= length, do: from + div(length - size, 2)

  defp axis(a, size, from, length) do
    a = a |> max(from) |> min(from + length - size)
    center = from + div(length - size, 2)

    Enum.find([from, from + length - size, center], a, &(abs(a - &1) <= @snap))
  end

  # An item on the floor: flush with the side of an item near it, when the
  # gap is a snap or less and the two are side by side.
  defp beside(item, others, plan) do
    box = Layout.item_box(item)

    {dx, dy} =
      Enum.reduce(others, {nil, nil}, fn other, {dx, dy} ->
        o = Layout.item_box(other)
        side_y = box.y < o.y + o.d and o.y < box.y + box.d
        side_x = box.x < o.x + o.w and o.x < box.x + box.w

        dx =
          dx ||
            if side_y do
              Enum.find([o.x + o.w - box.x, o.x - (box.x + box.w)], &(abs(&1) <= @snap))
            end

        dy =
          dy ||
            if side_x do
              Enum.find([o.y + o.d - box.y, o.y - (box.y + box.d)], &(abs(&1) <= @snap))
            end

        {dx, dy}
      end)

    Layout.clamp(%{x: box.x + (dx || 0), y: box.y + (dy || 0)}, item, plan)
  end
end
