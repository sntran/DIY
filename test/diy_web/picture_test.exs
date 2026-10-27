defmodule DIYWeb.PictureTest do
  use DIYWeb.ConnCase, async: true

  alias DIY.{Build, House, Share}

  # The DATA of the link of a house that a link can carry.
  defp encode!(build, summary, opts \\ []) do
    {:ok, data} = Share.encode(build, summary, opts)
    data
  end

  alias DIYWeb.Picture
  alias DIYWeb.Picture.Labels

  defp house(preset \\ %{}) do
    preset = Map.merge(%{size: 2400, year: 2005, floors: 2, heat: "gas", lot: nil}, preset)
    {house, rooms, items} = House.preset(preset)
    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp summary(cost \\ 2190, locale \\ "en", items \\ []),
    do:
      Share.summary(
        [1180, 980, 1010, 1100, 1350, 1720, 2010, 2080, 1760, 1300, 1050, 1190],
        cost,
        locale,
        %{time: "day", weather: "sun"},
        items
      )

  # The id of the first item of a type in a build.
  defp id(build, type), do: Enum.find(build.items, &(&1.type == type)).id

  # A summary with labels for the items of a house: the kWh and the cost
  # of a year of each type.
  defp labeled(build, uses, sky \\ %{time: "day", weather: "sun"}) do
    items = for {type, kwh, cost} <- uses, do: {id(build, type), kwh, cost}

    %{
      summary()
      | items: Share.summary(List.duplicate(0, 12), nil, "en", sky, items).items,
        sky: sky
    }
  end

  # A house with a pool in the yard and a spa inside, with the items of a
  # pool.
  defp pool_house do
    build = house()
    yard = Enum.find(build.rooms, &(&1.name == "Backyard")).id
    {:ok, build, spa} = Build.add_room(build, "Spa", "f1", :indoor)

    Enum.reduce(
      [
        {yard, "pool"},
        {yard, "pool_pump"},
        {yard, "pool_heater"},
        {spa, "pool"},
        {spa, "hot_tub"}
      ],
      build,
      fn {room, type}, build ->
        {:ok, build, _id} = Build.add_item(build, room, type)
        build
      end
    )
  end

  # Each sky of a picture: each time of day with each weather.
  @skies for time <- DIY.Sky.times(),
             weather <- DIY.Sky.weathers(),
             do: %{time: time, weather: weather}

  # The parts of the picture with their classes (`Picture.parts/2`), as
  # one text, in a sky.
  defp svg_of(build, sky \\ %{time: "day", weather: "sun"}) do
    {parts, _labels} = Picture.parts(build, %{summary() | sky: sky})
    Enum.map_join(parts, fn {svg, _scale} -> svg end)
  end

  # The classes of the parts of the picture.
  defp classes(build, sky) do
    build
    |> svg_of(sky)
    |> then(&Regex.scan(~r/ class="([^"]*)"/, &1))
    |> Enum.flat_map(fn [_, c] -> String.split(c) end)
    |> MapSet.new()
  end

  # The classes of the picture that have no style on the page. They are
  # the classes of the frame of the SVG, and of the group of an item or of
  # a piece of furniture. The class of the textures has only
  # `stroke: none`, as a shape with no class.
  @plain ~w(block w-full h-full touch-none select-none cutaway cutaway-house) ++
           ~w(p-item p-fixture p-tex)

  test "each class of the picture of a house has a style" do
    builds = [
      house(),
      house(%{floors: 1, size: 900, heat: "electric"}),
      house(%{floors: 3, size: 5200, heat: "heat_pump", lot: 9000}),
      pool_house()
    ]

    for build <- builds,
        sky <- @skies,
        styles = Picture.styles(sky.time, sky.weather, true),
        class <- classes(build, sky),
        class not in @plain do
      assert Map.has_key?(styles, class), "#{class} has no style in #{inspect(sky)}"
    end
  end

  # The SVG gets the styles of its classes in their order on each shape.
  # CSS uses the order of app.css: the two are the same only when the
  # classes of a shape set different properties, or the same values.
  test "the classes of a shape never set a property to two values" do
    for build <- [
          house(),
          house(%{floors: 1, size: 900, heat: "electric"}),
          house(%{floors: 3, size: 5200, lot: 9000}),
          pool_house()
        ],
        sky <- @skies,
        styles = Picture.styles(sky.time, sky.weather, true),
        html = svg_of(build, sky),
        [_, classes] <- Regex.scan(~r/ class="([^"]*)"/, html),
        list = String.split(classes),
        a <- list,
        b <- list,
        a < b,
        {prop, value} <- Map.get(styles, a, %{}),
        other = Map.get(styles, b, %{})[prop],
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

  test "the pool has its water in the picture" do
    assert svg_of(pool_house()) =~ "p-water"
    svg = Picture.svg(pool_house(), summary())
    assert svg =~ "fill:rgb(111, 191, 224)"
    assert {:ok, <<0x89, "PNG", _::binary>>} = Picture.png(pool_house(), summary())
  end

  test "the picture has the sky of the link: its colors follow the time of day" do
    night =
      Share.summary(Enum.map(1..12, &(&1 * 100)), 1500, "en", %{time: "night", weather: "sun"})

    svg = Picture.svg(house(), night)
    assert svg =~ ~s|style="fill:rgb(16, 27, 51)"|
    # The house cut open at night: a window has the color of the night.
    # The floor of a room has the light of a lamp.
    assert svg =~ "fill:rgb(44, 74, 102)"
    refute svg =~ "fill:rgb(242, 196, 107)"
    assert svg =~ "fill:url(#p-glow-fill)"
    refute svg =~ "display:none;fill:url(#p-glow-fill)"
    assert Picture.svg(house(), summary()) =~ "display:none;fill:url(#p-glow-fill)"

    snow = %{night | sky: %{time: "day", weather: "snow"}}
    svg = Picture.svg(house(), snow)
    assert svg =~ "fill:rgb(230, 236, 241)"
    refute svg =~ "fill:rgb(16, 27, 51)"
    assert {:ok, <<0x89, "PNG", _::binary>>} = Picture.png(house(), snow)

    # Snow changes some classes; the other classes keep the style of the scene.
    assert Picture.styles("night", "snow")["p-grass"] != Picture.styles("night")["p-grass"]

    # A tracker shows one position in each scene: the position of the
    # scene. The other positions have no display.
    positions =
      ~w(p-track-7 p-track-9 p-track-11 p-track-day p-track-15 p-track-17 p-track-sunset p-track-night)

    for scene <- ~w(day sunset night) do
      shown = Enum.reject(positions, &(Picture.styles(scene)[&1]["display"] == "none"))
      assert shown == ["p-track-#{scene}"]
    end

    assert Picture.styles("night", "snow")["p-pane"] == Picture.styles("night")["p-pane"]
    # Inside, a window at night has the color of the night.
    assert Picture.styles("night", "snow", true)["p-pane"] != Picture.styles("night")["p-pane"]

    assert Picture.styles("night", "snow", true)["p-grass"] ==
             Picture.styles("night", "snow")["p-grass"]
  end

  describe "the house cut open" do
    test "the picture shows each floor, and the attic and the roof only with a label" do
      build = house()
      svg = Picture.svg(build, summary())
      assert svg =~ ~s(id="plan-ground")
      assert svg =~ ~s(id="plan-f2")
      refute svg =~ ~s(id="plan-attic")
      refute svg =~ ~s(id="plan-roof")
      # No name of a room, and no lot: the yard is a room.
      refute svg =~ "Kitchen<"
      refute svg =~ "Floor 1 and around the house"

      # The gas furnace is in the attic.
      svg = Picture.svg(build, labeled(build, [{"furnace", 257, 34}]))
      assert svg =~ ~s(id="plan-attic")
      refute svg =~ ~s(id="plan-roof")
      assert svg =~ ">Gas furnace<"

      # The AC on the roof.
      roof = Enum.find(build.rooms, &(&1.name == "Roof")).id
      {:ok, build} = Build.move_item(build, id(build, "ac"), roof)
      svg = Picture.svg(build, labeled(build, [{"ac", 6828, 908}]))
      assert svg =~ ~s(id="plan-roof")

      # A house with 3 floors.
      svg = Picture.svg(house(%{floors: 3, size: 5200}), summary())
      assert svg =~ ~s(id="plan-f3")
    end

    test "a shell joins each floor to the floor under it: after the yards, before the slabs" do
      shells = fn svg -> length(Regex.scan(~r/class="p-shell-[lr]"/, svg)) end

      assert shells.(svg_of(house(%{floors: 1, size: 900, heat: "electric"}))) == 0
      assert shells.(svg_of(house(%{floors: 3, size: 5200}))) == 4

      # Two walls between floor 1 and floor 2. The layer of floor 1 paints
      # them after its yards and before its slabs. Thus the yard at the
      # back is behind them, and the rooms are in front of them.
      two = svg_of(house())
      assert shells.(two) == 2
      [_before, ground] = String.split(two, ~s(id="plan-ground"), parts: 2)
      [ground, _f2] = String.split(ground, ~s(id="plan-f2"), parts: 2)
      [yards, rest] = String.split(ground, ~s(class="p-shell-l"), parts: 2)
      assert yards =~ ~s(data-room=)
      refute yards =~ "p-slab"
      assert rest =~ "p-slab"

      # Floor 2 with no room: the shell has the box of the house.
      empty = Enum.reject(build_rooms = house().rooms, &(&1.level == "f2"))
      assert length(empty) < length(build_rooms)
      assert shells.(svg_of(%{house() | rooms: empty})) == 2

      # Floor 2 over a part of the house: the left wall goes only along the
      # rooms at the left of floor 2.
      build = house()
      f2 = for r <- build.rooms, r.level == "f2", do: r
      x0 = f2 |> Enum.map(& &1.plan.x) |> Enum.min()
      y0 = f2 |> Enum.map(& &1.plan.y) |> Enum.min()
      gone = for r <- f2, r.plan.x == x0, r.plan.y > y0, do: r.id
      assert gone != []
      part = %{build | rooms: Enum.reject(build.rooms, &(&1.id in gone))}
      rest = for r <- part.rooms, r.level == "f2", do: r.plan
      y1 = rest |> Enum.filter(&(&1.x == x0)) |> Enum.map(&(&1.y + &1.d)) |> Enum.max()
      x1 = rest |> Enum.filter(&(&1.y == y0)) |> Enum.map(&(&1.x + &1.w)) |> Enum.max()
      view = DIYWeb.Cutaway.view(part)
      [below, above] = Enum.filter(view.levels, &(&1.id in ["ground", "f2"]))
      box = %{x: x0, y: y0, w: x1 - x0, d: y1 - y0}
      svg = svg_of(part)

      for {points, _class} <- DIYWeb.Cutaway.shell(view.camera, below, above, box),
          do: assert(svg =~ ~s(points="#{points}"))

      # The attic with a label shows, but it has no shell.
      build = house()
      {parts, _labels} = Picture.parts(build, labeled(build, [{"furnace", 257, 34}]))
      svg = Enum.map_join(parts, fn {svg, _scale} -> svg end)
      assert svg =~ ~s(id="plan-attic")
      assert shells.(svg) == 2
    end

    test "the items with the most kWh have bubbles with their kWh and cost, and no name" do
      build = pool_house()

      uses = [
        {"ac", 6828, 908},
        {"pool_pump", 1346, 179},
        {"dryer", 652, 87},
        {"fridge", 500, 67},
        {"hot_tub", 1200, nil}
      ]

      svg = Picture.svg(build, labeled(build, uses))
      # The item keeps its title in the drawing, but no bubble has a name.
      refute svg =~ ~r/<text[^>]*>Central AC</
      assert svg =~ ">6,828 kWh · $908 a year<"
      assert svg =~ ">1,346 kWh · $179 a year<"
      # With no cost, the label has the kWh only.
      assert svg =~ ">1,200 kWh a year<"

      {_parts, labels} = Picture.parts(build, labeled(build, uses))
      assert hd(labels).numbers == "6,828 kWh · $908 a year"
      assert length(labels) == 5

      # A bubble has a pointer down to its item, as a tooltip. A bubble
      # that is not just above its item also has a line to it.
      bubbles = length(Regex.scan(~r/<path d="M[^"]+ L[^"]+ L[^"]+"/, svg))
      lines = length(Regex.scan(~r/<line /, svg))
      assert bubbles == 5
      assert lines < 5

      for a <- labels, b <- labels, a != b, do: refute(Labels.overlap?(a, b))

      for l <- labels do
        assert l.left >= 38 and l.left + l.w <= 694
        assert l.top >= 38 and l.top + l.h <= 592
      end

      # An item that is not in the house has no label. The labels are in
      # the language of the process.
      summary = %{labeled(build, uses) | items: [%{id: "i999", kwh: 5, cost: 1}]}
      assert {_parts, []} = Picture.parts(build, summary)

      svg =
        Gettext.with_locale(DIY.Gettext, "vi", fn ->
          Picture.svg(build, labeled(build, [{"ac", 6828, 908}]))
        end)

      assert svg =~ "6,828 kWh · $908 mỗi năm"
    end

    # The width of each letter of the fonts of the NIF, in Inter Regular or
    # Bold, the larger one (scripts/inter-widths.mjs).
    @widths "priv/picture/inter_widths.json"
            |> File.read!()
            |> Jason.decode!()
            |> Map.new(fn [c, w] -> {c, w} end)

    # The width of a text in resvg: each code point moves on by its width.
    # A code point that is not in the fonts moves on by the width of
    # .notdef (0.656).
    defp drawn_width(text, size),
      do:
        for(<<c::utf8 <- text>>, reduce: 0, do: (sum -> sum + Map.get(@widths, c, 0.656))) * size

    test "a bubble is never narrower than its text" do
      build = house()
      kitchen = Enum.find(build.rooms, &(&1.name == "Kitchen")).id
      {:ok, build, other} = Build.add_item(build, kitchen, "other")

      {_parts, [label]} =
        Picture.parts(build, %{summary() | items: [%{id: other, kwh: 88_888, cost: 8888}]})

      assert label.w >= drawn_width(label.numbers, 12)

      # An emoji of a family is 7 code points.
      family = "👨‍👩‍👧‍👦"
      # The width of a text with a letter that is not in the fonts is
      # larger than in resvg.
      assert Picture.width(family, 10) >= drawn_width(family, 10)
      assert Picture.width("ௌW", 10) == 2 * 10.38
      assert Picture.width("", 10) == 0
      assert map_size(@widths) == 311
    end

    test "the box of the house clips the sky, the rain and the snow" do
      svg = Picture.svg(house(), %{summary() | sky: %{time: "night", weather: "rain"}})

      assert svg =~
               ~s(<clipPath id="picture-house"><rect x="32" y="32" width="668" height="566"/></clipPath>)

      [before, inside] = String.split(svg, ~s|<g clip-path="url(#picture-house)">|)
      [inside, _after] = String.split(inside, "</g><text", parts: 2)
      # The sky and the rain are in the clipped group, and not before it.
      assert inside =~ "fill:rgb(16, 27, 51)"
      assert inside =~ ~s(id="plan-ground")
      refute before =~ "<path"
    end

    test "a sky over the house: the rain, the snow and the light of a sunset" do
      build = pool_house()

      for {time, weather, class} <- [
            {"day", "rain", "p-rain"},
            {"night", "snow", "p-snow"},
            {"sunset", "clouds", "p-dusk"}
          ] do
        assert svg_of(build, %{time: time, weather: weather}) =~ ~s(class="#{class}")
      end

      assert {:ok, <<0x89, "PNG", _::binary>>} =
               Picture.png(
                 build,
                 labeled(build, [{"ac", 6828, 908}], %{time: "sunset", weather: "rain"})
               )
    end
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
