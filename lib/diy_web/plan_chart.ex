defmodule DIYWeb.PlanChart do
  @moduledoc """
  The chart of the price for each kWh of plans (docs/design.md, "The
  chart of the price"). For each plan, it shows the bill of a month
  divided by its kWh, from 200 to 2,500 kWh. The bill has the delivery charges of the
  plan. A bill credit makes the line drop at its kWh, and a minimum usage
  fee makes it jump. Thus the chart shows that a plan can be cheap at
  1,000 kWh and expensive at 999 kWh.

  The chart is on the worksheet of the plan lesson and on the page of a
  link of plans (`DIY.PlanLink`). The picture of the preview of that
  link has it too (`png/1`). On a page, the colors come from classes
  (`app.css`, the light and the dark theme). In the picture, they are
  attributes, because resvg does not read the CSS of the page.

  The colors are the first 6 of the categorical palette of the data
  charts, in their fixed order. Each line after the first also has its
  own dashes, so a color is never the only sign of a plan.
  """

  alias DIY.Plan

  @from 200
  @to 2_500
  @step 25

  # The highest price of the chart: a plan with a high base charge costs
  # much for each kWh in a small month.
  @max_top 60

  # The colors of the lines in the picture (the light theme), and the
  # dashes of each line.
  @colors ~w(#2a78d6 #eb6834 #1baf7a #eda100 #e87ba4 #008300)
  @dashes ["", "9 5", "2 4", "12 4 2 4", "5 4", "14 3 2 3 2 3"]

  # The colors of the picture (`DIYWeb.Picture`).
  @paper "#faf7f2"
  @ink "#2b2118"
  @muted "#6b5e52"

  @width 1200
  @height 630

  @doc "The first and the last kWh of the chart."
  def range, do: {@from, @to}

  @doc "The dashes of the line of the plan at a place in the list (from 1)."
  def dashes(n), do: Enum.at(@dashes, n - 1)

  @doc """
  The points of the line of a plan: `{kwh, cents}`. They are each 25 kWh,
  and at each limit of a credit or of a fee: the kWh before it and the
  kWh of it. So the line drops (or jumps) at the limit.
  """
  def points(plan) do
    limits = for l <- limits(plan), k <- [l - 1, l], k > @from and k < @to, do: k

    (Enum.to_list(@from..@to//@step) ++ limits)
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.map(&{&1, Plan.bill(plan, &1).cents})
  end

  @doc """
  The kWh of a month where the price of a plan changes at once: the
  limits of its credits and of its minimum usage fee.
  """
  def limits(plan) do
    credits = for c <- plan.credits, c.min_kwh > 0, do: c.min_kwh
    fee = if plan.min_fee, do: [plan.min_fee.below_kwh], else: []
    Enum.sort(Enum.uniq(credits ++ fee))
  end

  @doc """
  The kWh of the table of the chart: 500, 1,000, 1,500 and 2,000, and
  the kWh before and at each limit of the plans (`limits/1`).
  """
  def table_kwh(plans) do
    limits = for p <- plans, l <- limits(p), k <- [l - 1, l], k >= @from and k <= @to, do: k
    Enum.sort(Enum.uniq([500, 1000, 1500, 2000] ++ limits))
  end

  @doc """
  The SVG of the chart on a page: the plot, the axes and the months of
  the house. Each month is a dot, with its name and its kWh. `id` makes
  the id of its clip unique on the page.
  """
  def svg(plans, months, id) do
    IO.iodata_to_binary([
      ~s(<svg viewBox="0 0 480 300" class="w-full h-auto" aria-hidden="true">),
      plot(plans, %{
        box: {44, 10, 424, 230},
        id: id,
        size: 15,
        months: months,
        page: true
      }),
      "</svg>"
    ])
  end

  @doc """
  The SVG of the picture of a link of plans: the title, the chart, and a
  key with the name of each plan.
  """
  def picture(plans) do
    title =
      if length(plans) == 1,
        do: "The price for each kWh of a plan",
        else: "The price for each kWh of #{length(plans)} plans"

    IO.iodata_to_binary([
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}">),
      ~s(<rect width="#{@width}" height="#{@height}" fill="#{@paper}"/>),
      text(56, 76, 38, 700, @ink, title),
      text(56, 114, 22, 400, @muted, "The bill of a month divided by its kWh, at each use"),
      text(1144, 76, 22, 700, @ink, "Small Steps Home", "end"),
      plot(plans, %{box: {104, 146, 1040, 330}, id: "picture", size: 20, months: [], page: false}),
      key(plans),
      "</svg>"
    ])
  end

  @doc "The PNG of the picture of a link of plans (`picture/1`)."
  def png(plans), do: DIY.Picture.NIF.render(picture(plans), @width)

  @doc """
  The title of a link of plans, for its preview. The plans are in its
  description.
  """
  def title([_plan]), do: "A plan: the price for each kWh at each use"
  def title(plans), do: "#{length(plans)} plans: the price for each kWh at each use"

  # The plot: the lines of the grid, the axes, a line for each plan, and
  # the dots of the months. The lines stay in the box (a clip).
  defp plot(plans, %{box: {x, y, w, h}} = o) do
    lines = for {plan, n} <- Enum.with_index(plans, 1), do: {n, points(plan)}
    top = top(lines)
    sx = fn kwh -> x + (kwh - @from) / (@to - @from) * w end
    sy = fn cents -> y + h - cents / top * h end
    every = if top <= 30, do: 5, else: 10

    [
      ~s(<clipPath id="pc-clip-#{o.id}"><rect x="#{x}" y="#{y}" width="#{w}" height="#{h}"/></clipPath>),
      for cents <- 0..top//every do
        [
          ~s(<line x1="#{x}" y1="#{r(sy.(cents))}" x2="#{x + w}" y2="#{r(sy.(cents))}" #{grid(o)}/>),
          label(o, x - 6, sy.(cents) + o.size * 0.35, "#{cents}¢", "end")
        ]
      end,
      # The last label ends at the end of the axis: it stays in the box.
      for kwh <- [500, 1000, 1500, 2000, 2500] do
        anchor = if kwh == @to, do: "end", else: "middle"
        label(o, sx.(kwh), y + h + o.size * 1.4, DIYWeb.Format.int(kwh), anchor)
      end,
      label(o, x + w, y + h + o.size * 2.9, "kWh in a month", "end"),
      ~s|<g clip-path="url(#pc-clip-#{o.id})">|,
      for {n, points} <- lines do
        d = Enum.map_join(points, " ", fn {k, c} -> "#{r(sx.(k))},#{r(sy.(c))}" end)

        ~s(<polyline points="#{d}" fill="none" stroke-width="#{o.size / 6}" stroke-linejoin="round" #{series(o, n)}/>)
      end,
      "</g>",
      for m <- o.months, m.kwh >= @from and m.kwh <= @to do
        ~s(<circle cx="#{r(sx.(m.kwh))}" cy="#{y + h}" r="4" class="pc-month"><title>#{escape("#{m.name}: #{DIYWeb.Format.kwh(m.kwh)}")}</title></circle>)
      end
    ]
  end

  # The top of the chart: the highest price of the lines, up to the next
  # 5¢, and 60¢ at most. Higher prices go out of the box.
  defp top(lines) do
    high =
      lines |> Enum.flat_map(fn {_n, points} -> Enum.map(points, &elem(&1, 1)) end) |> Enum.max()

    high |> Kernel./(5) |> Float.ceil() |> trunc() |> Kernel.*(5) |> max(10) |> min(@max_top)
  end

  # The key of the picture: a line and the name of each plan, 3 on a row.
  # A long name is cut to fit its place.
  defp key(plans) do
    for {plan, n} <- Enum.with_index(plans, 1) do
      col = rem(n - 1, 3)
      row = div(n - 1, 3)
      x = 56 + col * 362
      y = 560 + row * 38

      [
        ~s(<line x1="#{x}" y1="#{y - 7}" x2="#{x + 34}" y2="#{y - 7}" stroke-width="4" #{series(%{page: false}, n)}/>),
        text(x + 46, y, 22, 400, @ink, fit(plan.name, 300, 22))
      ]
    end
  end

  # A name with "…" at its end when it is wider than `max` pixels.
  defp fit(name, max, size) do
    if DIYWeb.Picture.width(name, size) <= max,
      do: name,
      else: cut(String.graphemes(name), max - DIYWeb.Picture.width("…", size), size)
  end

  defp cut(letters, max, size) do
    text = Enum.join(letters)

    if DIYWeb.Picture.width(text, size) <= max,
      do: String.trim_trailing(text) <> "…",
      else: cut(Enum.drop(letters, -1), max, size)
  end

  defp series(%{page: true}, n), do: ~s(class="pc-line pc-#{n}" stroke-dasharray="#{dashes(n)}")

  defp series(%{page: false}, n),
    do: ~s(stroke="#{Enum.at(@colors, n - 1)}" stroke-dasharray="#{dashes(n)}")

  defp grid(%{page: true}), do: ~s(class="pc-grid")
  defp grid(%{page: false}), do: ~s(stroke="#{@ink}" stroke-opacity="0.12")

  defp label(%{page: true, size: size}, x, y, value, anchor),
    do: [
      ~s(<text x="#{r(x)}" y="#{r(y)}" font-size="#{size}" text-anchor="#{anchor}" class="pc-text">),
      escape(value),
      "</text>"
    ]

  defp label(%{page: false, size: size}, x, y, value, anchor),
    do: text(r(x), r(y), size, 400, @muted, value, anchor)

  defp text(x, y, size, weight, color, value, anchor \\ "start") do
    [
      ~s(<text x="#{x}" y="#{y}" font-size="#{size}" font-weight="#{weight}" fill="#{color}" text-anchor="#{anchor}">),
      escape(value),
      "</text>"
    ]
  end

  # A text for the SVG. A control character or a noncharacter is not text
  # of XML (resvg refuses the SVG), so it goes.
  defp escape(text) do
    text
    |> String.replace(~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{FFFE}\x{FFFF}]/u, "")
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp r(n), do: Float.round(n / 1, 1)
end
