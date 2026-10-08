defmodule DIYWeb.IconTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DIY.Catalog
  alias DIYWeb.Icon

  test "each kind has an icon: a square SVG that holds all its points" do
    for kind <- Catalog.kinds() do
      html = render_component(&Icon.item/1, type: kind.type)
      assert html =~ ~s(aria-hidden="true")
      [x, y, w, h] = viewbox(html)
      assert w == h, "#{kind.type}: a square icon"

      for [px, py] <- Regex.scan(~r/(-?[\d.]+),(-?[\d.]+)/, html) |> Enum.map(&tl/1) do
        {px, _} = Float.parse(px)
        {py, _} = Float.parse(py)
        assert px >= x and px <= x + w and py >= y and py <= y + h, "#{kind.type}: a point out"
      end
    end
  end

  test "a kind that the app does not know has the icon of a box" do
    assert render_component(&Icon.item/1, type: "rocket", class: "size-5") =~ "i-gray-t"
  end

  defp viewbox(html) do
    [_, box] = Regex.run(~r/viewBox="([^"]+)"/, html)
    box |> String.split() |> Enum.map(&(&1 |> Float.parse() |> elem(0)))
  end
end
