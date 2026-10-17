defmodule DIY.BuildUnitsTest do
  @moduledoc "The links of the power stations to the units of a maker (`DIY.Build.link_unit/3`)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, House}

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp garage(build), do: Enum.find(build.rooms, &(&1.name == "Garage")).id

  defp stations(n) do
    Enum.reduce(1..n, {house(), []}, fn _n, {build, ids} ->
      {:ok, build, id} = Build.add_item(build, garage(build), "power_station")
      {build, ids ++ [id]}
    end)
  end

  test "a station links to a unit, one unit for each station" do
    {build, [s1, s2]} = stations(2)
    assert Build.unit?("pecron:dev_1")
    refute Build.unit?("pecron:")
    refute Build.unit?("ecoflow:dev_1")
    refute Build.unit?("pecron:dev/1")
    refute Build.unit?(5)

    {:ok, linked} = Build.link_unit(build, s1, "pecron:dev_1")
    assert linked.units == %{s1 => "pecron:dev_1"}
    assert linked.revision == build.revision + 1
    assert Build.unit_item(linked, "pecron:dev_1") == s1
    assert Build.unit_item(linked, "pecron:dev_2") == nil

    # The same link again, a unit of a different station, a different item,
    # and a unit that is not a unit.
    assert {:ok, _same} = Build.link_unit(linked, s1, "pecron:dev_1")
    assert Build.link_unit(linked, s2, "pecron:dev_1") == {:error, :taken}
    fridge = Enum.find(build.items, &(&1.type == "fridge")).id
    assert Build.link_unit(linked, fridge, "pecron:dev_2") == {:error, :item}
    assert Build.link_unit(linked, "no such item", "pecron:dev_2") == {:error, :item}
    assert Build.link_unit(linked, s2, "pecron:") == {:error, :unit}

    # A new unit for the station, and the end of the link.
    {:ok, moved} = Build.link_unit(linked, s1, "pecron:dev_2")
    assert moved.units == %{s1 => "pecron:dev_2"}
    {:ok, unlinked} = Build.unlink_unit(moved, s1)
    assert unlinked.units == %{}
    assert Build.unlink_unit(unlinked, s1) == {:error, :item}

    # A station that goes away takes its link with it. A new house has no
    # links.
    {:ok, gone} = Build.delete_item(linked, s1)
    assert gone.units == %{}

    {house, rooms, items} =
      House.preset(%{size: 1200, year: 1990, floors: 1, heat: "gas", lot: nil})

    assert Build.put_house(linked, house, rooms, items).units == %{}
  end

  test "an item of a device of Home Assistant gets no unit, also in a stored build" do
    build = house()
    {:ok, build, ha} = Build.add_device(build, garage(build), "power_station", "ha_dev_1")
    assert Build.link_unit(build, ha, "pecron:dev_1") == {:error, :device}
    {:ok, build, other} = Build.add_item(build, garage(build), "power_station")

    # The item of the device loses its unit. A different station keeps its
    # unit: the device of one item does not end the links of the others.
    json =
      build
      |> Build.to_json()
      |> Jason.decode!()
      |> Map.put("units", %{ha => "pecron:dev_1", other => "pecron:dev_2"})

    assert {:ok, loaded} = json |> Jason.encode!() |> Build.from_json()
    assert loaded.units == %{other => "pecron:dev_2"}
  end

  test "a stored build keeps its links, and an old build has none" do
    {build, [s1, _s2]} = stations(2)
    {:ok, linked} = Build.link_unit(build, s1, "pecron:dev_1")
    {:ok, loaded} = linked |> Build.to_json() |> Build.from_json()
    assert loaded.units == %{s1 => "pecron:dev_1"}

    old = linked |> Build.to_json() |> Jason.decode!() |> Map.delete("units") |> Jason.encode!()
    assert {:ok, loaded} = Build.from_json(old)
    assert loaded.units == %{}

    bad =
      linked |> Build.to_json() |> Jason.decode!() |> Map.put("units", "none") |> Jason.encode!()

    assert {:ok, loaded} = Build.from_json(bad)
    assert loaded.units == %{}
  end

  property "a stored build keeps only the links that it can read: a station, a unit, one station for each unit" do
    {build, ids} = stations(3)
    fridge = Enum.find(build.items, &(&1.type == "fridge")).id
    items = ids ++ [fridge, "no such item"]
    units = ["pecron:a", "pecron:b", "pecron:", "ecoflow:a", 5, nil]

    check all(links <- map(list_of(tuple({member_of(items), member_of(units)})), &Map.new/1)) do
      json =
        build |> Build.to_json() |> Jason.decode!() |> Map.put("units", links) |> Jason.encode!()

      {:ok, loaded} = Build.from_json(json)

      for {item, unit} <- loaded.units do
        assert item in ids
        assert Build.unit?(unit)
        assert links[item] == unit
      end

      assert loaded.units
             |> Map.values()
             |> Enum.frequencies()
             |> Map.values()
             |> Enum.all?(&(&1 == 1))

      # Each good unit of a station is in the build, at one station.
      for {item, unit} <- links, item in ids, Build.unit?(unit) do
        assert Build.unit_item(loaded, unit) != nil
      end
    end
  end
end
