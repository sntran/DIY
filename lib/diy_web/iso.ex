defmodule DIYWeb.Iso do
  @moduledoc """
  The isometric math of the pictures (`DIYWeb.Scene`): a point of the world
  goes to a point of the SVG.

  The world has three axes, in meters: `x` goes to the right and to the
  front, `y` goes to the left and to the front, and `z` goes up. A point
  goes to the SVG as in the games: 1 meter of `x` or of `y` is `@w` pixels
  to the side and half of that down, and 1 meter of `z` is `@h` pixels up.

  A picture has its origin: the point of the SVG for the point 0, 0, 0 of
  the world.
  """

  # The pixels of 1 meter: to the side for x and y (cos 30°), down for x and
  # y (sin 30°), and up for z.
  @w 8.66
  @d 5.0
  @h 10.0

  @type point :: {number(), number(), number()}

  @doc "The SVG point of a point of the world, from an origin."
  def at({ox, oy}, {x, y, z}), do: {ox + (x - y) * @w, oy + (x + y) * @d - z * @h}

  @doc "The SVG `points` of a polygon: one decimal for each number."
  def points(origin, corners) do
    Enum.map_join(corners, " ", fn corner ->
      {sx, sy} = at(origin, corner)
      "#{round1(sx)},#{round1(sy)}"
    end)
  end

  @doc "A number with one decimal, as a string with no zero after the point."
  def round1(n) do
    n = Float.round(n / 1, 1)
    if n == trunc(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n)
  end

  @doc """
  The three faces of a box that show: `:top`, `:left` (the face to the
  front and to the left, at `y + d`) and `:right` (the face to the front
  and to the right, at `x + w`). Each is a list of four corners.
  """
  def box({x, y, z}, {w, d, h}) do
    %{
      top: [{x, y, z + h}, {x + w, y, z + h}, {x + w, y + d, z + h}, {x, y + d, z + h}],
      left: [{x, y + d, z}, {x + w, y + d, z}, {x + w, y + d, z + h}, {x, y + d, z + h}],
      right: [{x + w, y, z}, {x + w, y + d, z}, {x + w, y + d, z + h}, {x + w, y, z + h}]
    }
  end

  @doc """
  A rectangle on a plane: the corner `a`, and the sides `u` and `v` (two
  vectors of the plane). `from` and `size` are in parts of `u` and of `v`.
  """
  def on_plane(a, u, v, {s, t}, {sw, th}) do
    for {i, j} <- [{s, t}, {s + sw, t}, {s + sw, t + th}, {s, t + th}],
        do: add(a, add(scale(u, i), scale(v, j)))
  end

  @doc """
  A circle on a plane: the center, two vectors of the plane with a length
  of 1, the radius, and the number of sides.
  """
  def circle(center, u, v, r, sides \\ 16) do
    for k <- 0..(sides - 1) do
      t = 2 * :math.pi() * k / sides
      add(center, add(scale(u, r * :math.cos(t)), scale(v, r * :math.sin(t))))
    end
  end

  @doc "The sum of two vectors."
  def add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}

  @doc "A vector times a number."
  def scale({x, y, z}, k), do: {x * k, y * k, z * k}

  ## The order of the paint

  @doc """
  Objects in the order of the paint, from the back to the front. They are
  the walls and the items of a plan (`DIYWeb.Cutaway`), or the parts of a
  model (`DIYWeb.Icon.Shapes`). An object has an `id`, a `box` in the world
  (`{x0, y0, z0, x1, y1, z1}`), a `key`, `loose`, and its `polys`
  (`{corners, class}`).

  Where two objects cover the same part of the screen, the one at the
  back comes first. Its box is on the far side of the other box along x,
  y or z. The other box is not on the far side of it. Else the one
  with the smaller key (x + y of its center) comes first. A loose object
  comes by its key only: it is an item that is larger than its room, and
  it goes through walls. Three boxes can each be behind the next one (a
  cycle). Then the box with the fewest boxes before it comes first.
  """
  def order(objects) do
    screens = Map.new(objects, &{&1.id, screen(&1.polys)})

    after_ =
      Map.new(objects, fn a ->
        {a.id,
         for(
           b <- objects,
           b.id != a.id,
           not a.loose and not b.loose,
           cover?(screens[a.id], screens[b.id]),
           behind?(a.box, b.box) and not behind?(b.box, a.box),
           do: b.id
         )}
      end)

    # The count of the objects before each object.
    count = after_ |> Map.values() |> List.flatten() |> Enum.frequencies()
    paint(Enum.sort_by(objects, &{&1.key, &1.id}), count, after_, [])
  end

  # Kahn: the next object is the first one (by key) with no object before
  # it. With none (a cycle), the one with the fewest objects before it.
  defp paint([], _count, _after, done), do: Enum.reverse(done)

  defp paint(todo, count, after_, done) do
    next =
      Enum.find(todo, &(Map.get(count, &1.id, 0) == 0)) ||
        Enum.min_by(todo, &Map.get(count, &1.id, 0))

    count = Enum.reduce(after_[next.id], count, &Map.update!(&2, &1, fn n -> n - 1 end))
    paint(List.delete(todo, next), count, after_, [next | done])
  end

  defp behind?({_, _, _, ax1, ay1, az1}, {bx0, by0, bz0, _, _, _}),
    do: ax1 <= bx0 + 1.0e-6 or ay1 <= by0 + 1.0e-6 or az1 <= bz0 + 1.0e-6

  defp screen(polys) do
    {xs, ys} =
      polys |> Enum.flat_map(&elem(&1, 0)) |> Enum.map(&at({0, 0}, &1)) |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp cover?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01
end
