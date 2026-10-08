defmodule DIY.Catalog.Param do
  @moduledoc false
  # The parameters of the kinds of DIY.Catalog, at compile time.

  # The months of a season. "warm" is the months when a fan or a pool pump
  # runs in the South, "cold" the months of a space heater.
  @seasons [
    {"all", "All year", Enum.to_list(1..12)},
    {"warm", "April to October", Enum.to_list(4..10)},
    {"summer", "May to September", Enum.to_list(5..9)},
    {"cold", "November to March", [11, 12, 1, 2, 3]},
    {"winter", "December to February", [12, 1, 2]}
  ]

  def season(default) do
    %{
      key: "season",
      label: "Months in use",
      unit: nil,
      type: {:choice, Enum.map(seasons(), fn {key, label, _} -> {key, label} end)},
      default: default,
      note: nil
    }
  end

  def int(key, label, unit, default, min, max, note \\ nil),
    do: %{
      key: key,
      label: label,
      unit: unit,
      type: :int,
      default: default,
      min: min,
      max: max,
      note: note
    }

  def float(key, label, unit, default, min, max, note),
    do: %{
      key: key,
      label: label,
      unit: unit,
      type: :float,
      default: default,
      min: min,
      max: max,
      note: note
    }

  def choice(key, label, values, default),
    do: %{key: key, label: label, unit: nil, type: {:choice, values}, default: default, note: nil}

  def seasons, do: @seasons
end

