defmodule DIYWeb.IconTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DIY.Catalog
  alias DIYWeb.Icon
  alias DIYWeb.Icon.Shapes

  test "each kind has shapes of its own" do
    shapes = for kind <- Catalog.kinds(), do: Shapes.shapes(kind.type)
    assert length(Enum.uniq(shapes)) == length(Catalog.kinds())
  end

  test "each class of the icons has a rule in app.css" do
    css = File.read!("assets/css/app.css")

    classes =
      for kind <- Catalog.kinds(),
          {:poly, _corners, class} <- Shapes.shapes(kind.type),
          name <- String.split(class),
          uniq: true,
          do: name

    for class <- classes, do: assert(css =~ "." <> class <> " {", "no rule for #{class}")
  end

  test "the sprite has a group for each kind, and an icon uses its group in a square box" do
    sprite = render_component(&Icon.sprite/1, %{})

    for kind <- Catalog.kinds() do
      assert sprite =~ ~s(id="icon-#{kind.type}")
      html = render_component(&Icon.item/1, type: kind.type)
      assert html =~ ~s(<use href="#icon-#{kind.type}")
      assert html =~ ~s(aria-hidden="true")
      [_, box] = Regex.run(~r/viewBox="([^"]+)"/, html)
      [_x, _y, w, h] = String.split(box)
      assert w == h
    end

    # Each point of the sprite is in the box of its icon, with a margin for
    # the edge of the faces.
    for kind <- Catalog.kinds() do
      [_, box] = Regex.run(~r/viewBox="([^"]+)"/, render_component(&Icon.item/1, type: kind.type))
      [x, y, w, h] = box |> String.split() |> Enum.map(&(&1 |> Float.parse() |> elem(0)))

      for {:poly, corners, _class} <- Shapes.shapes(kind.type), corner <- corners do
        {px, py} = DIYWeb.Iso.at({0, 0}, corner)
        assert px >= x + 0.9 and px <= x + w - 0.9 and py >= y + 0.9 and py <= y + h - 0.9
      end
    end
  end
end
