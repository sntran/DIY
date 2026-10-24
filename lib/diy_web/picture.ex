defmodule DIYWeb.Picture do
  @moduledoc """
  The picture of a shared house, for the preview of its link
  (docs/design.md, "The preview of a link"). It is a PNG of 1200 × 630
  pixels. It shows the house from the outside (`DIYWeb.Outside`), the
  numbers of the year and a bar for each month.

  The NIF resvg draws it (`DIY.Picture.NIF`). resvg reads no CSS of the
  page. Thus each shape of the SVG has its style in a `style` attribute,
  from `priv/picture/styles.json` (`scripts/picture-styles.mjs`).
  """
  use Gettext, backend: DIY.Gettext

  alias DIY.Share
  alias DIYWeb.{Format, Outside}

  @styles_path Path.expand("../../priv/picture/styles.json", __DIR__)
  @external_resource @styles_path
  @styles @styles_path |> File.read!() |> Jason.decode!()

  @width 1200
  @height 630

  # The box of the house in the picture: x, y, width and height.
  @house {32, 40, 660, 550}

  # The colors of the page (app.css, the light theme).
  @paper "#faf7f2"
  @ink "#2b2118"
  @muted "#6b5e52"
  @bar "#e8843c"

  @doc "The size of the picture in pixels."
  def size, do: {@width, @height}

  @doc "The style of each class of the picture (`priv/picture/styles.json`)."
  def styles, do: @styles

  @doc """
  The SVG of the picture of a shared house. The texts are in the locale
  of the process (`Gettext.put_locale/2`).
  """
  @spec svg(DIY.Build.t(), Share.summary()) :: String.t()
  def svg(build, summary) do
    view = Outside.view(build)
    {_x, _y, w, h} = view.box
    {hx, hy, hw, hh} = @house
    scale = min(hw / w, hh / h)

    house =
      %{__changed__: nil, view: view}
      |> Outside.house()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
      # HEEx marks the root of a component with `phx-r`, an attribute with
      # no value: XML does not allow it.
      |> String.replace(~r/ phx-r(?=[\s>\/])/, "")
      |> inline(scale)
      |> String.replace("<svg ", ~s(<svg x="#{hx}" y="#{hy}" width="#{hw}" height="#{hh}" ),
        global: false
      )

    IO.iodata_to_binary([
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}">),
      ~s(<rect width="#{@width}" height="#{@height}" fill="#{@paper}"/>),
      house,
      numbers(build, summary),
      bars(summary),
      ~s(<text x="1160" y="600" text-anchor="end" font-size="22" font-weight="700" fill="#{@ink}">Small Steps Home</text>),
      "</svg>"
    ])
  end

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
  @spec inline(String.t(), number()) :: String.t()
  def inline(svg, scale) do
    Regex.replace(~r/ class="([^"]*)"/, svg, fn _all, classes ->
      classes |> String.split() |> style(scale)
    end)
  end

  defp style(classes, scale) do
    props =
      Enum.reduce(classes, %{}, fn class, acc -> Map.merge(acc, Map.get(@styles, class, %{})) end)

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
