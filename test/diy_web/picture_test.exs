defmodule DIYWeb.PictureTest do
  use DIYWeb.ConnCase, async: true

  alias DIY.{Build, House, Share}

  # The DATA of the link of a house that a link can carry.
  defp encode!(build, summary, opts \\ []) do
    {:ok, data} = Share.encode(build, summary, opts)
    data
  end

  alias DIYWeb.{Outside, Picture}

  defp house(preset \\ %{}) do
    preset = Map.merge(%{size: 2400, year: 2005, floors: 2, heat: "gas", lot: nil}, preset)
    {house, rooms, items} = House.preset(preset)
    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp summary(cost \\ 2190, locale \\ "en"),
    do:
      Share.summary(
        [1180, 980, 1010, 1100, 1350, 1720, 2010, 2080, 1760, 1300, 1050, 1190],
        cost,
        locale
      )

  # The SVG of the house from the outside, with its classes.
  defp svg_of(build) do
    %{__changed__: nil, view: Outside.view(build)}
    |> Outside.house()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # The classes of the SVG of the house from the outside.
  defp classes(build) do
    build
    |> svg_of()
    |> then(&Regex.scan(~r/ class="([^"]*)"/, &1))
    |> Enum.flat_map(fn [_, c] -> String.split(c) end)
    |> MapSet.new()
  end

  # The classes of the picture that have no style on the page: the frame
  # of the SVG and the group of an item. The class of the textures has
  # only `stroke: none`, as a shape with no class.
  @plain ~w(block w-full cutaway cutaway-house cutaway-outside p-item p-tex)

  test "each class of the picture of a house has a style" do
    builds = [
      house(),
      house(%{floors: 1, size: 900, heat: "electric"}),
      house(%{floors: 3, size: 5200, heat: "heat_pump", lot: 9000})
    ]

    for build <- builds, class <- classes(build), class not in @plain do
      assert Map.has_key?(Picture.styles(), class), "#{class} has no style"
    end
  end

  # The SVG gets the styles of its classes in their order on each shape.
  # CSS uses the order of app.css: the two are the same only when the
  # classes of a shape set different properties, or the same values.
  test "the classes of a shape never set a property to two values" do
    for preset <- [
          %{},
          %{floors: 1, size: 900, heat: "electric"},
          %{floors: 3, size: 5200, lot: 9000}
        ],
        html = svg_of(house(preset)),
        [_, classes] <- Regex.scan(~r/ class="([^"]*)"/, html),
        list = String.split(classes),
        a <- list,
        b <- list,
        a < b,
        {prop, value} <- Map.get(Picture.styles(), a, %{}),
        other = Map.get(Picture.styles(), b, %{})[prop],
        other != nil do
      assert other == value, "#{a} and #{b} set #{prop} to #{value} and #{other}"
    end
  end

  test "the SVG has the style of each shape, with no class and no CSS" do
    svg = Picture.svg(house(), summary())
    refute svg =~ " class="
    refute svg =~ "<style"
    refute svg =~ " phx-r"
    refute svg =~ "vector-effect"
    assert svg =~ ~s(<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630")
    assert svg =~ "16,730 kWh"
    assert svg =~ "$2,190"
    assert svg =~ "A house of 2,400 sq ft in 75070"
    assert svg =~ "Small Steps Home"
    # A bar for each month.
    assert length(Regex.scan(~r/<rect x="\d+" y="[\d.]+" width="28"/, svg)) == 12
  end

  test "a house with no cost and no ZIP code" do
    build = %{house() | zip: nil}
    svg = Picture.svg(build, summary(nil))
    refute svg =~ "$"
    assert svg =~ "A house of 2,400 sq ft<"
    assert Picture.title(build, summary(nil)) == "A house of 2,400 sq ft: 16,730 kWh a year"

    assert Picture.title(house(), summary()) ==
             "A house of 2,400 sq ft in 75070: 16,730 kWh a year"
  end

  test "a month with no use has no bar, and all months with no use are not an error" do
    s = Share.summary(List.duplicate(0, 12), nil, "en")
    svg = Picture.svg(house(), s)
    assert svg =~ ~s(height="0.0")
  end

  test "a stroke that does not scale gets the width for the scale of the picture" do
    assert Picture.inline(~s(<polygon class="p-floor p-grass"/>), 2.0) =~ "stroke-width:0.4px"
    assert Picture.inline(~s(<g class="p-item"/>), 2.0) == "<g/>"
    assert Picture.inline(~s(<g class=""/>), 2.0) == "<g/>"

    assert Picture.inline(~s(<path class="p-tex-grass"/>), 2.0) ==
             ~s|<path style="fill:url(#tex-grass)"/>|
  end

  test "the text of the picture is in the locale of the process" do
    svg = Gettext.with_locale(DIY.Gettext, "vi", fn -> Picture.svg(house(), summary()) end)
    assert svg =~ "Nhà"
  end

  test "the NIF draws a PNG of 1200 × 630 pixels" do
    assert {:ok, png} = Picture.png(house(), summary())
    assert <<0x89, "PNG", _::binary-size(12), 1200::32, 630::32, _::binary>> = png
    assert Picture.size() == {1200, 630}
  end

  test "the NIF refuses a bad SVG, entities and a large picture" do
    assert {:error, _} = DIY.Picture.NIF.render("<svg", 100)

    assert {:error, "the width is 0"} =
             DIY.Picture.NIF.render(
               ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>),
               0
             )

    entity =
      ~s(<!DOCTYPE svg [<!ENTITY a "aaaa">]><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>)

    assert {:error, "entities are not supported"} = DIY.Picture.NIF.render(entity, 10)

    assert {:error, "the image has more than 1048576 pixels"} =
             DIY.Picture.NIF.render(
               ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>),
               2000
             )

    assert {:error, "the SVG is not UTF-8"} = DIY.Picture.NIF.render(<<0xFF, 0xFE>>, 10)
  end

  test "the NIF reads no image" do
    svg =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="4" height="4"><image width="4" height="4" xlink:href="/etc/passwd"/></svg>)

    assert {:ok, _png} = DIY.Picture.NIF.render(svg, 4)
  end

  describe "the controller" do
    test "a link gives its picture, with a cache of one year", %{conn: conn} do
      data = encode!(house(), summary())
      conn = get(conn, ~p"/s/#{data}/picture.png")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert <<0x89, "PNG", _::binary>> = conn.resp_body
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "a site that asks for HTML gets the picture", %{conn: conn} do
      data = encode!(house(), summary())
      conn = conn |> put_req_header("accept", "text/html") |> get(~p"/s/#{data}/picture.png")
      assert conn.status == 200
    end

    test "a bad link gives no picture", %{conn: conn} do
      assert get(conn, ~p"/s/1abc/picture.png").status == 404
    end
  end
end
