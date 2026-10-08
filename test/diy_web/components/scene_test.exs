defmodule DIYWeb.SceneTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Van}
  alias DIYWeb.Scene

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

  defp picture(build, flows \\ true),
    do: render_component(&Scene.house/1, id: "t", build: build, flows: flows)

  test "a plain house: its floors, its garage, the grid, and no equipment" do
    html = picture(house())
    assert html =~ ~s(class="scene w-full)
    assert html =~ "s-gdoor"
    assert html =~ "Grid"
    refute html =~ ~s(class="s-pv")
    refute html =~ "s-station"
    assert Scene.label(house()) == "A house with 2 floors, an AC"

    # Three floors: a taller picture.
    [_, tall] = Regex.run(~r/viewBox="0 (-?[\d.]+)/, picture(house(3)))
    [_, short] = Regex.run(~r/viewBox="0 (-?[\d.]+)/, html)
    assert elem(Float.parse(tall), 0) < elem(Float.parse(short), 0)
  end

  test "the equipment of the house, and the flows of its power" do
    build = house()
    {build, _} = add(build, room(build, "Roof"), "solar_panels", %{"watts" => "1600"})
    {build, _} = add(build, room(build, "Backyard"), "solar_panels", %{"watts" => "800"})
    {build, _} = add(build, room(build, "Laundry"), "power_station", %{"extra_kwh" => "3.6"})
    {build, _} = add(build, room(build, "Garage"), "transfer_switch")
    {build, _} = add(build, room(build, "Backyard"), "pool_pump")
    {build, _} = add(build, room(build, "Driveway"), "ev")
    html = picture(build)

    assert html =~ "2.4 kW"
    assert html =~ "5.6 kWh"
    assert html =~ "s-flow-sun"
    assert html =~ "s-flow-battery"
    assert html =~ "s-water"
    assert html =~ "s-car-l"

    assert Scene.label(build) ==
             "A house with 2 floors, solar panels on the roof, solar panels in the yard, " <>
               "a power station, an AC, a pool, an electric car"

    # With no flows: no labels and no flows.
    html = picture(build, false)
    refute html =~ "s-flow"
    refute html =~ "kWh"
  end

  test "panels on the grid, panels of a station in a van, and small panels" do
    build = house()

    {grid, _} =
      add(build, room(build, "Roof"), "solar_panels", %{"to" => "grid", "watts" => "300"})

    assert picture(grid) =~ "s-flow-sun"
    assert picture(grid) =~ "300 W"

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
    assert html =~ "s-van-r"
    assert html =~ ~s(class="s-pv")
    assert Scene.label(build) =~ "a camper van"
  end

  test "the van with its two budgets" do
    build = house()
    {build, van} = add(build, room(build, "Driveway"), "camper_van")
    {:ok, item} = Build.item(build, van)
    weight = Van.weight(build, item)
    html = render_component(&Scene.van/1, id: "v", build: build, van: item, weight: weight)
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
    power = %{storage: 2160.0}

    html =
      render_component(&Scene.van/1,
        id: "v",
        build: build,
        van: item,
        weight: Van.weight(build, item),
        power: power
      )

    assert html =~ "s-chip-bad"
    assert html =~ "2,160 Wh"
    assert html =~ "400 W"
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
  end
end
