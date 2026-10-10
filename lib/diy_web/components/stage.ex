defmodule DIYWeb.Stage do
  @moduledoc """
  An item in front of the person: the stage. A tap on an item of the plan
  does not open a card. The item comes out of the house, turns to the
  person, and shows its panel: its use, and the numbers that the person can
  change.

  The server draws the model of the item (`DIYWeb.Icon.Shapes`) from
  #{12} cameras, as the frames of a flipbook. The first camera is the
  camera of the house (`DIYWeb.Camera.house/0`), so the first frame is the
  drawing of the plan. The last camera looks at the front of the item, or
  down at its top for a panel on the top. Each frame has the center of the
  model at the same point, so the model turns in place.

  The hook `Stage` (`assets/js/stage.js`) puts the first frame on the item
  of the plan. Then it moves the model to the front of the page, and shows
  the frames one after the other while it moves. A close does the same in
  the other direction.

  The panel is in the style of the item (`style/1`). It is the LED screen
  of a hub, the screen of a TV or of a computer, or a printed label. It comes
  out of the front (or the top) of the model: its anchor (`frames/1`).
  """
  use DIYWeb, :html

  alias DIYWeb.{Camera, Icon}
  alias DIYWeb.Icon.Shapes

  # The frames of the flipbook, and the units of the largest side of the
  # drawing.
  @frames 12
  @size 100

  # The items with a screen, and the items with their panel on the top.
  @screens ~w(tv computer microwave power_station smart_meter cpap)
  @tops ~w(home_assistant)

  @doc "The number of frames of the flipbook."
  def frame_count, do: @frames

  @doc """
  The style of the panel of a kind of item:

  - `:led`: the LED screen of a Home Assistant hub;
  - `:screen`: the screen of an item with a screen;
  - `:label`: a printed label, as on the other items.
  """
  def style("home_assistant"), do: :led
  def style(type) when type in @screens, do: :screen
  def style(_type), do: :label

  @doc """
  The cameras of the frames: from the camera of the house to the front of
  the item, a little from over it. An item with its panel on its top ends
  with a camera over it.
  """
  def cameras(type) do
    house = Camera.house()
    {yaw, pitch} = if type in @tops, do: {89.0, 72.0}, else: {89.0, 12.0}

    for i <- 0..(@frames - 1) do
      t = i / (@frames - 1)

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
  - `anchor`: the point of the panel on the last frame (the center of the
    front, or of the top), in percent of the view.

  The center of the model is at 0, 0 in each frame. The largest side of all
  the frames is #{@size} units.
  """
  def frames(type) do
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

    boxes = Enum.map(drawn, &box/1)
    {vx0, vy0, vx1, vy1} = union(boxes)
    k = @size / max(vx1 - vx0, vy1 - vy0)
    pad = 2
    view = {vx0 * k - pad, vy0 * k - pad, (vx1 - vx0) * k + 2 * pad, (vy1 - vy0) * k + 2 * pad}

    frames =
      for polys <- drawn do
        for {points, class} <- polys, do: {points(points, k), class}
      end

    {sx0, sy0, sx1, sy1} = hd(boxes)

    anchor =
      if type in @tops,
        do: {elem(center, 0), elem(center, 1), z1},
        else: {elem(center, 0), y1, elem(center, 2)}

    last = List.last(cameras)
    {lx, ly} = Camera.at(last, {0, 0}, center)
    {ax, ay} = Camera.at(last, {-lx, -ly}, anchor)
    {vx, vy, vw, vh} = view

    %{
      view: view,
      frames: frames,
      start: {sx0 * k, sy0 * k, (sx1 - sx0) * k, (sy1 - sy0) * k},
      anchor: {(ax * k - vx) / vw * 100, (ay * k - vy) / vh * 100}
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

  defp numbers(tuple), do: tuple |> Tuple.to_list() |> Enum.map_join(" ", &round2/1)

  defp points(points, k),
    do: Enum.map_join(points, " ", fn {x, y} -> "#{round2(x * k)},#{round2(y * k)}" end)

  # A number with two decimals, as a string with no zero at the end.
  defp round2(n) do
    n = Float.round(n * 1.0, 2)
    if n == trunc(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n)
  end

  attr :id, :string, default: "item-stage"
  attr :type, :string, required: true, doc: "the kind of the item"
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
    %{view: view, frames: frames, start: start, anchor: {ax, ay}} = frames(assigns.type)

    assigns =
      assign(assigns,
        view: numbers(view),
        frames: Enum.with_index(frames),
        last: length(frames) - 1,
        start: numbers(start),
        anchor: numbers({ax, ay}),
        style: style(assigns.type)
      )

    ~H"""
    <div
      id={@id}
      phx-hook="Stage"
      data-item={@item}
      data-start={@start}
      data-anchor={@anchor}
      class="stage fixed inset-0 z-50 overflow-y-auto"
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
        class="stage-body relative mx-auto flex min-h-full w-full max-w-xl flex-col items-center gap-3 p-4"
      >
        <div
          id={"#{@id}-model-#{@item}"}
          phx-update="ignore"
          class="stage-model"
          data-view={@view}
          aria-hidden="true"
        >
          <svg
            :for={{polys, i} <- @frames}
            viewBox={@view}
            class="stage-frame"
            data-frame={i}
            hidden={i != @last}
          >
            <polygon :for={{points, class} <- polys} points={points} class={class} />
          </svg>
        </div>
        <section class={["stage-panel", "panel-#{@style}"]} data-style={@style}>
          <header class="flex items-start justify-between gap-2">
            <div>
              <h2 id={"#{@id}-title"} class="flex items-center gap-2 text-lg font-bold">
                <Icon.item type={@type} class="size-7" />{@title}
              </h2>
              <p :if={@note} class="stage-note text-sm">{@note}</p>
            </div>
            <.link patch={@close} class="stage-key stage-back" data-close>
              Put it back
            </.link>
          </header>
          {render_slot(@inner_block)}
        </section>
      </div>
    </div>
    """
  end
end
