defmodule DIYWeb.OutsideTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, Catalog, House}
  alias DIYWeb.Outside

  @m 0.0254

  defp house(floors \\ 2) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: floors, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  defp add(build, room, type, params) do
    {:ok, build, id} = Build.add_item(build, room(build, room).id, type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  defp delete(build, levels) do
    Enum.reduce(build.rooms, build, fn room, build ->
      if room.level in levels, do: elem(Build.delete_room(build, room.id), 1), else: build
    end)
  end

  defp ids(view), do: Enum.map(view.level.objects, & &1.id)
  defp object(view, id), do: Enum.find(view.level.objects, &(&1.id == id))
  defp classes(object), do: Enum.map(object.polys, &elem(&1, 1))
  defp count(object, class), do: Enum.count(classes(object), &(&1 == class))

  defp html(view), do: render_component(&Outside.house/1, view: view)

  test "the house from the outside: the slabs, the walls, the doors, the roof, and you" do
    build = house()
    view = Outside.view(build)
    ids = ids(view)
    rooms = Map.new(build.rooms, &{&1.name, &1.id})

    # Each room of the floors, and the garage, is on its slab. The slabs on
    # the ground paint first, as in the plan: 3 faces for each of the 4
    # rooms. A slab over floor 1 is an object.
    assert length(view.level.slabs) == 3 * 4
    assert Enum.all?(view.level.slabs, &match?({_, "p-slab-" <> _, nil}, &1))

    for name <- ["Bedroom 1", "Bedroom 2", "Bathroom", "Bedroom 3"],
        do: assert(("slab-" <> rooms[name]) in ids)

    # The walls are on the sides with no room. The kitchen has a wall on its
    # left end, its back and its front. Its right end has the living room.
    kitchen = rooms["Kitchen"]

    assert Enum.sort(Enum.filter(ids, &String.starts_with?(&1, "wall-#{kitchen}-"))) ==
             ["wall-#{kitchen}-x0-0", "wall-#{kitchen}-y0-0", "wall-#{kitchen}-y1-0"]

    # The door of the house is on the largest room of floor 1 with a wall at
    # the front. You are in front of it. The garage has its wide door, with
    # its lines, and a flat roof.
    door = object(view, "door-" <> rooms["Living room"])
    assert count(door, "p-door") == 1
    assert "you" in ids
    garage = object(view, "door-" <> rooms["Garage"])
    assert count(garage, "p-garage") == 1
    assert count(garage, "p-line") == 3
    assert ("top-" <> rooms["Garage"]) in ids

    # The roof: two slopes with their shingles, and the gable. It is on the
    # walls of floor 2: 0.3 m of slab, 2.4 m of wall, 0.3 m of slab and
    # 2.4 m of wall.
    roof = object(view, "roof-" <> rooms["Roof"])
    assert count(roof, "p-tex p-tex-roof") == 2
    assert count(roof, "p-gable") == 1
    assert_in_delta elem(roof.box, 2), 5.4, 1.0e-9

    # The attic is in the roof, and the rooms are in their walls: their
    # items do not show. The yards show their items and their furniture.
    attic = room(build, "Attic").id
    refute Enum.any?(ids, &String.contains?(&1, attic))

    shown = for %{kind: :item, id: id} <- view.level.objects, do: id
    places = Map.new(build.rooms, &{&1.id, &1.place})
    assert shown != []
    assert Enum.all?(build.items, &(&1.id not in shown or places[&1.room] == :outdoor))
    assert Enum.any?(ids, &String.starts_with?(&1, "decor-" <> rooms["Backyard"]))

    # The grid: its pole, a wire to the meter of the house, and its label.
    assert "pole" in ids
    assert view.wire =~ ~r/^M[-\d.]+,[-\d.]+ Q[-\d.]+,[-\d.]+ [-\d.]+,[-\d.]+$/

    assert Enum.map(view.meter, &elem(&1, 1)) |> Enum.uniq() |> Enum.sort() ==
             ~w(p-meter-l p-meter-r p-meter-t)

    assert Enum.map(view.chips, & &1.text) == ["Grid"]
  end

  test "the windows: one for each 8 feet of the front and of the right end" do
    build = house()
    view = Outside.view(build)

    for %{id: "wall-" <> id, box: {x0, y0, _, x1, y1, _}} = wall <- view.level.objects do
      [room_id, side, _] = String.split(id, "-")
      room = Enum.find(build.rooms, &(&1.id == room_id))
      p = room.plan

      # The box of a wall is flat, with no corner. A wall on x fills a
      # corner of its room: the thickness of a wall (0.16 m) at that end.
      {a, b, r0, r1} =
        if side in ~w(x0 x1),
          do: {y0 / @m, y1 / @m, p.y, p.y + p.d},
          else: {x0 / @m, x1 / @m, p.x, p.x + p.w}

      corners =
        if side in ~w(x0 x1),
          do: Enum.count([round(a) == r0, round(b) == r1], & &1),
          else: 0

      length = b - a + corners * 0.16 / @m
      panes = count(wall, "p-pane")

      cond do
        side in ~w(x0 y0) -> assert panes == 0
        room.level == "outside" -> assert panes == if(side == "x1", do: 2, else: 0)
        length >= 96 -> assert panes == 2 * div(round(length), 96)
        length >= 48 -> assert panes == 2
        true -> assert panes == 0
      end
    end

    # The front of the living room is 18 feet: 2 windows, at the two sides
    # of the door.
    living = room(build, "Living room").id
    assert count(object(view, "wall-#{living}-y1-0"), "p-pane") == 4
  end

  test "a part of a side with a room on the other side has no wall" do
    # The kitchen is between two rooms on its right: the living room in
    # front of it, and the laundry behind it. Its right end has a wall from
    # its back to its front.
    build = house()
    plan = &Build.size_room(&1, room(&1, &2).id, &3)
    {:ok, build} = plan.(build, "Kitchen", %{x: 0, y: 100, w: 144, d: 100})
    {:ok, build} = plan.(build, "Living room", %{x: 144, y: 0, w: 216, d: 50})
    {:ok, build} = plan.(build, "Laundry", %{x: 144, y: 250, w: 78, d: 44})
    view = Outside.view(build)

    kitchen = room(build, "Kitchen").id
    assert %{box: {_, y0, _, _, y1, _}} = object(view, "wall-#{kitchen}-x1-0")
    assert_in_delta y0, 100 * @m, 1.0e-9
    assert_in_delta y1, 200 * @m, 1.0e-9
    living = room(build, "Living room").id
    assert object(view, "wall-#{living}-x0-0")

    # With no bathroom on floor 2, the front of bedroom 1 has a wall where
    # the bathroom was, and none where bedroom 3 is.
    build = house()
    {:ok, build} = Build.delete_room(build, room(build, "Bathroom").id)
    view = Outside.view(build)
    bedroom = room(build, "Bedroom 1")
    assert %{box: {x0, _, _, x1, _, _}} = object(view, "wall-#{bedroom.id}-y1-0")
    assert {x0, x1} == {0.0, 144 * @m}
    refute object(view, "wall-#{bedroom.id}-y1-1")
  end

  test "the labels: the panels on the roof and in the yard, and the stations" do
    build = house()
    {build, _} = add(build, "Roof", "solar_panels", %{"watts" => 6400})
    {build, _} = add(build, "Backyard", "solar_panels", %{"watts" => 400})
    {build, _} = add(build, "Living room", "power_station", %{"kwh" => 2.0, "extra_kwh" => 2.0})
    {build, planned} = add(build, "Backyard", "power_station", %{"kwh" => 5.0})
    {:ok, build} = Build.flag_item(build, planned, :planned, true)

    view = Outside.view(build)
    assert Enum.map(view.chips, & &1.text) == ["Grid", "6.4 kW", "400 W", "4 kWh"]

    # The text for a screen reader tells the same facts.
    assert view.label ==
             "a house with 2 floors, a garage, solar panels of 6.4 kW on the roof, " <>
               "other solar panels of 400 W, outside: Central AC, Solar panels, " <>
               "1 power station of 4 kWh, " <>
               "the wire of the grid, you in front of the door"

    # The panels on the roof show. A planned item does not.
    roof = object(view, "roof-" <> room(build, "Roof").id)
    assert length(roof.polys) > 5
    refute planned in ids(view)

    # Each label is in the box of the SVG.
    {x, y, w, h} = view.box

    for %{box: {cx, cy, cw, ch}} <- view.chips,
        do: assert(cx >= x and cy >= y and cx + cw <= x + w and cy + ch <= y + h)
  end

  test "the kWh of the stations: rounded, and at the front with no room on floor 1" do
    # The sum of the batteries has one decimal.
    {build, _} =
      add(house(), "Living room", "power_station", %{"kwh" => 1.1, "extra_kwh" => 2.2})

    assert List.last(Outside.view(build).chips).text == "3.3 kWh"

    # With no room on floor 1, the label is at the front of the other
    # rooms. With no room at all, it is at the front of the lot.
    build = delete(house(), ["f1"])
    {build, _} = add(build, "Garage", "power_station", %{"kwh" => 2.0})
    view = Outside.view(build)
    assert List.last(view.chips).text == "2 kWh"
    refute view.label =~ "you in front of the door"

    build = delete(house(), ["f1", "f2", "roof"])
    {:ok, build} = Build.delete_room(build, room(build, "Garage").id)
    {build, _} = add(build, "Backyard", "power_station", %{"kwh" => 2.0})
    view = Outside.view(build)
    assert view.label =~ "a lot, outside: Central AC, Power station, 1 power station of 2 kWh"
    %{box: {_, y, _, h}} = List.last(view.chips)
    {_, lot_y, _, lot_h} = view.level.box
    assert y + h > lot_y + lot_h / 2
  end

  test "the panels outside: their label is over their yard, or over the lot" do
    {build, _} = add(house(), "Driveway", "solar_panels", %{"watts" => 400})
    view = Outside.view(build)
    [_grid, chip] = view.chips
    assert chip.text == "400 W"

    # Panels on a balcony over floor 1: their label is over the balcony.
    {:ok, build, deck} = Build.add_room(house(), "Balcony", "f2", :outdoor)
    {:ok, build, id} = Build.add_item(build, deck, "solar_panels")
    {:ok, build} = Build.update_item(build, id, %{"watts" => 400})
    [_grid, high] = Outside.view(build).chips
    assert high.top < chip.top

    # Panels on a room outside on the roof: the room does not show, and
    # their label is over the middle of the lot.
    {:ok, build, deck} = Build.add_room(house(), "Roof deck", "roof", :outdoor)
    {:ok, build, id} = Build.add_item(build, deck, "solar_panels")
    {:ok, build} = Build.update_item(build, id, %{"watts" => 400})
    view = Outside.view(build)
    refute Enum.any?(ids(view), &String.contains?(&1, deck))
    assert List.last(view.chips).text == "400 W"
  end

  test "a room on the roof is the roof only on the level of the roof" do
    # A room on the roof of floor 1 (a porch) is not the roof of the house.
    # With no room on the roof, the house gets its plain roof.
    build = delete(house(), ["roof"])
    {:ok, build, porch} = Build.add_room(build, "Porch roof", "f1", :roof)
    view = Outside.view(build)
    assert "roof-roof" in ids(view)
    refute Enum.any?(ids(view), &String.ends_with?(&1, porch))

    # The panels on the porch do not show. Their label is over the middle
    # of the lot, and not over the roof of the house.
    {:ok, build, id} = Build.add_item(build, porch, "solar_panels")
    {:ok, build} = Build.update_item(build, id, %{"watts" => 2000})
    view = Outside.view(build)
    assert Enum.map(view.chips, & &1.text) == ["Grid", "2 kW"]
    refute view.label =~ "on the roof"
    assert view.label =~ "other solar panels of 2 kW"

    # A roof on the garage: the same, and the roof of the house has no
    # label.
    {:ok, build, shed} = Build.add_room(house(), "Shed roof", "outside", :roof)
    {:ok, build, id} = Build.add_item(build, shed, "solar_panels")
    {:ok, build} = Build.update_item(build, id, %{"watts" => 1200})
    assert Enum.map(Outside.view(build).chips, & &1.text) == ["Grid", "1.2 kW"]
  end

  test "a balcony: on its slab, with its floor and its items, and no wall" do
    {:ok, build, deck} = Build.add_room(house(), "Balcony", "f2", :outdoor)
    {:ok, build, item} = Build.add_item(build, deck, "ac")
    view = Outside.view(build)

    # Floor 2 is 3 m over the ground: 2 slabs and the walls of floor 1.
    slab = object(view, "slab-" <> deck)
    assert_in_delta elem(slab.box, 5), 3.0, 1.0e-9
    assert Enum.any?(classes(slab), &String.starts_with?(&1, "p-floor"))
    assert_in_delta elem(object(view, item).box, 2), 3.0, 1.0e-9
    refute Enum.any?(ids(view), &String.starts_with?(&1, "wall-#{deck}-"))

    # A patio on floor 1 is on its slab on the ground. Its floor paints
    # after the slabs.
    {:ok, build, patio} = Build.add_room(house(), "Patio", "f1", :outdoor)
    view = Outside.view(build)
    assert [%{id: ^patio, polys: [{points, class} | _]}] = view.level.rooms
    refute object(view, "slab-" <> patio)
    assert html(view) =~ ~s(points="#{points}" class="#{class}")
  end

  test "a pool on a balcony paints after the slab of the balcony, and before its items" do
    {:ok, build, deck} = Build.add_room(house(), "Balcony", "f2", :outdoor)
    {:ok, build, pool} = Build.add_item(build, deck, "pool")
    {:ok, build} = Build.size_item(build, pool, %{w: 60, d: 60, h: 6})
    {:ok, build} = Build.place_item(build, pool, deck, %{x: 0, y: 0})
    {:ok, build, pump} = Build.add_item(build, deck, "pool_pump")
    {:ok, build} = Build.place_item(build, pump, deck, %{x: 10, y: 2}, true)
    ids = ids(Outside.view(build))
    at = fn id -> Enum.find_index(ids, &(&1 == id)) end
    assert at.("slab-" <> deck) < at.(pool)
    assert at.(pool) < at.(pump)
  end

  test "you stand in front of the door, also when a room is in front of a part of the wall" do
    # The laundry is in front of the right part of the living room. The
    # door is on the left part, and you are in front of it.
    build = house()
    plan = &Build.size_room(&1, room(&1, &2).id, &3)
    {:ok, build} = plan.(build, "Living room", %{x: 144, y: 0, w: 216, d: 200})
    {:ok, build} = plan.(build, "Laundry", %{x: 200, y: 200, w: 160, d: 94})
    view = Outside.view(build)

    %{box: {x0, y0, _, x1, _, _}} = object(view, "you")
    laundry = room(build, "Laundry").plan
    assert x1 <= laundry.x * @m or y0 >= (laundry.y + laundry.d) * @m
    door = object(view, "door-" <> room(build, "Living room").id)
    assert count(door, "p-door") == 1
    assert x0 >= 144 * @m
  end

  test "a house with no roof, no floor 2, or no room" do
    # With no room on the roof, the top floor still has a roof, with no
    # item.
    build = delete(house(), ["roof"])
    assert "roof-roof" in ids(Outside.view(build))

    # With no room on floor 2, the roof is on floor 1.
    build = delete(house(), ["f2"])
    roof = object(Outside.view(build), "roof-" <> room(build, "Roof").id)
    assert_in_delta elem(roof.box, 2), 2.7, 1.0e-9

    # With no room, the lot is the draft floor. There is no wall, no door,
    # no wire and no meter: only the pole of the grid.
    build = delete(house(), Build.levels(2))
    assert build.rooms == []
    view = Outside.view(build)
    assert ids(view) == ["pole"]
    assert view.wire == nil
    assert view.meter == []
    html = html(view)
    refute html =~ "p-wire"
    assert html =~ "Grid"
    assert view.label == "a lot"
  end

  test "the SVG: the look of the plan, the wire, the labels, and the items" do
    html = html(Outside.view(house()))

    assert html =~ ~s(class="cutaway cutaway-house cutaway-outside block w-full")
    assert html =~ ~s(aria-hidden="true")
    # The same textures and light as the plan (DIYWeb.Cutaway.defs/1).
    assert html =~ ~s(id="p-wall-light")
    assert html =~ ~s(class="p-wire")
    assert html =~ ~s(class="p-flow")
    assert html =~ ~s(class="p-chip")
    assert html =~ ~s(<text x=)
    assert html =~ ~s(<g class="p-item">)
  end

  test "the power of the grid flows a short time, and the windows have light at night" do
    css = File.read!("assets/css/app.css")

    [loops] =
      for [_, block] <-
            Regex.scan(~r/@media \(prefers-reduced-motion: no-preference\) \{(.*?)\n\}/s, css),
          block =~ "p-flow",
          do: block

    # The flow stops after 5 seconds at most, at its first state: it moves
    # by one period of its dashes for each run.
    [_, time, count] =
      Regex.run(
        ~r/\.cutaway-outside \.p-flow \{ animation: p-flow ([\d.]+)s linear (\d+) \}/,
        loops
      )

    assert String.to_float(time) * String.to_integer(count) <= 5
    [_, a, b] = Regex.run(~r/\.p-flow \{[^}]*stroke-dasharray: (\d+) (\d+);/, css)
    [_, offset] = Regex.run(~r/@keyframes p-flow \{ to \{ stroke-dashoffset: -(\d+) \} \}/, css)
    assert String.to_integer(offset) == String.to_integer(a) + String.to_integer(b)
    refute String.replace(css, loops, "") =~ "animation: p-flow"

    assert css =~ ":root:not([data-theme=light]) .cutaway-outside .p-pane { fill:"
    assert css =~ "[data-theme=dark] .cutaway-outside .p-pane,\n"
    assert css =~ ":root [data-scene=night].cutaway-outside .p-pane.p-pane,\n"

    # The rain and the snow stop after 5 seconds at most (WCAG 2.2.2).
    [falls] =
      for [_, block] <-
            Regex.scan(~r/@media \(prefers-reduced-motion: no-preference\) \{(.*?)\n\}/s, css),
          block =~ "p-fall",
          do: block

    for [_, time, count] <-
          Regex.scan(~r/\.p-fall-\w+ \{ animation: p-\w+ ([\d.]+)s \S+ (\d+)/, falls) do
      assert String.to_float(time) * String.to_integer(count) <= 5
    end

    assert length(Regex.scan(~r/\.p-fall-\w+ \{ animation:/, falls)) == 2
  end

  describe "the sky" do
    @box {0.0, 0.0, 400.0, 300.0}

    defp sky_classes(shapes), do: Enum.map(shapes, fn {_tag, a} -> a.class end)

    test "a day: the sky and the sun; clouds hide no sun" do
      assert sky_classes(Outside.sky(@box, %{time: "day", weather: "sun"}).back) ==
               ~w(p-sky p-sun)

      %{back: back, fall: [], glow: []} = Outside.sky(@box, %{time: "day", weather: "clouds"})
      assert "p-sun" in sky_classes(back)
      assert Enum.count(sky_classes(back), &(&1 == "p-cloud")) == 12
    end

    test "a night: the moon and the stars, fewer stars with clouds" do
      back = sky_classes(Outside.sky(@box, %{time: "night", weather: "sun"}).back)
      assert Enum.take(back, 3) == ~w(p-sky p-moon p-sky-cut)
      assert Enum.count(back, &(&1 == "p-star")) == 16
      back = sky_classes(Outside.sky(@box, %{time: "night", weather: "clouds"}).back)
      assert Enum.count(back, &(&1 == "p-star")) == 6
    end

    test "rain and snow: dark clouds, no sun and no moon, and the rain or the snow in front" do
      for time <- DIY.Sky.times() do
        %{back: back, fall: fall} = Outside.sky(@box, %{time: time, weather: "rain"})
        back = sky_classes(back)
        refute Enum.any?(back, &(&1 in ~w(p-sun p-sun-low p-moon p-star)))
        assert Enum.count(back, &(&1 == "p-cloud-dark")) == 16
        assert [{:path, %{class: "p-rain", d: d}}] = fall
        assert length(String.split(d, "M", trim: true)) == 60
      end

      %{fall: fall} = Outside.sky(@box, %{time: "day", weather: "snow"})
      assert Enum.count(sky_classes(fall), &(&1 == "p-snow")) == 70
    end

    test "a sunset: a low sun, and a warm light over the house" do
      %{back: back, glow: glow} = Outside.sky(@box, %{time: "sunset", weather: "sun"})
      assert "p-sun-low" in sky_classes(back)
      assert sky_classes(glow) == ["p-dusk"]

      # The warm light is not in the group of the rain, which moves.
      %{fall: fall, glow: glow} = Outside.sky(@box, %{time: "sunset", weather: "rain"})
      assert sky_classes(fall) == ["p-rain"]
      assert sky_classes(glow) == ["p-dusk"]
    end

    property "each shape of the sky is in the box of the picture" do
      check all(
              time <- member_of(DIY.Sky.times()),
              weather <- member_of(DIY.Sky.weathers()),
              w <- float(min: 100.0, max: 900.0),
              h <- float(min: 100.0, max: 900.0)
            ) do
        %{back: back, fall: fall, glow: glow} =
          Outside.sky({10.0, 20.0, w, h}, %{time: time, weather: weather})

        for {tag, a} <- back ++ fall ++ glow, tag in [:circle, :ellipse] do
          assert a.cx >= 10.0 and a.cx <= 10.0 + w
          assert a.cy >= 20.0 and a.cy <= 20.0 + h
        end
      end
    end

    test "the sky in words, and on the SVG" do
      assert Outside.sky_label(%{time: "night", weather: "rain"}) == "a night with rain"
      assert Outside.sky_label(%{time: "day", weather: "sun"}) == "a day with a clear sky"
      assert Outside.sky_label(%{time: "sunset", weather: "clouds"}) == "a sunset with clouds"
      assert Outside.sky_label(%{time: "day", weather: "snow"}) == "a day with snow"

      html =
        %{__changed__: nil, view: Outside.view(house()), sky: %{time: "night", weather: "snow"}}
        |> Outside.house()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ ~s(data-scene="night")
      assert html =~ ~s(data-weather="snow")
      assert html =~ ~s(<g class="p-fall p-fall-snow">)
    end
  end

  ## The property

  # A random house. First, random changes of its rooms: some go away, some
  # move, some change their size, and some are new. Then random items go
  # in random rooms, at random places, with random turns and sizes.
  defp builds do
    gen all(
          floors <- integer(1..3),
          changes <-
            list_of(
              one_of([
                tuple({constant(:delete), integer(0..20)}),
                tuple({constant(:move), integer(0..20), integer(-200..900), integer(-200..900)}),
                tuple({constant(:size), integer(0..20), integer(24..600), integer(24..600)}),
                tuple({
                  constant(:add),
                  member_of(~w(f1 f2 f3 roof outside)),
                  member_of([:indoor, :outdoor, :roof])
                })
              ]),
              max_length: 12
            ),
          steps <-
            list_of(
              tuple({
                integer(0..20),
                member_of(Catalog.types()),
                integer(-50..600),
                integer(-50..600),
                integer(0..3),
                one_of([constant(nil), integer(1..300)]),
                boolean()
              }),
              max_length: 15
            )
        ) do
      build = Enum.reduce(changes, house(floors), &change/2)

      Enum.reduce(steps, build, fn {r, type, x, y, turn, side, planned}, build ->
        rooms = Enum.reject(build.rooms, &Build.van_level?(&1.level))
        room = Enum.at(rooms, rem(r, max(length(rooms), 1)))

        with %{} <- room,
             {:ok, build, id} <- Build.add_item(build, room.id, type),
             {:ok, build} <- Build.place_item(build, id, room.id, %{x: x, y: y}),
             {:ok, build} <- Build.size_item(build, id, side && %{w: side, d: side, h: side}),
             {:ok, build} <- Build.flag_item(build, id, :planned, planned) do
          Enum.reduce(1..turn//1, build, fn _, build -> elem(Build.turn_item(build, id), 1) end)
        else
          _ -> build
        end
      end)
    end
  end

  # A change of a room. A change that breaks a rule of the plan is an
  # error, and the build stays.
  defp change({:add, level, place}, build) do
    case Build.add_room(build, "New room", level, place) do
      {:ok, build, _id} -> build
      _error -> build
    end
  end

  defp change(change, build) do
    case Enum.reject(build.rooms, &Build.van_level?(&1.level)) do
      [] -> build
      rooms -> change(change, Enum.at(rooms, rem(elem(change, 1), length(rooms))), build)
    end
  end

  defp change(change, room, build) do
    result =
      case change do
        {:delete, _} -> Build.delete_room(build, room.id)
        {:move, _, x, y} -> Build.move_room(build, room.id, x, y)
        {:size, _, w, d} -> Build.size_room(build, room.id, %{room.plan | w: w, d: d})
      end

    case result do
      {:ok, build} -> build
      _error -> build
    end
  end

  property "each point is in the box of the SVG, only the items of today outside show, and the back paints first" do
    check all(build <- builds(), max_runs: 40) do
      view = Outside.view(Build.house_view(build))
      html = html(view)
      [x, y, w, h] = box(html)

      inside = fn px, py ->
        px >= x - 0.1 and px <= x + w + 0.1 and py >= y - 0.1 and py <= y + h + 0.1
      end

      # The points of the polygons, the corners of the labels, the points of
      # the text, and the points of the wire.
      for [px, py] <- points(html), do: assert(inside.(px, py))

      for [_, rx, ry, rw, rh] <-
            Regex.scan(~r/<rect x="([^"]+)" y="([^"]+)" width="([^"]+)" height="([^"]+)"/, html),
          [rx, ry, rw, rh] = Enum.map([rx, ry, rw, rh], &number/1),
          do: assert(inside.(rx, ry) and inside.(rx + rw, ry + rh))

      for [_, tx, ty] <- Regex.scan(~r/<text x="([^"]+)" y="([^"]+)"/, html),
          do: assert(inside.(number(tx), number(ty)))

      for [_, d] <- Regex.scan(~r/ d="([^"]+)"/, html),
          [_, px, py] <- Regex.scan(~r/(-?[\d.]+),(-?[\d.]+)/, d),
          do: assert(inside.(number(px), number(py)))

      ids = for [_, id] <- Regex.scan(~r/ id="([^"]+)"/, html), do: id
      assert Enum.uniq(ids) == ids

      # An item shows when the person has it, and it is in a yard or on the
      # roof.
      places = Map.new(build.rooms, &{&1.id, &1.place})
      shown = MapSet.new(for %{kind: :item, id: id} <- view.level.objects, do: id)

      for item <- build.items, item.id in shown do
        refute item.planned
        assert places[item.room] in [:outdoor, :roof]
      end

      # Two objects that cover each other on the screen: the one behind paints
      # first. An item larger than its room goes through its walls, and an
      # item taller than floor 1 goes past the floors over it. Then no order
      # is right.
      big =
        MapSet.new(
          for(item <- build.items, not fits?(build, item), do: item.id) ++
            for(
              %{kind: :item, box: {_, _, z0, _, _, z1}, id: id} <- view.level.objects,
              z1 - z0 > 2.7,
              do: id
            )
        )

      indexed =
        view.level.objects
        |> Enum.reject(&MapSet.member?(big, &1.id))
        |> Enum.map(&{&1, screen(&1)})
        |> Enum.with_index()

      for {{a, sa}, i} <- indexed,
          {{b, sb}, j} <- indexed,
          i < j,
          not on_floor?(a, b),
          cover?(sa, sb) do
        refute behind?(b.box, a.box) and not behind?(a.box, b.box),
               "#{b.id} is behind #{a.id}, but it paints after it: #{inspect({b.box, a.box})}"
      end
    end
  end

  defp fits?(build, item) do
    {:ok, %{plan: %{w: w, d: d}}} = Build.room(build, item.room)
    {ew, ed} = DIY.Layout.extent(item)
    ew <= w and ed <= d
  end

  defp behind?({_, _, _, ax1, ay1, az1}, {bx0, by0, bz0, _, _, _}),
    do: ax1 <= bx0 + 1.0e-6 or ay1 <= by0 + 1.0e-6 or az1 <= bz0 + 1.0e-6

  defp cover?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01

  defp on_floor?(%{box: {_, _, az0, _, _, az1}}, %{box: {_, _, bz0, _, _, _}}),
    do: az1 - az0 <= 0.02 and bz0 >= az0 - 1.0e-6

  defp screen(object) do
    {xs, ys} =
      object.polys
      |> Enum.flat_map(fn {points, _class} -> String.split(points) end)
      |> Enum.map(fn pair ->
        pair |> String.split(",") |> Enum.map(&number/1) |> List.to_tuple()
      end)
      |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp box(html) do
    [_, box] = Regex.run(~r/viewBox="([^"]+)"/, html)
    box |> String.split() |> Enum.map(&number/1)
  end

  defp points(html) do
    for [_, list] <- Regex.scan(~r/points="([^"]+)"/, html),
        pair <- String.split(list),
        do: pair |> String.split(",") |> Enum.map(&number/1)
  end

  defp number(text), do: text |> Float.parse() |> elem(0)
end
