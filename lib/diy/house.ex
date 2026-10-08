defmodule DIY.House do
  @moduledoc """
  The presets of a house: "a house like mine" by size, age, floors and
  heat. A preset gives the rooms of the house and its typical items. Each
  item of a preset is typical: the user can check its numbers, change them,
  or remove the item.

  The typical numbers are guesses of the app for a house of that size and
  age. The page tells the user so.
  """

  alias DIY.Catalog

  @sizes [
    {"small", "Small", 1_200},
    {"medium", "Medium", 1_800},
    {"large", "Large", 2_500},
    {"very_large", "Very large", 3_500}
  ]

  @ages [
    {"before_1980", "Before 1980", 1_970},
    {"1980s_1990s", "1980 to 1999", 1_990},
    {"2000s", "2000 to 2009", 2_005},
    {"since_2010", "2010 or newer", 2_016}
  ]

  @heats [
    {"gas", "Gas", "A gas furnace, a gas water heater and a gas stove."},
    {"heat_pump", "Heat pump", "All electric: the AC heats too."},
    {"electric", "Electric heat", "All electric: heat strips or baseboard heaters."}
  ]

  @doc "The sizes of a preset: `{key, label, square feet}`."
  def sizes, do: @sizes

  @doc "The ages of a preset: `{key, label, year}`."
  def ages, do: @ages

  @doc "The kinds of heat: `{key, label, description}`."
  def heats, do: @heats

  @doc """
  The house, the rooms and the typical items of a preset. The house is a
  map with `size`, `year`, `floors`, `heat` and `lot`.
  """
  @spec preset(DIY.Build.house()) :: {DIY.Build.house(), [map()], [map()]}
  def preset(house) do
    {house, rooms(house.floors), items(house)}
  end

  @doc """
  A house from nothing, for "a house I'm planning": the rooms, with no
  items. The estimate shows when the house has an AC.
  """
  @spec scratch(DIY.Build.house()) :: {DIY.Build.house(), [map()], [map()]}
  def scratch(house), do: {house, rooms(house.floors), []}

  defp rooms(floors) do
    bedrooms_floor = if floors == 1, do: "f1", else: "f2"

    [
      room(:roof, "Roof", "roof", :roof),
      room(:attic, "Attic", "roof", :indoor)
    ] ++
      if(floors == 3, do: [room(:game, "Game room", "f3", :indoor)], else: []) ++
      [
        room(:bedroom1, "Bedroom 1", bedrooms_floor, :indoor),
        room(:bedroom2, "Bedroom 2", bedrooms_floor, :indoor),
        room(:bathroom, "Bathroom", bedrooms_floor, :indoor),
        room(:kitchen, "Kitchen", "f1", :indoor),
        room(:living, "Living room", "f1", :indoor),
        room(:laundry, "Laundry", "f1", :indoor),
        room(:garage, "Garage", "outside", :indoor),
        room(:backyard, "Backyard", "outside", :outdoor),
        room(:driveway, "Driveway", "outside", :outdoor)
      ]
  end

  defp room(key, name, level, place), do: %{key: key, name: name, level: level, place: place}

  defp items(%{size: size, year: year, heat: heat}) do
    gas = heat == "gas"

    [
      item(:backyard, "ac", %{
        "tons" => tons(size),
        "seer2" => seer2(year),
        "heat_pump" => heat == "heat_pump"
      })
    ] ++
      heater(heat, size) ++
      [
        item(:garage, "water_heater", %{
          "fuel" => if(gas, do: "gas", else: "electric"),
          "people" => people(size)
        }),
        item(:kitchen, "fridge", %{}),
        item(:kitchen, "range", %{"fuel" => if(gas, do: "gas", else: "electric")}),
        item(:kitchen, "microwave", %{}),
        item(:kitchen, "dishwasher", %{}),
        item(:laundry, "washer", %{}),
        item(:laundry, "dryer", %{}),
        item(:living, "tv", %{}),
        item(:living, "lights", %{"bulbs" => max(div(size, 60), 10), "watts" => 10}),
        item(:living, "ceiling_fan", %{"count" => max(div(size, 500), 1)}),
        item(:living, "always_on", %{"watts" => 150}),
        item(:living, "other", %{
          "name" => "Small devices",
          "watts" => 300,
          "hours" => 4.0,
          "season" => "all"
        }),
        item(:bedroom1, "computer", %{})
      ]
  end

  defp heater("gas", _size), do: [item(:attic, "furnace", %{})]
  defp heater("heat_pump", _size), do: []

  defp heater("electric", size),
    do: [item(:attic, "heat_strips", %{"kw" => min(max(round(size / 200), 5), 20) / 1})]

  defp item(room, type, params),
    do: %{room: room, type: type, params: Map.merge(Catalog.defaults(type), params)}

  # One ton of cooling for near 550 square feet, in steps of half a ton.
  defp tons(size), do: (round(size / 550 * 2) / 2) |> max(1.5) |> min(5.0)

  # The SEER2 of the AC that the house typically has now. An old house often
  # has a replaced unit, and the federal minimum went up in 1992, 2006, 2015
  # and 2023.
  defp seer2(year) when year < 1992, do: 9.5
  defp seer2(year) when year < 2006, do: 10.5
  defp seer2(year) when year < 2015, do: 12.4
  defp seer2(year) when year < 2023, do: 13.4
  defp seer2(_year), do: 14.3

  defp people(size) when size < 1_500, do: 2
  defp people(size) when size < 2_200, do: 3
  defp people(_size), do: 4
end
