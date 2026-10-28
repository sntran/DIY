defmodule DIY.Roof do
  @moduledoc """
  The shape of a roof: a room on the level of the roof (`place: :roof`).
  A house can have many roofs, each over a part of the house (the owner,
  October 2026). The shape of a roof is in its `roof` field:

  - `slope`: the way that the roof slopes.
    - `"x"`: two slopes, with the ridge along x (from the left to the
      right) at the middle of the depth. The gable ends are at the left and
      at the right. This is the first shape of the app.
    - `"y"`: two slopes, with the ridge along y (from the back to the
      front). The gable ends are at the back and at the front.
    - `"front"`, `"back"`, `"left"` or `"right"`: one slope, with its low
      side at that side of the room.
  - `pitch`: the rise of the roof for 12 inches of run, from 1 to 12.
  - `base`: the floor with the walls that hold the eaves (`"f1"`, `"f2"`,
    and on). With no base, the eaves are on the top floor.

  A roof with no `roof` field has the first shape: `"x"`, 5 in 12, on the
  top floor. All the numbers of the plan are in inches.
  """

  @slopes ~w(x y front back left right)
  @pitch 5

  @doc "The ways that a roof slopes, in the order of the choices."
  def slopes, do: @slopes

  @doc "The shape of a roof: `%{slope, pitch, base}`, with the first shape as the default."
  def shape(room) do
    roof = Map.get(room, :roof) || %{}

    %{
      slope: Map.get(roof, :slope, "x"),
      pitch: Map.get(roof, :pitch, @pitch),
      base: Map.get(roof, :base)
    }
  end

  @doc """
  Reads the shape of a roof from a map with text keys (a file or a form).
  The base must be a floor of the house (`floors`). It gives `{:ok,
  shape}` or `:error`.
  """
  def read(%{"slope" => slope, "pitch" => pitch} = roof, floors)
      when slope in @slopes and is_integer(pitch) and pitch in 1..12 do
    case Map.get(roof, "base") do
      nil ->
        {:ok, %{slope: slope, pitch: pitch, base: nil}}

      "f" <> n = base ->
        if n in Enum.map(1..floors//1, &Integer.to_string/1),
          do: {:ok, %{slope: slope, pitch: pitch, base: base}},
          else: :error

      _other ->
        :error
    end
  end

  def read(_roof, _floors), do: :error

  @doc "The height of the top of a roof over its eaves."
  def rise(room) do
    %{slope: slope, pitch: pitch} = shape(room)
    %{w: w, d: d} = room.plan

    run =
      case slope do
        "x" -> d / 2
        "y" -> w / 2
        side when side in ["front", "back"] -> d
        _side -> w
      end

    run * pitch / 12
  end

  @doc """
  The height of a roof over its eaves at a point of the plan `{x, y}`.
  Past the walls, the slope goes on: the eaves go lower than 0.
  """
  def height(room, {x, y}) do
    %{slope: slope, pitch: pitch} = shape(room)
    %{x: x0, y: y0, w: w, d: d} = room.plan
    k = pitch / 12

    case slope do
      "x" -> k * (d / 2 - abs(y - (y0 + d / 2)))
      "y" -> k * (w / 2 - abs(x - (x0 + w / 2)))
      "front" -> k * (y0 + d - y)
      "back" -> k * (y - y0)
      "left" -> k * (x - x0)
      "right" -> k * (x0 + w - x)
    end
  end

  @doc """
  The ridge of a roof: `{:y, y}` for two slopes along x, `{:x, x}` for two
  slopes along y, or nil for one slope.
  """
  def ridge(room) do
    %{x: x, y: y, w: w, d: d} = room.plan

    case shape(room).slope do
      "x" -> {:y, y + d / 2}
      "y" -> {:x, x + w / 2}
      _one -> nil
    end
  end

  @doc """
  The planes of a roof over a box of the plan (`%{x, y, w, d}`, the room or
  a larger box for the eaves). Each plane is its corners `{x, y}` and the
  side that it looks to (`:front`, `:back`, `:left` or `:right`).
  """
  def planes(room, %{x: x, y: y, w: w, d: d}) do
    {x1, y1} = {x + w, y + d}

    case {ridge(room), shape(room).slope} do
      {{:y, r}, _} ->
        [
          {[{x, y}, {x1, y}, {x1, r}, {x, r}], :back},
          {[{x, r}, {x1, r}, {x1, y1}, {x, y1}], :front}
        ]

      {{:x, r}, _} ->
        [
          {[{x, y}, {r, y}, {r, y1}, {x, y1}], :left},
          {[{r, y}, {x1, y}, {x1, y1}, {r, y1}], :right}
        ]

      {nil, side} ->
        [{[{x, y}, {x1, y}, {x1, y1}, {x, y1}], String.to_existing_atom(side)}]
    end
  end

  @doc """
  The plane of a roof at a point of the plan `{x, y}`: the side that it
  looks to (`:front`, `:back`, `:left` or `:right`). At the ridge, it is
  the front or the right plane.
  """
  def side(room, {x, y}) do
    case {ridge(room), shape(room).slope} do
      {{:y, r}, _} -> if y < r, do: :back, else: :front
      {{:x, r}, _} -> if x < r, do: :left, else: :right
      {nil, side} -> String.to_existing_atom(side)
    end
  end

  @doc """
  The normal of the plane of a roof that looks to a side: a vector `{x, y,
  z}` that goes up from the plane. The front is along y, the right is
  along x.
  """
  def normal(room, side) do
    k = shape(room).pitch / 12

    case side do
      :front -> {0.0, k, 1.0}
      :back -> {0.0, -k, 1.0}
      :left -> {-k, 0.0, 1.0}
      :right -> {k, 0.0, 1.0}
    end
  end

  @doc """
  The top of a wall of the house under the roof, at a side of a box of the
  plan (`:front`, `:back`, `:left` or `:right`). It is the points `{x, y}`
  along that side, each with the height of the roof over it, from one end
  to the other. The ridge is a point when it crosses the side. A height is
  0 at least: the wall under the eaves has no height.
  """
  def profile(room, side, %{x: x, y: y, w: w, d: d}) do
    ends =
      case side do
        :front -> [{x, y + d}, {x + w, y + d}]
        :back -> [{x, y}, {x + w, y}]
        :left -> [{x, y}, {x, y + d}]
        :right -> [{x + w, y}, {x + w, y + d}]
      end

    [{ax, ay}, {bx, by}] = ends

    middle =
      case ridge(room) do
        {:x, r} when side in [:front, :back] and r > ax and r < bx -> [{r, ay}]
        {:y, r} when side in [:left, :right] and r > ay and r < by -> [{ax, r}]
        _none -> []
      end

    for point <- [{ax, ay}] ++ middle ++ [{bx, by}], do: {point, max(height(room, point), 0)}
  end
end