defmodule DIY.Catalog do
  @moduledoc """
  The kinds of items that a user can put in a room. Each kind has its
  numbers (the parameters), the places where it can go, and the features
  that it turns on.

  A parameter is a map:

  - `key`, `label`, and `unit` (or `nil`).
  - `type`: `:int`, `:float`, `:bool`, `:text`, or `{:choice, values}`,
    where each value is `{key, label}`.
  - `default`, and `min` and `max` for a number.
  - `note`: where the user finds the number, or `nil`.

  The calculations of the kinds are in `DIY.Estimate`.
  """

  import DIY.Catalog.Param

  @places [:indoor, :outdoor, :roof]
  @seasons DIY.Catalog.Param.seasons()

  @fuels [{"electric", "Electric"}, {"gas", "Gas"}]

  @kinds [
    %{
      type: "ac",
      name: "Central AC",
      emoji: "❄️",
      places: [:outdoor, :roof],
      features: [:estimate],
      params: [
        float(
          "tons",
          "Size",
          "tons",
          3.0,
          1.0,
          6.0,
          "The model number on the outside unit has the size: 36 is 3 tons (36,000 BTU an hour)."
        ),
        float(
          "seer2",
          "Efficiency",
          "SEER2",
          13.4,
          8.0,
          30.0,
          "The yellow EnergyGuide label gives the SEER2. An old unit is near 9 to 11."
        ),
        %{
          key: "heat_pump",
          label: "It is a heat pump (it heats too)",
          unit: nil,
          type: :bool,
          default: false,
          note: nil
        },
        float(
          "hspf2",
          "Heat efficiency",
          "HSPF2",
          7.5,
          5.0,
          14.0,
          "Only for a heat pump. The EnergyGuide label gives the HSPF2."
        )
      ]
    },
    %{
      type: "mini_split",
      name: "Mini split or window AC",
      emoji: "🌬️",
      places: [:indoor],
      features: [:estimate],
      params: [
        int("area", "Area that it cools", "sq ft", 400, 50, 3000),
        float(
          "seer2",
          "Efficiency",
          "SEER2",
          12.0,
          8.0,
          40.0,
          "A window unit gives a CEER near 10 to 12. Use that number."
        ),
        %{
          key: "heat_pump",
          label: "It heats too",
          unit: nil,
          type: :bool,
          default: false,
          note: nil
        },
        float("hspf2", "Heat efficiency", "HSPF2", 8.5, 5.0, 14.0, "Only if it heats.")
      ]
    },
    %{
      type: "furnace",
      name: "Gas furnace",
      emoji: "🔥",
      places: [:indoor],
      features: [:estimate],
      params: [
        int(
          "blower",
          "Blower power",
          "W",
          500,
          100,
          1500,
          "The furnace uses gas for heat. Only its blower uses electricity."
        )
      ]
    },
    %{
      type: "heat_strips",
      name: "Electric heat",
      emoji: "♨️",
      places: [:indoor],
      features: [:estimate],
      params: [
        float(
          "kw",
          "Size",
          "kW",
          10.0,
          1.0,
          30.0,
          "Heat strips in the air handler, or baseboard heaters. The label on the air handler gives the kW."
        )
      ]
    },
    %{
      type: "smart_meter",
      name: "Smart meter",
      emoji: "📟",
      places: [:outdoor, :indoor],
      features: [:usage],
      params: []
    },
    %{
      type: "water_heater",
      name: "Water heater",
      emoji: "🚿",
      places: [:indoor, :outdoor],
      features: [:estimate],
      params: [
        choice(
          "fuel",
          "Fuel",
          [{"electric", "Electric"}, {"gas", "Gas"}, {"heat_pump", "Heat pump"}],
          "electric"
        ),
        int("people", "People in the house", nil, 3, 1, 12)
      ]
    },
    %{
      type: "fridge",
      name: "Fridge",
      emoji: "🧊",
      places: [:indoor],
      features: [:estimate],
      params: [
        int(
          "kwh_year",
          "Energy in one year",
          "kWh",
          500,
          100,
          2500,
          "The yellow EnergyGuide label gives this number. An old fridge uses more."
        )
      ]
    },
    %{
      type: "freezer",
      name: "Freezer",
      emoji: "🧊",
      places: [:indoor],
      features: [:estimate],
      params: [
        int(
          "kwh_year",
          "Energy in one year",
          "kWh",
          400,
          100,
          2500,
          "The yellow EnergyGuide label gives this number."
        )
      ]
    },
    %{
      type: "range",
      name: "Stove and oven",
      emoji: "🍳",
      places: [:indoor],
      features: [:estimate],
      params: [choice("fuel", "Fuel", @fuels, "electric")]
    },
    %{
      type: "microwave",
      name: "Microwave",
      emoji: "🍲",
      places: [:indoor],
      features: [:estimate],
      params: [
        int("watts", "Power", "W", 1200, 300, 3000),
        int("minutes", "Minutes in one day", "min", 15, 0, 300)
      ]
    },
    %{
      type: "dishwasher",
      name: "Dishwasher",
      emoji: "🍽️",
      places: [:indoor],
      features: [:estimate],
      params: [int("loads", "Loads in one week", nil, 4, 0, 21)]
    },
    %{
      type: "washer",
      name: "Clothes washer",
      emoji: "🧺",
      places: [:indoor],
      features: [:estimate],
      params: [int("loads", "Loads in one week", nil, 5, 0, 30)]
    },
    %{
      type: "dryer",
      name: "Clothes dryer",
      emoji: "🌀",
      places: [:indoor],
      features: [:estimate],
      params: [
        choice("fuel", "Fuel", @fuels, "electric"),
        int("loads", "Loads in one week", nil, 5, 0, 30)
      ]
    },
    %{
      type: "lights",
      name: "Lights",
      emoji: "💡",
      places: [:indoor, :outdoor],
      features: [:estimate],
      params: [
        int("bulbs", "Bulbs", nil, 30, 1, 300),
        int(
          "watts",
          "Power of one bulb",
          "W",
          9,
          1,
          150,
          "An LED bulb is near 9 W. An old bulb is 60 W."
        ),
        float("hours", "Hours in one day", "h", 3.0, 0.0, 24.0, nil)
      ]
    },
    %{
      type: "tv",
      name: "TV",
      emoji: "📺",
      places: [:indoor],
      features: [:estimate],
      params: [
        int("watts", "Power", "W", 100, 5, 1000),
        float("hours", "Hours in one day", "h", 5.0, 0.0, 24.0, nil)
      ]
    },
    %{
      type: "computer",
      name: "Computer",
      emoji: "💻",
      places: [:indoor],
      features: [:estimate],
      params: [
        int("watts", "Power", "W", 100, 5, 2000),
        float("hours", "Hours in one day", "h", 6.0, 0.0, 24.0, nil)
      ]
    },
    %{
      type: "ceiling_fan",
      name: "Ceiling fans",
      emoji: "🪭",
      places: [:indoor, :outdoor],
      features: [:estimate],
      params: [
        int("count", "Fans", nil, 3, 1, 30),
        int("watts", "Power of one fan", "W", 50, 5, 300),
        float("hours", "Hours in one day", "h", 8.0, 0.0, 24.0, nil),
        season("warm")
      ]
    },
    %{
      type: "always_on",
      name: "Always-on devices",
      emoji: "🔌",
      places: [:indoor],
      features: [:estimate],
      params: [
        int(
          "watts",
          "Power all the time",
          "W",
          100,
          0,
          3000,
          "The router, the modem, the alarm, and the devices that stay on standby. A smart plug can measure them."
        )
      ]
    },
    %{
      type: "pool_pump",
      name: "Pool pump",
      emoji: "🏊",
      places: [:outdoor],
      features: [:estimate],
      params: [
        int("watts", "Power", "W", 1100, 100, 4000, "A 1 HP pump uses near 1,100 W."),
        float("hours", "Hours in one day", "h", 8.0, 0.0, 24.0, nil),
        season("summer")
      ]
    },
    %{
      type: "space_heater",
      name: "Space heater",
      emoji: "🌡️",
      places: [:indoor],
      features: [:estimate],
      params: [
        int("watts", "Power", "W", 1500, 100, 5000),
        float("hours", "Hours in one day", "h", 4.0, 0.0, 24.0, nil),
        season("winter")
      ]
    },
    %{
      type: "power_station",
      name: "Power station",
      emoji: "🔋",
      places: [:indoor, :outdoor],
      features: [:backup, :shift, :power_view],
      params: [
        float(
          "kwh",
          "Battery",
          "kWh",
          2.0,
          0.1,
          100.0,
          "The label or the app of the station gives it in Wh: 2,048 Wh is 2.048 kWh."
        ),
        float(
          "extra_kwh",
          "Extra batteries",
          "kWh",
          0.0,
          0.0,
          200.0,
          "The sum of the expansion batteries that connect to the station."
        ),
        int(
          "output_w",
          "Output",
          "W",
          2400,
          100,
          30000,
          "The most power of its outlets, all the time (not the surge)."
        ),
        int(
          "charge_w",
          "Charge from the wall",
          "W",
          1800,
          50,
          20000,
          "The most power of its AC charge."
        ),
        int("solar_w", "Solar input", "W", 1000, 0, 20000, "The most solar power that it takes."),
        choice(
          "feeds",
          "It powers",
          [
            {"plug", "Items that plug into it"},
            {"panel", "Circuits of the house, through an inlet"}
          ],
          "plug"
        ),
        int(
          "cost",
          "Price",
          "$",
          1500,
          0,
          200_000,
          "What you paid, or what it costs: for the payback."
        )
      ]
    },
    %{
      type: "solar_panels",
      name: "Solar panels",
      emoji: "☀️",
      places: [:roof, :outdoor],
      features: [:solar],
      params: [
        int(
          "watts",
          "Size",
          "W",
          800,
          50,
          50000,
          "The sum of the watts on the labels of the panels."
        ),
        choice(
          "facing",
          "They face",
          [
            {"south", "South"},
            {"southeast", "South-east or south-west"},
            {"east", "East or west"},
            {"flat", "Up (flat)"}
          ],
          "south"
        ),
        choice(
          "to",
          "They connect to",
          [
            {"station", "A power station"},
            {"grid", "The house and the grid (a grid-tie inverter)"}
          ],
          "station"
        ),
        int(
          "cost",
          "Price",
          "$",
          800,
          0,
          200_000,
          "What you paid, or what they cost: for the payback."
        )
      ]
    },
    %{
      type: "transfer_switch",
      name: "Interlock, transfer switch or subpanel",
      emoji: "🔀",
      places: [:indoor, :outdoor],
      features: [:power_view],
      params: [
        choice(
          "device",
          "Device",
          [
            {"interlock", "Interlock kit on the main panel"},
            {"transfer", "Transfer switch"},
            {"subpanel", "Subpanel for the backup circuits, with a transfer switch"}
          ],
          "interlock"
        ),
        int(
          "cost",
          "Price",
          "$",
          300,
          0,
          50_000,
          "The device, the inlet and the work: for the payback."
        )
      ]
    },
    %{
      type: "ev",
      name: "Electric car",
      emoji: "🚗",
      places: [:outdoor, :indoor],
      features: [:ev],
      params: [
        int("miles", "Miles in one day", "mi", 30, 0, 500),
        float(
          "mi_kwh",
          "Efficiency",
          "mi/kWh",
          3.5,
          1.0,
          6.0,
          "The app of the car, or 100 ÷ the kWh/100 mi of the EPA label."
        ),
        choice(
          "charger",
          "Charger",
          [{"l1", "Level 1: a wall outlet (1.4 kW)"}, {"l2", "Level 2: 240 V (7.2 kW)"}],
          "l2"
        ),
        choice(
          "when",
          "It charges",
          [{"night", "At night"}, {"evening", "When I come home"}],
          "night"
        ),
        float("mpg", "The gas car that it replaces", "mpg", 25.0, 5.0, 80.0, nil),
        float("gas", "Price of gas", "$/gal", 2.7, 0.5, 10.0, "The price at your gas station.")
      ]
    },
    %{
      type: "other",
      name: "Other",
      emoji: "⚙️",
      places: @places,
      features: [:estimate],
      params: [
        %{key: "name", label: "Name", unit: nil, type: :text, default: "Other", note: nil},
        int("watts", "Power", "W", 100, 0, 20000, "The label on the device gives its power."),
        float("hours", "Hours in one day", "h", 1.0, 0.0, 24.0, nil),
        season("all")
      ]
    }
  ]

  @by_type Map.new(@kinds, &{&1.type, &1})

  @doc "All the kinds, in the order of the list of a new item."
  def kinds, do: @kinds

  @doc "The kind of a type, or `nil`."
  def kind(type), do: Map.get(@by_type, type)

  @doc "The types of all the kinds."
  def types, do: Map.keys(@by_type)

  @doc "The places of a room: inside, outside, or on the roof."
  def places, do: @places

  @doc "The kinds that can go in a place."
  def kinds_for(place), do: Enum.filter(@kinds, &(place in &1.places))

  @doc "The months of a season."
  def season_months(season) do
    {_key, _label, months} = List.keyfind(@seasons, season, 0)
    months
  end

  @doc "The name of a season, for example \"May to September\"."
  def season_label(season) do
    {_key, label, _months} = List.keyfind(@seasons, season, 0)
    label
  end

  @doc "The parameters of a type with their default values."
  def defaults(type), do: Map.new(kind(type).params, &{&1.key, &1.default})

  @doc """
  The name of an item: the name of its kind, or the name that the user gave
  to an item of the kind "Other".
  """
  def name(%{type: "other", params: %{"name" => name}}), do: name
  def name(%{type: type}), do: kind(type).name

  @doc """
  Reads the parameters of an item of a type, from the map of a form or of a
  stored build. A parameter that is not in the values gets its default value, and an unknown
  key goes away. The error names the first parameter that is not valid.
  """
  @spec params(String.t(), map()) :: {:ok, map()} | {:error, {:param, String.t()}}
  def params(type, values) when is_map(values) do
    Enum.reduce_while(kind(type).params, {:ok, %{}}, fn param, {:ok, acc} ->
      case value(param, Map.get(values, param.key, param.default)) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, param.key, value)}}
        :error -> {:halt, {:error, {:param, param.key}}}
      end
    end)
  end

  def params(_type, _values), do: {:error, {:param, nil}}

  # A value from JSON or from a form: a form gives text.
  defp value(%{type: :int} = p, value) when is_integer(value), do: range(p, value)

  defp value(%{type: :int} = p, value) when is_float(value) and value == trunc(value),
    do: range(p, trunc(value))

  defp value(%{type: :int} = p, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> range(p, int)
      _ -> :error
    end
  end

  defp value(%{type: :float} = p, value) when is_float(value), do: range(p, value)

  # The range first: a very large integer has no float.
  defp value(%{type: :float} = p, value) when is_integer(value) do
    with {:ok, value} <- range(p, value), do: {:ok, value / 1}
  end

  defp value(%{type: :float} = p, value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> range(p, float)
      _ -> :error
    end
  end

  defp value(%{type: :bool}, value) when is_boolean(value), do: {:ok, value}
  defp value(%{type: :bool}, "true"), do: {:ok, true}
  defp value(%{type: :bool}, "false"), do: {:ok, false}

  defp value(%{type: :text}, value) when is_binary(value) do
    text = value |> String.trim() |> String.slice(0, 40)
    if text == "", do: :error, else: {:ok, text}
  end

  defp value(%{type: {:choice, values}}, value) when is_binary(value) do
    if List.keymember?(values, value, 0), do: {:ok, value}, else: :error
  end

  defp value(_param, _value), do: :error

  defp range(%{min: min, max: max}, value) when value >= min and value <= max, do: {:ok, value}
  defp range(_param, _value), do: :error
end
