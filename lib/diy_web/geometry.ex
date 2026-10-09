defmodule DIYWeb.Geometry do
  @moduledoc """
  The math of the world of the pictures, in meters: points, boxes,
  rectangles and circles. `DIYWeb.Camera` takes them to the SVG.

  The world has three axes: `x`, `y`, and `z` (up). A house has its back
  at y = 0 and its front at the largest y. A van has its back at y = 0 and
  its cab at the largest y. Its right side (the side of the sliding door)
  is at x = 0, and its left side (the side of the driver) is at the
  largest x. The front of an item looks to y.
  """

  @type point :: {number(), number(), number()}

  @doc """
  The three faces of a box that a camera can show (`DIYWeb.Camera`):
  `:top`, `:front` (at `y + d`) and `:side` (at `x + w`). Each is a list of
  four corners.
  """
  def box({x, y, z}, {w, d, h}) do
    %{
      top: [{x, y, z + h}, {x + w, y, z + h}, {x + w, y + d, z + h}, {x, y + d, z + h}],
      front: [{x, y + d, z}, {x + w, y + d, z}, {x + w, y + d, z + h}, {x, y + d, z + h}],
      side: [{x + w, y, z}, {x + w, y + d, z}, {x + w, y + d, z + h}, {x + w, y, z + h}]
    }
  end

  @doc """
  A box with a top that slopes: its height goes from `h0` to `h1` along an
  axis (`:x` or `:y`). It has the faces of `box/2`. A wall that is cut on
  a slope is such a box.
  """
  def wedge({x, y, z}, {w, d}, {h0, h1}, :y) do
    %{
      top: [{x, y, z + h0}, {x + w, y, z + h0}, {x + w, y + d, z + h1}, {x, y + d, z + h1}],
      front: [{x, y + d, z}, {x + w, y + d, z}, {x + w, y + d, z + h1}, {x, y + d, z + h1}],
      side: [{x + w, y, z}, {x + w, y + d, z}, {x + w, y + d, z + h1}, {x + w, y, z + h0}]
    }
  end

  def wedge({x, y, z}, {w, d}, {h0, h1}, :x) do
    %{
      top: [{x, y, z + h0}, {x + w, y, z + h1}, {x + w, y + d, z + h1}, {x, y + d, z + h0}],
      front: [{x, y + d, z}, {x + w, y + d, z}, {x + w, y + d, z + h1}, {x, y + d, z + h0}],
      side: [{x + w, y, z}, {x + w, y + d, z}, {x + w, y + d, z + h1}, {x + w, y, z + h1}]
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

  @doc "The dot product of two vectors."
  def dot({a, b, c}, {x, y, z}), do: a * x + b * y + c * z
end
