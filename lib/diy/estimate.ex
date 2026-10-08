defmodule DIY.Estimate do
  @moduledoc """
  The estimate of the power that a house uses in each month, from the
  weather and the items, with a range (honesty rule 3: a range, not one
  number, when the estimate comes from the weather).

  ## The model

  The heat that goes through the walls, the roof and the windows is in
  proportion to the difference of the temperatures inside and outside. The
  degree days of a month add that difference for each day (base 65 °F). So:

      heat of a month (BTU) = UA × degree days × 24 hours

  UA is the heat that the house gains or loses in one hour for each °F. The
  app uses UA = size × a factor for the age × a factor for the floors. The
  factors are a simple model of the app, not a measurement: an older house
  has less insulation, and a house with more floors has less roof for each
  square foot. For cooling, the factor also has the sun and the people in
  the house. For heating, the sun and the people help, so the factor is 60%
  of the cooling factor. A meter file (phase 2) replaces this model.

  - An AC uses `BTU ÷ (SEER2 × 1,000)` kWh. A heat pump uses
    `BTU ÷ (HSPF2 × 1,000)` kWh. Electric heat uses `BTU ÷ 3,412` kWh.
  - A gas furnace uses gas for heat. Only its blower uses electricity, for
    the hours that it runs.
  - A water heater heats the water of the people: 15 gallons for each
    person in one day, from the temperature of the water in the ground to
    120 °F.
  - The other items use `power × hours`, or the kWh in one year of their
    label.

  ## The range

  The range has two parts, and they are independent, so the range adds
  them as squares (`√(weather² + model²)`):

  - The weather. For a month: the low end uses the mildest month of that
    name in the 10 years, and the high end the hottest or the coldest one.
    For the year: the year with the least and the year with the most kWh.
  - The model: 15% for the heat and the cooling, 20% for a typical item (a
    guess of the preset), and 10% for an item that the user checked. The
    model is wrong in the same direction in each month, so the model part
    of the year is the sum of the months.
  """

  alias DIY.{Build, Catalog}

  @month_names ~w(January February March April May June July August September October November December)
  @days [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

  # The UA factor (BTU in one hour, for each square foot and each °F) for
  # cooling, by the year that the house was built.
  @ua [{1980, 0.65}, {2000, 0.55}, {2010, 0.48}]
  @ua_new 0.40
  @floors %{1 => 1.0, 2 => 0.92, 3 => 0.88}
  @heating 0.6

  # An AC runs at most 85% of the hours of a month.
  @duty 0.85

  @hvac_range 0.15
  @typical_range 0.20
  @checked_range 0.10

  @doc "The names of the months."
  def month_names, do: @month_names

  @doc """
  The UA of a house (BTU in one hour, for each °F) for cooling, with the
  factors that give it.
  """
  def ua(%{size: size, year: year, floors: floors}) do
    age = Enum.find_value(@ua, @ua_new, fn {before, factor} -> if year < before, do: factor end)
    floor = Map.fetch!(@floors, floors)
    %{ua: size * age * floor, age: age, floor: floor}
  end

  @doc """
  The estimate of a build with the weather of its place. The result has
  `ready` false, and the reason in `missing`, when the build cannot have an
  estimate yet.
  """
  @spec run(Build.t(), DIY.Weather.t() | nil) :: map()
  def run(%Build{} = build, climate) do
    case missing(build, climate) do
      [] -> estimate(build, climate)
      missing -> %{ready: false, missing: missing}
    end
  end

  defp missing(build, climate) do
    [
      build.zip == nil && :zip,
      build.house == nil && :house,
      build.door == "planning" && not Enum.any?(build.items, &cooling?/1) && :ac,
      climate == nil && :weather
    ]
    |> Enum.filter(& &1)
  end

  defp cooling?(%{type: "ac"}), do: true
  defp cooling?(%{type: "mini_split"}), do: true
  defp cooling?(_item), do: false

  defp estimate(build, climate) do
    %{ua: ua} = ua(build.house)

    run = fn cdd, hdd, weather, days, month ->
      items_kwh(build, ua, cdd, hdd, weather.t, climate.t_year, days, month)
    end

    months =
      for {month, index} <- Enum.with_index(1..12) do
        weather = Map.fetch!(climate.months, month)
        days = Enum.at(@days, index)
        mean = run.(weather.cdd, weather.hdd, weather, days, month)
        kwh = total(mean)
        mild = total(run.(weather.cdd_min, weather.hdd_min, weather, days, month))
        hard = total(run.(weather.cdd_max, weather.hdd_max, weather, days, month))
        model = model(build, mean)

        %{
          month: month,
          name: Enum.at(@month_names, index),
          days: days,
          cdd: weather.cdd,
          hdd: weather.hdd,
          items: mean,
          kwh: kwh,
          model: model,
          low: max(kwh - hypot(kwh - mild, model), 0.0),
          high: kwh + hypot(hard - kwh, model),
          cooling: part(mean, :cooling),
          heating: part(mean, :heating),
          other: part(mean, :other)
        }
      end

    kwh = Enum.sum(Enum.map(months, & &1.kwh))
    years = years(build, climate, run)
    model = Enum.sum(Enum.map(months, & &1.model))

    %{
      ready: true,
      missing: [],
      ua: ua(build.house),
      months: months,
      kwh: kwh,
      low: max(kwh - hypot(kwh - Enum.min(years, fn -> kwh end), model), 0.0),
      high: kwh + hypot(Enum.max(years, fn -> kwh end) - kwh, model),
      items: by_item(build, months),
      shares: %{
        cooling: cooling_split(build.items, build.house.size),
        heating: heating_split(build.items, build.house.size)
      },
      notes: notes(build, months),
      climate: %{first: climate.first, last: climate.last, lat: climate.lat, lon: climate.lon}
    }
  end

  defp hypot(a, b), do: :math.sqrt(a * a + b * b)

  # The kWh of each full year of the weather history.
  defp years(build, climate, run) do
    for year <- climate.first..climate.last,
        months = for(m <- 1..12, value = climate.series[{year, m}], do: {m, value}),
        length(months) == 12 do
      months
      |> Enum.map(fn {m, value} ->
        weather = Map.fetch!(climate.months, m)
        total(run.(value.cdd, value.hdd, weather, Enum.at(@days, m - 1), m))
      end)
      |> Enum.sum()
    end
    |> then(fn years -> if build.items == [], do: [], else: years end)
  end

  # The model part of the range of a month: each item with its own range.
  defp model(build, items) do
    typical = Map.new(build.items, &{&1.id, &1.typical})

    items
    |> Enum.map(fn {id, %{kwh: kwh, part: part}} ->
      kwh *
        cond do
          part in [:cooling, :heating] -> @hvac_range
          typical[id] -> @typical_range
          true -> @checked_range
        end
    end)
    |> Enum.sum()
  end

  defp total(items), do: items |> Map.values() |> Enum.map(& &1.kwh) |> Enum.sum()

  defp part(items, part) do
    items |> Map.values() |> Enum.filter(&(&1.part == part)) |> Enum.map(& &1.kwh) |> Enum.sum()
  end

  defp by_item(build, months) do
    Map.new(build.items, fn item ->
      kwh = Enum.map(months, &Map.fetch!(&1.items, item.id).kwh)

      {item.id,
       %{year: Enum.sum(kwh), months: kwh, part: Map.fetch!(hd(months).items, item.id).part}}
    end)
  end

  # A note for each problem that the user must know.
  defp notes(build, months) do
    small =
      Enum.flat_map(months, fn month ->
        for {id, %{full: true}} <- month.items, do: id
      end)
      |> Enum.uniq()

    Enum.flat_map(build.items, fn item ->
      if item.id in small,
        do: [
          {item.id,
           "#{Catalog.name(item)} is small for the house: on the hottest or coldest days, it runs all the time."}
        ],
        else: []
    end)
  end

  ## The items of one month

  # The kWh of each item in a month: %{id => %{kwh, part, full}}.
  defp items_kwh(build, ua, cdd, hdd, t, t_year, days, month) do
    house = build.house
    cooling = cooling_split(build.items, house.size)
    heating = heating_split(build.items, house.size)
    cool_btu = ua * cdd * 24
    heat_btu = ua * @heating * hdd * 24

    Map.new(build.items, fn item ->
      {item.id,
       kwh(item, %{
         days: days,
         month: month,
         t: t,
         t_year: t_year,
         cool_btu: cool_btu * Map.get(cooling, item.id, 0),
         heat_btu: heat_btu * Map.get(heating, item.id, 0),
         size: house.size
       })}
    end)
  end

  @doc """
  The share of the cooling of each item. A mini split cools its area. The
  central ACs cool the rest, in proportion to their size.
  """
  def cooling_split(items, size) do
    splits = Enum.filter(items, &(&1.type == "mini_split"))
    central = Enum.filter(items, &(&1.type == "ac"))
    split_shares(splits, size, central, & &1.params["tons"])
  end

  @doc """
  The share of the heating of each item. A mini split that heats heats its
  area. The rest goes to one kind of heater: a heat pump, else a gas
  furnace, else electric heat. The heaters of that kind share it equally.
  """
  def heating_split(items, size) do
    splits = Enum.filter(items, &(&1.type == "mini_split" and &1.params["heat_pump"]))

    central =
      [
        &(&1.type == "ac" and &1.params["heat_pump"]),
        &(&1.type == "furnace"),
        &(&1.type == "heat_strips")
      ]
      |> Enum.map(&Enum.filter(items, &1))
      |> Enum.find([], &(&1 != []))

    split_shares(splits, size, central, fn _ -> 1 end)
  end

  defp split_shares(splits, size, central, weight) do
    {shares, left} =
      Enum.reduce(splits, {%{}, 1.0}, fn item, {shares, left} ->
        share = min(item.params["area"] / size, left)
        {Map.put(shares, item.id, share), left - share}
      end)

    total = central |> Enum.map(weight) |> Enum.sum()

    Enum.reduce(central, shares, fn item, shares ->
      Map.put(shares, item.id, left * weight.(item) / total)
    end)
  end

  @doc """
  The kWh of one item in one month. `ctx` has the days, the month, the
  temperature, the BTU of cooling and heating of the item, and the size of
  the house.
  """
  def kwh(%{type: "ac", params: p}, ctx) do
    capacity = p["tons"] * 12_000 * 24 * ctx.days * @duty
    cool = min(ctx.cool_btu, capacity)
    heat = if p["heat_pump"], do: ctx.heat_btu / (p["hspf2"] * 1_000), else: 0.0

    %{
      kwh: cool / (p["seer2"] * 1_000) + heat,
      part: hvac_part(ctx),
      full: ctx.cool_btu > capacity
    }
  end

  def kwh(%{type: "mini_split", params: p}, ctx) do
    heat = if p["heat_pump"], do: ctx.heat_btu / (p["hspf2"] * 1_000), else: 0.0
    %{kwh: ctx.cool_btu / (p["seer2"] * 1_000) + heat, part: hvac_part(ctx), full: false}
  end

  def kwh(%{type: "furnace", params: p}, ctx) do
    # A furnace of 30 BTU an hour for each square foot.
    hours = ctx.heat_btu / (30 * ctx.size)
    %{kwh: hours * p["blower"] / 1_000, part: :heating, full: false}
  end

  def kwh(%{type: "heat_strips", params: p}, ctx) do
    capacity = p["kw"] * 3_412 * 24 * ctx.days * @duty
    %{kwh: min(ctx.heat_btu, capacity) / 3_412, part: :heating, full: ctx.heat_btu > capacity}
  end

  def kwh(%{type: "water_heater", params: p}, ctx) do
    per_kwh = %{"electric" => 0.93, "heat_pump" => 3.5, "gas" => nil}[p["fuel"]]
    btu = p["people"] * 15 * 8.34 * max(120 - inlet(ctx), 0) * ctx.days
    other(if(per_kwh, do: btu / 3_412 / per_kwh, else: 0.0))
  end

  def kwh(%{type: type, params: p}, ctx) when type in ["fridge", "freezer"],
    do: other(p["kwh_year"] * ctx.days / 365)

  def kwh(%{type: "range", params: p}, ctx),
    do: other(if(p["fuel"] == "electric", do: 1.0, else: 0.05) * ctx.days)

  def kwh(%{type: "microwave", params: p}, ctx),
    do: other(p["watts"] * p["minutes"] / 60 / 1_000 * ctx.days)

  def kwh(%{type: "dishwasher", params: p}, ctx), do: other(p["loads"] * ctx.days / 7 * 1.0)
  def kwh(%{type: "washer", params: p}, ctx), do: other(p["loads"] * ctx.days / 7 * 0.25)

  def kwh(%{type: "dryer", params: p}, ctx),
    do: other(p["loads"] * ctx.days / 7 * if(p["fuel"] == "electric", do: 2.5, else: 0.2))

  def kwh(%{type: "lights", params: p}, ctx),
    do: other(p["bulbs"] * p["watts"] * p["hours"] * ctx.days / 1_000)

  def kwh(%{type: "ceiling_fan", params: p} = item, ctx),
    do: other(in_season(item, ctx) * p["count"] * p["watts"] * p["hours"] * ctx.days / 1_000)

  def kwh(%{type: "always_on", params: p}, ctx), do: other(p["watts"] * 24 * ctx.days / 1_000)

  def kwh(%{params: p} = item, ctx),
    do: other(in_season(item, ctx) * p["watts"] * p["hours"] * ctx.days / 1_000)

  defp other(kwh), do: %{kwh: kwh / 1, part: :other, full: false}

  defp hvac_part(%{cool_btu: cool, heat_btu: heat}) when cool >= heat, do: :cooling
  defp hvac_part(_ctx), do: :heating

  defp in_season(%{params: %{"season" => season}}, ctx),
    do: if(ctx.month in Catalog.season_months(season), do: 1, else: 0)

  defp in_season(_item, _ctx), do: 1

  @doc """
  The temperature of the water that comes into the house, in °F: the
  ground follows the air of the year, and half of the change of the month.
  """
  def inlet(%{t: t, t_year: t_year}), do: (t_year + (t - t_year) / 2) |> max(40) |> min(90)

  @doc """
  The steps of the calculation of an item in one month, as text (honesty
  rule 1: show the math).
  """
  def explain(%{type: "ac", params: p} = item, month, estimate) do
    m = Enum.at(estimate.months, month - 1)
    %{ua: ua, age: age, floor: floor} = estimate.ua
    share = Map.get(estimate.shares.cooling, item.id, 0)
    btu = ua * m.cdd * 24 * share
    capacity = p["tons"] * 12_000 * 24 * m.days * @duty

    [
      "The house gains #{fmt(ua)} BTU in one hour for each °F hotter outside: #{fmt(ua / age / floor)} sq ft × #{age} for its age × #{floor} for its floors.",
      "#{m.name} has #{fmt(m.cdd)} °F-days of cooling: the mean of #{estimate.climate.first} to #{estimate.climate.last} (NASA POWER).",
      "#{fmt(ua)} × #{fmt(m.cdd)} × 24 hours#{share_text(share)} = #{fmt(btu)} BTU.",
      "÷ (#{p["seer2"]} SEER2 × 1,000) = #{fmt(min(btu, capacity) / (p["seer2"] * 1_000))} kWh for cooling in #{m.name}."
    ] ++
      if(p["heat_pump"],
        do: ["It heats too: the heat of a cold month ÷ (#{p["hspf2"]} HSPF2 × 1,000)."],
        else: []
      )
  end

  def explain(%{type: "water_heater", params: p}, month, estimate) do
    m = Enum.at(estimate.months, month - 1)

    [
      "#{p["people"]} people × 15 gallons in one day × 8.34 pounds for each gallon × (120 °F − the water from the ground).",
      "The water of #{m.name} comes in near the temperature of the ground: the mean air of the year, and half of the change of the month.",
      case p["fuel"] do
        "gas" ->
          "The water heater uses gas: no electricity."

        "electric" ->
          "÷ 3,412 BTU for each kWh ÷ 0.93 (the efficiency of an electric water heater)."

        "heat_pump" ->
          "÷ 3,412 BTU for each kWh ÷ 3.5 (a heat pump gives 3.5 times the heat of its electricity)."
      end
    ]
  end

  def explain(%{type: type, params: p}, _month, _estimate) when type in ["fridge", "freezer"],
    do: ["#{fmt(p["kwh_year"])} kWh in one year ÷ 365 days × the days of the month."]

  def explain(%{type: "furnace", params: p}, _month, _estimate),
    do: [
      "The furnace burns gas for heat. Its blower uses #{p["blower"]} W while it runs.",
      "The hours: the heat of the month ÷ 30 BTU in one hour for each square foot (a typical furnace)."
    ]

  def explain(%{type: "heat_strips", params: p}, _month, _estimate),
    do: ["The heat of the month ÷ 3,412 BTU for each kWh. At most #{p["kw"]} kW all the time."]

  def explain(%{type: "mini_split", params: p}, _month, _estimate),
    do: [
      "It cools #{p["area"]} sq ft of the house: that share of the heat ÷ (#{p["seer2"]} SEER2 × 1,000)."
    ]

  def explain(%{type: "range", params: p}, _month, _estimate),
    do: [
      "A #{p["fuel"]} stove and oven: #{if p["fuel"] == "electric", do: "1 kWh", else: "0.05 kWh (the igniter and the clock)"} in one day."
    ]

  def explain(%{type: "microwave", params: p}, _month, _estimate),
    do: ["#{p["watts"]} W × #{p["minutes"]} minutes in one day × the days of the month."]

  def explain(%{type: type, params: p}, _month, _estimate)
      when type in ["dishwasher", "washer", "dryer"] do
    per_load =
      case {type, p["fuel"]} do
        {"dishwasher", _} -> "1 kWh"
        {"washer", _} -> "0.25 kWh (the motor; the hot water is on the water heater)"
        {"dryer", "electric"} -> "2.5 kWh"
        {"dryer", "gas"} -> "0.2 kWh (the drum and the fan; the heat is gas)"
      end

    ["#{p["loads"]} loads in one week × #{per_load} for each load."]
  end

  def explain(%{type: "lights", params: p}, _month, _estimate),
    do: [
      "#{p["bulbs"]} bulbs × #{p["watts"]} W × #{p["hours"]} hours in one day × the days of the month."
    ]

  def explain(%{type: "ceiling_fan", params: p}, _month, _estimate),
    do: [
      "#{p["count"]} fans × #{p["watts"]} W × #{p["hours"]} hours in one day, #{season_text(p)}."
    ]

  def explain(%{type: "always_on", params: p}, _month, _estimate),
    do: ["#{p["watts"]} W × 24 hours × the days of the month."]

  def explain(%{params: p}, _month, _estimate),
    do: [
      "#{p["watts"]} W × #{p["hours"]} hours in one day × the days of the month#{if p["season"], do: ", #{season_text(p)}", else: ""}."
    ]

  defp share_text(share) when share >= 0.999, do: ""
  defp share_text(share), do: " × #{round(share * 100)}% (its share of the house)"

  defp season_text(%{"season" => season}), do: String.downcase(Catalog.season_label(season))

  @doc "A number with a comma for thousands, and no decimals."
  def fmt(number) when is_number(number) do
    number
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
