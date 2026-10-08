defmodule DIYWeb.Icon do
  @moduledoc """
  The isometric icon of each kind of item (`DIYWeb.Icon.Shapes`), in SVG.

  The root layout has a sprite (`sprite/1`): the shapes of each kind one
  time, in a group with the id `icon-TYPE`. An icon (`item/1`) is a small
  SVG with the box of its kind, and a `use` of its group. So a page sends
  each icon in about 100 bytes. The app makes the sprite and the boxes one
  time, when it compiles.

  An icon is for the eyes only (`aria-hidden`): the name of the item is
  next to it. The colors are classes of `assets/css/app.css` (`i-*`).
  """
  use DIYWeb, :html

  alias DIY.Catalog
  alias DIYWeb.Icon.Shapes
  alias DIYWeb.Iso

  # The box and the SVG of the shapes of each kind.
  @icons Map.new(Catalog.kinds(), fn %{type: type} ->
           shapes = Shapes.shapes(type)

           points =
             for {:poly, corners, _class} <- shapes, corner <- corners, do: Iso.at({0, 0}, corner)

           {xs, ys} = Enum.unzip(points)
           {x0, x1} = Enum.min_max(xs)
           {y0, y1} = Enum.min_max(ys)
           size = max(x1 - x0, y1 - y0) + 2
           {cx, cy} = {(x0 + x1) / 2, (y0 + y1) / 2}
           view = Enum.map_join([cx - size / 2, cy - size / 2, size, size], " ", &Iso.round1/1)

           svg =
             Enum.map_join(shapes, fn {:poly, corners, class} ->
               ~s(<polygon points="#{Iso.points({0, 0}, corners)}" class="#{class}"/>)
             end)

           {type, {view, svg}}
         end)

  attr :type, :string, required: true, doc: "the kind of the item"
  attr :class, :string, default: "size-10"

  @doc "The icon of a kind of item."
  def item(assigns) do
    {view, _svg} = Map.fetch!(@icons, assigns.type)
    assigns = assign(assigns, view: view, href: "#icon-" <> assigns.type)

    ~H"""
    <svg viewBox={@view} class={["shrink-0", @class]} aria-hidden="true"><use href={@href} /></svg>
    """
  end

  @groups Enum.sort(@icons)

  @doc "The sprite of the icons, for the root layout: it shows nothing."
  def sprite(assigns) do
    assigns = assign(assigns, :groups, @groups)

    ~H"""
    <svg width="0" height="0" class="absolute" aria-hidden="true" focusable="false">
      <defs>
        <g :for={{type, {_view, svg}} <- @groups} id={"icon-" <> type}>{raw(svg)}</g>
      </defs>
    </svg>
    """
  end
end
