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

  # The weight of an item of a van, in pounds.
  def weight(default, note \\ "The label or the page of the maker gives it."),
    do: int("weight", "Weight", "lb", default, 0, 3000, note)

  # A power that an item uses some minutes in one day.
  def minutes(default), do: int("minutes", "Minutes in one day", "min", default, 0, 1440)

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

  # The zones of a camper van: the rooms of its build.
  @zones [
    cab: "Cab",
    galley: "Galley",
    living: "Living area",
    bed: "Bed",
    bay: "Electrical bay",
    van_roof: "Roof of the van",
    shell: "Shell"
  ]

  # The models of camper vans, with typical numbers and their source (the
  # page shows it). The label in the door frame of a van gives its weight
  # rating (GVWR) and the rating of each axle (GAWR); a truck scale gives
  # the weight of each axle of the empty van. 0 for the rating of an axle:
  # the app does not know it.
  @van_models [
    {"promaster_159", "Ram ProMaster 2500, 159 in, high roof",
     %{
       "gvwr" => 8900,
       "front_gawr" => 4629,
       "rear_gawr" => 5291,
       "front_empty" => 3133,
       "rear_empty" => 1762
     },
     "The rating (8,900 lb) and the empty weight (4,895 lb): Autopadre, 2025 Tradesman. The ratings of the axles, and 64% of the empty weight on the front axle: Auto123, 2025 ProMaster 2500 with 136 in (reserves of 1,731 and 3,679 lb)."},
    {"transit_148", "Ford Transit 250, 148 in, high roof",
     %{
       "gvwr" => 9070,
       "front_gawr" => 0,
       "rear_gawr" => 0,
       "front_empty" => 2932,
       "rear_empty" => 2398
     },
     "The rating (9,070 lb) and the empty weight (5,330 lb): Autopadre, 2025. The app does not know the ratings of the axles. 55% of the empty weight on the front axle is a guess of the app."},
    {"sprinter_170", "Mercedes-Benz Sprinter 2500, 170 in, high roof",
     %{
       "gvwr" => 9050,
       "front_gawr" => 0,
       "rear_gawr" => 0,
       "front_empty" => 2970,
       "rear_empty" => 2430
     },
     "The rating (9,050 lb): Autopadre, 2022. The empty weight is 4,993 to 5,743 lb with the options: the app takes 5,400 lb. The app does not know the ratings of the axles. 55% of the empty weight on the front axle is a guess of the app."},
    {"other", "Another van", %{}, nil}
  ]

  # The size of each model, in inches:
  # - outside: the length, the width with no mirrors, and the height;
  # - the wheelbase, and the front overhang (from the front of the van to
  #   the front axle);
  # - the cargo area: its length and its width at the floor, its height,
  #   and the width between the wheel wells.
  # Each model has the source of its size (the page shows it).
  @van_sizes %{
    "promaster_159" => %{
      length: 236,
      width: 80,
      height: 102,
      wheelbase: 159,
      front: 41,
      cargo_length: 146,
      cargo_width: 76,
      cargo_height: 76,
      wells: 56,
      source:
        "The cargo area (146 by 75.6 in, 55.8 in between the wheel wells, 76 in high): vandimensions.com, ProMaster L3 H2. The length (236 in) and the height (102.1 in): Merchants Fleet, 2025. The width with no mirrors (80 in): Cars.com. The place of the front axle is a guess of the app."
    },
    "transit_148" => %{
      length: 236,
      width: 81,
      height: 109,
      wheelbase: 148,
      front: 40,
      cargo_length: 144,
      cargo_width: 70,
      cargo_height: 82,
      wells: 55,
      source:
        "The length of the cargo floor (143.7 in) and the width between the wheel wells (54.8 in): Ford Canada. The width (70.2 in) and the height (81.5 in) of the cargo area: Ford Middle East. The length (235.5 in), the width with no mirrors (81 in) and the height (109 in): Autopadre, 2025. The place of the front axle is a guess of the app."
    },
    "sprinter_170" => %{
      length: 274,
      width: 80,
      height: 107,
      wheelbase: 170,
      front: 39,
      cargo_length: 174,
      cargo_width: 70,
      cargo_height: 79,
      wells: 53,
      source:
        "The length (274.3 in) and the height (107.3 in): Mercedes-Benz of Warwick, 2024. The cargo area (173.6 by 70.4 in, 53.1 in between the wheel wells, 79.1 in high): tables of Mercedes-Benz dealers. The width with no mirrors (80 in) and the place of the front axle are guesses of the app."
    }
  }

  @fuels [{"electric", "Electric"}, {"gas", "Gas"}]

  @kinds [
    %{
      type: "ac",
      name: "Central AC",
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
          "A ton is a size of cooling, not a weight. The model number on the outside unit has the size: 36 is 3 tons (36,000 BTU an hour)."
        ),
        float(
          "seer2",
          "Efficiency",
          "SEER2",
          13.4,
          8.0,
          30.0,
          "The efficiency of the cooling: a higher number uses less power. The yellow EnergyGuide label gives the SEER2. An old unit is near 9 to 11."
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
          "The efficiency of the heat: a higher number uses less power. The EnergyGuide label gives the HSPF2."
        )
      ]
    },
    %{
      type: "mini_split",
      name: "Mini split or window AC",
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
      places: [:outdoor, :indoor],
      features: [:usage],
      params: []
    },
    %{
      type: "water_heater",
      name: "Water heater",
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
      places: [:indoor],
      features: [:estimate],
      params: [choice("fuel", "Fuel", @fuels, "electric")]
    },
    %{
      type: "microwave",
      name: "Microwave",
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
      places: [:indoor],
      features: [:estimate],
      params: [int("loads", "Loads in one week", nil, 4, 0, 21)]
    },
    %{
      type: "washer",
      name: "Clothes washer",
      places: [:indoor],
      features: [:estimate],
      params: [int("loads", "Loads in one week", nil, 5, 0, 30)]
    },
    %{
      type: "dryer",
      name: "Clothes dryer",
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
      places: [:indoor, :outdoor, :bay, :bed],
      features: [:backup, :shift, :power_view, :weight, :van_power],
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
            {"panel", "Circuits of the house, through an inlet (a plug on the wall of the house)"}
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
        ),
        weight(50, "The label gives it. It counts in a van.")
      ]
    },
    %{
      type: "solar_panels",
      name: "Solar panels",
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
      type: "camper_van",
      name: "Camper van",
      places: [:outdoor, :indoor],
      features: [:van],
      params: [
        choice(
          "model",
          "Model",
          Enum.map(@van_models, &{elem(&1, 0), elem(&1, 1)}),
          "promaster_159"
        ),
        int(
          "gvwr",
          "Weight rating (GVWR)",
          "lb",
          8900,
          2000,
          30000,
          "The most that the van can weigh, with all its load (the gross vehicle weight rating). The label in the door frame of the driver gives it."
        ),
        int(
          "front_gawr",
          "Rating of the front axle (GAWR)",
          "lb",
          4629,
          0,
          20000,
          "The most that this axle can carry (the gross axle weight rating). The same label gives it. 0: the app does not know it."
        ),
        int(
          "rear_gawr",
          "Rating of the rear axle (GAWR)",
          "lb",
          5291,
          0,
          20000,
          "The most that this axle can carry. The same label gives it. 0: the app does not know it."
        ),
        int(
          "front_empty",
          "Empty weight on the front axle",
          "lb",
          3133,
          0,
          20000,
          "A truck scale gives the weight of each axle of the empty van."
        ),
        int(
          "rear_empty",
          "Empty weight on the rear axle",
          "lb",
          1762,
          0,
          20000,
          "A truck scale gives the weight of each axle of the empty van."
        ),
        int("people", "People", nil, 2, 0, 9),
        int("person_lb", "Weight of one person", "lb", 180, 0, 500),
        int("gear_lb", "Gear, clothes and food", "lb", 200, 0, 5000),
        float(
          "drive_hours",
          "Hours that you drive in one day",
          "h",
          1.0,
          0.0,
          24.0,
          "The alternator charger works when the engine runs."
        )
      ]
    },
    %{
      type: "swivel_seat",
      name: "Swivel seat base",
      places: [:cab],
      features: [:weight],
      params: [weight(35)]
    },
    %{
      type: "dc_charger",
      name: "Alternator charger (DC-DC)",
      places: [:cab, :bay],
      features: [:weight, :van_power],
      params: [int("amps", "Charge", "A", 30, 1, 200, "The label gives its amps."), weight(5)]
    },
    %{
      type: "van_fridge",
      name: "12 V fridge",
      places: [:galley, :living],
      features: [:weight, :van_power],
      params: [
        int(
          "wh_day",
          "Power in one day",
          "Wh",
          400,
          0,
          5000,
          "The label gives the Ah (amp hours) in one day at 12 V: 30 Ah is near 360 Wh."
        ),
        weight(45)
      ]
    },
    %{
      type: "stove",
      name: "Stove",
      places: [:galley],
      features: [:weight, :van_power, :safety],
      params: [
        choice(
          "fuel",
          "Fuel",
          [
            {"propane", "Propane"},
            {"butane", "Butane"},
            {"diesel", "Diesel"},
            {"induction", "Induction (electric)"}
          ],
          "propane"
        ),
        int("watts", "Power of an induction stove", "W", 1800, 0, 5000, nil),
        minutes(30),
        weight(15)
      ]
    },
    %{
      type: "sink",
      name: "Sink and faucet",
      places: [:galley],
      features: [:weight],
      params: [weight(15)]
    },
    %{
      type: "water_tank",
      name: "Water tank",
      places: [:galley, :bed, :bay, :living],
      features: [:weight],
      params: [
        choice("water", "Water", [{"fresh", "Fresh water"}, {"grey", "Grey water"}], "fresh"),
        int(
          "gallons",
          "Water in it when you drive",
          "gal",
          20,
          0,
          100,
          "A gallon of water weighs 8.34 lb."
        ),
        weight(10, "The weight of the empty tank.")
      ]
    },
    %{
      type: "water_pump",
      name: "Water pump",
      places: [:galley, :bed, :bay],
      features: [:weight, :van_power],
      params: [int("watts", "Power", "W", 60, 0, 1000, nil), minutes(10), weight(3)]
    },
    %{
      type: "counter",
      name: "Counter and cabinets",
      places: [:galley, :living],
      features: [:weight],
      params: [weight(80)]
    },
    %{
      type: "bench",
      name: "Bench or seat",
      places: [:living],
      features: [:weight],
      params: [weight(50)]
    },
    %{
      type: "van_table",
      name: "Table",
      places: [:living],
      features: [:weight],
      params: [weight(20)]
    },
    %{
      type: "van_fan",
      name: "Roof fan",
      places: [:van_roof, :living],
      features: [:weight, :van_power],
      params: [
        int("watts", "Power", "W", 30, 0, 500, nil),
        float("hours", "Hours in one day", "h", 8.0, 0.0, 24.0, nil),
        season("warm"),
        weight(15)
      ]
    },
    %{
      type: "window",
      name: "Window",
      places: [:living, :galley, :bed],
      features: [:weight],
      params: [weight(20)]
    },
    %{
      type: "van_lights",
      name: "Lights",
      places: [:living, :galley, :bed],
      features: [:weight, :van_power],
      params: [
        int("watts", "Power", "W", 20, 0, 500, nil),
        float("hours", "Hours in one day", "h", 4.0, 0.0, 24.0, nil),
        weight(3)
      ]
    },
    %{
      type: "devices",
      name: "Phones and a laptop",
      places: [:living, :bed, :cab],
      features: [:weight, :van_power],
      params: [
        int("watts", "Power", "W", 60, 0, 3000, nil),
        float("hours", "Hours in one day", "h", 3.0, 0.0, 24.0, nil),
        choice(
          "outlet",
          "They plug into",
          [{"usb", "USB or 12 V"}, {"ac", "An outlet of 120 V (the inverter)"}],
          "usb"
        ),
        weight(5)
      ]
    },
    %{
      type: "diesel_heater",
      name: "Diesel heater",
      places: [:bay, :living, :bed],
      features: [:weight, :van_power, :safety],
      params: [
        int("watts", "Power of its fan and pump", "W", 25, 0, 500, nil),
        float("hours", "Hours in one day", "h", 8.0, 0.0, 24.0, nil),
        season("cold"),
        weight(25)
      ]
    },
    %{
      type: "co_alarm",
      name: "Carbon monoxide and propane alarm",
      places: [:living, :galley, :bed],
      features: [:weight, :safety],
      params: [weight(1)]
    },
    %{
      type: "bed_platform",
      name: "Bed and mattress",
      places: [:bed],
      features: [:weight],
      params: [weight(120)]
    },
    %{
      type: "storage",
      name: "Storage",
      places: [:bed, :living, :galley, :cab],
      features: [:weight],
      params: [weight(40, "The cabinets or the boxes, with no gear in them.")]
    },
    %{
      type: "van_battery",
      name: "Battery bank",
      places: [:bay, :bed],
      features: [:weight, :van_power, :safety],
      params: [
        int(
          "ah",
          "Capacity",
          "Ah",
          200,
          1,
          5000,
          "The Ah (amp hours) on the label of each battery. Add the Ah of the batteries that are in parallel."
        ),
        choice("volts", "Voltage", [{"12", "12 V"}, {"24", "24 V"}, {"48", "48 V"}], "12"),
        choice(
          "chemistry",
          "Kind",
          [{"lifepo4", "Lithium (LiFePO4)"}, {"agm", "Lead acid or AGM"}],
          "lifepo4"
        ),
        %{
          key: "fused",
          label: "It has a fuse near its positive post",
          unit: nil,
          type: :bool,
          default: false,
          note: nil
        },
        weight(50)
      ]
    },
    %{
      type: "inverter",
      name: "Inverter",
      places: [:bay],
      features: [:weight, :van_power],
      params: [
        int(
          "watts",
          "Output",
          "W",
          2000,
          100,
          10000,
          "The most power of its outlets, all the time (not the surge)."
        ),
        int(
          "idle_w",
          "Power when it is on, with no load",
          "W",
          15,
          0,
          200,
          "The data sheet calls it the no-load power."
        ),
        float("hours", "Hours on in one day", "h", 6.0, 0.0, 24.0, nil),
        weight(15)
      ]
    },
    %{
      type: "shore_power",
      name: "Shore power inlet and charger",
      places: [:bay],
      features: [:weight],
      params: [weight(10)]
    },
    %{
      type: "van_solar",
      name: "Solar panels",
      places: [:van_roof],
      features: [:weight, :van_power],
      params: [
        int(
          "watts",
          "Power",
          "W",
          400,
          0,
          5000,
          "The label of each panel gives its watts. Add them."
        ),
        weight(60, "The panels and their mounts.")
      ]
    },
    %{
      type: "insulation",
      name: "Insulation",
      places: [:shell],
      features: [:weight],
      params: [weight(40)]
    },
    %{
      type: "walls",
      name: "Walls and ceiling",
      places: [:shell],
      features: [:weight],
      params: [weight(150)]
    },
    %{
      type: "van_floor",
      name: "Floor",
      places: [:shell],
      features: [:weight],
      params: [weight(100)]
    },
    %{
      type: "other",
      name: "Other",
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

  # The typical size of an item of each kind, in inches. The width is from
  # its left to its right, and the depth from its back to its front. The
  # third number is its height. The front is the side that a person uses. For solar panels, it
  # is one panel (`DIY.Layout.size/1` gives the size of the array).
  #
  # The source of each size is next to it: the spec sheet of a common
  # model (rounded to the inch), or a standard size. "No source" is a size
  # for the plan only: the item sheet asks for the size of the real item.
  @sizes %{
    # Goodman GSX140361, 3 tons: 29 by 29 by 32 1/2 in (distributor listing).
    "ac" => {29, 29, 33},
    # Mitsubishi MSZ-GL12NA: 31 7/16 by 9 1/8 by 11 5/8 in (Mitsubishi spec sheet).
    "mini_split" => {31, 9, 12},
    # Goodman GM9S800804BN, 80,000 BTU: 17 1/2 by 28 by 33 3/8 in (distributor listing).
    "furnace" => {18, 28, 33},
    # No source: heat strips are in an air handler.
    "heat_strips" => {48, 24, 24},
    # No source: a meter and its socket box.
    "smart_meter" => {10, 6, 14},
    # Rheem PROG50-40N RH62, 50 gallons: 21 1/2 in across, 61 1/2 in high (distributor listing).
    "water_heater" => {22, 22, 62},
    # LG LRFXS2503S: 32 3/4 by 33 (with the handles) by 69 7/8 in (retailer listings).
    "fridge" => {33, 33, 70},
    # Frigidaire FFCL1542AW, 14.8 cu ft: 55 3/4 by 29 9/16 by 32 1/2 in (Best Buy).
    "freezer" => {56, 30, 33},
    # A range is 30 in wide: the cutout of most counters. No source for the depth and the height.
    "range" => {30, 28, 47},
    # Panasonic NN-SN966S: 23 7/8 by 19 7/16 by 14 in (Panasonic spec table).
    "microwave" => {24, 19, 14},
    # A dishwasher goes under a counter: an opening of 24 in. No source for the depth and the height.
    "dishwasher" => {24, 24, 34},
    # LG WM4000HWA: 27 by 30 1/4 by 39 in (LG spec sheet).
    "washer" => {27, 30, 39},
    # No source: the size of the washer (a dryer of the same line).
    "dryer" => {27, 30, 39},
    # No source: a floor lamp.
    "lights" => {16, 16, 60},
    # Samsung UN50CU7000, 50 in, on its stand: 44 by 9.9 by 28.3 in (P.C. Richard).
    "tv" => {44, 10, 28},
    # No source: a screen and a keyboard on a desk.
    "computer" => {24, 16, 20},
    # No source: the blades of a fan of 52 in, a common size.
    "ceiling_fan" => {52, 52, 12},
    # No source: a router and its power supply.
    "always_on" => {18, 6, 3},
    # Hayward SP2610X15: 25 1/8 by 7 7/8 by 10 7/8 in (Pool360).
    "pool_pump" => {25, 8, 11},
    # No source: a tower heater.
    "space_heater" => {10, 7, 25},
    # EcoFlow DELTA Pro: 25 by 11.2 by 16.4 in (retailer listings).
    "power_station" => {25, 11, 16},
    # One panel of 400 W (`DIY.Layout`): 1134 by 1722 mm, 108 half cells.
    "solar_panels" => {45, 68, 2},
    # Generac RXSW100A3, 100 A: 14.6 by 7.1 by 20 in (Greentech Renewables).
    "transfer_switch" => {15, 7, 20},
    # Tesla Model 3 (2024): 1849 mm wide (no mirrors), 4720 mm long, 1441 mm high (CarExpert).
    "ev" => {73, 186, 57},
    # The Mercedes-Benz Sprinter 170 in, high roof (the van models above).
    "camper_van" => {80, 274, 110},
    # No source: a seat of a van on a swivel base.
    "swivel_seat" => {26, 26, 40},
    # Victron Orion-Tr Smart 12/12-30: 186 by 80 by 130 mm (retailer listings).
    "dc_charger" => {7, 3, 5},
    # Dometic CFX3 45: 15.7 by 24.8 (no handle) by 18.7 in (retailer listing of the spec).
    "van_fridge" => {16, 25, 19},
    # No source: a stove of two burners.
    "stove" => {22, 16, 4},
    # No source: a sink in a cabinet of 36 in, with a faucet of 8 in.
    "sink" => {24, 18, 44},
    # No source: a tank of about 20 gallons.
    "water_tank" => {24, 15, 14},
    # Shurflo 4008: 8.1 by 4.9 by 4.3 in (retailer listings).
    "water_pump" => {8, 5, 4},
    # No source: a counter that you build.
    "counter" => {48, 22, 36},
    # No source: a bench that you build.
    "bench" => {40, 20, 32},
    # No source: a table that you build.
    "van_table" => {28, 20, 28},
    # MaxxAir MaxxFan Deluxe 7500K: 16 1/2 by 22 1/2 by 5 in (retailer listing).
    "van_fan" => {17, 23, 5},
    # No source: a window of a van.
    "window" => {36, 2, 24},
    # No source: a strip of lights.
    "van_lights" => {12, 4, 1},
    # No source: a laptop and a phone.
    "devices" => {14, 10, 10},
    # Webasto Air Top 2000 STC: 310 by 120 by 118 mm (Webasto).
    "diesel_heater" => {12, 5, 5},
    # No source: an alarm on a wall.
    "co_alarm" => {5, 5, 2},
    # No source: a bed that you build.
    "bed_platform" => {60, 75, 24},
    # No source: a cabinet that you build.
    "storage" => {36, 24, 24},
    # Battle Born BB10012, 100 Ah: 12 3/4 by 6 7/8 by 9 in (retailer listings).
    "van_battery" => {13, 7, 9},
    # Victron MultiPlus 12/3000/120 on a wall: 258 by 218 by 362 mm (retailer listings).
    "inverter" => {10, 9, 14},
    # No source: an inlet and its charger.
    "shore_power" => {6, 3, 6},
    # One panel of 400 W, as the solar panels of a house.
    "van_solar" => {45, 68, 2},
    # No source: a part of the insulation.
    "insulation" => {48, 24, 6},
    # No source: a panel of a wall.
    "walls" => {48, 2, 36},
    # No source: a part of the floor.
    "van_floor" => {48, 48, 1},
    # No source.
    "other" => {24, 24, 24}
  }

  for %{type: type} <- @kinds,
      not Map.has_key?(@sizes, type),
      do: raise("the kind #{type} has no size")

  # The height of the bottom of an item on a wall or on a ceiling, in
  # inches. Another item stands on the floor.
  @lifts %{
    # No source: high on a wall.
    "mini_split" => 84,
    # No source: a meter is near the height of the eyes.
    "smart_meter" => 48,
    # No source: on a wall, near the panel.
    "transfer_switch" => 40,
    # No source: the blades are 7 ft over the floor.
    "ceiling_fan" => 84
  }

  @doc "All the kinds, in the order of the list of a new item."
  def kinds, do: @kinds

  @doc "The kind of a type, or `nil`."
  def kind(type), do: Map.get(@by_type, type)

  @doc "The types of all the kinds."
  def types, do: Map.keys(@by_type)

  @doc "The typical size of an item of a type, in inches: `{w, d, h}`."
  def size(type), do: Map.fetch!(@sizes, type)

  @doc "The height of the bottom of an item of a type above its floor, in inches."
  def lift(type), do: Map.get(@lifts, type, 0)

  @doc "The places of a room: inside, outside, or on the roof."
  def places, do: @places

  @doc "The zones of a camper van, with their names, in order."
  def zones, do: @zones

  @doc "The models of camper vans: `{key, name, numbers, source}`."
  def van_models, do: @van_models

  @doc """
  The size of a model of camper van, in inches (`@van_sizes`), with its
  source. A model that the app does not know (\"other\") gets the size
  of a typical van: the Ford Transit 148 in.
  """
  def van_size(model) do
    case Map.fetch(@van_sizes, model) do
      {:ok, size} ->
        size

      :error ->
        %{
          @van_sizes["transit_148"]
          | source:
              "The app does not have the size of this van: it uses the size of a typical van, the Ford Transit 148 in."
        }
    end
  end

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

  @doc """
  Reads the parameters as `params/2`, but a value that is not valid gets
  the default value (for the parts of a stored build that must not stop
  the build from loading).
  """
  @spec loose_params(String.t(), term()) :: map()
  def loose_params(type, values) when is_map(values) do
    Map.new(kind(type).params, fn param ->
      case value(param, Map.get(values, param.key, param.default)) do
        {:ok, value} -> {param.key, value}
        :error -> {param.key, param.default}
      end
    end)
  end

  def loose_params(type, _values), do: defaults(type)

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
