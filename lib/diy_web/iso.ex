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
end
