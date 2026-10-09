defmodule DIYWeb.SceneTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, House}
  alias DIYWeb.{Camera, Scene}

  defp house(floors \\ 2) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: floors, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id

  defp add(build, room, type, params \\ %{}) do
    {:ok, build, id} = Build.add_item(build, room, type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  defp picture(build),
    do: render_component(&Scene.house/1, id: "t", parts: Scene.parts(build))

  test "a plain house: its floors, its garage, the grid, and no equipment" do
    html = picture(house())
    assert html =~ ~s(class="scene w-full)
    assert html =~ "s-gdoor"
    assert html =~ "Grid"
    refute html =~ ~s(class="s-pv")
    refute html =~ "s-station"
    refute html =~ "s-flow-sun"
    assert Scene.label(Scene.parts(house())) == "a house with 2 floors, an AC"

    # Three floors: a taller picture.
    [_x, _y, _w, tall] = box(picture(house(3)))
    [_x, _y, _w, short] = box(html)
    assert tall > short
  end

  test "the equipment of the house, and the flows of its power" do
    build = house()
    {build, _} = add(build, room(build, "Roof"), "solar_panels", %{"watts" => "1600"})
    {build, _} = add(build, room(build, "Backyard"), "solar_panels", %{"watts" => "800"})

    {build, _} =
      add(build, room(build, "Laundry"), "power_station", %{
        "extra_kwh" => "3.6",
        "feeds" => "panel"
      })

    {build, _} = add(build, room(build, "Laundry"), "power_station")
    {build, _} = add(build, room(build, "Garage"), "transfer_switch")
    {build, _} = add(build, room(build, "Backyard"), "pool_pump")
    {build, _} = add(build, room(build, "Driveway"), "ev")
    html = picture(build)

    assert html =~ "1.6 kW"
    assert html =~ "800 W"
    assert html =~ "7.6 kWh"
    assert html =~ "s-flow-sun"
    assert html =~ "s-flow-battery"
    assert html =~ "s-water"
    assert html =~ "s-car-l"

    assert Scene.label(Scene.parts(build)) ==
             "a house with 2 floors, solar panels on the roof, solar panels in the yard, " <>
               "2 power stations, an AC, a pool, an electric car"
  end

  test "a station on plugs gives no flow to the panel, and planned items do not show" do
    build = house()
    {build, _} = add(build, room(build, "Laundry"), "power_station")
    {build, _} = add(build, room(build, "Garage"), "transfer_switch")
    refute picture(build) =~ "s-flow-battery"

    {:ok, build, panels} = Build.add_item(build, room(build, "Roof"), "solar_panels")
    {:ok, planned} = Build.flag_item(build, panels, :planned, true)
    refute picture(planned) =~ ~s(class="s-pv")
    refute Scene.label(Scene.parts(planned)) =~ "solar panels"
    assert picture(build) =~ ~s(class="s-pv")
  end

  test "panels on the grid, mixed panels, and panels of a station in a van" do
    build = house()

    {grid, _} =
      add(build, room(build, "Roof"), "solar_panels", %{"to" => "grid", "watts" => "300"})

    assert picture(grid) =~ "s-flow-sun"
    assert picture(grid) =~ "300 W"

    # Panels in the yard on the grid: a flow to the meter. Panels on the
    # roof to a station: a flow to the station. Each has its label.
    {mixed, _} = add(build, room(build, "Laundry"), "power_station")
    {mixed, _} = add(mixed, room(build, "Roof"), "solar_panels", %{"watts" => "1200"})

    {mixed, _} =
      add(mixed, room(build, "Backyard"), "solar_panels", %{"to" => "grid", "watts" => "2000"})

    html = picture(mixed)
    assert length(Regex.scan(~r/s-flow-sun/, html)) == 2
    assert html =~ "1.2 kW" and html =~ "2 kW"

    # The station of the panels is in the van: the sun gives nothing.
    {build, _} = add(build, room(build, "Roof"), "solar_panels")
    {build, station} = add(build, room(build, "Laundry"), "power_station")
    {build, van} = add(build, room(build, "Driveway"), "camper_van")
    {:ok, away} = Build.take_to_van(build, station, van)
    refute picture(away) =~ "s-flow-sun"
    assert picture(build) =~ "s-flow-sun"
  end

  test "a house with no garage, and a van with panels and a fan" do
    build = house(1)
    {:ok, build} = Build.delete_room(build, room(build, "Garage"))
    {build, van} = add(build, room(build, "Driveway"), "camper_van")
    {build, _} = add(build, Build.zone(build, van, :van_roof).id, "van_solar")
    {build, _} = add(build, Build.zone(build, van, :living).id, "van_fan")
    html = picture(build)
    refute html =~ "s-gdoor"
    assert html =~ ~s(class="i-white-)
    assert html =~ ~s(class="s-pv")
    assert Scene.label(Scene.parts(build)) =~ "a camper van"
  end

  test "the labels of the axles are at the axles of each model of van" do
    for model <- models() do
      build = house()
      {build, van} = add(build, room(build, "Driveway"), "camper_van", %{"model" => model})
      {:ok, item} = Build.item(build, van)
      html = render_component(&Scene.van/1, id: "v", parts: Scene.van_parts(build, item))
      size = DIY.Catalog.van_size(model)
      front = (size.length - size.front) * 0.0254
      rear = front - size.wheelbase * 0.0254

      for {name, y} <- [{"Front", front}, {"Rear", rear}] do
        {sx, sy} = Camera.at(Camera.van(), {0, 0}, {size.width * 0.0254 + 1.0, y, 0.0})
        at = "translate(#{Camera.round1(sx)} #{Camera.round1(sy)})"

        assert html =~
                 ~r/#{Regex.escape(at)} scale\([\d.]+\)">\s*<rect[^>]*><\/rect>\s*<text[^>]*>#{name} /
      end
    end
  end

  test "the van with its two budgets" do
    build = house()
    {build, van} = add(build, room(build, "Driveway"), "camper_van")
    {:ok, item} = Build.item(build, van)
    html = render_component(&Scene.van/1, id: "v", parts: Scene.van_parts(build, item))
    assert html =~ ~r/Front [\d,]+ lb/
    assert html =~ ~r/Rear [\d,]+ lb/
    assert html =~ ~s(width="92.4")
    refute html =~ "s-chip-bad"
    refute html =~ " Wh<"

    # Over the rating of the rear axle, a battery, and panels.
    {build, _} = add(build, Build.zone(build, van, :bed).id, "storage", %{"weight" => "3000"})
    {build, _} = add(build, Build.zone(build, van, :bed).id, "storage", %{"weight" => "1500"})
    {build, _} = add(build, Build.zone(build, van, :bay).id, "van_battery")
    {build, _} = add(build, Build.zone(build, van, :van_roof).id, "van_solar")
    {:ok, item} = Build.item(build, van)
    html = render_component(&Scene.van/1, id: "v", parts: Scene.van_parts(build, item))
    assert html =~ "s-chip-bad"
    assert html =~ "2,160 Wh"
    assert html =~ "400 W"

    # A planned panel: the page Van counts it, and the house does not show it.
    {:ok, build, panel} = Build.add_item(build, Build.zone(build, van, :van_roof).id, "van_solar")
    {:ok, build} = Build.flag_item(build, panel, :planned, true)
    {:ok, item} = Build.item(build, van)
    assert Scene.van_parts(build, item).solar == 800
    assert Scene.parts(build).van.solar == 400
  end

  test "the two houses of the first page" do
    house = render_component(&Scene.sample/1, id: "a")
    plan = render_component(&Scene.sample/1, id: "b", plan: true)
    assert house =~ "s-sun"
    assert house =~ "s-leaf-l"
    assert plan =~ "scene-plan"
    assert plan =~ "s-plan"
    refute plan =~ "s-sun"
    refute plan =~ "s-leaf-l"
    # The plan uses no gradient of the house.
    refute plan =~ "b-s-grass"
  end

  # The parts of a picture of a house.
  defp parts do
    gen all(
          floors <- integer(1..3),
          [garage, panel, switch, ac, pool, car] <- list_of(boolean(), length: 6),
          roof <- fixed_map(%{station: watts(), grid: watts()}),
          yard <- fixed_map(%{station: watts(), grid: watts()}),
          stations <- list_of(tuple({float(min: 0.1, max: 30.0), boolean()}), max_length: 3),
          van <-
            one_of([
              constant(nil),
              fixed_map(%{solar: watts(), fan: boolean(), model: member_of(models())})
            ])
        ) do
      %{
        floors: floors,
        garage: garage,
        roof: roof,
        yard: yard,
        stations: stations,
        panel: panel and stations != [],
        switch: switch,
        ac: ac,
        pool: pool,
        car: car,
        van: van
      }
    end
  end

  defp models, do: Enum.map(DIY.Catalog.van_models(), &elem(&1, 0))

  defp watts, do: one_of([constant(0), integer(1..20_000)])

  defp roof?(parts), do: parts.roof.station + parts.roof.grid > 0
  defp yard?(parts), do: parts.yard.station + parts.yard.grid > 0

  property "each point of a picture of a house is in its box, and each label has its equipment" do
    check all(parts <- parts()) do
      html = render_component(&Scene.house/1, id: "p", parts: parts)
      [x, y, w, h] = box(html)

      # Each label of the equipment, and the label of the grid.
      assert length(chips(html)) ==
               4 * Enum.count([true, roof?(parts), yard?(parts), parts.stations != []], & &1)

      for [px, py] <- points(html) ++ chips(html) do
        assert px >= x and px <= x + w and py >= y and py <= y + h
      end

      # No label covers the van or the car.
      for object <- ["i-white", "s-car"],
          box = screen_box(html, object),
          box != nil,
          label <- Enum.chunk_every(chips(html), 4) do
        refute overlap?(box, label), "a label covers #{object}"
      end

      assert html =~ "kWh" == (parts.stations != [])
      assert html =~ "s-flow-battery" == parts.panel

      assert html =~ "s-flow-sun" ==
               (parts.roof.grid + parts.yard.grid > 0 or
                  (parts.stations != [] and parts.roof.station + parts.yard.station > 0))

      # The van is the only white part of the picture.
      assert html =~ ~s(class="i-white-) == (parts.van != nil)
      assert html =~ "s-car-l" == parts.car
    end
  end

  test "the box of a picture holds the lot, and the sun is in its sky" do
    html = picture(house())
    [x, y, w, h] = box(html)

    # The four corners of the bottom of the lot.
    for corner <- [{-3.0, -2.5, -1.2}, {19.0, -2.5, -1.2}, {19.0, 13.5, -1.2}, {-3.0, 13.5, -1.2}] do
      {sx, sy} = Camera.at(Camera.house(), {0, 0}, corner)
      assert sx >= x and sx <= x + w and sy >= y and sy <= y + h
    end

    [_, cx, cy] =
      Regex.run(~r/<circle cx="(-?[\d.]+)" cy="(-?[\d.]+)" r="14" class="s-sun"/, html)

    {cx, cy} = {elem(Float.parse(cx), 0), elem(Float.parse(cy), 0)}
    assert cx - 14 > x and cy - 14 > y and cy + 14 <= y + 44
  end

  defp box(html) do
    [_, box] = Regex.run(~r/viewBox="([^"]+)"/, html)
    box |> String.split() |> Enum.map(&(&1 |> Float.parse() |> elem(0)))
  end

  # The corners of the labels: a label is a rect at a point, with a scale.
  defp chips(html) do
    for [_, x, y, k, rx, w] <-
          Regex.scan(
            ~r/translate\((-?[\d.]+) (-?[\d.]+)\) scale\(([\d.]+)\)">\s*<rect x="(-?[\d.]+)" y="-8" width="([\d.]+)" height="15"/,
            html
          ),
        [x, y, k, rx, w] = Enum.map([x, y, k, rx, w], &(&1 |> Float.parse() |> elem(0))),
        {dx, dy} <- [{rx, -8}, {rx + w, -8}, {rx, 7}, {rx + w, 7}],
        do: [x + dx * k, y + dy * k]
  end

  # The box on the screen of the polygons of an object (by the start of
  # their class), or nil.
  defp screen_box(html, object) do
    case for [_, list] <- Regex.scan(~r/points="([^"]+)" class="#{object}-/, html),
             pair <- String.split(list),
             do: pair |> String.split(",") |> Enum.map(&(&1 |> Float.parse() |> elem(0))) do
      [] ->
        nil

      points ->
        {xs, ys} = points |> Enum.map(&List.to_tuple/1) |> Enum.unzip()
        {Enum.min_max(xs), Enum.min_max(ys)}
    end
  end

  # True when the box of a label and the box of an object overlap.
  defp overlap?({{x0, x1}, {y0, y1}}, [[a0, b0], _, _, [a1, b1]]),
    do: a0 < x1 and a1 > x0 and b0 < y1 and b1 > y0

  # The points of the polygons.
  defp points(html) do
    for [_, list] <- Regex.scan(~r/points="([^"]+)"/, html),
        pair <- String.split(list),
        do: pair |> String.split(",") |> Enum.map(&(&1 |> Float.parse() |> elem(0)))
  end
end
