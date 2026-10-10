defmodule DIYWeb.Stage do
  @moduledoc """
  An item in front of the person: the stage. A tap on an item of the plan
  does not open a card. The item comes out of the house, turns to the
  person, and shows its panel: its use, and the numbers that the person can
  change.

  The server draws the model of the item (`DIYWeb.Icon.Shapes`) from
  #{12} cameras, as the frames of a flipbook. The first camera is the
  camera of the house (`DIYWeb.Camera.house/0`), so the first frame looks
  as the item on the plan. The last camera looks at the front of the item, or
  down at its top for a panel on the top. Each frame has the center of the
  model at the same point, so the model turns in place.

  The hook `Stage` (`assets/js/stage.js`) puts the first frame on the item
  of the plan. The first frame is the model of the kind, at its own size
  and with no turn. So an item with a turn, or with a size of its own,
  changes a little at the start. Then the hook moves the model to the
  front of the page, and shows the frames one after the other while it
  moves. A close does the same in the other direction.

  The panel is on the item: on its screen, or on a label on its front
  (`region/1`). It is in the style of the item (`style/1`). It is the LED
  screen of a hub, the screen of a TV or of a computer, or a printed label. The
  hook puts the panel on its place on the last frame. The model comes as
  near as necessary to make the panel large enough to read.
  """
  use DIYWeb, :html

  alias DIYWeb.{Camera, Icon}
  alias DIYWeb.Icon.Shapes

  # The frames of the flipbook, and the units of the largest side of the
  # drawing.
  @count 12
  @size 100

  # The items with a screen: the place of the screen on the model, in
  # meters. A screen on the front is in the plane y, from x, z. A screen on
  # the top is in the plane z, from x, y.
  @screens %{
    "tv" => {:front, {0.015, 0.137, 0.135}, {1.09, 0.57}},
    "computer" => {:front, {0.015, 0.107, 0.135}, {0.58, 0.358}},
    "microwave" => {:front, {0.03, 0.464, 0.04}, {0.42, 0.28}},
    "power_station" => {:front, {0.03, 0.267, 0.05}, {0.565, 0.28}},
    "smart_meter" => {:front, {0.035, 0.15, 0.08}, {0.18, 0.18}},
    "cpap" => {:top, {0.04, 0.012, 0.111}, {0.12, 0.128}},
    "home_assistant" => {:top, {0.0078, 0.0078, 0.0256}, {0.086, 0.086}}
  }

  @doc "The number of frames of the flipbook."
  def frame_count, do: @count

  @doc """
  The style of the panel of a kind of item:

  - `:led`: the LED screen of a Home Assistant hub;
  - `:screen`: the screen of an item with a screen;
  - `:label`: a printed label, as on the other items.
  """
  def style("home_assistant"), do: :led
  def style(type) when is_map_key(@screens, type), do: :screen
  def style(_type), do: :label

  @doc """
  The place of the panel on the model of a kind: its screen, or a label on
  its front. A label is at the middle of the width (3/4 of it), and a
  little over the middle of the height. Its height is 0.6 of its width at
  least, so that the panel is large enough to read. A label that is too
  high for the front hangs from the top of the front, as a tag.
  """
  def region(type) do
    case @screens do
      %{^type => region} ->
        region

      _none ->
        {{x0, _y0, z0}, {x1, y1, z1}} = Shapes.bounds(Shapes.model(type))
        w = (x1 - x0) * 0.75
        h = max(min((z1 - z0) * 0.6, w * 1.3), w * 0.6)
        z = min(z0 + (z1 - z0) * 0.58 - h / 2, z1 - h)
        {:front, {x0 + (x1 - x0 - w) / 2, y1 + 0.003, z}, {w, h}}
    end
  end

  # Three corners of a place on a model, as the camera sees them. They are
  # at the top left, at the top right, and at the bottom left.
  defp corners({:front, {x, y, z}, {w, h}}), do: [{x, y, z + h}, {x + w, y, z + h}, {x, y, z}]
  defp corners({:top, {x, y, z}, {w, d}}), do: [{x, y, z}, {x + w, y, z}, {x, y + d, z}]

  @doc """
  The cameras of the frames: from the camera of the house to the panel.
  The last camera looks at the panel, a little from the side and from over
  it, so the item keeps its depth. For a panel on the top (a hub), it looks
  down at the top, and the front shows too.
  """
  def cameras(type) do
    house = Camera.house()
    {yaw, pitch} = if elem(region(type), 0) == :top, do: {88.0, 58.0}, else: {84.0, 10.0}

    for i <- 0..(@count - 1) do
      t = i / (@count - 1)

      Camera.new(
        :stage,
        house.yaw + (yaw - house.yaw) * t,
        house.pitch + (pitch - house.pitch) * t
      )
    end
  end

  @doc """
  The frames of the model of a kind:

  - `view`: the box of all the frames (`{x, y, w, h}`), for the `viewBox`;
  - `frames`: the polygons of each frame (`{points, class}`);
  - `start`: the box of the first frame (`{x, y, w, h}`), the drawing that
    is on the plan;
  - `region`: the place of the panel on the last frame (`region/1`), in
    units of the view (`{x0, y0, x1, y1, x2, y2}`). It is three corners:
    at the top left, at the top right and at the bottom left.

  The center of the model is at 0, 0 in each frame. The largest side of all
  the frames is #{@size} units. The frames of a kind do not change: the app
  keeps them after the first time (`:persistent_term`).
  """
  def frames(type) do
    # A new version of the code that draws the frames has new frames.
    key = {__MODULE__, type, Enum.map([__MODULE__, Shapes, Camera], & &1.module_info(:md5))}

    case :persistent_term.get(key, nil) do
      nil ->
        frames = draw(type)
        :persistent_term.put(key, frames)
        frames

      frames ->
        frames
    end
  end

  defp draw(type) do
    model = Shapes.model(type)
    {{x0, y0, z0}, {x1, y1, z1}} = Shapes.bounds(model)
    center = {(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2}
    cameras = cameras(type)

    drawn =
      for camera <- cameras do
        {cx, cy} = Camera.at(camera, {0, 0}, center)
        at = fn corner -> Camera.at(camera, {-cx, -cy}, corner) end

        for {:poly, corners, class} <- Shapes.shapes(type, camera),
            do: {Enum.map(corners, at), class}
      end

    # The corners of the panel on the last frame. A tag can go past the
    # model: the view has the whole panel too.
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

    %{
      view: view,
      frames: frames,
      start: {sx0 * k, sy0 * k, (sx1 - sx0) * k, (sy1 - sy0) * k},
      region: region |> Enum.flat_map(fn {x, y} -> [x * k, y * k] end) |> List.to_tuple()
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
      "the frames of the kind (`frames/1`): a LiveView keeps them, so a render does not send them again"

  attr :item, :string, required: true, doc: "the id of the item on the plan"
  attr :title, :string, required: true
  attr :close, :string, required: true, doc: "the page of the close link"
  attr :note, :string, default: nil, doc: "a short line under the title"
  slot :inner_block, required: true, doc: "the panel"

  @doc """
  The stage of an item: the frames of its model, and its panel. It is a
  modal dialog. The Escape key and the close link put the item back.
  """
  def stage(assigns) do
    assigns = assign(assigns, style: style(assigns.type), frame_count: @count)

    # The hook is on an element of each item: a different item has a new
    # hook, with a new flight.
    ~H"""
    <div id={@id} class="fixed inset-0 z-50">
      <div
        id={"#{@id}-#{@item}"}
        phx-hook="Stage"
        data-item={@item}
        data-start={numbers(@frames.start)}
        data-region={numbers(@frames.region)}
        class="stage absolute inset-0 overflow-y-auto"
      >
        <.link
          patch={@close}
          class="stage-scrim fixed inset-0"
          aria-label="Close"
          tabindex="-1"
          data-close
        ></.link>
        <div
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          class="stage-body"
        >
          <div
            id={"#{@id}-model-#{@item}"}
            phx-update="ignore"
            class="stage-model"
            data-view={numbers(@frames.view)}
            aria-hidden="true"
          >
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
          <section
            class={["stage-panel", "panel-#{@style}"]}
            data-style={@style}
            phx-mounted={JS.ignore_attributes(["style"])}
          >
            <header class="stage-head">
              <div class="min-w-0">
                <h2 id={"#{@id}-title"} class="stage-title">
                  <Icon.item type={@type} class="size-6" />{@title}
                </h2>
                <p :if={@note} class="stage-note">{@note}</p>
              </div>
              <.link patch={@close} class="stage-key stage-back" data-close>
                Put it back
              </.link>
            </header>
            {render_slot(@inner_block)}
          </section>
        </div>
      </div>
    </div>
    """
  end
end
