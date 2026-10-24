defmodule DIYWeb.Camera do
  @moduledoc """
  The camera of a picture: a point of the world (`DIYWeb.Geometry`, in
  meters) goes to a point of the SVG. The camera is far away and has no
  vanishing point, so each part of a picture keeps its scale.

  The camera has its turn around `z` (`yaw`) and the angle that it looks
  down at (`pitch`). Two cameras draw the pictures of the app:

  - `house/0`: a dollhouse with no front wall. The camera is in front of
    the house (at the large y) and to its right (a yaw of 60°). It looks
    down at 34°, as in a picture that an artist drew of a house. The house
    goes along the screen, and its floors go down the screen. An item
    shows its front, and its right side.
  - `van/0`: a van with no wall on its left side. The camera is at the
    left side of the van (the side of the driver, at the large x). It is
    a little to the front of the van (to the cab). The cab is at the left
    of the screen, and the doors at the back are at the right.

  The eye is at the large x, the large y and the large z of the world, for
  the two cameras. So a box shows its top, its front (at `y + d`) and its
  side (at `x + w`). The face that looks more to the camera is in the
  light (the class `l`), and the other is in the shade (`r`).

  A picture has its origin: the SVG point of the point 0, 0, 0 of the
  world.
  """

  import DIYWeb.Geometry, only: [dot: 2]

  # The SVG units of 1 meter.
  @scale 12.25

  defstruct [:name, :yaw, :pitch, :right, :down, :eye, :ground, :lit]

  @doc "The camera of the house: a dollhouse, seen from the front."
  def house, do: new(:house, 60, 34)

  @doc "The camera of a van: seen from its left side."
  def van, do: new(:van, 18, 28)

  @doc """
  A camera from its yaw and its pitch, in degrees. At a yaw of 90, the
  camera looks along y; at a yaw of 0, along x. The yaw and the pitch are
  more than 0 and less than 90.
  """
  def new(name, yaw, pitch) when yaw > 0 and yaw < 90 and pitch > 0 and pitch < 90 do
    {a, b} = {yaw * :math.pi() / 180, pitch * :math.pi() / 180}
    {sa, ca, sb, cb} = {:math.sin(a), :math.cos(a), :math.sin(b), :math.cos(b)}
    {ex, ey} = {ca * cb, sa * cb}

    %__MODULE__{
      name: name,
      yaw: yaw,
      pitch: pitch,
      # The SVG x of 1 meter along x and along y (z does not move it).
      right: {@scale * sa, -@scale * ca},
      # The SVG y of 1 meter along x, y and z.
      down: {@scale * ca * sb, @scale * sa * sb, -@scale * cb},
      # The direction to the eye, and its part on the ground.
      eye: {ex, ey, sb},
      ground: {ca, sa},
      # The face of a box that looks more to the camera.
      lit: if(ey >= ex, do: :front, else: :side)
    }
  end

  @doc "The SVG point of a point of the world, from an origin."
  def at(%__MODULE__{right: {rx, ry}, down: {dx, dy, dz}}, {ox, oy}, {x, y, z}),
    do: {ox + rx * x + ry * y, oy + dx * x + dy * y + dz * z}

  @doc "The SVG `points` of a polygon: one decimal for each number."
  def points(camera, origin, corners) do
    Enum.map_join(corners, " ", fn corner ->
      {sx, sy} = at(camera, origin, corner)
      "#{round1(sx)},#{round1(sy)}"
    end)
  end

  @doc """
  The SVG `points` of a polygon of the plan. A small polygon (a side of
  its box under 1 unit) gets two decimals, so that its shape stays at the
  highest zoom. One step of one decimal is near 8 mm of the house. Each
  other polygon gets one decimal.
  """
  def plan_points(camera, origin, corners) do
    points = Enum.map(corners, &at(camera, origin, &1))
    {xs, ys} = Enum.unzip(points)
    {x0, x1} = Enum.min_max(xs)
    {y0, y1} = Enum.min_max(ys)
    round = if x1 - x0 < 1 or y1 - y0 < 1, do: &round2/1, else: &round1/1
    Enum.map_join(points, " ", fn {sx, sy} -> "#{round.(sx)},#{round.(sy)}" end)
  end

  @doc "A number with one decimal, as a string with no zero after the point."
  def round1(n), do: rounded(n, 1)

  @doc "A number with two decimals, as a string with no zero at the end."
  def round2(n), do: rounded(n, 2)

  defp rounded(n, decimals) do
    n = Float.round(n / 1, decimals)
    if n == trunc(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n)
  end

  @doc """
  The axis of the plan that goes most to the eye. It is `:y` for the house
  (the camera is in front of it), and `:x` for a van (the camera is at its
  side).
  """
  def depth_axis(%__MODULE__{lit: :front}), do: :y
  def depth_axis(%__MODULE__{lit: :side}), do: :x

  @doc "How near a point is to the eye: a larger number is nearer."
  def depth(camera, point), do: dot(camera.eye, point)

  @doc "True when a face with a normal looks to the eye."
  def shows?(camera, normal), do: dot(camera.eye, normal) > 1.0e-9

  @doc """
  The light of a face with a normal: `t` (a top), `l`, `m1`, `m2`, `m3` or
  `r`. `l` is the face that looks to the side in the light of the camera.
  This side is the front for the house, and the side for a van. `r` is
  the face in the shade. The three steps between them are for a face that
  looks between the two: a part of a round shape.
  """
  def light(camera, {x, y, z}) do
    if z >= max(x, y), do: "t", else: side_light(camera, x, y)
  end

  # The part of the normal on the ground that goes to the side in the
  # light (from -1 to 1).
  defp side_light(camera, x, y) do
    length = :math.sqrt(x * x + y * y)
    part = if camera.lit == :front, do: y, else: x
    step(if length < 1.0e-9, do: -1.0, else: part / length)
  end

  defp step(part) when part >= 0.92, do: "l"
  defp step(part) when part >= 0.7, do: "m1"
  defp step(part) when part >= 0.45, do: "m2"
  defp step(part) when part >= 0.2, do: "m3"
  defp step(_part), do: "r"

  @doc """
  The three faces of a box (`DIYWeb.Geometry.box/2`) with the classes of a
  material: `NAME-l` (in the light), `NAME-r` (in the shade) and `NAME-t`
  (the top).
  """
  def faces(camera, box, class) do
    {lit, shade} = if camera.lit == :front, do: {box.front, box.side}, else: {box.side, box.front}
    [{shade, class <> "-r"}, {lit, class <> "-l"}, {box.top, class <> "-t"}]
  end

  @doc """
  The SVG units of 1 inch along x, along y and up, as three vectors of the
  SVG: `{{ax, ay}, {bx, by}, {cx, cy}}`. The hook Plan uses them.
  """
  def axes(%__MODULE__{right: {rx, ry}, down: {dx, dy, dz}}) do
    inch = 0.0254
    {{rx * inch, dx * inch}, {ry * inch, dy * inch}, {0.0, dz * inch}}
  end

  @doc """
  The steps of the plan (`{dx, dy}`) for two moves on the screen: to the
  right, and down. They are the axes of the plan that go most to the right
  and most down. The arrow keys and the move buttons use them.
  """
  def arrows(%__MODULE__{right: {rx, ry}, down: {dx, dy, _dz}}) do
    if abs(rx) >= abs(ry),
      do: {{sign(rx), 0}, {0, sign(dy)}},
      else: {{0, sign(ry)}, {sign(dx), 0}}
  end

  defp sign(n) when n < 0, do: -1
  defp sign(_n), do: 1

  ## The order of the paint

  @doc """
  Objects in the order of the paint, from the back to the front. They are
  the walls, the furniture and the items of a plan (`DIYWeb.Cutaway`), or
  the parts of a model (`DIYWeb.Icon.Shapes`). An object has an `id`, a `box` in the world
  (`{x0, y0, z0, x1, y1, z1}`), a `key`, `loose`, and its `polys`
  (`{corners, class}`).

  Where two objects cover the same part of the screen, the one at the
  back comes first. Its box is on the far side of the other box along x,
  y or z. (The eye is at the large x, y and z.) And the other box is not
  on the far side of it. Else the one with the smaller key (the depth of its
  center, `depth/2`) comes first. A loose object comes by its key only. It
  is an item that is larger than its room (it goes through walls), or a
  flat rug. A part that stands behind a rug does not cover it.
  Three boxes can each be behind the next one (a cycle). Then the box with
  the fewest boxes before it comes first.

  An object with `flat: true` is in the floor (a pool), also when it is
  loose. Each object that goes lower than it comes before it, for example
  the slab of a balcony. Each object that rises over it comes after it,
  for example a pump on its coping. An object at the same height (a rug)
  has no rule with it. These two rules make no cycle by themselves:
  an object lower than it is behind each object over it, along z. A flat
  object through a wall can still be in a cycle with that wall.
  """
  def order(objects, camera) do
    screens = Map.new(objects, &{&1.id, screen(camera, &1.polys)})

    after_ =
      Map.new(objects, fn a ->
        {a.id,
         for(
           b <- objects,
           b.id != a.id,
           cover?(screens[a.id], screens[b.id]),
           before?(a, b),
           do: b.id
         )}
      end)

    # The count of the objects before each object.
    count = after_ |> Map.values() |> List.flatten() |> Enum.frequencies()
    paint(Enum.sort_by(objects, &{&1.key, &1.id}), count, after_, [])
  end

  # The object a must paint before the object b (they cover the same part
  # of the screen).
  defp before?(a, b) do
    case {flat?(a), flat?(b)} do
      {true, true} ->
        false

      {true, false} ->
        rises_over?(b.box, a.box)

      {false, true} ->
        goes_lower?(a.box, b.box)

      {false, false} ->
        not a.loose and not b.loose and behind?(a.box, b.box) and not behind?(b.box, a.box)
    end
  end

  defp flat?(object), do: Map.get(object, :flat, false)

  # The box a starts at or over the top of the flat box f, and rises over
  # it.
  defp rises_over?({_, _, az0, _, _, az1}, {_, _, _, _, _, fz1}),
    do: az0 >= fz1 - 1.0e-6 and az1 > fz1 + 1.0e-6

  # The box a ends at or under the bottom of the flat box f, and goes lower
  # than it.
  defp goes_lower?({_, _, az0, _, _, az1}, {_, _, fz0, _, _, _}),
    do: az1 <= fz0 + 1.0e-6 and az0 < fz0 - 1.0e-6

  # Kahn: the next object is the first one (by key) with no object before
  # it. With none (a cycle), the one with the fewest objects before it. A
  # flat object comes first in a cycle: then an object that goes lower than
  # it can cover its edge, but it does not cover an item on it.
  defp paint([], _count, _after, done), do: Enum.reverse(done)

  defp paint(todo, count, after_, done) do
    next =
      Enum.find(todo, &(Map.get(count, &1.id, 0) == 0)) ||
        Enum.min_by(todo, &{not flat?(&1), Map.get(count, &1.id, 0)})

    count = Enum.reduce(after_[next.id], count, &Map.update!(&2, &1, fn n -> n - 1 end))
    paint(List.delete(todo, next), count, after_, [next | done])
  end

  defp behind?({_, _, _, ax1, ay1, az1}, {bx0, by0, bz0, _, _, _}),
    do: ax1 <= bx0 + 1.0e-6 or ay1 <= by0 + 1.0e-6 or az1 <= bz0 + 1.0e-6

  defp screen(camera, polys) do
    {xs, ys} =
      polys |> Enum.flat_map(&elem(&1, 0)) |> Enum.map(&at(camera, {0, 0}, &1)) |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp cover?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01
end
