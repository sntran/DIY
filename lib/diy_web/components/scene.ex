defmodule DIYWeb.Scene do
  @moduledoc """
  The pictures of the app, in SVG. `house/1` draws the house on
  its lot, with the equipment of the build and the flows of the power.
  `van/1` draws a camper van with its two budgets. `sample/1` draws the
  two houses of the first page.

  A picture of the house shows only what the house of today has
  (`DIY.Build.today/1`, with no planned item). The picture of a van on the
  page Van counts the planned items too, as the budgets of that page do.
  The picture of the house shows the floors and a garage (a room outside
  that is not a yard). It shows the panels on the roof or in the yard, the
  stations, the AC, the pool, the car and the van. A flow shows only where
  the power goes in the model (`DIY.Power`).

  The page gives the parts of a picture (`parts/1`, `van_parts/2`), and the
  LiveView keeps them as an assign. So the page sends a picture again only
  when its parts change.

  The math of the points is in `DIYWeb.Geometry`, and the cameras are in
  `DIYWeb.Camera`: the camera of the house for a house, and the camera of a
  van for a van. The colors are CSS variables
  (`assets/css/app.css`): one set for the light mode (a day) and one for
  the dark mode (a night). The pictures are for the eyes only: the text of
  the page gives the same facts, and a link with a picture has a label
  (`label/1`).

  A shape is one of:

  - `{:poly, corners, class}`: a polygon of points of the world.
  - `{:line, points, class}`: a line through points of the world.
  - `{:wire, a, b, class}`: a wire that hangs from a to b.
  - `{:circle, point, r, class}`: a circle at a point of the world.
  - `{:chip, point, text, class}`: a label at a point of the world.
  """
  use DIYWeb, :html

  alias DIY.{Build, Power, Van}
  alias DIYWeb.{Camera, Format, Geometry}

  # The house: its width (x), its depth (y), the height of a floor, the
  # rise of the roof, and the overhang of the roof (in meters).
  @w 10.0
  @d 7.0
  @floor 3.0
  @rise 2.4
  @eave 0.5

  # The lot: from x0 to x1, and from y0 to y1, and its depth.
  @lot {-3.0, 19.0, -2.5, 13.5}
  @slab 1.2

  # The garage, on the right of the house: x, y, width, depth, height.
  @garage {@w, 1.8, 5.2, @d - 1.8, 2.8}

  # The sky over a picture of the house (SVG units): the sun is in it.
  @sky 44

  # The size of the labels in the picture of the house.
  @chip 1.3

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
    roof: %{station: 0, grid: 0},
    yard: %{station: 0, grid: 0},
    stations: [],
    panel: false,
    switch: false,
    ac: true,
    pool: false,
    car: false,
    van: nil
  }

  @doc """
  The parts of the picture of a house, from a build: the house of today
  (with no item of a van, and no planned item), and its first van (with no
  planned item too).
  """
  def parts(build) do
    house = build |> Build.house_view() |> Build.today()
    places = Map.new(house.rooms, &{&1.id, &1.place})
    of = fn type -> Enum.filter(house.items, &(&1.type == type)) end
    stations = of.("power_station")

    # The watts of the panels in a place, to a station and to the grid.
    panels = fn place ->
      on = Enum.filter(of.("solar_panels"), &(places[&1.room] == place))
      to = fn to -> watts(Enum.filter(on, &(&1.params["to"] == to))) end
      %{station: to.("station"), grid: to.("grid")}
    end

    %{
      floors: house.house.floors,
      garage: Enum.any?(house.rooms, &(&1.level == "outside" and &1.place == :indoor)),
      roof: panels.(:roof),
      yard: panels.(:outdoor),
      stations:
        Enum.map(
          stations,
          &{&1.params["kwh"] + &1.params["extra_kwh"], &1.params["extra_kwh"] > 0}
        ),
      panel: Power.panel?(Power.system(house.items)),
      switch: of.("transfer_switch") != [],
      ac: Enum.any?(house.items, &(&1.type in ["ac", "mini_split"])),
      pool: of.("pool_pump") != [],
      car: of.("ev") != [],
      van:
        case of.("camper_van") do
          [van | _] -> van_look(Enum.reject(van_items(build, van), & &1.planned))
          [] -> nil
        end
    }
  end

  defp van_items(build, van), do: for({_zone, item} <- Van.items(build, van.id), do: item)

  # What a van shows from the outside: the watts of its panels, and a fan.
  defp van_look(items) do
    %{
      solar: watts(Enum.filter(items, &(&1.type == "van_solar"))),
      fan: Enum.any?(items, &(&1.type == "van_fan"))
    }
  end

  @doc """
  The parts of the picture of a van: its panels and its fan, the weight on
  each axle and the ratings of the axles, and the Wh of its batteries. As
  the page Van, it counts the planned items too.
  """
  def van_parts(build, van) do
    weight = Van.weight(build, van)

    Map.merge(van_look(van_items(build, van)), %{
      front: weight.front,
      rear: weight.rear,
      front_gawr: weight.front_gawr,
      rear_gawr: weight.rear_gawr,
      storage: Van.storage(build, van)
    })
  end

  defp watts(panels), do: panels |> Enum.map(& &1.params["watts"]) |> Enum.sum()

  @doc "A text for a screen reader: what the picture of the house shows."
  def label(parts) do
    count = length(parts.stations)

    things =
      Enum.filter(
        [
          parts.roof.station + parts.roof.grid > 0 && "solar panels on the roof",
          parts.yard.station + parts.yard.grid > 0 && "solar panels in the yard",
          count == 1 && "a power station",
          count > 1 && "#{count} power stations",
          parts.ac && "an AC",
          parts.pool && "a pool",
          parts.car && "an electric car",
          parts.van && "a camper van"
        ],
        & &1
      )

    "a house with #{Format.count(parts.floors, "floor")}" <>
      Enum.map_join(things, "", &(", " <> &1))
  end

  attr :id, :string, required: true, doc: "the prefix of the ids of the gradients"
  attr :parts, :map, required: true, doc: "the parts of the picture (`parts/1`)"

  @doc "The house on its lot, with its equipment and the flows of its power."
  def house(assigns) do
    parts = assigns.parts
    {back, front} = house_shapes(parts)
    {lines, chips} = flows(parts)
    shapes = back ++ lines ++ front ++ chips
    view = house_view(shapes)

    assigns =
      assign(assigns,
        shapes: shapes,
        view: view,
        camera: Camera.house(),
        sun: sun(view),
        chip: @chip
      )

    ~H"""
    <.canvas
      id={@id}
      view={@view}
      camera={@camera}
      shapes={@shapes}
      sun={@sun}
      chip={@chip}
    />
    """
  end

  # The box of the picture of a house: its shapes, with some sky over them
  # for the sun.
  defp house_view(shapes) do
    {x, y, w, h} = bounds(Camera.house(), shapes, 4, @chip)
    {x, y - @sky, w, h + @sky}
  end

  # The sun (or the moon) in the sky, at the top left of a picture.
  defp sun({x, y, _w, _h}), do: {Camera.round1(x + 36), Camera.round1(y + 28)}

  attr :id, :string, required: true
  attr :plan, :boolean, default: false, doc: "a plan on paper, not a house that is there"

  @doc "A house for the first page: a house that is there, or a plan."
  def sample(assigns) do
    {back, front} = house_shapes(@sample)

    shapes =
      if assigns.plan,
        do: Enum.map(lot() ++ ground(@sample) ++ building(@sample) ++ garage(@sample), &plan/1),
        else: back ++ front

    view = house_view(back ++ front)

    assigns =
      assign(assigns,
        shapes: shapes,
        view: view,
        camera: Camera.house(),
        sun: if(assigns.plan, do: nil, else: sun(view))
      )

    ~H"""
    <.canvas
      id={@id}
      view={@view}
      camera={@camera}
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
  attr :parts, :map, required: true, doc: "the parts of the picture (`van_parts/2`)"

  @doc """
  A camper van on its spot, with its two budgets: the weight on each axle
  (red when it is over the rating), the Wh that its batteries keep, and
  the watts of its panels.
  """
  def van(assigns) do
    parts = assigns.parts
    camera = Camera.van()
    {x0, x1, y0, y1} = {-1.6, @van_w + 1.6, -1.4, @van_l + 1.6}
    slab = Geometry.box({x0, y0, -0.5}, {x1 - x0, y1 - y0, 0.5})
    [dirt_r, dirt_l, _top] = faces(slab, "s-dirt", camera)

    shapes =
      [dirt_r, dirt_l, {:poly, slab.top, "s-drive"}] ++
        van_body({0.0, 0.0}, parts, camera) ++ van_chips(parts)

    assigns =
      assign(assigns, shapes: shapes, camera: camera, view: bounds(camera, shapes, 6, 0.5))

    ~H"""
    <.canvas id={@id} view={@view} camera={@camera} shapes={@shapes} chip={0.5} />
    """
  end

  # The labels of the van: the weight on each axle at its wheels, the Wh of
  # the batteries, and the watts of the panels.
  defp van_chips(parts) do
    axle = fn lb, limit -> if limit > 0 and lb > limit, do: "s-chip-bad", else: "s-chip" end

    [
      {:chip, {@van_w + 1.0, 5.6, 0.0}, "Front #{lb(parts.front)}",
       axle.(parts.front, parts.front_gawr)},
      {:chip, {@van_w + 1.0, 1.2, 0.0}, "Rear #{lb(parts.rear)}",
       axle.(parts.rear, parts.rear_gawr)}
    ] ++
      if(parts.storage > 0,
        do: [
          {:chip, {@van_w / 2, 1.0, @van_h + 1.2}, "#{Format.int(parts.storage)} Wh",
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

  # The box of the SVG around the shapes, with a margin. The labels have
  # their size (`chip`).
  defp bounds(camera, shapes, margin, chip) do
    at = &Camera.at(camera, {0, 0}, &1)

    points =
      Enum.flat_map(shapes, fn
        {:poly, corners, _class} -> Enum.map(corners, at)
        {:line, points, _class} -> Enum.map(points, at)
        {:wire, a, b, _class} -> [at.(a), at.(b)]
        {:circle, point, _r, _class} -> [at.(point)]
        {:chip, point, text, _class} -> chip_box(at.(point), text, chip)
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
  attr :camera, :any, required: true, doc: "the camera (`DIYWeb.Camera`)"
  attr :shapes, :list, required: true
  attr :sun, :any, default: nil, doc: "the SVG point of the sun (or of the moon)"
  attr :chip, :float, default: 1.0, doc: "the size of the labels"
  attr :class, :any, default: nil

  # The SVG of a picture: the sky, the sun, and the shapes. It defines only
  # the gradients and the filter that its shapes use.
  defp canvas(assigns) do
    {x, y, w, h} = assigns.view
    classes = MapSet.new(assigns.shapes, &elem(&1, tuple_size(&1) - 1))

    assigns =
      assign(assigns,
        box: Enum.map_join([x, y, w, h], " ", &Camera.round1/1),
        x: Camera.round1(x),
        y: Camera.round1(y),
        w: Camera.round1(w),
        h: Camera.round1(h),
        bottom: Camera.round1(y + h),
        fills: for(c <- ~w(s-grass s-glass s-pv), MapSet.member?(classes, c), do: c),
        blur: MapSet.member?(classes, "s-shadow")
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
        <linearGradient :for={fill <- @fills} id={"#{@id}-#{fill}"} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" class={fill <> "1"} />
          <stop offset="1" class={fill <> "2"} />
        </linearGradient>
        <filter :if={@blur} id={"#{@id}-blur"} x="-20%" y="-20%" width="140%" height="140%">
          <feGaussianBlur stdDeviation="3" />
        </filter>
      </defs>
      <rect x={@x} y={@y} width={@w} height={@h} fill={"url(##{@id}-sky)"} />
      <circle :if={@sun} cx={elem(@sun, 0)} cy={elem(@sun, 1)} r="14" class="s-sun" />
      <.shape :for={shape <- @shapes} shape={shape} camera={@camera} id={@id} chip={@chip} />
    </svg>
    """
  end

  attr :shape, :any, required: true
  attr :camera, :any, required: true
  attr :id, :string, required: true
  attr :chip, :float, required: true

  defp shape(%{shape: {:poly, corners, class}} = assigns) do
    assigns =
      assign(assigns, points: Camera.points(assigns.camera, {0, 0}, corners), class: class)

    ~H"""
    <polygon points={@points} class={@class} {fills(@class, @id)} />
    """
  end

  defp shape(%{shape: {:line, points, class}} = assigns) do
    d = "M" <> Enum.map_join(points, " L", &Camera.points(assigns.camera, {0, 0}, [&1]))
    assigns = assign(assigns, d: d, class: class)

    ~H"""
    <path d={@d} class={@class} />
    """
  end

  defp shape(%{shape: {:wire, a, b, class}} = assigns) do
    {ax, ay} = Camera.at(assigns.camera, {0, 0}, a)
    {bx, by} = Camera.at(assigns.camera, {0, 0}, b)

    [a1, a2, c1, c2, b1, b2] =
      Enum.map([ax, ay, (ax + bx) / 2, max(ay, by) + 6, bx, by], &Camera.round1/1)

    assigns = assign(assigns, d: "M#{a1},#{a2} Q#{c1},#{c2} #{b1},#{b2}", class: class)

    ~H"""
    <path d={@d} class={@class} />
    """
  end

  defp shape(%{shape: {:circle, point, r, class}} = assigns) do
    {x, y} = Camera.at(assigns.camera, {0, 0}, point)
    assigns = assign(assigns, x: Camera.round1(x), y: Camera.round1(y), r: r, class: class)

    ~H"""
    <circle cx={@x} cy={@y} r={@r} class={@class} />
    """
  end

  defp shape(%{shape: {:chip, point, text, class}} = assigns) do
    {x, y} = Camera.at(assigns.camera, {0, 0}, point)
    move = "translate(#{Camera.round1(x)} #{Camera.round1(y)}) scale(#{assigns.chip})"
    w = chip_w(text)

    assigns =
      assign(assigns,
        move: move,
        text: text,
        x: Camera.round1(-w / 2),
        w: Camera.round1(w),
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
  defp fills("s-grass", id), do: [fill: "url(##{id}-s-grass)"]
  defp fills("s-glass", id), do: [fill: "url(##{id}-s-glass)"]
  defp fills("s-pv", id), do: [fill: "url(##{id}-s-pv)"]
  defp fills("s-shadow", id), do: [filter: "url(##{id}-blur)"]
  defp fills(_class, _id), do: []

  defp chip_w(text), do: String.length(text) * 5.6 + 14

  defp height(parts), do: parts.floors * @floor

  # The shapes of the house and of its lot, in the order of the paint (from
  # the back to the front, by hand for each object): the shapes behind the
  # flows of the power, and the shapes in front of them.
  defp house_shapes(parts) do
    back =
      lot() ++
        pole() ++
        tree({14.4, -1.6}, 1.0) ++
        ground(parts) ++
        shadow(parts) ++
        building(parts) ++
        garage(parts) ++
        meter(parts) ++
        yard_panels(parts) ++
        ac(parts) ++
        stations(parts)

    # The van is behind the car, on its left.
    front =
      bushes() ++
        person() ++
        if(parts.van, do: van_body({van_x(parts), 7.3}, parts.van, Camera.house()), else: []) ++
        car(parts) ++
        tree({-2.1, 12.4}, 0.8)

    {back, front}
  end

  # The van and the car share the drive.
  defp van_x(%{car: true}), do: 10.7
  defp van_x(_parts), do: 11.6

  defp lot do
    {x0, x1, y0, y1} = @lot
    slab = Geometry.box({x0, y0, -@slab}, {x1 - x0, y1 - y0, @slab})
    turf = Geometry.box({x0, y0, -0.25}, {x1 - x0, y1 - y0, 0.25})

    [
      {:poly, slab.front, "s-dirt-l"},
      {:poly, slab.side, "s-dirt-r"},
      {:poly, turf.front, "s-turf-l"},
      {:poly, turf.side, "s-turf-r"},
      {:poly, slab.top, "s-grass"}
    ]
  end

  # The pole of the grid, at the back on the right.
  defp pole do
    post = Geometry.box({18.0, -2.1, 0.0}, {0.25, 0.25, 7.0})
    arm = Geometry.box({17.3, -2.0, 6.4}, {1.6, 0.12, 0.12})
    [{:poly, post.front, "s-pole-l"}, {:poly, post.side, "s-pole-r"}] ++ faces(arm, "s-pole")
  end

  # A tree of low polygons: a trunk and two cones.
  defp tree({x, y}, k) do
    trunk = Geometry.box({x - 0.12 * k, y - 0.12 * k, 0.0}, {0.24 * k, 0.24 * k, 1.2 * k})
    top = {x, y, 5.2 * k}

    cone = fn z, r ->
      left = {x - r, y + r, z}
      front = {x + r, y + r, z}
      right = {x + r, y - r, z}
      [{:poly, [left, front, top], "s-leaf-l"}, {:poly, [front, right, top], "s-leaf-r"}]
    end

    [{:poly, trunk.front, "s-trunk-l"}, {:poly, trunk.side, "s-trunk-r"}] ++
      cone.(1.0 * k, 1.5 * k) ++ cone.(2.6 * k, 1.1 * k)
  end

  # The panels in the yard: rows that face the front (the south).
  defp yard_panels(%{yard: yard}) do
    case yard.station + yard.grid do
      0 ->
        []

      watts ->
        for i <- 0..(count(watts, @panel_w, 8) - 1),
            shape <- yard_panel({15.6 + rem(i, 3) * 1.15, 3.6 - div(i, 3) * 1.9}),
            do: shape
    end
  end

  defp yard_panel({x, y}) do
    low = {x, y, 0.5}
    high = {x, y - 1.2, 1.3}
    leg = Geometry.box({x + 0.45, y - 1.1, 0.0}, {0.08, 0.08, 1.3})

    [
      {:poly, leg.side, "s-pole-r"},
      {:poly,
       [low, Geometry.add(low, {1.0, 0.0, 0.0}), Geometry.add(high, {1.0, 0.0, 0.0}), high],
       "s-pv"}
    ]
  end

  # The paths: the walk to the door, the drive to the garage, and the pool.
  defp ground(parts) do
    {_x0, _x1, _y0, y1} = @lot
    walk = Geometry.box({4.6, @d, 0.0}, {1.3, y1 - @d, 0.02})

    drive =
      if parts.garage or parts.car or parts.van,
        do: [{:poly, Geometry.box({10.5, @d, 0.0}, {4.4, y1 - @d, 0.02}).top, "s-drive"}],
        else: []

    pool =
      if parts.pool,
        do: [
          {:poly, Geometry.box({-2.4, 8.4, 0.0}, {5.0, 3.2, 0.05}).top, "s-rim"},
          {:poly, Geometry.box({-2.0, 8.75, 0.0}, {4.2, 2.5, 0.06}).top, "s-water"}
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
    walls = Geometry.box({0.0, 0.0, 0.0}, {@w, @d, h})
    base = Geometry.box({0.0, 0.0, 0.0}, {@w, @d, 0.35})
    ridge = @d / 2
    top = h + @rise
    back = [{-0.4, -@eave, h}, {@w, -@eave, h}, {@w, ridge, top}, {-0.4, ridge, top}]
    front = [{-0.4, @d + @eave, h}, {@w, @d + @eave, h}, {@w, ridge, top}, {-0.4, ridge, top}]

    [
      {:poly, back, "s-roof-b"},
      {:poly, walls.front, "s-wall-l"},
      {:poly, walls.side, "s-wall-r"},
      {:poly, base.front, "s-base-l"},
      {:poly, base.side, "s-base-r"}
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
  defp fascia(a, b), do: [a, b, Geometry.add(b, {0, 0, -0.22}), Geometry.add(a, {0, 0, -0.22})]

  # A line between two floors, on the two walls that show.
  defp bands(parts) do
    for f <- 1..(parts.floors - 1)//1,
        {face, class} <- [{:front, "s-band-l"}, {:side, "s-band-r"}] do
      band = Geometry.box({0.0, 0.0, f * @floor - 0.08}, {@w, @d, 0.16})
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
    plane = &Geometry.on_plane(corner, along, {0, 0, 1}, &1, &2)

    [
      {:poly, plane.({-0.1, -0.1}, {1.5, 1.6}), frame},
      {:poly, plane.({0.0, 0.0}, {1.3, 1.4}), "s-glass"},
      {:poly, plane.({0.62, 0.0}, {0.06, 1.4}), frame}
    ]
  end

  # A round window in the gable.
  defp gable_window(h, ridge) do
    [
      {:poly, Geometry.circle({@w, ridge, h + 1.0}, {0, 1, 0}, {0, 0, 1}, 0.55), "s-frame-r"},
      {:poly, Geometry.circle({@w, ridge, h + 1.0}, {0, 1, 0}, {0, 0, 1}, 0.42), "s-glass"}
    ]
  end

  # The door, its roof, and its step.
  defp door do
    plane = &Geometry.on_plane({4.7, @d, 0.0}, {1, 0, 0}, {0, 0, 1}, &1, &2)

    [
      {:poly, plane.({-0.12, 0.0}, {1.34, 2.32}), "s-frame"},
      {:poly, plane.({0.0, 0.0}, {1.1, 2.2}), "s-door"},
      {:poly, plane.({0.15, 1.3}, {0.8, 0.6}), "s-glass"},
      {:poly, plane.({0.86, 1.0}, {0.1, 0.1}), "s-knob"}
    ] ++
      faces(Geometry.box({4.4, @d, 0.0}, {1.7, 0.6, 0.16}), "s-step") ++
      faces(Geometry.box({4.3, @d, 2.45}, {1.9, 0.7, 0.14}), "s-fascia")
  end

  # The panels on the front of the roof: rows from the eave, at the middle.
  defp roof_panels(%{roof: roof}, h, ridge) do
    case roof.station + roof.grid do
      0 -> []
      watts -> roof_panels(count(watts, @panel_w, 16), h, ridge)
    end
  end

  defp roof_panels(n, h, ridge) do
    slope = {0.0, -(@d + @eave - ridge), @rise}
    up = Geometry.scale(slope, 1 / :math.sqrt(elem(slope, 1) ** 2 + @rise ** 2))
    eave = {-0.4, @d + @eave, h + 0.04}

    for i <- 0..(n - 1) do
      row = div(i, 8)
      x = (@w + 0.4 - min(n - row * 8, 8) * 1.12) / 2 + rem(i, 8) * 1.12

      {:poly, Geometry.on_plane(eave, {1, 0, 0}, up, {x, 0.45 + row * 1.85}, {1.04, 1.75}),
       "s-pv"}
    end
  end

  # The count of panels in a picture: one for each `size` W (at least one),
  # at most `max`.
  defp count(watts, size, max), do: watts |> div(size) |> max(1) |> min(max)

  # The garage: a box with a flat roof, and its door.
  defp garage(%{garage: false}), do: []

  defp garage(_parts) do
    {x, y, w, d, h} = @garage
    body = Geometry.box({x, y, 0.0}, {w, d, h})
    base = Geometry.box({x, y, 0.0}, {w, d, 0.35})
    plane = &Geometry.on_plane({x + 0.6, @d, 0.0}, {1, 0, 0}, {0, 0, 1}, &1, &2)

    [
      {:poly, body.front, "s-wall-l"},
      {:poly, body.side, "s-wall-r"},
      {:poly, base.front, "s-base-l"},
      {:poly, base.side, "s-base-r"},
      {:poly, plane.({-0.1, 0.0}, {4.2, 2.35}), "s-frame"},
      {:poly, plane.({0.0, 0.0}, {4.0, 2.2}), "s-gdoor"}
    ] ++
      for(k <- 1..3, do: {:poly, plane.({0.0, k * 0.55}, {4.0, 0.04}), "s-gline"}) ++
      faces(Geometry.box({x - 0.05, y - 0.05, h}, {w + 0.1, d + 0.1, 0.2}), "s-fascia")
  end

  # The meter on the wall at the right, and the switch of the panel on the
  # front wall, next to the stations. A station that powers the circuits of
  # the house with no switch has its inlet there.
  defp meter(parts) do
    {x, y} = meter_at(parts)
    glass = Geometry.circle({x + 0.19, y + 0.25, 1.75}, {0, 1, 0}, {0, 0, 1}, 0.15)

    box =
      cond do
        parts.switch -> faces(Geometry.box({8.85, @d, 1.15}, {0.7, 0.15, 0.85}), "s-meter")
        parts.panel -> faces(Geometry.box({8.85, @d, 1.35}, {0.3, 0.12, 0.4}), "s-meter")
        true -> []
      end

    faces(Geometry.box({x, y, 1.3}, {0.18, 0.5, 0.7}), "s-meter") ++
      [{:poly, glass, "s-glass"}] ++ box
  end

  defp meter_at(%{garage: true}), do: {@w + 5.2, 3.4}
  defp meter_at(_parts), do: {@w, 2.4}

  # The AC on the ground, on the right side.
  defp ac(%{ac: false}), do: []

  defp ac(parts) do
    {x, y} = if parts.garage, do: {@w + 5.6, 5.4}, else: {@w + 0.5, 4.6}
    fan = Geometry.circle({x + 0.5, y + 0.5, 0.81}, {1, 0, 0}, {0, 1, 0}, 0.36)
    faces(Geometry.box({x, y, 0.0}, {1.0, 1.0, 0.8}), "s-ac") ++ [{:poly, fan, "s-fan"}]
  end

  # The stations, at the front wall: each with its extra batteries under it.
  defp stations(parts) do
    for {{_kwh, extra}, i} <- Enum.with_index(Enum.take(parts.stations, 2)),
        shape <- station({6.4 + i * 0.95, @d + 0.15}, extra),
        do: shape
  end

  defp station({x, y}, extra) do
    base = if extra, do: 0.42, else: 0.0

    screen =
      Geometry.on_plane({x, y + 0.5, base}, {1, 0, 0}, {0, 0, 1}, {0.12, 0.34}, {0.56, 0.12})

    pack = if extra, do: faces(Geometry.box({x, y, 0.0}, {0.8, 0.5, 0.38}), "s-station"), else: []

    pack ++
      faces(Geometry.box({x, y, base}, {0.8, 0.5, 0.62}), "s-station") ++
      [{:poly, screen, "s-screen"}]
  end

  # The top, the front and the side of a box, with a class for each: the
  # camera of the house has the front in the light.
  defp faces(box, class), do: faces(box, class, Camera.house())

  defp faces(box, class, camera),
    do: for({corners, class} <- Camera.faces(camera, box, class), do: {:poly, corners, class})

  # Bushes at the front wall.
  defp bushes, do: for(x <- [0.9, 2.6, 8.9], do: {:circle, {x, @d + 0.5, 0.35}, 7, "s-bush"})

  # The user, at the door.
  defp person do
    body = Geometry.box({5.05, @d + 1.4, 0.0}, {0.4, 0.3, 1.25})

    [
      {:poly, body.front, "s-shirt-l"},
      {:poly, body.side, "s-shirt-r"},
      {:circle, {5.25, @d + 1.55, 1.55}, 2.6, "s-skin"}
    ]
  end

  # An electric car in the drive (on the right of a van).
  defp car(%{car: false}), do: []

  defp car(parts) do
    {x, y} = if parts.van, do: {13.0, 7.5}, else: {11.8, 8.2}
    l = 4.5

    roof = [
      {x + 0.2, y + 1.5, 1.5},
      {x + 1.6, y + 1.5, 1.5},
      {x + 1.6, y + 3.0, 1.5},
      {x + 0.2, y + 3.0, 1.5}
    ]

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
      faces(Geometry.box({x, y, 0.28}, {1.8, l, 0.7}), "s-car") ++
      [{:poly, side, "s-vglass"}, {:poly, shield, "s-vglass"}, {:poly, roof, "s-car-t"}] ++
      lights({x, y + l, 0.6}, 1.8)
  end

  # The wheels on the side at the right, at x.
  defp wheels(x, ys, r) do
    for y <- ys,
        {radius, class} <- [{r, "s-tire"}, {r * 0.5, "s-hub"}],
        do: {:poly, Geometry.circle({x + 0.02, y, r}, {0, 1, 0}, {0, 0, 1}, radius), class}
  end

  # The lights at the front of a car or a van.
  defp lights({x, y, z}, w) do
    for s <- [0.15, w - 0.45] do
      {:poly, Geometry.on_plane({x, y + 0.01, z}, {1, 0, 0}, {0, 0, 1}, {s, 0.0}, {0.3, 0.14}),
       "s-lamp"}
    end
  end

  # A camper van, from its back corner at x, y, with the front to +y: the
  # wheels, the side with its windows and its door, the roof (with panels
  # and a fan), the windshield, the hood, and the front. The camera gives
  # the light of the side and of the front.
  defp van_body({x, y}, parts, camera) do
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

    front = Geometry.on_plane({x, nose, low}, {1, 0, 0}, {0, 0, 1}, {0.0, 0.0}, {w, 1.0})
    plane = &Geometry.on_plane({x + w + 0.01, y, low}, {0, 1, 0}, {0, 0, 1}, &1, &2)

    wheels(x + w, [y + 1.1, y + 5.1], 0.42) ++
      [
        {:poly, side, "s-van-" <> Camera.light(camera, {1, 0, 0})},
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
        {:poly, front, "s-van-" <> Camera.light(camera, {0, 1, 0})}
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
          {:poly, Geometry.on_plane(corner, {1, 0, 0}, {0, 1, 0}, at, {0.92, 1.5}), "s-pv"}
        end
      else
        []
      end

    fan =
      if parts.fan,
        do: faces(Geometry.box({x + 0.75, y + 3.4, @van_h}, {0.6, 0.6, 0.18}), "s-ac"),
        else: []

    panels ++ fan
  end

  # The label of the kWh of the stations: on the open ground at the front,
  # clear of the van and of the car.
  @kwh_chip {5.2, 12.8, 0.0}

  # The flows of the power (lines), and the labels (chips), as the model of
  # the power has them (`DIY.Power`):
  #
  # - the grid to the meter;
  # - the panels on the roof, down the corner of the house: to the stations,
  #   or into the house with a grid-tie inverter;
  # - the panels in the yard, along the ground: to the stations, or to the
  #   meter with a grid-tie inverter;
  # - the stations to the switch of the panel, when a station powers the
  #   circuits of the house through an inlet.
  #
  # Panels on a station that is not there (in a van) give no flow.
  defp flows(parts) do
    h = height(parts)
    {mx, my} = meter_at(parts)
    pole = {18.1, -2.0, 6.4}
    meter = {mx + 0.2, my + 0.25, 1.65}
    stations = parts.stations != []
    to_station = {7.2, @d + 0.4, 0.6}
    corner = [{9.8, @d + @eave, h - 0.2}, {9.8, @d + 0.2, 0.6}]
    # The flow from the yard goes on the right of the AC.
    yard = [{16.9, 3.7, 0.45}, {16.9, @d + 0.3, 0.05}]

    lines =
      [{:wire, pole, meter, "s-wire"}, {:wire, pole, meter, "s-flow s-flow-grid"}] ++
        flow(parts.roof.station > 0 and stations, corner ++ [to_station], "s-flow-sun") ++
        flow(parts.roof.grid > 0, corner, "s-flow-sun") ++
        flow(
          parts.yard.station > 0 and stations,
          yard ++ [{8.0, @d + 0.3, 0.05}, to_station],
          "s-flow-sun"
        ) ++
        flow(parts.yard.grid > 0, [{16.1, 3.7, 0.45}, {mx + 0.2, 3.7, 0.45}, meter], "s-flow-sun") ++
        flow(
          parts.panel,
          [{6.8, @d + 0.4, station_top(parts)}, {6.8, @d + 0.2, 1.55}, {8.85, @d + 0.2, 1.55}],
          "s-flow-battery"
        )

    roof = parts.roof.station + parts.roof.grid
    yard_w = parts.yard.station + parts.yard.grid

    chips =
      [{:chip, Geometry.add(pole, {0, 0, 0.9}), "Grid", "s-chip"}] ++
        if(roof > 0, do: [{:chip, {4.6, 5.6, h + 1.9}, kw(roof), "s-chip"}], else: []) ++
        if(yard_w > 0, do: [{:chip, yard_chip(yard_w), kw(yard_w), "s-chip"}], else: []) ++
        if(stations, do: [{:chip, @kwh_chip, kwh(parts.stations), "s-chip"}], else: [])

    # A thin line goes from the label of the kWh to the stations.
    leader = if stations, do: [{:line, [@kwh_chip, {6.6, @d + 0.7, 0.0}], "s-leader"}], else: []

    {lines ++ leader, chips}
  end

  # The label of the panels in the yard: above the top of the back row.
  defp yard_chip(watts) do
    rows = div(count(watts, @panel_w, 8) + 2, 3)
    {17.2, 2.4 - 1.9 * (rows - 1), 3.3}
  end

  defp flow(true, points, class), do: [{:line, points, "s-flow " <> class}]
  defp flow(false, _points, _class), do: []

  defp station_top(parts),
    do: if(Enum.any?(parts.stations, &elem(&1, 1)), do: 1.02, else: 0.62)

  defp kwh(stations),
    do:
      "#{stations |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> Kernel./(1) |> Float.round(1) |> Format.value()} kWh"

  defp kw(watts) when watts >= 1000, do: "#{Format.value(Float.round(watts / 1000, 1))} kW"
  defp kw(watts), do: "#{watts} W"
end
