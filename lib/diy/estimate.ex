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
  - An AC, a heat pump and electric heat give at most their size for 85%
    of the hours of a month. The heat that the heat pumps cannot give goes
    to the electric heat (the heat strips), if the house has it.
  - A gas furnace uses gas for heat. Only its blower uses electricity, for
    the hours that it runs.
  - A gas furnace, a gas water heater, a gas stove and a gas dryer burn
    gas. The gas is in therms (100,000 BTU), with its own range
    (`therms/2`).
  - A water heater heats the water of the people: 15 gallons for each
    person in one day, from the temperature of the water in the ground to
    120 °F.
  - The other items use `power × hours`, or the kWh in one year of their
    label. A fridge or a freezer in a room around the house (a garage, a
    shed) uses more in a hot month (`air_factor/2`).

  ## The range

  The range has two parts, and they are independent, so the range adds
  them as squares (`√(weather² + model²)`):

  - The weather. For a month: the same month of each of the 10 years,
    with the least and the most kWh. For the year: the year with the least
    and the year with the most kWh.
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

  # The gas items (`therms/2`):
  #
  # - A furnace gives 80% of the heat of its gas: the AFUE that the US asks
  #   of a gas furnace (10 CFR 430.32(e)).
  # - A gas water heater of 40 gallons gives 58% (the UEF of 10 CFR
  #   430.32(d), for a medium draw).
  # - A gas stove and oven burns 2.02 million BTU in one year. This is the
  #   mean of the US homes that cook with gas (RECS 2020 of the US Energy
  #   Information Administration, table CE5.4.ST).
  # - A gas dryer burns 2.06 million BTU in one year: the mean of the US
  #   homes with a gas dryer (RECS 2020, table CE5.4.ST). The test of the
  #   US Department of Energy counts 283 loads in one year (10 CFR 430,
  #   subpart B, appendix D1). So a load burns 0.073 therm.
  @furnace 0.8
  @gas_water 0.58
  @stove 0.055
  @dryer 0.073
  @therm 100_000

  @hvac_range 0.15
  @typical_range 0.20
  @checked_range 0.10

  @doc "The names of the months."
  def month_names, do: @month_names

  @doc """
  The UA of a house (BTU in one hour, for each °F) for cooling, with the
  factors that give it, and the UA for heat (60% of it).
  """
  def ua(%{size: size, year: year, floors: floors}) do
    age = Enum.find_value(@ua, @ua_new, fn {before, factor} -> if year < before, do: factor end)
    floor = Map.fetch!(@floors, floors)
    ua = size * age * floor
    %{ua: ua, size: size, age: age, floor: floor, heat: ua * @heating}
  end

  @doc """
  The estimate of a build with the weather of its place: of the house only
  (`DIY.Build.house_view/1`), with no van and no item in a van. The result
  has `ready` false, and the reason in `missing`, when the build cannot
  have an estimate yet.
  """
  @spec run(Build.t(), DIY.Weather.t() | nil) :: map()
  def run(%Build{} = build, climate) do
    build = Build.house_view(build)

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

    # The kWh of each month of each year of the history.
    history =
      Map.new(climate.series, fn {{year, month}, value} ->
        weather = Map.fetch!(climate.months, month)
        days = Enum.at(@days, month - 1)
        items = run.(value.cdd, value.hdd, weather, days, month)
        {{year, month}, %{kwh: total(items), therms: total(items, :therms)}}
      end)

    months =
      for {month, index} <- Enum.with_index(1..12) do
        weather = Map.fetch!(climate.months, month)
        days = Enum.at(@days, index)
        mean = run.(weather.cdd, weather.hdd, weather, days, month)
        kwh = total(mean)
        therms = total(mean, :therms)
        # The same month of each year: the least and the most.
        same = for year <- climate.first..climate.last, v = history[{year, month}], v, do: v
        model = model(build, mean, :kwh)
        therms_model = model(build, mean, :therms)
        {low, high} = ends(kwh, Enum.min_max([kwh | Enum.map(same, & &1.kwh)]), model)

        {therms_low, therms_high} =
          ends(therms, Enum.min_max([therms | Enum.map(same, & &1.therms)]), therms_model)

        %{
          month: month,
          name: Enum.at(@month_names, index),
          days: days,
          cdd: weather.cdd,
          hdd: weather.hdd,
          t: weather.t,
          items: mean,
          kwh: kwh,
          model: model,
          low: low,
          high: high,
          therms: therms,
          therms_model: therms_model,
          therms_low: therms_low,
          therms_high: therms_high,
          cooling: part(mean, :cooling),
          heating: part(mean, :heating),
          other: part(mean, :other)
        }
      end

    kwh = Enum.sum(Enum.map(months, & &1.kwh))
    therms = Enum.sum(Enum.map(months, & &1.therms))
    years = years(build, climate, history)
    {low, high} = ends(kwh, least_most(years, :kwh, kwh), Enum.sum(Enum.map(months, & &1.model)))

    {therms_low, therms_high} =
      ends(
        therms,
        least_most(years, :therms, therms),
        Enum.sum(Enum.map(months, & &1.therms_model))
      )

    %{
      ready: true,
      missing: [],
      ua: ua(build.house),
      months: months,
      kwh: kwh,
      low: low,
      high: high,
      therms: therms,
      therms_low: therms_low,
      therms_high: therms_high,
      items: by_item(build, months),
      shares: %{
        cooling: cooling_split(build.items, build.house.size),
        heating: heating_split(build.items, build.house.size)
      },
      notes: notes(build, months),
      climate: %{
        first: climate.first,
        last: climate.last,
        lat: climate.lat,
        lon: climate.lon,
        t_year: climate.t_year
      }
    }
  end

  defp hypot(a, b), do: :math.sqrt(a * a + b * b)

  # The range of a value, from the least and the most of the weather, and
  # the part of the model.
  defp ends(value, {least, most}, model),
    do: {max(value - hypot(value - least, model), 0.0), value + hypot(most - value, model)}

  defp least_most(years, key, value) do
    values = Enum.map(years, &Map.fetch!(&1, key))
    {Enum.min(values, fn -> value end), Enum.max(values, fn -> value end)}
  end

  # The kWh and the therms of each full year of the weather history.
  defp years(build, climate, history) do
    for year <- climate.first..climate.last,
        months = for(m <- 1..12, value = history[{year, m}], value, do: value),
        length(months) == 12 do
      %{
        kwh: Enum.sum(Enum.map(months, & &1.kwh)),
        therms: Enum.sum(Enum.map(months, & &1.therms))
      }
    end
    |> then(fn years -> if build.items == [], do: [], else: years end)
  end

  # The model part of the range of a month (of the kWh or of the therms):
  # each item with its own range.
  defp model(build, items, key) do
    typical = Map.new(build.items, &{&1.id, &1.typical})

    items
    |> Enum.map(fn {id, %{part: part} = data} ->
      Map.fetch!(data, key) *
        cond do
          part in [:cooling, :heating] -> @hvac_range
          typical[id] -> @typical_range
          true -> @checked_range
        end
    end)
    |> Enum.sum()
  end

  defp total(items, key \\ :kwh),
    do: items |> Map.values() |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  defp part(items, part) do
    items |> Map.values() |> Enum.filter(&(&1.part == part)) |> Enum.map(& &1.kwh) |> Enum.sum()
  end

  defp by_item(build, months) do
    Map.new(build.items, fn item ->
      kwh = Enum.map(months, &Map.fetch!(&1.items, item.id).kwh)

      {item.id,
       %{
         year: Enum.sum(kwh),
         months: kwh,
         therms: months |> Enum.map(&Map.fetch!(&1.items, item.id).therms) |> Enum.sum(),
         part: Map.fetch!(hd(months).items, item.id).part
       }}
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

  # The kWh and the therms of each item in a month: %{id => %{kwh, therms,
  # part, full, cool_btu, heat_btu}}. The BTU of cooling and of heat that
  # the item must give are in cool_btu and heat_btu.
  defp items_kwh(build, ua, cdd, hdd, t, t_year, days, month) do
    house = build.house
    cooling = cooling_split(build.items, house.size)
    heating = heating_split(build.items, house.size)
    cool_btu = ua * cdd * 24
    heat_btu = ua * @heating * hdd * 24
    backup = backup(build.items, heating, heat_btu, days)

    around = MapSet.new(for r <- build.rooms, r.level == "outside", do: r.id)

    Map.new(build.items, fn item ->
      ctx = %{
        days: days,
        month: month,
        t: t,
        around: MapSet.member?(around, item.room),
        t_year: t_year,
        cool_btu: cool_btu * Map.get(cooling, item.id, 0),
        heat_btu: heat_btu * Map.get(heating, item.id, 0) + Map.get(backup, item.id, 0),
        size: house.size
      }

      {item.id,
       item
       |> kwh(ctx)
       |> Map.put(:therms, therms(item, ctx))
       |> Map.merge(Map.take(ctx, [:cool_btu, :heat_btu]))}
    end)
  end

  # The heat that the heat pumps cannot give in a month: the electric heat
  # (the heat strips) shares it equally, if the house has it.
  defp backup(items, heating, heat_btu, days) do
    strips = Enum.filter(items, &(&1.type == "heat_strips"))

    unmet =
      items
      |> Enum.filter(&(&1.type == "ac" and &1.params["heat_pump"]))
      |> Enum.map(&max(heat_btu * Map.get(heating, &1.id, 0) - capacity(&1, days), 0))
      |> Enum.sum()

    Map.new(strips, &{&1.id, unmet / length(strips)})
  end

  @doc """
  The most BTU that an AC, a heat pump or electric heat gives in a month:
  its size for 85% of the hours.
  """
  def capacity(%{type: "heat_strips", params: p}, days), do: p["kw"] * 3_412 * 24 * days * @duty
  def capacity(%{params: p}, days), do: p["tons"] * 12_000 * 24 * days * @duty

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
  the house. It also has `around`: true for an item in a room around the
  house.
  """
  def kwh(%{type: "ac", params: p} = item, ctx) do
    capacity = capacity(item, ctx.days)
    cool = min(ctx.cool_btu, capacity)
    heat = if p["heat_pump"], do: min(ctx.heat_btu, capacity), else: 0.0

    %{
      kwh: cool / (p["seer2"] * 1_000) + heat / (p["hspf2"] * 1_000),
      part: hvac_part(ctx),
      full: ctx.cool_btu > capacity or (p["heat_pump"] and ctx.heat_btu > capacity)
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

  def kwh(%{type: "heat_strips"} = item, ctx) do
    capacity = capacity(item, ctx.days)
    %{kwh: min(ctx.heat_btu, capacity) / 3_412, part: :heating, full: ctx.heat_btu > capacity}
  end

  def kwh(%{type: "water_heater", params: p}, ctx) do
    per_kwh = %{"electric" => 0.93, "heat_pump" => 3.5, "gas" => nil}[p["fuel"]]
    other(if(per_kwh, do: water_btu(p, ctx) / 3_412 / per_kwh, else: 0.0))
  end

  def kwh(%{type: type, params: p}, ctx) when type in ["fridge", "freezer"] do
    air = air_factor(type, ctx)

    other(p["kwh_year"] * ctx.days / 365 * air)
    |> Map.merge(%{air: air, around: Map.get(ctx, :around, false)})
  end

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

  # A meter measures the power of the house. Its own power is too small to
  # show. A camper van has its own build, with its own power (DIY.Van).
  def kwh(%{type: type}, _ctx) when type in ["smart_meter", "camper_van"], do: other(0)

  # The power equipment changes the power from the grid, not the use of
  # the house: see DIY.Power.
  def kwh(%{type: type}, _ctx) when type in ["power_station", "solar_panels", "transfer_switch"],
    do: other(0)

  def kwh(%{type: "ev", params: p}, ctx),
    do: other(p["miles"] * ctx.days / p["mi_kwh"] / charge_efficiency(p["charger"]))

  def kwh(%{params: p} = item, ctx),
    do: other(in_season(item, ctx) * p["watts"] * p["hours"] * ctx.days / 1_000)

  defp other(kwh), do: %{kwh: kwh / 1, part: :other, full: false}

  # The label of a fridge comes from a test at 90 °F with closed doors.
  # This test stands for a kitchen near 72 °F, with doors that open (10
  # CFR 430, subpart B, appendix A). A fridge works against the heat that
  # comes in through its walls. This heat is in proportion to the
  # difference between the air around it and its inside. The inside of the
  # test is 39 °F in a fridge and 0 °F in a freezer. A room around the house
  # (a garage, a shed) has the mean air outside: a simple model of the app.
  @kitchen 72
  @cold %{"fridge" => 39, "freezer" => 0}

  @doc """
  The factor of the use of a fridge or a freezer for the air around it. In
  the house, it is 1. Around the house, it is the difference between the
  mean air outside (`ctx.t`, °F) and its inside, divided by the same
  difference in a kitchen. It is never under 1. In a cold month, the app
  keeps the label: a garage is warmer than the air outside.
  """
  def air_factor(type, %{around: true, t: t}),
    do: max((t - @cold[type]) / (@kitchen - @cold[type]), 1.0)

  def air_factor(_type, _ctx), do: 1.0

  # The heat of the hot water of a month, in BTU.
  defp water_btu(p, ctx), do: p["people"] * 15 * 8.34 * max(120 - inlet(ctx), 0) * ctx.days

  @doc """
  The gas of one item in one month, in therms (100,000 BTU). A gas
  furnace, a gas water heater, a gas stove and a gas dryer burn gas. The
  other items burn no gas. `ctx` is the same as for `kwh/2`.
  """
  def therms(%{type: "furnace"}, ctx), do: ctx.heat_btu / @furnace / @therm

  def therms(%{type: "water_heater", params: %{"fuel" => "gas"} = p}, ctx),
    do: water_btu(p, ctx) / @gas_water / @therm

  def therms(%{type: "range", params: %{"fuel" => "gas"}}, ctx), do: @stove * ctx.days

  def therms(%{type: "dryer", params: %{"fuel" => "gas"} = p}, ctx),
    do: p["loads"] * ctx.days / 7 * @dryer

  def therms(_item, _ctx), do: 0.0

  @doc "The part of the power that goes into the battery of a car: a charge loses some."
  def charge_efficiency("l1"), do: 0.85
  def charge_efficiency("l2"), do: 0.9

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
  rule 1: show the math). Each step shows its numbers, and the last step
  gives the kWh of the item in the month.
  """
  def explain(item, month, estimate) do
    m = Enum.at(estimate.months, month - 1)
    steps(item, m, Map.fetch!(m.items, item.id), estimate) ++ [last(item, m)]
  end

  # The last step: the kWh of the month.
  defp last(%{type: "ac", params: %{"heat_pump" => true}} = item, m) do
    %{cool: cool, heat: heat} = hvac_kwh(item, m)

    "#{number_text(cool)} kWh of cooling + #{number_text(heat)} kWh of heat = #{total_text(item, m)}."
  end

  defp last(%{type: "mini_split", params: %{"heat_pump" => true}} = item, m) do
    %{cool: cool, heat: heat} = hvac_kwh(item, m)

    "#{number_text(cool)} kWh of cooling + #{number_text(heat)} kWh of heat = #{total_text(item, m)}."
  end

  defp last(item, m), do: "In all: #{total_text(item, m)}."

  defp total_text(item, m),
    do: "#{number_text(Map.fetch!(m.items, item.id).kwh)} kWh in #{m.name}"

  # The kWh of cooling and of heat of an AC or a mini split.
  defp hvac_kwh(%{params: p} = item, m) do
    %{cool_btu: cool, heat_btu: heat} = Map.fetch!(m.items, item.id)
    limit = if item.type == "ac", do: capacity(item, m.days), else: nil

    %{
      cool: given(cool, limit) / (p["seer2"] * 1_000),
      heat: given(heat, limit) / (p["hspf2"] * 1_000)
    }
  end

  defp given(btu, nil), do: btu
  defp given(btu, limit), do: min(btu, limit)

  defp steps(%{type: "ac", params: p} = item, m, data, estimate) do
    limit = capacity(item, m.days)

    cooling(m, data, estimate, share(estimate.shares.cooling, item)) ++
      limit_steps(item, data.cool_btu, limit, m, "cooling") ++
      [
        "#{fmt(given(data.cool_btu, limit))} BTU ÷ (#{num(p["seer2"])} SEER2 × 1,000) = #{number_text(given(data.cool_btu, limit) / (p["seer2"] * 1_000))} kWh of cooling."
      ] ++
      if p["heat_pump"] do
        heating(m, data.heat_btu, estimate, share(estimate.shares.heating, item)) ++
          limit_steps(item, data.heat_btu, limit, m, "heat") ++
          [
            "#{fmt(given(data.heat_btu, limit))} BTU ÷ (#{num(p["hspf2"])} HSPF2 × 1,000) = #{number_text(given(data.heat_btu, limit) / (p["hspf2"] * 1_000))} kWh of heat."
          ]
      else
        []
      end
  end

  defp steps(%{type: "mini_split", params: p} = item, m, data, estimate) do
    ["It cools #{fmt(p["area"])} sq ft of the house."] ++
      cooling(m, data, estimate, share(estimate.shares.cooling, item)) ++
      [
        "#{fmt(data.cool_btu)} BTU ÷ (#{num(p["seer2"])} SEER2 × 1,000) = #{number_text(data.cool_btu / (p["seer2"] * 1_000))} kWh of cooling."
      ] ++
      if p["heat_pump"] do
        heating(m, data.heat_btu, estimate, share(estimate.shares.heating, item)) ++
          [
            "#{fmt(data.heat_btu)} BTU ÷ (#{num(p["hspf2"])} HSPF2 × 1,000) = #{number_text(data.heat_btu / (p["hspf2"] * 1_000))} kWh of heat."
          ]
      else
        []
      end
  end

  defp steps(%{type: "furnace", params: p} = item, m, data, estimate) do
    size = estimate.ua.size
    hours = data.heat_btu / (30 * size)

    ["The furnace burns gas for heat. Its blower uses #{fmt(p["blower"])} W while it runs."] ++
      heating(m, data.heat_btu, estimate, share(estimate.shares.heating, item)) ++
      if(data.therms > 0,
        do: [
          "#{fmt(data.heat_btu)} BTU ÷ 80% (the heat that a standard furnace gets from its gas) ÷ 100,000 BTU for each therm = #{number_text(data.therms)} therms of gas."
        ],
        else: []
      ) ++
      [
        "#{fmt(data.heat_btu)} BTU ÷ (30 BTU in one hour for each sq ft × #{fmt(size)} sq ft, a typical furnace) = #{number_text(hours)} hours that it runs.",
        "#{number_text(hours)} hours × #{fmt(p["blower"])} W ÷ 1,000 = #{number_text(hours * p["blower"] / 1_000)} kWh."
      ]
  end

  defp steps(%{type: "heat_strips"} = item, m, data, estimate) do
    share = share(estimate.shares.heating, item)
    own = estimate.ua.heat * m.hdd * 24 * share
    backup = data.heat_btu - own
    limit = capacity(item, m.days)

    if(share > 0, do: heating(m, own, estimate, share), else: []) ++
      if(backup > 0.5,
        do: [
          "The heat pump cannot give #{fmt(backup)} BTU of the heat of #{m.name}: the heat strips give it."
        ],
        else: []
      ) ++
      if(share == 0 and backup <= 0.5,
        do: ["The house has other heat: the heat strips give no heat in #{m.name}."],
        else: []
      ) ++
      limit_steps(item, data.heat_btu, limit, m, "heat") ++
      [
        "#{fmt(given(data.heat_btu, limit))} BTU ÷ 3,412 BTU for each kWh = #{number_text(given(data.heat_btu, limit) / 3_412)} kWh."
      ]
  end

  defp steps(%{type: "water_heater", params: p}, m, data, estimate) do
    inlet = inlet(%{t: m.t, t_year: estimate.climate.t_year})
    btu = water_btu(p, %{t: m.t, t_year: estimate.climate.t_year, days: m.days})

    [
      "The water of #{m.name} comes in at #{number_text(inlet)} °F: near the ground, which follows the mean air of the year, and half of the change of the month.",
      "#{p["people"]} people × 15 gallons in one day × 8.34 pounds for each gallon × (120 °F − #{number_text(inlet)} °F) × #{m.days} days = #{fmt(btu)} BTU."
    ] ++
      case p["fuel"] do
        "gas" ->
          [
            "#{fmt(btu)} BTU ÷ 0.58 (the efficiency of a standard gas tank) ÷ 100,000 BTU for each therm = #{number_text(data.therms)} therms of gas.",
            "The water heater uses gas: no electricity."
          ]

        "electric" ->
          [
            "#{fmt(btu)} BTU ÷ 3,412 BTU for each kWh ÷ 0.93 (the efficiency of an electric water heater) = #{number_text(btu / 3_412 / 0.93)} kWh."
          ]

        "heat_pump" ->
          [
            "#{fmt(btu)} BTU ÷ 3,412 BTU for each kWh ÷ 3.5 = #{number_text(btu / 3_412 / 3.5)} kWh: a heat pump gives 3.5 times the heat of its electricity."
          ]
      end
  end

  defp steps(%{type: type, params: p}, m, %{around: true} = data, _estimate)
       when type in ["fridge", "freezer"] do
    label = p["kwh_year"] * m.days / 365

    air =
      "Around the house, the app uses the mean air outside: #{number_text(m.t)} °F in #{m.name}."

    if data.air > 1.0 do
      [
        "#{fmt(p["kwh_year"])} kWh in one year ÷ 365 days × #{m.days} days = #{number_text(label)} kWh: the label, for a kitchen near #{@kitchen} °F.",
        air,
        "#{number_text(label)} kWh × (#{number_text(m.t)} °F − #{@cold[type]} °F in the #{type}) ÷ (#{@kitchen} °F − #{@cold[type]} °F) = #{number_text(data.kwh)} kWh."
      ]
    else
      [
        air <> " It is not hotter than a kitchen: the app uses the label.",
        "#{fmt(p["kwh_year"])} kWh in one year ÷ 365 days × #{m.days} days."
      ]
    end
  end

  defp steps(%{type: type, params: p}, m, _data, _estimate) when type in ["fridge", "freezer"],
    do: ["#{fmt(p["kwh_year"])} kWh in one year ÷ 365 days × #{m.days} days."]

  defp steps(%{type: "range", params: p}, m, _data, _estimate) do
    case p["fuel"] do
      "electric" ->
        ["An electric stove and oven: 1 kWh in one day × #{m.days} days."]

      "gas" ->
        [
          "A gas stove and oven burns 0.055 therm of gas in one day (the mean of the US homes that cook with gas) × #{m.days} days = #{number_text(@stove * m.days)} therms.",
          "A gas stove and oven: 0.05 kWh in one day (the igniter and the clock) × #{m.days} days."
        ]
    end
  end

  defp steps(%{type: "microwave", params: p}, m, _data, _estimate),
    do: [
      "#{fmt(p["watts"])} W × #{num(p["minutes"])} minutes in one day ÷ 60 × #{m.days} days ÷ 1,000."
    ]

  defp steps(%{type: type, params: p}, m, _data, _estimate)
       when type in ["dishwasher", "washer", "dryer"] do
    per_load =
      case {type, p["fuel"]} do
        {"dishwasher", _} -> "1 kWh"
        {"washer", _} -> "0.25 kWh (the motor; the hot water is on the water heater)"
        {"dryer", "electric"} -> "2.5 kWh"
        {"dryer", "gas"} -> "0.2 kWh (the drum and the fan; the heat is gas)"
      end

    gas =
      if type == "dryer" and p["fuel"] == "gas",
        do: [
          "#{num(p["loads"])} loads in one week × #{m.days} days ÷ 7 × 0.073 therm of gas for each load (the mean of the US homes) = #{number_text(p["loads"] * m.days / 7 * @dryer)} therms."
        ],
        else: []

    gas ++
      ["#{num(p["loads"])} loads in one week × #{m.days} days ÷ 7 × #{per_load} for each load."]
  end

  defp steps(%{type: "lights", params: p}, m, _data, _estimate),
    do: [
      "#{fmt(p["bulbs"])} bulbs × #{num(p["watts"])} W × #{num(p["hours"])} hours in one day × #{m.days} days ÷ 1,000."
    ]

  defp steps(%{type: "ceiling_fan", params: p} = item, m, _data, _estimate) do
    if in_season(item, %{month: m.month}) == 1,
      do: [
        "#{num(p["count"])} fans × #{num(p["watts"])} W × #{num(p["hours"])} hours in one day × #{m.days} days ÷ 1,000 (#{season_text(p)})."
      ],
      else: ["The fans are off in #{m.name} (#{season_text(p)})."]
  end

  defp steps(%{type: "camper_van"}, _m, _data, _estimate),
    do: [
      "A camper van has its own build, with its own batteries and power. The button \"Open the build of the van\" opens it. Its charge at home is not in this estimate."
    ]

  defp steps(%{type: "smart_meter"}, _m, _data, _estimate),
    do: ["The meter measures the power of the house. Its own power is too small to show."]

  defp steps(%{type: "power_station"}, _m, _data, _estimate),
    do: [
      "A power station keeps power for later. It changes the power from the grid, not the use of the house: see the page Power."
    ]

  defp steps(%{type: "solar_panels"}, _m, _data, _estimate),
    do: [
      "The panels make power. They change the power from the grid, not the use of the house: see the page Power."
    ]

  defp steps(%{type: "transfer_switch"}, _m, _data, _estimate),
    do: ["The device connects the circuits to the grid or to a power station. It uses no power."]

  defp steps(%{type: "ev", params: p}, m, _data, _estimate),
    do: [
      "#{fmt(p["miles"])} miles in one day × #{m.days} days ÷ #{num(p["mi_kwh"])} miles for each kWh ÷ #{num(charge_efficiency(p["charger"]))} (the charge loses some power)."
    ]

  defp steps(%{type: "always_on", params: p}, m, _data, _estimate),
    do: ["#{num(p["watts"])} W × 24 hours × #{m.days} days ÷ 1,000."]

  defp steps(%{params: p} = item, m, _data, _estimate) do
    cond do
      in_season(item, %{month: m.month}) == 0 ->
        ["It is off in #{m.name} (#{season_text(p)})."]

      p["season"] ->
        [
          "#{num(p["watts"])} W × #{num(p["hours"])} hours in one day × #{m.days} days ÷ 1,000 (#{season_text(p)})."
        ]

      true ->
        ["#{num(p["watts"])} W × #{num(p["hours"])} hours in one day × #{m.days} days ÷ 1,000."]
    end
  end

  # The share of an item in the cooling or the heat of the house.
  defp share(shares, item), do: Map.get(shares, item.id, 0)

  # The steps of the cooling of the house for an item.
  defp cooling(m, data, estimate, share) do
    %{ua: ua, size: size, age: age, floor: floor} = estimate.ua

    [
      "The house gains #{fmt(ua)} BTU in one hour for each °F hotter outside: #{fmt(size)} sq ft × #{age} for its age × #{floor} for its floors.",
      "#{m.name} has #{number_text(m.cdd)} °F-days of cooling: the mean of #{estimate.climate.first} to #{estimate.climate.last} (NASA POWER).",
      "#{fmt(ua)} × #{number_text(m.cdd)} × 24 hours#{share_text(share)} = #{fmt(data.cool_btu)} BTU of cooling."
    ]
  end

  # The steps of the heat of the house for an item.
  defp heating(m, btu, estimate, share) do
    %{ua: ua, heat: heat} = estimate.ua

    [
      "In the cold, the house loses #{fmt(heat)} BTU in one hour for each °F colder outside: 60% of #{fmt(ua)}, because the sun and the people in the house help.",
      "#{m.name} has #{number_text(m.hdd)} °F-days of heat: the mean of #{estimate.climate.first} to #{estimate.climate.last} (NASA POWER).",
      "#{fmt(heat)} × #{number_text(m.hdd)} × 24 hours#{share_text(share)} = #{fmt(btu)} BTU of heat."
    ]
  end

  # A step when the item is too small for the month.
  defp limit_steps(%{type: "heat_strips", params: p}, btu, limit, m, _part) when btu > limit,
    do: [
      "#{num(p["kw"])} kW × 3,412 × 24 hours × #{m.days} days × 85% = #{fmt(limit)} BTU: the most that it gives in #{m.name}. It gives that."
    ]

  defp limit_steps(%{params: p}, btu, limit, m, part) when btu > limit do
    rest =
      if part == "heat", do: " The heat strips give the rest, if the house has them.", else: ""

    [
      "#{num(p["tons"])} tons × 12,000 BTU × 24 hours × #{m.days} days × 85% = #{fmt(limit)} BTU: the most #{part} that it gives in #{m.name}. It gives that.#{rest}"
    ]
  end

  defp limit_steps(_item, _btu, _limit, _m, _part), do: []

  defp share_text(share) when share >= 0.999, do: ""
  defp share_text(share), do: " × #{number_text(share * 100)}% (its share of the house)"

  # A number of a parameter: no decimals for a whole number.
  defp num(number) when is_float(number) and number == trunc(number),
    do: Integer.to_string(trunc(number))

  defp num(number), do: to_string(number)

  defp season_text(%{"season" => season}), do: String.downcase(Catalog.season_label(season))

  @doc """
  A number of a step of the math (kWh, degree days, a share): one decimal
  under 100, so that the step adds up on the page, else no decimals.
  """
  def number_text(number) when abs(number) < 99.95,
    do: :erlang.float_to_binary(number / 1, decimals: 1)

  def number_text(number), do: fmt(number)

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
