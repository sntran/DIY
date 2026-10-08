defmodule DIYWeb.Scene do
  @moduledoc """
  The isometric pictures of the app, in SVG: the house on its lot with the
  equipment of the build and the flows of the power (`house/1`), a camper
  van with its two budgets (`van/1`), and the two houses of the first page
  (`sample/1`).

  A picture shows only what the build has: the floors of the house, a
  garage when the build has a room outside that is not a yard, the panels
  on the roof or in the yard, the stations, the AC, the pool, the car and
  the van. The math of the points is in `DIYWeb.Iso`. The colors are CSS
  variables (`assets/css/app.css`): one set for the light mode (a day) and
  one for the dark mode (a night). The pictures are for the eyes only: the
  text of the page gives the same facts, and a link with a picture has a
  label (`label/1`).

  A shape is one of:

  - `{:poly, corners, class}`: a polygon of points of the world.
  - `{:line, points, class}`: a line through points of the world.
  - `{:wire, a, b, class}`: a wire that hangs from a to b.
  - `{:circle, point, r, class}`: a circle at a point of the world.
  - `{:chip, point, text, class}`: a label at a point of the world.
  """
  use DIYWeb, :html

  alias DIY.Build
  alias DIYWeb.{Format, Iso}

  # The house: its width (x), its depth (y), the height of a floor, the
  # rise of the roof, and the overhang of the roof (in meters).
  @w 10.0
  @d 7.0
  @floor 3.0
  @rise 2.4
  @eave 0.5

  # The lot: from x0 to x1, and from y0 to y1.
  @lot {-3.0, 19.0, -2.5, 13.5}

  # The garage, on the right of the house: x, y, width, depth, height.
  @garage {@w, 1.8, 5.2, @d - 1.8, 2.8}

  # The SVG point of the origin of the world, in the picture of the house,
  # and the SVG point of the sun (or of the moon).
  @origin {152.0, 92.0}
  @sun {44, 30}

  # The watts of a panel, for the count of the panels in a picture: one of
  # a house, and one of a van.
  @panel_w 400
  @van_panel_w 200

  # The van: its width, its length, and its height.
  @van_w 2.1
  @van_l 5.9
  @van_h 2.75

  # The house of the first page.
  @sample %{
    floors: 2,
    garage: true,
    roof_w: 0,
    yard_w: 0,
    grid_tie: false,
    stations: [],
    switch: false,
    ac: true,
    pool: false,
    car: false,
    van: nil
  }

  attr :id, :string, required: true, doc: "the prefix of the ids of the gradients"
  attr :build, :map, required: true, doc: "the build: the house and its vans"
  attr :flows, :boolean, default: true, doc: "show the flows of the power and their labels"

  @doc "The house on its lot, with its equipment."
  def house(assigns) do
    parts = parts(assigns.build)
    shapes = house_shapes(parts) ++ if(assigns.flows, do: flows(parts), else: [])
    top = top(parts)

    assigns =
      assign(assigns,
        shapes: shapes,
        view: {0.0, top, 360.0, 258.0 - top},
        origin: @origin,
        sun: @sun
      )

    ~H"""
    <.canvas id={@id} view={@view} origin={@origin} shapes={@shapes} sun={@sun} />
    """
  end

  attr :id, :string, required: true
  attr :plan, :boolean, default: false, doc: "a plan on paper, not a house that is there"

  @doc "A house for the first page: a house that is there, or a plan."
  def sample(assigns) do
    shapes =
      if assigns.plan,
        do: Enum.map(lot() ++ ground(@sample) ++ building(@sample) ++ garage(@sample), &plan/1),
        else: house_shapes(@sample)

    top = top(@sample)

    assigns =
      assign(assigns,
        shapes: shapes,
        view: {0.0, top + 10, 360.0, 248.0 - top},
        origin: @origin,
        sun: if(assigns.plan, do: nil, else: @sun)
      )

    ~H"""
    <.canvas
      id={@id}
      view={@view}
      origin={@origin}
      shapes={@shapes}
      sun={@sun}
      class={@plan && "scene-plan"}
    />
    """
  end

  # A shape of a plan: lines on blue paper.
  defp plan({:poly, corners, _class}), do: {:poly, corners, "s-plan"}
  defp plan({:line, points, _class}), do: {:line, points, "s-plan-line"}

  attr :id, :string, required: true
  attr :build, :map, required: true
  attr :van, :map, required: true, doc: "the camper van (an item)"
  attr :weight, :map, required: true, doc: "the weight budget (`DIY.Van.weight/2`)"
  attr :power, :map, default: nil, doc: "the power budget (`DIY.Van.power/3`)"

  @doc """
  A camper van on its spot, with its two budgets: the weight on each axle
  (red when it is over the rating), the Wh that its batteries keep, and
  the watts of its panels.
  """
  def van(assigns) do
    parts = van_parts(assigns.build, assigns.van)
    {x0, x1, y0, y1} = {-1.6, @van_w + 1.6, -1.4, @van_l + 1.6}
    slab = Iso.box({x0, y0, -0.5}, {x1 - x0, y1 - y0, 0.5})

    shapes =
      [
        {:poly, slab.left, "s-dirt-l"},
        {:poly, slab.right, "s-dirt-r"},
        {:poly, slab.top, "s-drive"}
      ] ++ van_body({0.0, 0.0}, parts) ++ van_chips(assigns.weight, assigns.power, parts)

    origin = {0.0, 0.0}
    assigns = assign(assigns, shapes: shapes, origin: origin, view: bounds(origin, shapes, 6))

    ~H"""
    <.canvas id={@id} view={@view} origin={@origin} shapes={@shapes} chip={0.5} />
    """
  end

  # The labels of the van: the weight on each axle at its wheels, the Wh of
  # the batteries, and the watts of the panels.
  defp van_chips(weight, power, parts) do
    axle = fn lb, limit -> if limit > 0 and lb > limit, do: "s-chip-bad", else: "s-chip" end

    [
      {:chip, {@van_w + 1.0, 5.6, 0.0}, "Front #{lb(weight.front)}",
       axle.(weight.front, weight.front_gawr)},
      {:chip, {@van_w + 1.0, 1.2, 0.0}, "Rear #{lb(weight.rear)}",
       axle.(weight.rear, weight.rear_gawr)}
    ] ++
      if(power && power.storage > 0,
        do: [
          {:chip, {@van_w / 2, 1.0, @van_h + 1.2}, "#{Format.int(power.storage)} Wh",
           "s-chip-good"}
        ],
        else: []
      ) ++
      if(parts.solar > 0,
        do: [{:chip, {@van_w / 2, 3.4, @van_h + 1.2}, "#{parts.solar} W", "s-chip-sun"}],
        else: []
      )
  end

  defp lb(pounds), do: "#{Format.int(pounds)} lb"

  # The box of the SVG around the shapes, with a margin.
  defp bounds(origin, shapes, margin) do
    points =
      Enum.flat_map(shapes, fn
        {:poly, corners, _class} -> Enum.map(corners, &Iso.at(origin, &1))
        {:chip, point, text, _class} -> chip_box(Iso.at(origin, point), text, 0.5)
      end)

    {xs, ys} = Enum.unzip(points)
    {x0, x1} = Enum.min_max(xs)
    {y0, y1} = Enum.min_max(ys)
    {x0 - margin, y0 - margin, x1 - x0 + 2 * margin, y1 - y0 + 2 * margin}
  end

  defp chip_box({x, y}, text, k) do
    w = chip_w(text) * k / 2
    [{x - w, y - 8 * k}, {x + w, y + 7 * k}]
  end

  attr :id, :string, required: true
  attr :view, :any, required: true, doc: "the box of the SVG: {x, y, width, height}"
  attr :origin, :any, required: true
  attr :shapes, :list, required: true
  attr :sun, :any, default: nil, doc: "the SVG point of the sun (or of the moon)"
  attr :chip, :float, default: 1.0, doc: "the size of the labels"
  attr :class, :any, default: nil

  # The SVG of a picture: the sky, the sun, and the shapes.
  defp canvas(assigns) do
    {x, y, w, h} = assigns.view

    assigns =
      assign(assigns,
        box: Enum.map_join([x, y, w, h], " ", &Iso.round1/1),
        x: Iso.round1(x),
        y: Iso.round1(y),
        w: Iso.round1(w),
        h: Iso.round1(h),
        bottom: Iso.round1(y + h)
      )

    ~H"""
    <svg viewBox={@box} class={["scene w-full", @class]} aria-hidden="true">
      <defs>
        <linearGradient
          id={"#{@id}-sky"}
          gradientUnits="userSpaceOnUse"
          x1="0"
          y1={@y}
          x2="0"
          y2={@bottom}
        >
          <stop offset="0" class="s-sky1" />
          <stop offset="1" class="s-sky2" />
        </linearGradient>
        <linearGradient id={"#{@id}-grass"} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" class="s-grass1" />
          <stop offset="1" class="s-grass2" />
        </linearGradient>
        <linearGradient id={"#{@id}-glass"} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" class="s-glass1" />
          <stop offset="1" class="s-glass2" />
        </linearGradient>
        <linearGradient id={"#{@id}-pv"} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" class="s-pv1" />
          <stop offset="1" class="s-pv2" />
        </linearGradient>
        <filter id={"#{@id}-blur"} x="-20%" y="-20%" width="140%" height="140%">
          <feGaussianBlur stdDeviation="3" />
        </filter>
      </defs>
      <rect x={@x} y={@y} width={@w} height={@h} fill={"url(##{@id}-sky)"} />
      <circle :if={@sun} cx={elem(@sun, 0)} cy={elem(@sun, 1)} r="14" class="s-sun" />
      <.shape :for={shape <- @shapes} shape={shape} origin={@origin} id={@id} chip={@chip} />
    </svg>
    """
  end

  attr :shape, :any, required: true
  attr :origin, :any, required: true
  attr :id, :string, required: true
  attr :chip, :float, required: true

  defp shape(%{shape: {:poly, corners, class}} = assigns) do
    assigns = assign(assigns, points: Iso.points(assigns.origin, corners), class: class)

    ~H"""
    <polygon points={@points} class={@class} {fills(@class, @id)} />
    """
  end

  defp shape(%{shape: {:line, points, class}} = assigns) do
    d = "M" <> Enum.map_join(points, " L", &Iso.points(assigns.origin, [&1]))
    assigns = assign(assigns, d: d, class: class)

    ~H"""
    <path d={@d} class={@class} />
    """
  end

  defp shape(%{shape: {:wire, a, b, class}} = assigns) do
    {ax, ay} = Iso.at(assigns.origin, a)
    {bx, by} = Iso.at(assigns.origin, b)

    [a1, a2, c1, c2, b1, b2] =
      Enum.map([ax, ay, (ax + bx) / 2, max(ay, by) + 6, bx, by], &Iso.round1/1)

    assigns = assign(assigns, d: "M#{a1},#{a2} Q#{c1},#{c2} #{b1},#{b2}", class: class)

    ~H"""
    <path d={@d} class={@class} />
    """
  end

  defp shape(%{shape: {:circle, point, r, class}} = assigns) do
    {x, y} = Iso.at(assigns.origin, point)
    assigns = assign(assigns, x: Iso.round1(x), y: Iso.round1(y), r: r, class: class)

    ~H"""
    <circle cx={@x} cy={@y} r={@r} class={@class} />
    """
  end

  defp shape(%{shape: {:chip, point, text, class}} = assigns) do
    {x, y} = Iso.at(assigns.origin, point)
    move = "translate(#{Iso.round1(x)} #{Iso.round1(y)}) scale(#{assigns.chip})"
    w = chip_w(text)

    assigns =
      assign(assigns,
        move: move,
        text: text,
        x: Iso.round1(-w / 2),
        w: Iso.round1(w),
        class: class
      )

    ~H"""
    <g transform={@move}>
      <rect x={@x} y="-8" width={@w} height="15" rx="7.5" class={@class} />
      <text y="3" text-anchor="middle" class="s-chip-text">{@text}</text>
    </g>
    """
  end

  # A fill of a gradient, or a filter, for the classes that have one.
  defp fills("s-grass", id), do: [fill: "url(##{id}-grass)"]
  defp fills("s-glass", id), do: [fill: "url(##{id}-glass)"]
  defp fills("s-pv", id), do: [fill: "url(##{id}-pv)"]
  defp fills("s-shadow", id), do: [filter: "url(##{id}-blur)"]
  defp fills(_class, _id), do: []

  defp chip_w(text), do: String.length(text) * 5.6 + 14

  @doc "A text for a screen reader: what the picture of the house shows."
  def label(build) do
    parts = parts(build)

    things =
      Enum.filter(
        [
          parts.roof_w > 0 && "solar panels on the roof",
          parts.yard_w > 0 && "solar panels in the yard",
          parts.stations != [] && "a power station",
          parts.ac && "an AC",
          parts.pool && "a pool",
          parts.car && "an electric car",
          parts.van && "a camper van"
        ],
        & &1
      )

    "A house with #{Format.count(parts.floors, "floor")}" <>
      Enum.map_join(things, "", &(", " <> &1))
  end

  # What the picture of the house shows, from the build: the house (with
  # no item of a van), and the first van.
  defp parts(build) do
    house = Build.house_view(build)
    places = Map.new(house.rooms, &{&1.id, &1.place})
    panels = Enum.filter(house.items, &(&1.type == "solar_panels"))
    of = fn type -> Enum.filter(house.items, &(&1.type == type)) end
    on = fn place -> watts(Enum.filter(panels, &(places[&1.room] == place))) end
    van = List.first(of.("camper_van"))

    %{
      floors: house.house.floors,
      garage: Enum.any?(house.rooms, &(&1.level == "outside" and &1.place == :indoor)),
      roof_w: on.(:roof),
      yard_w: on.(:outdoor),
      grid_tie: Enum.any?(panels, &(&1.params["to"] == "grid")),
      stations: of.("power_station"),
      switch: of.("transfer_switch") != [],
      ac: Enum.any?(house.items, &(&1.type in ["ac", "mini_split"])),
      pool: of.("pool_pump") != [],
      car: of.("ev") != [],
      van: van && van_parts(build, van)
    }
  end

  # What the picture of a van shows: the watts of its panels, and its fan.
  defp van_parts(build, van) do
    items = Enum.map(DIY.Van.items(build, van.id), &elem(&1, 1))

    %{
      solar: watts(Enum.filter(items, &(&1.type == "van_solar"))),
      fan: Enum.any?(items, &(&1.type == "van_fan"))
    }
  end

  defp watts(panels), do: panels |> Enum.map(& &1.params["watts"]) |> Enum.sum()

  # The top of the picture: the ridge of the roof, and some sky.
  defp top(parts) do
    {_x, sy} = Iso.at(@origin, {@w / 2, @d / 2, height(parts) + @rise})
    min(sy - 34, 0.0)
  end

  defp height(parts), do: parts.floors * @floor

  # The shapes of the house and of its lot, in the order of the paint: from
  # the back to the front.
  defp house_shapes(parts) do
    lot() ++
      pole() ++
      tree({14.4, -1.6}, 1.0) ++
      yard_panels(parts) ++
      ground(parts) ++
      shadow(parts) ++
      building(parts) ++
      garage(parts) ++
      meter(parts) ++
      ac(parts) ++
      stations(parts) ++
      bushes() ++
      person() ++
      car(parts) ++
      if(parts.van, do: van_body({11.6, 7.3}, parts.van), else: []) ++
      tree({-2.1, 12.4}, 0.8)
  end

  defp lot do
    {x0, x1, y0, y1} = @lot
    slab = Iso.box({x0, y0, -1.2}, {x1 - x0, y1 - y0, 1.2})
    turf = Iso.box({x0, y0, -0.25}, {x1 - x0, y1 - y0, 0.25})

    [
      {:poly, slab.left, "s-dirt-l"},
      {:poly, slab.right, "s-dirt-r"},
      {:poly, turf.left, "s-turf-l"},
      {:poly, turf.right, "s-turf-r"},
      {:poly, slab.top, "s-grass"}
    ]
  end

  # The pole of the grid, at the back on the right.
  defp pole do
    post = Iso.box({18.0, -2.1, 0.0}, {0.25, 0.25, 7.0})
    arm = Iso.box({17.3, -2.0, 6.4}, {1.6, 0.12, 0.12})
    [{:poly, post.left, "s-pole-l"}, {:poly, post.right, "s-pole-r"}] ++ faces(arm, "s-pole")
  end

  # A tree of low polygons: a trunk and two cones.
  defp tree({x, y}, k) do
    trunk = Iso.box({x - 0.12 * k, y - 0.12 * k, 0.0}, {0.24 * k, 0.24 * k, 1.2 * k})
    top = {x, y, 5.2 * k}

    cone = fn z, r ->
      left = {x - r, y + r, z}
      front = {x + r, y + r, z}
      right = {x + r, y - r, z}
      [{:poly, [left, front, top], "s-leaf-l"}, {:poly, [front, right, top], "s-leaf-r"}]
    end

    [{:poly, trunk.left, "s-trunk-l"}, {:poly, trunk.right, "s-trunk-r"}] ++
      cone.(1.0 * k, 1.5 * k) ++ cone.(2.6 * k, 1.1 * k)
  end

  # The panels in the yard: rows that face the front (the south).
  defp yard_panels(%{yard_w: 0}), do: []

  defp yard_panels(%{yard_w: watts}) do
    for i <- 0..(count(watts, @panel_w, 8) - 1),
        shape <- yard_panel({15.6 + rem(i, 3) * 1.15, 3.6 - div(i, 3) * 1.9}),
        do: shape
  end

  defp yard_panel({x, y}) do
    low = {x, y, 0.5}
    high = {x, y - 1.2, 1.3}
    leg = Iso.box({x + 0.45, y - 1.1, 0.0}, {0.08, 0.08, 1.3})

    [
      {:poly, leg.right, "s-pole-r"},
      {:poly, [low, Iso.add(low, {1.0, 0.0, 0.0}), Iso.add(high, {1.0, 0.0, 0.0}), high], "s-pv"}
    ]
  end

  # The paths: the walk to the door, the drive to the garage, and the pool.
  defp ground(parts) do
    {_x0, _x1, _y0, y1} = @lot
    walk = Iso.box({4.6, @d, 0.0}, {1.3, y1 - @d, 0.02})

    drive =
      if parts.garage or parts.car or parts.van,
        do: [{:poly, Iso.box({10.5, @d, 0.0}, {4.4, y1 - @d, 0.02}).top, "s-drive"}],
        else: []

    pool =
      if parts.pool,
        do: [
          {:poly, Iso.box({-2.4, 8.4, 0.0}, {5.0, 3.2, 0.05}).top, "s-rim"},
          {:poly, Iso.box({-2.0, 8.75, 0.0}, {4.2, 2.5, 0.06}).top, "s-water"}
        ],
        else: []

    [{:poly, walk.top, "s-drive"}] ++ drive ++ pool
  end

  # A soft shadow on the ground, behind and on the right of the house.
  defp shadow(parts) do
    w = if parts.garage, do: @w + 5.2, else: @w

    [
      {:poly, [{0.0, 0.0, 0}, {w, 0.0, 0}, {w + 0.8, @d + 0.4, 0}, {0.6, @d + 0.6, 0}],
       "s-shadow"}
    ]
  end

  # The house: the back of the roof, the walls with their windows and the
  # door, the gable, the front of the roof, and the panels on it.
  defp building(parts) do
    h = height(parts)
    walls = Iso.box({0.0, 0.0, 0.0}, {@w, @d, h})
    base = Iso.box({0.0, 0.0, 0.0}, {@w, @d, 0.35})
    ridge = @d / 2
    top = h + @rise
    back = [{-0.4, -@eave, h}, {@w, -@eave, h}, {@w, ridge, top}, {-0.4, ridge, top}]
    front = [{-0.4, @d + @eave, h}, {@w, @d + @eave, h}, {@w, ridge, top}, {-0.4, ridge, top}]

    [
      {:poly, back, "s-roof-b"},
      {:poly, walls.left, "s-wall-l"},
      {:poly, walls.right, "s-wall-r"},
      {:poly, base.left, "s-base-l"},
      {:poly, base.right, "s-base-r"}
    ] ++
      bands(parts) ++
      windows(parts) ++
      door() ++
      [{:poly, [{@w, 0.0, h}, {@w, @d, h}, {@w, ridge, top}], "s-wall-r"}] ++
      gable_window(h, ridge) ++
      [
        {:poly, fascia(Enum.at(back, 2), Enum.at(back, 1)), "s-fascia-r"},
        {:poly, front, "s-roof"},
        {:poly, fascia(Enum.at(front, 1), Enum.at(front, 2)), "s-fascia-r"},
        {:poly, fascia(Enum.at(front, 0), Enum.at(front, 1)), "s-fascia-l"}
      ] ++
      roof_panels(parts, h, ridge) ++
      [{:line, [{-0.4, ridge, top}, {@w, ridge, top}], "s-ridge"}]
  end

  # The edge of a roof plane, from a to b, down.
  defp fascia(a, b), do: [a, b, Iso.add(b, {0, 0, -0.22}), Iso.add(a, {0, 0, -0.22})]

  # A line between two floors, on the two walls that show.
  defp bands(parts) do
    for f <- 1..(parts.floors - 1)//1,
        {face, class} <- [{:left, "s-band-l"}, {:right, "s-band-r"}] do
      band = Iso.box({0.0, 0.0, f * @floor - 0.08}, {@w, @d, 0.16})
      {:poly, Map.fetch!(band, face), class}
    end
  end

  # The windows: on the front wall (with no window at the door) and on the
  # side wall, on each floor.
  defp windows(parts) do
    for f <- 0..(parts.floors - 1),
        spot <- spots(f),
        shape <- window(spot, f * @floor + if(f == 0, do: 1.05, else: 0.9)),
        do: shape
  end

  defp spots(0), do: [{:front, 1.0}, {:front, 2.75}, {:front, 7.0}, {:side, 1.4}, {:side, 4.6}]

  defp spots(_floor),
    do: [{:front, 1.0}, {:front, 2.75}, {:front, 4.65}, {:front, 7.0}, {:side, 1.4}, {:side, 4.6}]

  # A window: its frame, its glass, and its bar. On the front wall it is at
  # y = @d, from x = at; on the side wall at x = @w, from y = at.
  defp window({:front, at}, z), do: window({at, @d, z}, {1, 0, 0}, "s-frame")
  defp window({:side, at}, z), do: window({@w, at, z}, {0, 1, 0}, "s-frame-r")

  defp window(corner, along, frame) do
    plane = &Iso.on_plane(corner, along, {0, 0, 1}, &1, &2)

    [
      {:poly, plane.({-0.1, -0.1}, {1.5, 1.6}), frame},
      {:poly, plane.({0.0, 0.0}, {1.3, 1.4}), "s-glass"},
      {:poly, plane.({0.62, 0.0}, {0.06, 1.4}), frame}
    ]
  end

  # A round window in the gable.
  defp gable_window(h, ridge) do
    [
      {:poly, Iso.circle({@w, ridge, h + 1.0}, {0, 1, 0}, {0, 0, 1}, 0.55), "s-frame-r"},
      {:poly, Iso.circle({@w, ridge, h + 1.0}, {0, 1, 0}, {0, 0, 1}, 0.42), "s-glass"}
    ]
  end

  # The door, its roof, and its step.
  defp door do
    plane = &Iso.on_plane({4.7, @d, 0.0}, {1, 0, 0}, {0, 0, 1}, &1, &2)

    [
      {:poly, plane.({-0.12, 0.0}, {1.34, 2.32}), "s-frame"},
      {:poly, plane.({0.0, 0.0}, {1.1, 2.2}), "s-door"},
      {:poly, plane.({0.15, 1.3}, {0.8, 0.6}), "s-glass"},
      {:poly, plane.({0.86, 1.0}, {0.1, 0.1}), "s-knob"}
    ] ++
      faces(Iso.box({4.4, @d, 0.0}, {1.7, 0.6, 0.16}), "s-step") ++
      faces(Iso.box({4.3, @d, 2.45}, {1.9, 0.7, 0.14}), "s-fascia")
  end

  # The panels on the front of the roof: rows from the eave, at the middle.
  defp roof_panels(%{roof_w: 0}, _h, _ridge), do: []

  defp roof_panels(%{roof_w: watts}, h, ridge) do
    n = count(watts, @panel_w, 16)
    slope = {0.0, -(@d + @eave - ridge), @rise}
    up = Iso.scale(slope, 1 / :math.sqrt(elem(slope, 1) ** 2 + @rise ** 2))
    eave = {-0.4, @d + @eave, h + 0.04}

    for i <- 0..(n - 1) do
      row = div(i, 8)
      x = (@w + 0.4 - min(n - row * 8, 8) * 1.12) / 2 + rem(i, 8) * 1.12
      {:poly, Iso.on_plane(eave, {1, 0, 0}, up, {x, 0.45 + row * 1.85}, {1.04, 1.75}), "s-pv"}
    end
  end

  # The count of panels in a picture: one for each `size` W (at least one),
  # at most `max`.
  defp count(watts, size, max), do: watts |> div(size) |> max(1) |> min(max)

  # The garage: a box with a flat roof, and its door.
  defp garage(%{garage: false}), do: []

  defp garage(_parts) do
    {x, y, w, d, h} = @garage
    body = Iso.box({x, y, 0.0}, {w, d, h})
    base = Iso.box({x, y, 0.0}, {w, d, 0.35})
    plane = &Iso.on_plane({x + 0.6, @d, 0.0}, {1, 0, 0}, {0, 0, 1}, &1, &2)

    [
      {:poly, body.left, "s-wall-l"},
      {:poly, body.right, "s-wall-r"},
      {:poly, base.left, "s-base-l"},
      {:poly, base.right, "s-base-r"},
      {:poly, plane.({-0.1, 0.0}, {4.2, 2.35}), "s-frame"},
      {:poly, plane.({0.0, 0.0}, {4.0, 2.2}), "s-gdoor"}
    ] ++
      for(k <- 1..3, do: {:poly, plane.({0.0, k * 0.55}, {4.0, 0.04}), "s-gline"}) ++
      faces(Iso.box({x - 0.05, y - 0.05, h}, {w + 0.1, d + 0.1, 0.2}), "s-fascia")
  end

  # The meter on the wall at the right, and the switch of the panel on the
  # front wall, next to the stations.
  defp meter(parts) do
    {x, y} = meter_at(parts)
    glass = Iso.circle({x + 0.19, y + 0.25, 1.75}, {0, 1, 0}, {0, 0, 1}, 0.15)
    switch = Iso.box({8.85, @d, 1.15}, {0.7, 0.15, 0.85})

    faces(Iso.box({x, y, 1.3}, {0.18, 0.5, 0.7}), "s-meter") ++
      [{:poly, glass, "s-glass"}] ++
      if(parts.switch, do: faces(switch, "s-meter"), else: [])
  end

  defp meter_at(%{garage: true}), do: {@w + 5.2, 3.4}
  defp meter_at(_parts), do: {@w, 2.4}

  # The AC on the ground, on the right side.
  defp ac(%{ac: false}), do: []

  defp ac(parts) do
    {x, y} = if parts.garage, do: {@w + 5.6, 5.4}, else: {@w + 0.5, 4.6}
    fan = Iso.circle({x + 0.5, y + 0.5, 0.81}, {1, 0, 0}, {0, 1, 0}, 0.36)
    faces(Iso.box({x, y, 0.0}, {1.0, 1.0, 0.8}), "s-ac") ++ [{:poly, fan, "s-fan"}]
  end

  # The stations, at the front wall: each with its extra batteries under it.
  defp stations(parts) do
    for {station, i} <- Enum.with_index(Enum.take(parts.stations, 2)),
        shape <- station({6.4 + i * 0.95, @d + 0.15}, station.params["extra_kwh"] > 0),
        do: shape
  end

  defp station({x, y}, extra) do
    base = if extra, do: 0.42, else: 0.0
    screen = Iso.on_plane({x, y + 0.5, base}, {1, 0, 0}, {0, 0, 1}, {0.12, 0.34}, {0.56, 0.12})
    pack = if extra, do: faces(Iso.box({x, y, 0.0}, {0.8, 0.5, 0.38}), "s-station"), else: []

    pack ++
      faces(Iso.box({x, y, base}, {0.8, 0.5, 0.62}), "s-station") ++ [{:poly, screen, "s-screen"}]
  end

  # The top, the left and the right of a box, with a class for each.
  defp faces(box, class) do
    [
      {:poly, box.left, class <> "-l"},
      {:poly, box.right, class <> "-r"},
      {:poly, box.top, class <> "-t"}
    ]
  end

  # Bushes at the front wall.
  defp bushes, do: for(x <- [0.9, 2.6, 8.9], do: {:circle, {x, @d + 0.5, 0.35}, 7, "s-bush"})

  # The user, at the door.
  defp person do
    body = Iso.box({5.05, @d + 1.4, 0.0}, {0.4, 0.3, 1.25})

    [
      {:poly, body.left, "s-shirt-l"},
      {:poly, body.right, "s-shirt-r"},
      {:circle, {5.25, @d + 1.55, 1.55}, 2.6, "s-skin"}
    ]
  end

  # An electric car in the drive (on the right of a van).
  defp car(%{car: false}), do: []

  defp car(parts) do
    x = if parts.van, do: 15.6, else: 11.8
    {y, l} = {8.2, 4.5}

    top = fn a, b ->
      [{x + a, y + 1.5, 1.5}, {x + b, y + 1.5, 1.5}, {x + b, y + 3.0, 1.5}, {x + a, y + 3.0, 1.5}]
    end

    side = [
      {x + 1.8, y + 1.1, 0.98},
      {x + 1.8, y + 3.5, 0.98},
      {x + 1.6, y + 3.0, 1.5},
      {x + 1.6, y + 1.5, 1.5}
    ]

    shield = [
      {x + 0.1, y + 3.5, 0.98},
      {x + 1.8, y + 3.5, 0.98},
      {x + 1.6, y + 3.0, 1.5},
      {x + 0.2, y + 3.0, 1.5}
    ]

    wheels(x + 1.8, [y + 0.9, y + l - 0.9], 0.34) ++
      faces(Iso.box({x, y, 0.28}, {1.8, l, 0.7}), "s-car") ++
      [{:poly, side, "s-vglass"}, {:poly, shield, "s-vglass"}, {:poly, top.(0.2, 1.6), "s-car-t"}] ++
      lights({x, y + l, 0.6}, 1.8)
  end

  # The wheels on the side at the right, at x.
  defp wheels(x, ys, r) do
    for y <- ys,
        {radius, class} <- [{r, "s-tire"}, {r * 0.5, "s-hub"}],
        do: {:poly, Iso.circle({x + 0.02, y, r}, {0, 1, 0}, {0, 0, 1}, radius), class}
  end

  # The lights at the front of a car or a van.
  defp lights({x, y, z}, w) do
    for s <- [0.15, w - 0.45] do
      {:poly, Iso.on_plane({x, y + 0.01, z}, {1, 0, 0}, {0, 0, 1}, {s, 0.0}, {0.3, 0.14}),
       "s-lamp"}
    end
  end

  # A camper van, from its back corner at x, y, with the front to +y: the
  # wheels, the side with its windows and its door, the roof (with panels
  # and a fan), the windshield, the hood, and the front.
  defp van_body({x, y}, parts) do
    {w, low, high} = {@van_w, 0.45, @van_h}
    {cab, nose} = {y + 4.5, y + @van_l}

    profile = [
      {y, low},
      {nose, low},
      {nose, 1.45},
      {y + 5.3, 1.6},
      {y + 4.8, 2.5},
      {cab, high},
      {y, high}
    ]

    side = Enum.map(profile, fn {b, z} -> {x + w, b, z} end)

    across = fn {b1, z1}, {b2, z2} ->
      [{x, b1, z1}, {x + w, b1, z1}, {x + w, b2, z2}, {x, b2, z2}]
    end

    front = Iso.on_plane({x, nose, low}, {1, 0, 0}, {0, 0, 1}, {0.0, 0.0}, {w, 1.0})
    plane = &Iso.on_plane({x + w + 0.01, y, low}, {0, 1, 0}, {0, 0, 1}, &1, &2)

    wheels(x + w, [y + 1.1, y + 5.1], 0.42) ++
      [
        {:poly, side, "s-van-r"},
        {:poly, plane.({0.0, 0.0}, {@van_l, 0.35}), "s-van-trim"},
        {:poly, plane.({1.6, 1.15}, {1.3, 0.75}), "s-vglass"},
        {:poly, plane.({3.0, 0.35}, {1.5, 1.85}), "s-van-door"},
        {:poly, plane.({4.75, 1.1}, {0.9, 0.8}), "s-vglass"},
        {:poly, across.({y, high}, {cab, high}), "s-van-t"},
        {:poly, across.({cab, high}, {y + 4.8, 2.5}), "s-van-t"}
      ] ++
      van_roof({x, y}, parts) ++
      [
        {:poly, across.({y + 5.3, 1.6}, {y + 4.8, 2.5}), "s-vglass"},
        {:poly, across.({nose, 1.45}, {y + 5.3, 1.6}), "s-van-t"},
        {:poly, front, "s-van-l"}
      ] ++
      lights({x, nose, 0.95}, w)
  end

  # The panels on the roof of a van (two in a row), and its fan.
  defp van_roof({x, y}, parts) do
    panels =
      if parts.solar > 0 do
        for i <- 0..(count(parts.solar, @van_panel_w, 4) - 1) do
          at = {rem(i, 2) * 0.97, div(i, 2) * 1.55}
          corner = {x + 0.1, y + 0.2, @van_h + 0.06}
          {:poly, Iso.on_plane(corner, {1, 0, 0}, {0, 1, 0}, at, {0.92, 1.5}), "s-pv"}
        end
      else
        []
      end

    fan =
      if parts.fan,
        do: faces(Iso.box({x + 0.75, y + 3.4, @van_h}, {0.6, 0.6, 0.18}), "s-ac"),
        else: []

    panels ++ fan
  end

  # The flows of the power, with their labels: the grid to the meter, the
  # panels down the corner of the house to the stations (or into the house
  # with a grid-tie inverter), and the stations to the switch of the panel.
  defp flows(parts) do
    h = height(parts)
    {mx, my} = meter_at(parts)
    pole = {18.1, -2.0, 6.4}
    meter = {mx + 0.2, my + 0.25, 1.65}
    corner = [{9.8, @d + @eave, h - 0.2}, {9.8, @d + 0.2, 0.6}]

    grid = [
      {:wire, pole, meter, "s-wire"},
      {:wire, pole, meter, "s-flow s-flow-grid"},
      {:chip, Iso.add(pole, {0, 0, 0.9}), "Grid", "s-chip"}
    ]

    # Panels on a station that is not there (in a van) give nothing.
    sun =
      cond do
        parts.roof_w == 0 -> []
        parts.grid_tie -> [{:line, corner, "s-flow s-flow-sun"}]
        parts.stations != [] -> [{:line, corner ++ [{7.2, @d + 0.4, 0.6}], "s-flow s-flow-sun"}]
        true -> []
      end

    sun_chip =
      if parts.roof_w + parts.yard_w > 0,
        do: [{:chip, {4.6, 5.6, h + 1.9}, kw(parts.roof_w + parts.yard_w), "s-chip"}],
        else: []

    grid ++ sun ++ store(parts) ++ sun_chip
  end

  # The flow from the stations to the switch of the panel, and the kWh of
  # the stations.
  defp store(%{stations: []}), do: []

  defp store(parts) do
    kwh = parts.stations |> Enum.map(&(&1.params["kwh"] + &1.params["extra_kwh"])) |> Enum.sum()
    top = if Enum.any?(parts.stations, &(&1.params["extra_kwh"] > 0)), do: 1.02, else: 0.62
    station = {6.8, @d + 0.4, top}

    wire =
      if parts.switch,
        do: [
          {:line, [station, {6.8, @d + 0.2, 1.55}, {8.85, @d + 0.2, 1.55}],
           "s-flow s-flow-battery"}
        ],
        else: []

    wire ++
      [{:chip, {7.0, @d + 2.6, 0.0}, "#{Format.value(Float.round(kwh / 1, 1))} kWh", "s-chip"}]
  end

  defp kw(watts) when watts >= 1000, do: "#{Format.value(Float.round(watts / 1000, 1))} kW"
  defp kw(watts), do: "#{watts} W"
end
