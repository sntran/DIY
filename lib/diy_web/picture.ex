defmodule DIYWeb.Picture do
  @moduledoc """
  The picture of a shared house, for the preview of its link
  (docs/design.md, "The preview of a link"). It is a PNG of 1200 × 630
  pixels. It shows the floors of the house cut open (`DIYWeb.Cutaway`)
  in the sky of the link. The items that use the most kWh have labels
  (`DIYWeb.Picture.Labels`). At the right, it shows the numbers of the
  year and a bar for each month.

  The NIF resvg draws it (`DIY.Picture.NIF`). resvg reads no CSS of the
  page. Thus each shape of the SVG has its style in a `style` attribute,
  from `priv/picture/styles.json` (`scripts/picture-styles.mjs`).
  """
  use Gettext, backend: DIY.Gettext

  alias DIY.{Layout, Share}
  alias DIYWeb.{Camera, Cutaway, Format, Outside}
  alias DIYWeb.Picture.Labels

  @styles_path Path.expand("../../priv/picture/styles.json", __DIR__)
  @external_resource @styles_path
  @styles @styles_path |> File.read!() |> Jason.decode!()

  # The width of each letter of the fonts of the NIF, in parts of the size
  # of the font (`scripts/inter-widths.mjs`), and the widest.
  @widths_path Path.expand("../../priv/picture/inter_widths.json", __DIR__)
  @external_resource @widths_path
  @widths @widths_path |> File.read!() |> Jason.decode!() |> Map.new(fn [c, w] -> {c, w} end)
  @widest @widths |> Map.values() |> Enum.max()

  @width 1200
  @height 630

  # The box of the sky and the house in the picture: x, y, width and
  # height. Then the space around the house in the box, the space above it
  # for the labels, and the largest scale of the house.
  @house {32, 32, 668, 566}
  @pad 14
  @head 40
  @max_scale 2.5

  # The layers of the house that the picture always shows. The attic and
  # the roof show only with an item that has a label.
  @floors ~w(ground f2 f3)

  # The two floors that a shell joins: floor 1 and floor 2, and floor 2
  # and floor 3.
  @joined [{"ground", "f2"}, {"f2", "f3"}]

  # A label is a bubble with the numbers of its item, and a pointer down
  # to the item, as a tooltip. Then: the size of its text, the space at
  # its sides, and the height of the bubble. Then the height of the
  # pointer, which is also half of its width.
  @numbers_size 12
  @label_pad 9
  @bubble_h 24
  @pointer 7
  @radius 8
  # The largest space between the tip of a pointer and its item: the
  # space of `DIYWeb.Picture.Labels`. A label that is farther has a line.
  @gap_max 4
  # The largest distance at the side between the tip of a pointer and its
  # item. A bubble at the side of its item (`DIYWeb.Picture.Labels`) has
  # its tip 1 pixel from the item.
  @side_max 3

  # The colors of the page (app.css, the light theme).
  @paper "#faf7f2"
  @ink "#2b2118"
  @muted "#6b5e52"
  @bar "#e8843c"
  @pill "#fffaf2"
  @pill_line "#8a7a6a"

  @doc "The size of the picture in pixels."
  def size, do: {@width, @height}

  @doc """
  The style of each class of the picture in a scene (`day`, `sunset` or
  `night`) and a weather, from `priv/picture/styles.json`. Snow changes
  the style of some classes. With `inside`, the styles are for the house
  cut open: a window has the color of the sky, not of a lamp in the room.
  """
  def styles(scene \\ "day", weather \\ "sun", inside \\ false)

  def styles(scene, weather, true),
    do: Map.merge(styles(scene, weather), Map.fetch!(@styles, scene <> "-inside"))

  def styles(scene, "snow", false),
    do: Map.merge(styles(scene), Map.fetch!(@styles, scene <> "-snow"))

  def styles(scene, _weather, false), do: Map.fetch!(@styles, scene)

  @doc """
  The SVG of the picture of a shared house. The texts are in the locale
  of the process (`Gettext.put_locale/2`).
  """
  @spec svg(DIY.Build.t(), Share.summary()) :: String.t()
  def svg(build, summary) do
    IO.iodata_to_binary([
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}">),
      ~s(<rect width="#{@width}" height="#{@height}" fill="#{@paper}"/>),
      house(build, summary),
      numbers(build, summary),
      bars(summary),
      ~s(<text x="1160" y="600" text-anchor="end" font-size="22" font-weight="700" fill="#{@ink}">Small Steps Home</text>),
      "</svg>"
    ])
  end

  # The sky, the house cut open in it, and the labels. The box of the
  # house clips the sky, the rain and the snow. All the lines are under
  # all the labels.
  defp house(build, summary) do
    {parts, labels} = parts(build, summary)
    {x, y, w, h} = @house

    [
      ~s(<clipPath id="picture-house"><rect x="#{x}" y="#{y}" width="#{w}" height="#{h}"/></clipPath>),
      ~s|<g clip-path="url(#picture-house)">|,
      Enum.map(parts, fn {svg, scale} -> inline(svg, scale, summary.sky, true) end),
      "</g>",
      Enum.map(labels, &line/1),
      Enum.map(labels, &label/1)
    ]
  end

  @doc false
  # The parts of the house in the picture, with their classes, in their
  # order: each SVG with its scale. They are the sky, the house cut open,
  # the rain or the snow, and the light of a sunset. Then the labels in
  # their places. The tests read the classes of the parts.
  def parts(build, summary) do
    costs = Map.new(summary.items, &{&1.id, &1})
    view = layers(build, costs)
    {bx, by, bw, bh} = view.box
    {hx, hy, hw, hh} = @house
    {room_w, room_h} = {hw - 2 * @pad, hh - 2 * @pad - @head}
    scale = Enum.min([room_w / bw, room_h / bh, @max_scale])
    {w, h} = {bw * scale, bh * scale}
    {x, y} = {hx + (hw - w) / 2, hy + @pad + @head + (room_h - h) / 2}
    at = fn {px, py} -> {x + (px - bx) * scale, y + (py - by) * scale} end
    shapes = Outside.sky(@house, summary.sky)

    house =
      %{__changed__: nil, view: view, selected: nil, open: nil, states: %{}}
      |> Cutaway.cutaway()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
      # HEEx marks the root of a component with `phx-r`, an attribute with
      # no value: XML does not allow it. The picture has no script.
      |> String.replace(~r/ phx-r(?=[\s>\/])/, "")
      |> String.replace(~r/ phx-mounted="[^"]*"/, "")
      |> String.replace(
        "<svg ",
        ~s(<svg x="#{r(x)}" y="#{r(y)}" width="#{r(w)}" height="#{r(h)}" ),
        global: false
      )

    parts = [
      {sky_shapes(shapes.back), 1},
      {house, scale},
      {sky_shapes(shapes.fall), 1},
      {sky_shapes(shapes.glow), 1}
    ]

    {parts, labels(view, costs, at)}
  end

  # The layers of the house cut open, with no names of rooms, and the box
  # of their shapes. The lot is not in the picture: the rooms outside show
  # the yard. A floor under a floor has the shell that joins them
  # (`DIYWeb.Cutaway.shell/4`).
  defp layers(build, costs) do
    view = Cutaway.view(build)

    levels =
      for level <- view.levels,
          level.id in @floors or Enum.any?(level.objects, &labeled?(&1, costs)),
          do: %{level | labels: [], ground: []}

    levels =
      levels
      |> Enum.zip(tl(levels) ++ [nil])
      |> Enum.map(fn
        {%{id: id} = level, %{id: above_id} = above} when {id, above_id} in @joined ->
          %{level | shell: Cutaway.shell(view.camera, level, above, plan(build, above_id))}

        {level, _above} ->
          level
      end)

    points =
      Enum.flat_map(levels, fn level ->
        Enum.flat_map(level.low ++ level.rooms, & &1.polys) ++
          Enum.map(level.slabs, fn {points, class, _room} -> {points, class} end) ++
          Enum.flat_map(level.objects, & &1.polys) ++ level.shell
      end)

    %{view | levels: levels, box: bounds(points)}
  end

  defp labeled?(object, costs), do: object.kind == :item and Map.has_key?(costs, object.id)

  # The places of the walls of the shell of a floor
  # (`DIYWeb.Cutaway.shell/4`). They come from its rooms inside. A floor
  # with no room uses the box of the house. The back wall goes along the
  # rooms at the back of the floor, and the left wall along the rooms at
  # its left. So an upper floor over a part of the house (for example,
  # not over a room with one story) has walls only under it.
  defp plan(build, id) do
    case for(r <- build.rooms, r.plan, r.place == :indoor, Layout.layer(r) == id, do: r.plan) do
      [] -> walls([Layout.house_box(build)])
      plans -> walls(plans)
    end
  end

  defp walls(plans) do
    y = plans |> Enum.map(& &1.y) |> Enum.min()
    x = plans |> Enum.map(& &1.x) |> Enum.min()
    back = for p <- plans, p.y == y, do: p
    left = for p <- plans, p.x == x, do: p

    %{
      back:
        {back |> Enum.map(& &1.x) |> Enum.min(), back |> Enum.map(&(&1.x + &1.w)) |> Enum.max(),
         y},
      left:
        {x, left |> Enum.map(& &1.y) |> Enum.min(),
         left |> Enum.map(&(&1.y + &1.d)) |> Enum.max()}
    }
  end

  # The box {x, y, w, h} of polygons.
  defp bounds(polys) do
    {xs, ys} = polys |> Enum.flat_map(fn {points, _class} -> parse(points) end) |> Enum.unzip()
    {x0, x1} = Enum.min_max(xs)
    {y0, y1} = Enum.min_max(ys)
    {x0, y0, max(x1 - x0, 1.0), max(y1 - y0, 1.0)}
  end

  defp parse(points) do
    for pair <- String.split(points, " ", trim: true) do
      [x, y] = String.split(pair, ",")
      {number(x), number(y)}
    end
  end

  # A number of the points of a polygon: "140" or "140.5".
  defp number(text) do
    {n, ""} = Float.parse(text)
    n
  end

  # The labels of the items of the summary, in the box of the house: the
  # item with the most kWh first. `at` gives the place in the picture of a
  # point of the house.
  defp labels(view, costs, at) do
    {hx, hy, hw, hh} = @house

    view.levels
    |> Enum.flat_map(& &1.objects)
    |> Enum.filter(&labeled?(&1, costs))
    |> Enum.map(fn object ->
      %{kwh: kwh, cost: cost} = costs[object.id]
      {x0, y0, w, _h} = bounds(object.polys)
      {x, y} = at.({x0 + w / 2, y0})
      numbers = label_numbers(kwh, cost)
      width = width(numbers, @numbers_size) + 2 * @label_pad

      %{x: x, y: y, w: width, h: @bubble_h + @pointer, kwh: kwh, numbers: numbers}
    end)
    |> Enum.sort_by(&(-&1.kwh))
    |> Labels.place({hx + 6, hy + 6, hw - 12, hh - 12})
  end

  defp label_numbers(kwh, nil), do: gettext("%{kwh} a year", kwh: Format.kwh(kwh))

  defp label_numbers(kwh, cost),
    do: gettext("%{kwh} · %{cost} a year", kwh: Format.kwh(kwh), cost: Format.money(cost))

  @doc false
  # The width of a text: the sum of the widths of its code points, because
  # resvg moves on for each code point. Each width is the larger width of
  # the letter in Inter regular and bold (`priv/picture/inter_widths.json`).
  # A letter that is not in the fonts gets the width of W, the widest.
  def width(text, size) do
    for(<<c::utf8 <- text>>, reduce: 0, do: (sum -> sum + Map.get(@widths, c, @widest))) * size
  end

  @doc false
  # True when a placed label is just above its item: its pointer touches
  # the item, so it needs no line. `x` is the tip of its pointer.
  def just_above?(%{top: top, h: h} = label) do
    x = tip(label)
    abs(top + h - label.y) <= @gap_max and abs(x - label.x) <= @side_max
  end

  # The x of the tip of the pointer of a label: over its item, but not
  # under the round corners of the bubble.
  defp tip(%{left: left, w: w} = label),
    do: label.x |> max(left + @radius + @pointer) |> min(left + w - @radius - @pointer)

  # A label that is not just above its item has a thin line from the tip
  # of its pointer down to the item. All the lines are under all the
  # labels.
  defp line(%{top: top, h: h} = label) do
    x = tip(label)

    if just_above?(label),
      do: [],
      else: [
        ~s(<line x1="#{r(x)}" y1="#{r(top + h)}" x2="#{r(label.x)}" y2="#{r(label.y)}" stroke="#{@ink}" stroke-width="1.2" stroke-opacity="0.7"/>),
        ~s(<circle cx="#{r(label.x)}" cy="#{r(label.y)}" r="2.2" fill="#{@ink}"/>)
      ]
  end

  # The bubble and its pointer are one path, so the line around them has
  # no gap.
  defp label(%{left: left, top: top, w: w} = label) do
    {right, bottom, x, k} = {left + w, top + @bubble_h, tip(label), @radius}

    d =
      "M#{r(left + k)},#{r(top)} H#{r(right - k)} A#{k},#{k} 0 0 1 #{r(right)},#{r(top + k)} " <>
        "V#{r(bottom - k)} A#{k},#{k} 0 0 1 #{r(right - k)},#{r(bottom)} " <>
        "H#{r(x + @pointer)} L#{r(x)},#{r(bottom + @pointer)} L#{r(x - @pointer)},#{r(bottom)} " <>
        "H#{r(left + k)} A#{k},#{k} 0 0 1 #{r(left)},#{r(bottom - k)} " <>
        "V#{r(top + k)} A#{k},#{k} 0 0 1 #{r(left + k)},#{r(top)} Z"

    [
      ~s(<path d="#{d}" fill="#{@pill}" stroke="#{@pill_line}" stroke-width="1"/>),
      text(r(left + w / 2), r(top + 16.5), @numbers_size, 600, @ink, label.numbers, "middle")
    ]
  end

  # The shapes of the sky (`DIYWeb.Outside.sky/2`), with their classes.
  defp sky_shapes(shapes) do
    Enum.map_join(shapes, fn
      {:rect, a} ->
        ~s(<rect x="#{r(a.x)}" y="#{r(a.y)}" width="#{r(a.w)}" height="#{r(a.h)}" class="#{a.class}"/>)

      {:circle, a} ->
        ~s(<circle cx="#{r(a.cx)}" cy="#{r(a.cy)}" r="#{r(a.r)}" class="#{a.class}"/>)

      {:ellipse, a} ->
        ~s(<ellipse cx="#{r(a.cx)}" cy="#{r(a.cy)}" rx="#{r(a.rx)}" ry="#{r(a.ry)}" class="#{a.class}"/>)

      {:path, a} ->
        ~s(<path d="#{a.d}" class="#{a.class}"/>)
    end)
  end

  defp r(n), do: Camera.round1(n)

  @doc "The PNG of the picture of a shared house (`svg/2`)."
  @spec png(DIY.Build.t(), Share.summary()) :: {:ok, binary()} | {:error, String.t()}
  def png(build, summary), do: DIY.Picture.NIF.render(svg(build, summary), @width)

  @doc """
  The title of a shared house, for the preview of its link: the house,
  its place and its kWh of a year.
  """
  @spec title(DIY.Build.t(), Share.summary()) :: String.t()
  def title(build, summary) do
    kwh = Format.int(Share.year(summary))

    case {build.house, build.zip} do
      {%{size: size}, zip} when is_binary(zip) ->
        gettext("A house of %{size} sq ft in %{zip}: %{kwh} kWh a year",
          size: Format.int(size),
          zip: zip,
          kwh: kwh
        )

      {%{size: size}, nil} ->
        gettext("A house of %{size} sq ft: %{kwh} kWh a year", size: Format.int(size), kwh: kwh)
    end
  end

  # The numbers of the year, at the right of the house.
  defp numbers(build, summary) do
    place =
      if build.zip,
        do:
          gettext("A house of %{size} sq ft in %{zip}",
            size: Format.int(build.house.size),
            zip: build.zip
          ),
        else: gettext("A house of %{size} sq ft", size: Format.int(build.house.size))

    cost =
      if summary.cost do
        [
          text(724, 300, 52, 700, @ink, Format.money(summary.cost)),
          text(724, 334, 24, 400, @muted, gettext("for the electricity of a year"))
        ]
      else
        []
      end

    [
      text(724, 100, 26, 400, @muted, place),
      text(724, 182, 64, 700, @ink, Format.kwh(Share.year(summary))),
      text(724, 216, 24, 400, @muted, gettext("of electricity in a year")),
      cost
    ]
  end

  # A bar for each month, from January.
  defp bars(summary) do
    top = summary.months |> Enum.max() |> max(1)
    names = month_letters()

    for {kwh, i} <- Enum.with_index(summary.months) do
      x = 724 + i * 36
      h = Float.round(110 * kwh / top, 1)

      [
        ~s(<rect x="#{x}" y="#{Float.round(530 - h, 1)}" width="28" height="#{h}" rx="3" fill="#{@bar}"/>),
        text(x + 14, 556, 16, 400, @muted, Enum.at(names, i), "middle")
      ]
    end
  end

  @doc "The short label of each month, from January, in the locale of the process."
  def month_letters do
    [
      gettext("J"),
      gettext("F"),
      gettext("M"),
      gettext("A"),
      pgettext("May", "M"),
      pgettext("June", "J"),
      pgettext("July", "J"),
      pgettext("August", "A"),
      gettext("S"),
      gettext("O"),
      gettext("N"),
      gettext("D")
    ]
  end

  defp text(x, y, size, weight, color, value, anchor \\ "start") do
    [
      ~s(<text x="#{x}" y="#{y}" font-size="#{size}" font-weight="#{weight}" fill="#{color}" text-anchor="#{anchor}">),
      escape(value),
      "</text>"
    ]
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc """
  The SVG with the style of each class in a `style` attribute, and no
  `class`. A stroke that does not scale on the page
  (`vector-effect: non-scaling-stroke`) gets the width for the scale of
  the picture: resvg does not know `vector-effect`.
  """
  @spec inline(String.t(), number(), map(), boolean()) :: String.t()
  def inline(svg, scale, sky \\ %{time: "day", weather: "sun"}, inside \\ false) do
    styles = styles(sky.time, sky.weather, inside)

    Regex.replace(~r/ class="([^"]*)"/, svg, fn _all, classes ->
      classes |> String.split() |> style(scale, styles)
    end)
  end

  defp style(classes, scale, styles) do
    props =
      Enum.reduce(classes, %{}, fn class, acc -> Map.merge(acc, Map.get(styles, class, %{})) end)

    props =
      case Map.pop(props, "vector-effect") do
        {"non-scaling-stroke", %{"stroke-width" => w} = props} ->
          Map.put(props, "stroke-width", thin(w, scale))

        {_effect, props} ->
          props
      end

    if props == %{} do
      ""
    else
      ~s( style=") <> Enum.map_join(Enum.sort(props), ";", fn {k, v} -> "#{k}:#{v}" end) <> ~s(")
    end
  end

  defp thin(width, scale) do
    {px, _unit} = Float.parse(width)
    "#{Float.round(px / scale, 3)}px"
  end
end
