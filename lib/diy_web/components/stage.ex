defmodule DIYWeb.Stage do
  @moduledoc """
  An item in front of the person: the stage. A tap on an item of the plan
  brings the item out of the house. It turns to the person, and its panel
  opens next to it. The panel has its cost, its use, its place, and the
  numbers that the person can change. The panel is the same for each item
  (`DIYWeb.Inside`): the same parts in the same order, and the same
  controls.

  The server draws the model of the item (`DIYWeb.Icon.Shapes`) from #{12}
  cameras, as the frames of a flipbook. The first camera is the camera of
  the plan: of the house (`DIYWeb.Camera.house/0`), or of a van
  (`DIYWeb.Camera.van/0`). So the first frame looks as the item on the
  plan. The last camera looks at the front of the item, or down at
  its top for a screen on the top. Each frame has the center of the model at
  the same point, so the model turns in place.

  The hook `Stage` (`assets/js/stage.js`) puts the first frame on the item
  of the plan. The first frame is the model of the kind, at its own size and
  with no turn. So an item with a turn, or with a size of its own, changes a
  little at the start. The plan cuts a tree (`DIYWeb.Icon.TreeShapes`): its
  first frame is the whole tree, with its middle on the middle of the
  shadow of its crown. Then the hook moves the model to the front of the
  page, and shows the frames one after the other while it moves. A close
  does the same in the other direction.

  The panel is next to the model on a wide page, and under it on a narrow
  page. The item helps the person. A tag on the model (the `spots` of
  `frames/2`) shows where a number is on the real item. An example is the
  label on the back of a TV. A tap on the tag goes to the number in the
  panel.

  A Home Assistant hub is the only item with its own screen. The LED screen
  on its top asks for the address of Home Assistant (the slot `screen`). The
  hook puts it on the top of the last frame (`region/1`). The model comes
  near enough to read it.
  """
  use DIYWeb, :html

  alias DIY.Catalog
  alias DIYWeb.Camera
  alias DIYWeb.Icon.{Shapes, StationShapes, TreeShapes, VanShapes}

  # The frames of the flipbook, and the units of the largest side of the
  # drawing.
  @count 12
  @size 100

  # The items with a screen: the place of the screen on the model, in
  # meters. A screen on the front is in the plane y, from x, z. A screen on
  # the top is in the plane z, from x, y. The tags of a TV are on its
  # screen, and the LED screen of a hub is on its top.
  @screens %{
    "tv" => {:front, {0.015, 0.137, 0.135}, {1.09, 0.57}},
    "computer" => {:front, {0.015, 0.107, 0.135}, {0.58, 0.358}},
    "microwave" => {:front, {0.03, 0.464, 0.04}, {0.42, 0.28}},
    "power_station" => {:front, {0.045, 0.377, 0.262}, {0.461, 0.145}},
    "smart_meter" => {:front, {0.035, 0.15, 0.08}, {0.18, 0.18}},
    "cpap" => {:top, {0.04, 0.012, 0.111}, {0.12, 0.128}},
    "home_assistant" => {:top, {0.0078, 0.0078, 0.0256}, {0.086, 0.086}}
  }

  # The places on an item where the person finds a number: a label, or a
  # screen. Each has the key of the number, the text of its tag, and the
  # place in words. It also has a point of the face of the item
  # (`region/1`): u goes to the right, and v goes down, from 0 to 1.
  @spots %{
    "fridge" => [{"kwh_year", "kWh label", "the yellow EnergyGuide label", {0.5, 0.55}}],
    "freezer" => [{"kwh_year", "kWh label", "the yellow EnergyGuide label", {0.5, 0.55}}],
    "tv" => [
      {"hours", "Hours on", "the screen", {0.38, 0.4}},
      {"watts", "Watts", "the label on the back", {0.72, 0.84}}
    ],
    "computer" => [
      {"hours", "Hours on", "the screen", {0.38, 0.4}},
      {"watts", "Watts", "the label on the back", {0.72, 0.84}}
    ],
    "microwave" => [{"watts", "Watts", "the label inside the door", {0.5, 0.5}}]
  }

  @doc "The number of frames of the flipbook."
  def frame_count, do: @count

  @doc """
  The face of the model of a kind: its screen, or else the middle of its
  front (3/4 of its width, and all its height). The tags are on it. The
  LED screen of a hub is on its face, on its top. The face of a model of
  power station is its panel (`DIYWeb.Icon.StationShapes.screen/1`).
  """
  def region({"power_station", model}), do: StationShapes.screen(model)

  def region(type) do
    case @screens do
      %{^type => region} ->
        region

      _none ->
        {{x0, _y0, z0}, {x1, y1, z1}} = Shapes.bounds(Shapes.model(type))
        w = (x1 - x0) * 0.75
        {:front, {x0 + (x1 - x0 - w) / 2, y1 + 0.003, z0}, {w, z1 - z0}}
    end
  end

  # Three corners of a place on a model, as the camera sees them. They are
  # at the top left, at the top right, and at the bottom left.
  defp corners({:front, {x, y, z}, {w, h}}), do: [{x, y, z + h}, {x + w, y, z + h}, {x, y, z}]
  defp corners({:top, {x, y, z}, {w, d}}), do: [{x, y, z}, {x + w, y, z}, {x, y + d, z}]

  @doc """
  The cameras of the frames: from the camera of the plan to the face of
  the item. The plan is the house (`:house`, `DIYWeb.Camera.house/0`) or a
  van (`:van`, `DIYWeb.Camera.van/0`). The last camera looks at the face, a
  little from the side and from over it, so the item keeps its depth. For a
  face on the top (a hub), it looks down at the top, and the front shows
  too.
  """
  def cameras(type, plan \\ :house) do
    first = if plan == :van, do: Camera.van(), else: Camera.house()
    {yaw, pitch} = if elem(region(type), 0) == :top, do: {88.0, 58.0}, else: {84.0, 10.0}

    for i <- 0..(@count - 1) do
      t = i / (@count - 1)

      Camera.new(
        :stage,
        first.yaw + (yaw - first.yaw) * t,
        first.pitch + (pitch - first.pitch) * t
      )
    end
  end

  @doc """
  The frames of the model of a kind:

  - `view`: the box of all the frames (`{x, y, w, h}`), for the `viewBox`;
  - `frames`: the polygons of each frame (`{points, class}`);
  - `start`: the box of the first frame (`{x, y, w, h}`), the drawing that
    is on the plan;
  - `region`: the face on the last frame (`region/1`), in units of the
    view (`{x0, y0, x1, y1, x2, y2}`). It is three corners: at the top
    left, at the top right and at the bottom left;
  - `spots`: the tags on the last frame (`@spots`), each with its point
    `at` in units of the view.

  The center of the model is at 0, 0 in each frame. The largest side of all
  the frames is #{@size} units. The first frame is from the camera of the
  plan (`cameras/2`). The frames of a kind and a plan do not change: the
  app keeps them after the first time (`:persistent_term`).
  """
  def frames(type, plan \\ :house) when plan in [:house, :van] do
    # A new version of the code that draws the frames has new frames.
    modules =
      Enum.map(
        [__MODULE__, Shapes, StationShapes, TreeShapes, VanShapes, Camera],
        & &1.module_info(:md5)
      )

    key = {__MODULE__, type, plan, modules}

    case :persistent_term.get(key, nil) do
      nil ->
        frames = draw(type, plan)
        :persistent_term.put(key, frames)
        frames

      frames ->
        frames
    end
  end

  defp draw(type, plan) do
    model = Shapes.model(type)
    {{x0, y0, z0}, {x1, y1, z1}} = Shapes.bounds(model)
    center = {(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2}
    cameras = cameras(type, plan)

    drawn =
      for camera <- cameras do
        {cx, cy} = Camera.at(camera, {0, 0}, center)
        at = fn corner -> Camera.at(camera, {-cx, -cy}, corner) end

        for {:poly, corners, class} <- Shapes.shapes(type, camera),
            do: {Enum.map(corners, at), class}
      end

    # The corners of the face on the last frame. The view has the whole face.
    last = List.last(cameras)
    {lx, ly} = Camera.at(last, {0, 0}, center)
    region = Enum.map(corners(region(type)), &Camera.at(last, {-lx, -ly}, &1))
    [{ax, ay}, {bx, by}, {cx, cy}] = region
    panel = box([{[{ax, ay}, {bx, by}, {cx, cy}, {bx + cx - ax, by + cy - ay}], nil}])

    boxes = Enum.map(drawn, &box/1)
    {vx0, vy0, vx1, vy1} = union([panel | boxes])
    k = @size / max(vx1 - vx0, vy1 - vy0)
    pad = 2
    view = {vx0 * k - pad, vy0 * k - pad, (vx1 - vx0) * k + 2 * pad, (vy1 - vy0) * k + 2 * pad}

    frames =
      for polys <- drawn do
        for {points, class} <- polys, do: {points(points, k), class}
      end

    {sx0, sy0, sx1, sy1} = hd(boxes)

    spots =
      for {key, tag, where, {u, v}} <- Map.get(@spots, type, []) do
        at = {ax + u * (bx - ax) + v * (cx - ax), ay + u * (by - ay) + v * (cy - ay)}
        %{key: key, tag: tag, where: where, at: {elem(at, 0) * k, elem(at, 1) * k}}
      end

    %{
      view: view,
      frames: frames,
      start: {sx0 * k, sy0 * k, (sx1 - sx0) * k, (sy1 - sy0) * k},
      region: region |> Enum.flat_map(fn {x, y} -> [x * k, y * k] end) |> List.to_tuple(),
      spots: spots
    }
  end

  defp box(polys) do
    union(
      for {points, _class} <- polys do
        {xs, ys} = Enum.unzip(points)
        {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
      end
    )
  end

  defp union(boxes) do
    {Enum.min(Enum.map(boxes, &elem(&1, 0))), Enum.min(Enum.map(boxes, &elem(&1, 1))),
     Enum.max(Enum.map(boxes, &elem(&1, 2))), Enum.max(Enum.map(boxes, &elem(&1, 3)))}
  end

  defp numbers(tuple), do: tuple |> Tuple.to_list() |> Enum.map_join(" ", &round1/1)

  defp points(points, k),
    do: Enum.map_join(points, " ", fn {x, y} -> "#{round1(x * k)},#{round1(y * k)}" end)

  # A number with one decimal, as a string with no zero at the end. The
  # largest side is 100 units, so a step is 0.1% of it.
  defp round1(n) do
    n = Float.round(n * 1.0, 1)
    if n == trunc(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n)
  end

  attr :id, :string, default: "item-stage"
  attr :type, :string, required: true, doc: "the kind of the item"

  attr :frames, :map,
    required: true,
    doc:
      "the frames of the kind (`frames/2`): a LiveView keeps them, so a render does not send them again"

  attr :item, :string, required: true, doc: "the id of the item on the plan"
  attr :title, :string, required: true
  attr :close, :string, required: true, doc: "the page of the close link"
  attr :note, :string, default: nil, doc: "a short line under the title"

  attr :state, :string,
    default: nil,
    doc:
      "the state of the device of the item in Home Assistant (`on`, `off` or `unavailable`), for its model"

  slot :screen, doc: "the LED screen of a hub: on the top of its model"
  slot :inner_block, required: true, doc: "the panel"

  @doc """
  The stage of an item: the frames of its model, its tags, and its panel.
  It is a modal dialog. The Escape key, a tap next to the panel and the
  key Put it back put the item back.
  """
  def stage(assigns) do
    params = Map.new(Catalog.kind(assigns.type).params, &{&1.key, &1.label})

    assigns =
      assign(assigns,
        frame_count: @count,
        spots: for(spot <- assigns.frames.spots, do: Map.put(spot, :label, params[spot.key]))
      )

    # The hook is on an element of each item: a different item has a new
    # hook, with a new flight. The tags and the screen are in the dialog,
    # after the panel: a screen reader reads the title first. The name of a
    # tag starts with its text (WCAG 2.5.3).
    ~H"""
    <div id={@id} class="fixed inset-0 z-50">
      <div
        id={"#{@id}-#{@item}"}
        phx-hook="Stage"
        data-item={@item}
        data-start={numbers(@frames.start)}
        data-region={numbers(@frames.region)}
        data-screen={@screen != [] && "true"}
        data-ha={@state}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        class="stage absolute inset-0"
      >
        <.link
          patch={@close}
          class="stage-scrim fixed inset-0"
          aria-hidden="true"
          tabindex="-1"
          data-close
        ></.link>
        <%!-- The hook places the model with its style: a patch keeps it.
          The frames keep the frame that shows (phx-update="ignore"). --%>
        <div
          id={"#{@id}-model-#{@item}"}
          phx-mounted={JS.ignore_attributes(["style"])}
          class="stage-model"
          data-view={numbers(@frames.view)}
          aria-hidden="true"
        >
          <div id={frames_id(@id, @item, @frames)} phx-update="ignore" class="contents">
            <svg
              :for={{polys, i} <- Enum.with_index(@frames.frames)}
              viewBox={numbers(@frames.view)}
              class="stage-frame"
              data-frame={i}
              hidden={i != @frame_count - 1}
            >
              <polygon :for={{points, class} <- polys} points={points} class={class} />
            </svg>
          </div>
        </div>
        <section class="stage-panel" phx-mounted={JS.ignore_attributes(["style"])}>
          <div class="stage-scroll">
            <header class="stage-head">
              <div class="min-w-0">
                <h2 id={"#{@id}-title"} class="stage-title" tabindex="-1">{@title}</h2>
                <p :if={@note} class="stage-note">{@note}</p>
              </div>
              <.link patch={@close} class="stage-btn stage-back" data-close>Put it back</.link>
            </header>
            {render_slot(@inner_block)}
          </div>
        </section>
        <button
          :for={spot <- @spots}
          type="button"
          id={"#{@id}-spot-#{spot.key}"}
          class="stage-spot"
          data-spot={spot.key}
          data-at={numbers(spot.at)}
          aria-label={"#{spot.tag}: #{spot.label}, on #{spot.where}"}
          phx-mounted={JS.ignore_attributes(["style"])}
        >
          <span class="stage-spot-mark" aria-hidden="true">+</span>{spot.tag}
        </button>
        <div
          :if={@screen != []}
          id={"#{@id}-screen"}
          class="stage-screen"
          phx-mounted={JS.ignore_attributes(["style"])}
        >
          {render_slot(@screen)}
        </div>
      </div>
    </div>
    """
  end

  # The frames of the model stay (phx-update="ignore"). A new look of the
  # item (a busbar with a new number of positions) has new frames. They have
  # a new id, so the page gets them.
  defp frames_id(id, item, %{shown: {{_type, n}, _plan}}), do: "#{id}-frames-#{item}-#{n}"
  defp frames_id(id, item, _frames), do: "#{id}-frames-#{item}"
end
