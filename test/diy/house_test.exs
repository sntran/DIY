defmodule DIY.HouseTest do
  use ExUnit.Case, async: true

  alias DIY.{Build, Catalog, House}

  defp items(house),
    do:
      House.preset(Map.merge(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil}, house))
      |> elem(2)

  defp item(house, type), do: Enum.find(items(house), &(&1.type == type))

  test "each preset gives rooms on the levels of its floors, and valid items" do
    for {_key, _label, size} <- House.sizes(),
        {_key, _label, year} <- House.ages(),
        floors <- 1..3,
        {heat, _label, _text} <- House.heats() do
      house = %{size: size, year: year, floors: floors, heat: heat, lot: nil}
      {^house, rooms, items} = House.preset(house)
      keys = Enum.map(rooms, & &1.key)
      assert keys == Enum.uniq(keys)
      assert Enum.all?(rooms, &(&1.level in Build.levels(floors)))

      for item <- items do
        room = Enum.find(rooms, &(&1.key == item.room))
        assert room.place in Catalog.kind(item.type).places
        assert Catalog.params(item.type, item.params) == {:ok, item.params}
      end
    end
  end

  test "the heat gives the heater, and the fuel of the water heater and of the stove" do
    assert item(%{heat: "gas"}, "furnace")
    assert item(%{heat: "gas"}, "water_heater").params["fuel"] == "gas"
    assert item(%{heat: "gas"}, "range").params["fuel"] == "gas"
    refute item(%{heat: "gas"}, "ac").params["heat_pump"]

    assert item(%{heat: "heat_pump"}, "ac").params["heat_pump"]
    refute item(%{heat: "heat_pump"}, "furnace")
    assert item(%{heat: "heat_pump"}, "water_heater").params["fuel"] == "electric"

    assert item(%{heat: "electric"}, "heat_strips").params["kw"] == 9.0
    assert item(%{heat: "electric", size: 600}, "heat_strips").params["kw"] == 5.0
    assert item(%{heat: "electric", size: 9000}, "heat_strips").params["kw"] == 20.0
  end

  test "the size of the AC and of the family follow the size of the house" do
    assert item(%{size: 1200}, "ac").params["tons"] == 2.0
    assert item(%{size: 2500}, "ac").params["tons"] == 4.5
    assert item(%{size: 500}, "ac").params["tons"] == 1.5
    assert item(%{size: 9000}, "ac").params["tons"] == 5.0
    assert item(%{size: 1200}, "water_heater").params["people"] == 2
    assert item(%{size: 1800}, "water_heater").params["people"] == 3
    assert item(%{size: 3500}, "water_heater").params["people"] == 4
  end

  test "the SEER2 of the AC follows the age of the house" do
    assert item(%{year: 1970}, "ac").params["seer2"] == 9.5
    assert item(%{year: 1995}, "ac").params["seer2"] == 10.5
    assert item(%{year: 2010}, "ac").params["seer2"] == 12.4
    assert item(%{year: 2020}, "ac").params["seer2"] == 13.4
    assert item(%{year: 2026}, "ac").params["seer2"] == 14.3
  end

  test "a house from nothing has the rooms and no items" do
    {_house, rooms, items} =
      House.scratch(%{size: 1500, year: 2026, floors: 1, heat: "gas", lot: 8000})

    assert items == []
    assert Enum.any?(rooms, &(&1.name == "Kitchen" and &1.level == "f1"))
    assert Enum.any?(rooms, &(&1.name == "Bedroom 1" and &1.level == "f1"))
  end
end
