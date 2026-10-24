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

  def choice(key, label, values, default, note \\ nil),
    do: %{
      key: key,
      label: label,
      unit: nil,
      type: {:choice, values},
      default: default,
      note: note
    }

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
    {"promaster_136", "Ram ProMaster 2500, 136 in, high roof",
     %{
       "gvwr" => 8900,
       "front_gawr" => 4629,
       "rear_gawr" => 5291,
       "front_empty" => 2982,
       "rear_empty" => 1696
     },
     "The source is Stellantis, 2026 Ram ProMaster Trailer Towing Charts, row 2L13. It gives the rating (8,900 lb), the ratings of the axles, and the empty weight on each axle (2,982 and 1,696 lb)."},
    {"promaster_159", "Ram ProMaster 2500, 159 in, high roof",
     %{
       "gvwr" => 8900,
       "front_gawr" => 4629,
       "rear_gawr" => 5291,
       "front_empty" => 3133,
       "rear_empty" => 1762
     },
     "The rating (8,900 lb) and the empty weight (4,895 lb): Autopadre, 2025 Tradesman. The ratings of the axles, and 64% of the empty weight on the front axle: Auto123, 2025 ProMaster 2500 with 136 in (reserves of 1,731 and 3,679 lb)."},
    {"promaster_159_ext", "Ram ProMaster 3500, 159 in extended, high roof",
     %{
       "gvwr" => 9350,
       "front_gawr" => 4629,
       "rear_gawr" => 5291,
       "front_empty" => 3131,
       "rear_empty" => 1834
     },
     "The source is Stellantis, 2026 Ram ProMaster Trailer Towing Charts, row 3L17. It gives the rating (9,350 lb), the ratings of the axles, and the empty weight on each axle (3,131 and 1,834 lb)."},
    {"transit_148_medium", "Ford Transit 250, 148 in, medium roof",
     %{
       "gvwr" => 9070,
       "front_gawr" => 0,
       "rear_gawr" => 0,
       "front_empty" => 3063,
       "rear_empty" => 2193
     },
     "The rating (9,070 lb) and the empty weight (5,256 lb, rear wheel drive): Ford, 2025 Transit Technical Specifications. 58% of the empty weight is on the front axle: Cars.com, 2025 Transit-250 148 in medium roof (3,051 and 2,184 lb). The app does not know the ratings of the axles."},
    {"transit_148", "Ford Transit 250, 148 in, high roof",
     %{
       "gvwr" => 9070,
       "front_gawr" => 0,
       "rear_gawr" => 0,
       "front_empty" => 2932,
       "rear_empty" => 2398
     },
     "The rating (9,070 lb) and the empty weight (5,330 lb): Autopadre, 2025. The app does not know the ratings of the axles. 55% of the empty weight on the front axle is a guess of the app."},
    {"transit_148_el", "Ford Transit 250, 148 in extended, high roof",
     %{
       "gvwr" => 9070,
       "front_gawr" => 0,
       "rear_gawr" => 0,
       "front_empty" => 3032,
       "rear_empty" => 2520
     },
     "The rating (9,070 lb) and the empty weight (5,552 lb, rear wheel drive): Ford, 2025 Transit Technical Specifications. 55% of the empty weight is on the front axle of the van with all wheel drive (3,135 and 2,605 lb): Cars.com. The app uses this split. It does not know the ratings of the axles."},
    {"sprinter_144", "Mercedes-Benz Sprinter 2500, 144 in, high roof",
     %{
       "gvwr" => 9050,
       "front_gawr" => 4101,
       "rear_gawr" => 5359,
       "front_empty" => 2914,
       "rear_empty" => 2025
     },
     "The rating (9,050 lb) and the ratings of the axles: mbvans.com, 2026 Sprinter Cargo Van with rear wheel drive. The page gives 2,025 and 2,914 lb on the axles, in an order that is not sure. The app puts 2,914 lb on the front axle, as the 170 in extended with all wheel drive (3,274 lb front). The page gives 4,916 lb in all: the two axles give 23 lb more."},
    {"sprinter_170", "Mercedes-Benz Sprinter 2500, 170 in, high roof",
     %{
       "gvwr" => 9050,
       "front_gawr" => 0,
       "rear_gawr" => 0,
       "front_empty" => 2970,
       "rear_empty" => 2430
     },
     "The rating (9,050 lb): Autopadre, 2022. The empty weight is 4,993 to 5,743 lb with the options: the app takes 5,400 lb. The app does not know the ratings of the axles. 55% of the empty weight on the front axle is a guess of the app."},
    {"sprinter_170_ext", "Mercedes-Benz Sprinter 2500, 170 in extended, high roof",
     %{
       "gvwr" => 9050,
       "front_gawr" => 4101,
       "rear_gawr" => 5359,
       "front_empty" => 2954,
       "rear_empty" => 2416
     },
     "The rating (9,050 lb) and the ratings of the axles: mbvans.com, 2026 Sprinter Cargo Van with rear wheel drive. The page gives 2,416 and 2,954 lb on the axles, in an order that is not sure. The app puts 2,954 lb on the front axle, as the van with all wheel drive (3,274 lb front). The page gives 5,346 lb in all: the two axles give 24 lb more."},
    {"other", "Another van", %{}, nil}
  ]

  # The models of power stations, with the numbers of their makers, their
  # size and their sources (the panel shows them). The charge from the wall
  # is the AC charge from an outlet of 120 V and 15 A: 1,800 W for each
  # model. The source tells the AC charge with a better cable or outlet.
  # The size is in inches: the width of the front, the depth and the
  # height. "other" is a station
  # that the app does not know. It keeps its numbers, and it has the look
  # and the size of the kind (the F5000LFP).
  @station_models [
    {"pecron_f5000lfp", "Pecron F5000LFP",
     %{"kwh" => 5.12, "output_w" => 7200, "charge_w" => 1800, "solar_w" => 5800, "weight" => 124},
     {22, 15, 17},
     "Pecron, the page of the F5000LFP: 5,120 Wh, 7,200 W at 240 V, an AC charge of 3,600 W with the 30 A cable (1,800 W with the 15 A cable), 5,800 W of solar input for one unit (6,400 W with an extra battery), and 123.9 lb. The station is 21.7 by 15 by 13.1 in. The data of Pecron does not give the trolley: on it, the station is near 17 in high (an estimate from the photos of Pecron)."},
    {"pecron_e3800lfp", "Pecron E3800LFP",
     %{"kwh" => 3.84, "output_w" => 4200, "charge_w" => 1800, "solar_w" => 3000, "weight" => 87},
     {18, 12, 15},
     "Pecron, the page of the E3800LFP: 3,840 Wh, 4,200 W at 120 V, an AC charge of 3,200 W with the 30 A cable (1,800 W with the 15 A cable), 3,000 W of solar input, 87.3 lb, and 17.5 by 12.1 by 14.7 in. The front is 17.5 in wide. It has no wheels: its cart is an accessory that the app does not show."},
    {"ecoflow_delta_pro", "EcoFlow DELTA Pro",
     %{"kwh" => 3.6, "output_w" => 3600, "charge_w" => 1800, "solar_w" => 1600, "weight" => 99},
     {11, 25, 16},
     "EcoFlow, the page of the DELTA Pro: 3,600 Wh, 3,600 W, an AC charge of 3,000 W at 240 V (1,800 W at 120 V), 1,600 W of solar input, 99 lb, and 25 by 11.2 by 16.4 in. The front is the short end: it is 11.2 in wide, and the station is 25 in deep."},
    {"ecoflow_delta_pro_3", "EcoFlow DELTA Pro 3",
     %{
       "kwh" => 4.096,
       "output_w" => 4000,
       "charge_w" => 1800,
       "solar_w" => 2600,
       "weight" => 114
     }, {13, 27, 16},
     "EcoFlow, the page of the DELTA Pro 3: 4,096 Wh, 4,000 W, 2,600 W of solar input, 113.5 lb, and 410.4 by 341 by 693 mm. The front is the short end: it is 13.4 in wide, and the station is 27.3 in deep and 16.2 in high. EcoFlow gives its AC charge as 15 A. Adorama gives 3,600 W at 240 V (1,800 W at 120 V)."},
    {"ecoflow_delta_pro_ultra", "EcoFlow DELTA Pro Ultra",
     %{
       "kwh" => 6.144,
       "output_w" => 7200,
       "charge_w" => 1800,
       "solar_w" => 5600,
       "weight" => 182
     }, {27, 19, 16},
     "EcoFlow, the page of the DELTA Pro Ultra: the inverter on one battery, with 6,144 Wh, 7,200 W and 5,600 W of solar input. The inverter is 690 by 481 by 214 mm (70 lb), and the battery is 660 by 455 by 204 mm (111.8 lb). The app adds them: 27.2 by 18.9 by 16.5 in, and 181.8 lb. EcoFlow gives its AC charge as 12.5 A at 240 V. Adorama gives 3,000 W at 240 V (1,800 W at 120 V). Its port Power In/Out takes more. It has no wheels: its stand is an accessory that the app does not show."},
    {"anker_solix_f3800", "Anker SOLIX F3800",
     %{"kwh" => 3.84, "output_w" => 6000, "charge_w" => 1800, "solar_w" => 2400, "weight" => 132},
     {15, 16, 28},
     "Anker, the page of the SOLIX F3800: 3,840 Wh, 6,000 W at 120 V and 240 V, an AC charge of 1,800 W, 2,400 W of solar input, 132.3 lb, and 27.6 by 15.3 by 15.6 in with its wheels. Its user guide shows that it stands up: it is 27.6 in high, 15.3 in wide at the front, and 15.6 in deep."},
    {"anker_solix_f3800_plus", "Anker SOLIX F3800 Plus",
     %{"kwh" => 3.84, "output_w" => 6000, "charge_w" => 1800, "solar_w" => 3200, "weight" => 137},
     {15, 16, 28},
     "Anker, the page of the SOLIX F3800 Plus: 3,840 Wh, 6,000 W at 120 V and 240 V, an AC charge of 1,800 W from an outlet of 120 V, 3,200 W of solar input, 136.7 lb, and the size of the F3800. Its port for a home panel or a generator takes up to 3,300 W (6,000 W with an extra battery)."},
    {"other", "Another station", %{}, nil, nil}
  ]

  # The size of each model, in inches:
  # - outside: the length, the width with no mirrors, and the height;
  # - the wheelbase, and the front overhang (from the front of the van to
  #   the front axle);
  # - the cargo area: its length and its width at the floor, its height,
  #   and the width between the wheel wells.
  # Each model has the source of its size (the page shows it).
  @van_sizes %{
    "promaster_136" => %{
      length: 213,
      width: 80,
      height: 104,
      wheelbase: 136,
      front: 38,
      cargo_length: 123,
      cargo_width: 76,
      cargo_height: 76,
      wells: 56,
      source:
        "The length (213.2 in), the width with no mirrors (80.3 in) and the height (103.6 in): iSeeCars, 2025 ProMaster. The cargo area and the front axle: Cars.com, 2025 ProMaster 2500 136 in high roof. The cargo area is 123 in long and 76 in high, with 56 in between the wheel wells. The front axle is 38 in from the front. The width of the cargo area (75.6 in) is the width of the other ProMaster vans: Ram Canada."
    },
    "promaster_159_ext" => %{
      length: 251,
      width: 80,
      height: 103,
      wheelbase: 159,
      front: 38,
      cargo_length: 160,
      cargo_width: 76,
      cargo_height: 76,
      wells: 56,
      source:
        "The source of the size is Ram Canada, 2026 ProMaster. The van is 250.6 in long, 80.3 in wide with no mirrors, and 102.5 in high. The cargo area is 160.2 by 75.6 in, 76 in high, with 55.8 in between the wheel wells. The front axle (38 in from the front): Cars.com, 2025 ProMaster 3500 159 in extended high roof."
    },
    "transit_148_medium" => %{
      length: 236,
      width: 81,
      height: 101,
      wheelbase: 148,
      front: 40,
      cargo_length: 144,
      cargo_width: 70,
      cargo_height: 72,
      wells: 55,
      source:
        "The source of the size is Ford, 2025 Transit Technical Specifications. The van is 235.5 in long, 81.3 in wide with no mirrors, and 101.3 in high. The front axle is 40.3 in from the front. The cargo area is 143.7 in long and 72 in high, with 54.8 in between the wheel wells. The width of the cargo area (70.2 in) is the width of the high roof: Ford Middle East."
    },
    "transit_148_el" => %{
      length: 264,
      width: 81,
      height: 110,
      wheelbase: 148,
      front: 40,
      cargo_length: 172,
      cargo_width: 70,
      cargo_height: 82,
      wells: 55,
      source:
        "The source of the size is Ford, 2025 Transit Technical Specifications. The van is 263.9 in long, 81.3 in wide with no mirrors, and 110.4 in high. The front axle is 40.3 in from the front. The cargo area is 172.2 in long and 81.5 in high, with 54.8 in between the wheel wells. The width of the cargo area (70.2 in) is the width of the high roof: Ford Middle East."
    },
    "sprinter_144" => %{
      length: 234,
      width: 80,
      height: 108,
      wheelbase: 144,
      front: 40,
      cargo_length: 133,
      cargo_width: 70,
      cargo_height: 79,
      wells: 53,
      source:
        "The source of the size is Mercedes-Benz USA, the drawing for upfitters of the 2500 cargo van 144 in high roof. The van is 234 in long, 80 in wide with no mirrors, and 107.5 in high with no load. The front axle is 40 in from the front. The cargo area is 133 by 70 in, 79 in high, with 53 in between the wheel wells."
    },
    "sprinter_170_ext" => %{
      length: 290,
      width: 80,
      height: 107,
      wheelbase: 170,
      front: 40,
      cargo_length: 189,
      cargo_width: 70,
      cargo_height: 79,
      wells: 53,
      source:
        "The source of the size is Mercedes-Benz USA, the drawing for upfitters of the 2500 cargo van 170 in extended high roof. The van is 290 in long, 79.5 in wide with no mirrors, and 107 in high. The front axle is 40.2 in from the front. The cargo area is 189.4 by 70.4 in, 79.1 in high, with 53.1 in between the wheel wells."
    },
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
          "The efficiency of the cooling: a unit with a higher number uses less power. The yellow EnergyGuide label gives the SEER2. An old unit is near 9 to 11."
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
          "The efficiency of the heat: a unit with a higher number uses less power. The EnergyGuide label gives the HSPF2."
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
      type: "cpap",
      name: "Medical device (CPAP)",
      places: [:indoor],
      features: [:estimate],
      params: [
        # ResMed, "Power consumption of Air10 devices" (2015): an AirSense
        # 10 AutoSet uses 7 W, and 22 W with its humidifier. With the heated
        # tube too, it uses 34 W. Its user guide gives a typical 53 W.
        int(
          "watts",
          "Power",
          "W",
          50,
          1,
          1000,
          "A CPAP uses near 10 W with no humidifier, and 20 to 50 W with a heated humidifier and tube (ResMed). Its manual gives the typical watts, not its label."
        ),
        float("hours", "Hours in one day", "h", 8.0, 0.0, 24.0, nil)
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
      type: "home_assistant",
      name: "Home Assistant hub",
      places: [:indoor],
      features: [:estimate],
      params: [
        # Home Assistant Green, datasheet v1.1 (2024): 1.7 W at idle and 3 W
        # under load, at 12 V. The hub is on all the time, and mostly idle:
        # the app takes 2 W, between the two.
        int(
          "watts",
          "Power all the time",
          "W",
          2,
          1,
          100,
          "A Home Assistant Green uses 1.7 W at idle and 3 W under load (its datasheet). The app takes 2 W, between the two. A Raspberry Pi or a small PC uses more."
        )
      ]
    },
    # The items of a pool go outside, or in a room that is a pool
    # (`:pool`, `fits?/2`).
    %{
      type: "pool_pump",
      name: "Pool pump",
      places: [:outdoor, :pool],
      features: [:estimate],
      params: [
        int("watts", "Power", "W", 1100, 100, 4000, "A 1 HP pump uses near 1,100 W."),
        float("hours", "Hours in one day", "h", 8.0, 0.0, 24.0, nil),
        season("summer")
      ]
    },
    %{
      type: "pool_heater",
      name: "Pool heater",
      places: [:outdoor, :pool],
      features: [:estimate],
      params: [
        choice(
          "fuel",
          "Kind",
          [{"heat_pump", "Heat pump"}, {"electric", "Electric"}, {"gas", "Gas"}],
          "heat_pump"
        ),
        int(
          "watts",
          "Power",
          "W",
          5500,
          500,
          30000,
          "Only for a heat pump or an electric heater. A heat pump of 140,000 BTU/h uses near 5,500 W. The electric heater of a spa uses near 11,000 W."
        ),
        int(
          "kbtu",
          "Gas input",
          "kBTU/h",
          400,
          50,
          500,
          "Only for a gas heater. The label gives it, for example 400,000 BTU/h."
        ),
        float("hours", "Hours in one day", "h", 4.0, 0.0, 24.0, nil),
        season("warm")
      ]
    },
    %{
      type: "hot_tub",
      name: "Hot tub",
      places: [:outdoor, :pool],
      features: [:estimate],
      params: [
        float(
          "kwh_day",
          "Use in one day",
          "kWh",
          5.0,
          0.0,
          40.0,
          "A hot tub with a good cover uses near 3 to 8 kWh in one day, more in a cold month."
        ),
        season("all")
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
      features: [:backup, :shift, :power_view, :weight, :van_power, :wires],
      params: [
        choice(
          "model",
          "Model",
          Enum.map(@station_models, &{elem(&1, 0), elem(&1, 1)}),
          "other",
          "A model gives its numbers, its size and its look. Another station keeps the numbers that you give."
        ),
        float(
          "kwh",
          "Battery",
          "kWh",
          2.0,
          0.1,
          100.0,
          "The label or the app of the station gives it in Wh: 2,048 Wh is 2.048 kWh. Common stations have near 1 kWh (with 1,800 W of outlets), 2 kWh (2,400 W) or 4 kWh (4,000 W). Their data sheets of 2025 and 2026 give these sizes."
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
          "The most power of its AC charge from a wall outlet. An outlet of 120 V and 15 A gives 1,800 W at most, and 1,440 W for a load that runs for hours. Some stations take more with a cable of 30 A or on 240 V."
        ),
        int("solar_w", "Solar input", "W", 1000, 0, 20000, "The most solar power that it takes."),
        choice(
          "feeds",
          "It powers",
          [
            {"plug", "Items that plug into it"},
            {"panel", "Circuits of the house, through an inlet"}
          ],
          "plug",
          "An inlet is a connector for a station on the wall of the house. It is not an outlet: an electrician installs it."
        ),
        int(
          "cost",
          "Price",
          "$",
          1500,
          0,
          200_000,
          "What you paid, or what it costs, with its extra batteries: for the payback."
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
      features: [:power_view, :wires],
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
          [
            {"l1", "Level 1: a wall outlet (1.4 kW)"},
            {"l2", "Level 2: 240 V (7.2 kW)"},
            {"l2_48", "Level 2: Tesla Wall Connector, 48 A (11.5 kW)"}
          ],
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
      features: [:weight, :van_power, :wires],
      params: [
        int(
          "amps",
          "Charge",
          "A",
          30,
          1,
          200,
          "It charges the batteries from the engine while you drive. The label gives its amps."
        ),
        weight(5)
      ]
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
          "The label gives the Ah (amp hours) in one day at 12 V, near 77 °F (25 °C): 30 Ah is near 360 Wh. In the heat, it uses more."
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
      features: [:weight, :van_power, :safety, :wires],
      params: [
        int(
          "ah",
          "Capacity",
          "Ah",
          200,
          1,
          5000,
          "The label of each battery gives its Ah (amp hours). Add the Ah of the batteries that are in parallel."
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
      features: [:weight, :van_power, :wires],
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
      type: "dc_bus",
      name: "DC busbar or distributor",
      places: [:indoor, :outdoor, :bay],
      features: [:weight, :wires],
      params: [
        int(
          "ports",
          "Positions for wires",
          nil,
          4,
          1,
          24,
          "The studs or the fuse holders for the wires. A Victron Lynx Distributor has 4."
        ),
        int(
          "fuse_min",
          "Smallest fuse",
          "A",
          40,
          0,
          2000,
          "The smallest fuse that its fuse holders take, or 0 with no fuse holders. A Victron Lynx Distributor takes MEGA fuses. The smallest MEGA fuse of Victron for 48 V is 40 A (80 V, part CIP138040020)."
        ),
        weight(5)
      ]
    },
    %{
      type: "shore_power",
      name: "Shore power inlet and charger",
      places: [:bay],
      features: [:weight, :wires],
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
    # ResMed AirSense 10, with its water tub: 255 by 150 by 116 mm (its user guide).
    "cpap" => {10, 6, 5},
    # No source: the blades of a fan of 52 in, a common size.
    "ceiling_fan" => {52, 52, 12},
    # No source: a router and its power supply.
    "always_on" => {18, 6, 3},
    # Home Assistant Green: 112 by 112 by 32 mm (its datasheet).
    "home_assistant" => {4, 4, 1},
    # Hayward SP2610X15: 25 1/8 by 7 7/8 by 10 7/8 in (Pool360).
    "pool_pump" => {25, 8, 11},
    # No source: a heat pump of a pool, near 3 ft on each side.
    "pool_heater" => {34, 34, 40},
    # No source: a hot tub of 7 by 7 ft for 5 or 6 persons.
    "hot_tub" => {84, 84, 36},
    # No source: a tower heater.
    "space_heater" => {10, 7, 25},
    # Pecron F5000LFP: 21.7 by 15 by 13.1 in (Pecron). Its trolley is not in
    # the data of Pecron: on it, the station is near 17 in high (an estimate
    # from the photos of Pecron).
    "power_station" => {22, 15, 17},
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
    # Victron Lynx Distributor: 290 by 170 by 80 mm, 2.2 kg (the manual of
    # Victron). It is on a wall: 80 mm is its depth.
    "dc_bus" => {11, 3, 7},
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
  The models of power stations: `{key, name, numbers, size, source}`. The
  size is in inches, `{w, d, h}`.
  """
  def station_models, do: @station_models

  @doc """
  The size of a model of power station, in inches. A station that the app
  does not know (\"other\") has the size of the kind.
  """
  def station_size(model) do
    case List.keyfind(@station_models, model, 0) do
      {_key, _name, _numbers, {_w, _d, _h} = size, _source} -> size
      _other -> size("power_station")
    end
  end

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

  @doc """
  True when an item of a kind can go in a room. A room that is a pool
  (`kind: "pool"`, `DIY.Build.pool?/1`) also takes the items of the place
  `:pool`. So an indoor pool takes a pool pump, a pool heater and a hot
  tub.
  """
  def fits?(%{places: places}, room) do
    room.place in places or (:pool in places and Map.get(room, :kind) == "pool")
  end

  @doc "The kinds that can go in a room (`fits?/2`)."
  def kinds_for_room(room), do: Enum.filter(@kinds, &fits?(&1, room))

  # More words for the search of the kinds (`search/2`): the words that a
  # person can type for a kind with a different name.
  @words %{
    "ev" => ~w(tesla ev car charger charging wall connector vehicle),
    "pool_pump" => ~w(pool pump spa),
    "pool_heater" => ~w(pool heater spa heat pump),
    "hot_tub" => ~w(hot tub spa jacuzzi),
    "fridge" => ~w(refrigerator),
    "freezer" => ~w(refrigerator),
    "ac" => ~w(air conditioner hvac cooling),
    "mini_split" => ~w(heat pump ductless air conditioner),
    "furnace" => ~w(heater heating hvac),
    "water_heater" => ~w(tank tankless),
    "range" => ~w(stove oven cooktop),
    "computer" => ~w(pc laptop desk),
    "always_on" => ~w(router modem standby),
    "solar_panels" => ~w(solar pv),
    "power_station" => ~w(battery backup ecoflow pecron generator)
  }

  @doc "The more words of the kinds (`@words`), for the tests."
  def words, do: @words

  @doc """
  The kinds of the house that match a text. Each word of the text must be
  the start of a word of the kind: of its name or of its more words
  (`@words`). Capitals have no effect. So "tes" finds the car, and "ump" finds
  no pump. An empty text matches all the kinds.
  """
  def search(text, kinds \\ house_kinds()) do
    case words_of(text) do
      [] ->
        kinds

      parts ->
        Enum.filter(kinds, fn kind ->
          words = words_of(Enum.join([kind.name | Map.get(@words, kind.type, [])], " "))
          Enum.all?(parts, fn part -> Enum.any?(words, &String.starts_with?(&1, part)) end)
        end)
    end
  end

  defp words_of(text),
    do: text |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

  @doc "The kinds that can go in the house: in a room, on the roof or in a pool."
  def house_kinds,
    do: Enum.filter(@kinds, fn kind -> Enum.any?(kind.places, &(&1 in [:pool | @places])) end)

  @doc """
  Where a kind can go in the house, in words: for example "a room inside
  or a pool".
  """
  def where(%{places: places}) do
    names = %{
      indoor: "a room inside",
      outdoor: "a room outside",
      roof: "the roof",
      pool: "a pool"
    }

    places
    |> Enum.filter(&Map.has_key?(names, &1))
    |> Enum.sort_by(&Enum.find_index([:indoor, :outdoor, :roof, :pool], fn p -> p == &1 end))
    |> Enum.map(&names[&1])
    |> join_or()
  end

  defp join_or([one]), do: one
  defp join_or(list), do: Enum.join(Enum.drop(list, -1), ", ") <> " or " <> List.last(list)

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

  @doc """
  The step of the buttons − and + of a number parameter, at a value. Hours
  with decimals go by half an hour. For the other numbers, the step is near
  5% of the value: 1, 2 or 5 times a power of ten. It is 1 at least for a
  whole number, and 0.1 at least for a number with decimals. For a value
  near 0, the step is 5% of 1/200 of the range (1/4000 of the range), so it
  is never 0.
  """
  def step(%{unit: "h", type: :float}, _value), do: 0.5

  def step(%{type: type, min: min, max: max}, value) do
    step = round_step(max(abs(value), (max - min) / 200) * 0.05)
    if type == :int, do: max(1, round(step)), else: max(0.1, step)
  end

  # The power of ten times 1, 2 or 5 that is nearest to a number (in its
  # ratio to the number).
  defp round_step(n) do
    ten = :math.pow(10, Float.floor(:math.log10(n)))
    Enum.min_by([1, 2, 5, 10], &abs(:math.log(n / (&1 * ten)))) * ten
  end

  @doc """
  The value after a tap on − (`by` = -1) or + (`by` = 1). It is the next
  round value (a multiple of the step), down or up. It stays in the range
  of the parameter.
  """
  def stepped(%{type: type, min: min, max: max} = param, value, by) when by in [-1, 1] do
    step = step(param, value)
    # The ratio has a round: 0.3 / 0.1 is 2.9999999999999996.
    ratio = Float.round(value / step, 6)
    count = if by > 0, do: Float.floor(ratio) + 1, else: Float.ceil(ratio) - 1
    next = count * step

    case type do
      :int -> next |> round() |> max(min) |> min(max)
      :float -> next |> Float.round(2) |> max(min / 1) |> min(max / 1)
    end
  end

  @doc "The parameters of a type with their default values."
  def defaults(type), do: Map.new(kind(type).params, &{&1.key, &1.default})

  @doc """
  The name of an item: the name of its kind, or the name that the user
  gave to an item of the kind "Other". A power station of a model has the
  name of its model.
  """
  def name(%{type: "other", params: %{"name" => name}}), do: name

  def name(%{type: "power_station", params: %{"model" => model}}) when model != "other" do
    {_key, name, _numbers, _size, _source} = List.keyfind(@station_models, model, 0)
    name
  end

  def name(%{type: type}), do: kind(type).name

  @doc """
  The name of an item in the middle of a sentence. The name of a model of
  power station is a proper name, and it stays. Else the first letter is
  in lower case, but not in a word of capitals ("TV").
  """
  def text_name(%{type: "power_station", params: %{"model" => model}} = item)
      when model != "other",
      do: name(item)

  def text_name(item) do
    name = name(item)
    {first, rest} = String.split_at(name, 1)
    second = String.slice(rest, 0, 1)
    if String.downcase(second) == second, do: String.downcase(first) <> rest, else: name
  end

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
