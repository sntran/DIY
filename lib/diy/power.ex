defmodule DIY.Power do
  @moduledoc """
  The power equipment of a house (power stations, solar panels, an
  interlock or a transfer switch, electric cars), and the what-if: the
  house of today next to the house with the planned items.

  ## The day of a month

  For each month, the app runs an average day, hour by hour
  (`DIY.Profile` gives the shape of each item and of the sun):

  1. The sun of the panels on a station goes first to the items that the
     station runs (the items with `backup`), through its outlets.
  2. The battery gives the rest of these items, when the mode lets it:
     never in the mode "backup" (the battery stays full for an outage), in
     the day in the mode "night", and at all hours in the mode "solar". It
     keeps the reserve (a part of the battery for an outage).
  3. The rest of the sun charges the battery. A full battery loses the sun.
  4. The grid charges the battery: in the mode "night" at night, in the
     mode "backup" at all hours (to keep it full), and in the mode "solar"
     only up to the reserve.
  5. The grid gives the rest: the other items, the items of the station
     that the station does not give, and the charge of the battery. The
     panels on the grid (a grid-tie inverter) give power to the house
     first, and the rest goes to the grid.

  The day starts with the charge that the day gives back at its end (an
  average day of many days in a row). The charge at the end of a day
  grows with the charge at its start, but never by more, so the app finds
  that charge by bisection.

  The numbers of the model, and their sources:

  - A station uses 95% of its battery, and gives 92% of the power of its
    battery at its outlets: 87% of the label. Tests of stations at a
    large load get 87.5% (The Solar Lab, Jackery Explorer 1000 v2) and
    89% on average (PCWorld).
  - A station stores 92% of the power that goes into it. This is a simple
    model of the app: the same loss as the output.
  - Panels give 80% of their watts in full sun. PVWatts of NREL counts 14%
    of losses (the dust, the wires, the shade and more) and an inverter
    of 96%: 83%. The app takes a little less for the heat of Texas.
  - The direction of the panels changes the sun of a flat surface (NASA
    POWER): south 110% (EIA, with PVWatts: a south roof at 20° gives 11%
    more than a flat one), south-east or south-west 105% (5% less than
    south, CAFS), east or west 95% (85% to 92% of south: CAFS, and a
    study of the UK at 22°).

  The stations of a house work as one: their batteries, their outputs and
  their inputs add up. The sun above the solar input of the stations is
  lost.

  ## An outage

  In an outage, the station runs its items from the charge of its battery
  at 18:00 of an average day, with the sun of the next days (at most 7
  days).
  """

  alias DIY.{Bill, Build, Estimate, Profile}

  @modes [
    {"backup", "Keep the batteries full for an outage"},
    {"night", "Charge at night, and use the batteries in the day"},
    {"solar", "Charge with the sun, and use the batteries at all hours"}
  ]
  @mode_keys Enum.map(@modes, &elem(&1, 0))

  @charge 0.92
  @discharge 0.92
  @usable 0.95
  @derate 0.8
  @facing %{"south" => 1.1, "southeast" => 1.05, "east" => 0.95, "flat" => 1.0}
  @outage_hours 7 * 24

  @doc "The part of the label of a station that its battery gives (95%)."
  def usable, do: @usable

  @doc "The part of the watts of a panel in full sun (80%)."
  def derate, do: @derate

  # The years that a planned item lasts, for the payback. A battery of
  # LiFePO4: 3,000 cycles to 80% of its charge (a common label of the
  # stations), near 8 years of one cycle each day. A panel: 25 to 35 years
  # (a survey of Berkeley Lab, in the plan of DOE for the end of life of
  # the panels). The app takes the low end.
  @life %{"power_station" => 8, "solar_panels" => 25}

  # The planned items with a price in the app: the payback is for them.
  @priced ~w(power_station solar_panels transfer_switch)

  @type settings :: %{
          mode: String.t(),
          night_cents: float() | nil,
          night_from: 0..23,
          night_to: 0..23,
          buyback_cents: float(),
          reserve: 0..100
        }

  @doc """
  The default settings of the power of a house:

  - `mode`: how the stations use their batteries (`modes/0`).
  - `night_cents`: the price of one kWh at night, or `nil` for one price at
    all hours.
  - `night_from` and `night_to`: the hours of the night (from 22:00 to
    6:00).
  - `buyback_cents`: the price that the plan pays for one kWh to the grid.
  - `reserve`: the part of the batteries (%) that the modes "night" and
    "solar" keep for an outage.
  """
  @spec settings() :: settings()
  def settings,
    do: %{
      mode: "backup",
      night_cents: nil,
      night_from: 22,
      night_to: 6,
      buyback_cents: 0.0,
      reserve: 20
    }

  @doc "The modes of the stations, with their names."
  def modes, do: @modes

  @doc "The settings as a map for JSON."
  def to_map(settings), do: Map.new(settings, fn {key, value} -> {Atom.to_string(key), value} end)

  @doc "Reads the settings from a stored build. It accepts only valid settings."
  @spec read(term()) :: {:ok, settings()} | :error
  def read(%{} = map) do
    with {:ok, mode} <- mode(map["mode"]),
         {:ok, night_cents} <- cents(map["night_cents"], true),
         {:ok, night_from} <- hour(map["night_from"]),
         {:ok, night_to} <- hour(map["night_to"]),
         {:ok, buyback} <- cents(map["buyback_cents"], false),
         {:ok, reserve} <- reserve(map["reserve"]) do
      {:ok,
       %{
         mode: mode,
         night_cents: night_cents,
         night_from: night_from,
         night_to: night_to,
         buyback_cents: buyback,
         reserve: reserve
       }}
    end
  end

  def read(_map), do: :error

  defp mode(mode) when mode in @mode_keys, do: {:ok, mode}
  defp mode(_mode), do: :error

  defp cents(nil, true), do: {:ok, nil}

  defp cents(cents, _nil?) when is_number(cents) and cents >= 0 and cents <= 200,
    do: {:ok, cents / 1}

  defp cents(_cents, _nil?), do: :error

  defp hour(hour) when is_integer(hour) and hour in 0..23, do: {:ok, hour}
  defp hour(_hour), do: :error

  defp reserve(reserve) when is_integer(reserve) and reserve in 0..100, do: {:ok, reserve}
  defp reserve(_reserve), do: :error

  @doc """
  Changes the settings with the text of a form. An empty price of the
  night is one price at all hours. The night must have one hour or more.
  The error names the field (`:night` for a night with no hours).
  """
  @spec update(settings(), map()) :: {:ok, settings()} | {:error, atom()}
  def update(settings, form) do
    with {:ok, mode} <- field(form, "mode", settings.mode, &mode/1, :mode),
         {:ok, night_cents} <- night(form["night_cents"], settings.night_cents),
         {:ok, night_from} <-
           field(form, "night_from", settings.night_from, &hour_text/1, :night_from),
         {:ok, night_to} <- field(form, "night_to", settings.night_to, &hour_text/1, :night_to),
         {:ok, buyback} <-
           field(form, "buyback_cents", settings.buyback_cents, &cents_text/1, :buyback_cents),
         {:ok, reserve} <- field(form, "reserve", settings.reserve, &reserve_text/1, :reserve),
         true <- night_from != night_to || {:error, :night} do
      {:ok,
       %{
         mode: mode,
         night_cents: night_cents,
         night_from: night_from,
         night_to: night_to,
         buyback_cents: buyback,
         reserve: reserve
       }}
    end
  end

  defp field(form, key, old, read, error) do
    case Map.fetch(form, key) do
      :error -> {:ok, old}
      {:ok, value} -> with(:error <- read.(value), do: {:error, error})
    end
  end

  defp night(nil, old), do: {:ok, old}

  defp night(text, _old) when is_binary(text) do
    if String.trim(text) == "",
      do: {:ok, nil},
      else: with(:error <- cents_text(text), do: {:error, :night_cents})
  end

  defp night(_value, _old), do: {:error, :night_cents}

  defp hour_text(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {hour, ""} -> hour(hour)
      _ -> :error
    end
  end

  defp hour_text(_text), do: :error

  defp cents_text(text) when is_binary(text) do
    case Float.parse(String.trim(text)) do
      {cents, ""} -> cents(cents, false)
      _ -> :error
    end
  end

  defp cents_text(_text), do: :error

  defp reserve_text(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {reserve, ""} -> reserve(reserve)
      _ -> :error
    end
  end

  defp reserve_text(_text), do: :error

  @doc "True when an hour is in the night of the settings."
  def night?(%{night_from: from, night_to: to}, hour) when from > to,
    do: hour >= from or hour < to

  def night?(%{night_from: from, night_to: to}, hour), do: hour >= from and hour < to

  @doc """
  The power equipment of a list of items: the stations as one (their
  batteries, outputs and inputs add up), the panels on the stations and on
  the grid (in watts, with their direction), the interlock or transfer
  switch, and the items that the stations run.
  """
  def system(items) do
    stations = Enum.filter(items, &(&1.type == "power_station"))
    panels = Enum.filter(items, &(&1.type == "solar_panels"))
    cars = Enum.filter(items, &(&1.type == "ev"))

    %{
      stations: stations,
      kwh: sum(stations, &(&1.params["kwh"] + &1.params["extra_kwh"])),
      output_w: sum(stations, & &1.params["output_w"]),
      charge_w: sum(stations, & &1.params["charge_w"]),
      solar_in_w: sum(stations, & &1.params["solar_w"]),
      station_panels_w: sum(Enum.filter(panels, &(&1.params["to"] == "station")), &panel_w/1),
      grid_panels_w: sum(Enum.filter(panels, &(&1.params["to"] == "grid")), &panel_w/1),
      switch: Enum.find(items, &(&1.type == "transfer_switch")),
      chargers: Enum.filter(cars, &(&1.params["charger"] == "l2")),
      backup: if(stations == [], do: [], else: Enum.filter(items, & &1.backup))
    }
  end

  # The watts of panels in full sun, with their direction.
  defp panel_w(%{params: p}), do: p["watts"] * Map.fetch!(@facing, p["facing"])

  defp sum(list, fun), do: list |> Enum.map(fun) |> Enum.sum() |> Kernel./(1)

  @doc """
  The power of a build from the grid in each month, for the house only
  (`DIY.Build.house_view/1`): the estimate of its use (`DIY.Estimate.run/2`
  of the same items), the equipment, the settings of `build.power`, and
  the price of the day (`cents`).
  """
  def run(%Build{} = build, %{ready: true} = estimate, climate, cents) do
    build = Build.house_view(build)
    settings = build.power
    sys = system(build.items)
    night_cents = settings.night_cents || cents

    months =
      for m <- estimate.months do
        sun = (climate.months[m.month].sun || 0.0) * @derate
        shape = Profile.sun(climate.lat, m.month)
        loads = loads(build.items, m, settings)
        {backup, house} = Enum.split_with(loads, fn {item, _} -> item in sys.backup end)
        need = add_hours(backup)
        other = add_hours(house)

        # The sun of the panels on the stations, and the part of it that
        # the solar input of the stations takes.
        pv_panels = for s <- shape, do: s * sun * sys.station_panels_w / 1_000
        pv_station = for pv <- pv_panels, do: min(pv, sys.solar_in_w / 1_000)
        cut = Enum.sum(pv_panels) - Enum.sum(pv_station)
        pv_grid = for s <- shape, do: s * sun * sys.grid_panels_w / 1_000

        day =
          day(
            %{need: need, other: other, pv_station: pv_station, pv_grid: pv_grid},
            sys,
            settings
          )

        times = fn value -> value * m.days end

        cost =
          (day.day * cents + day.night * night_cents - day.export * settings.buyback_cents) / 100

        %{
          month: m.month,
          name: m.name,
          days: m.days,
          use: times.(Enum.sum(need) + Enum.sum(other)),
          backup: times.(Enum.sum(need)),
          grid: times.(day.day + day.night),
          day: times.(day.day),
          night: times.(day.night),
          export: times.(day.export),
          sun: times.(Enum.sum(pv_panels) + Enum.sum(pv_grid)),
          lost: times.(day.lost + cut),
          cost: times.(cost),
          price: price(day.day, day.night, cents, night_cents),
          outage: outage(need, pv_station, sys, Enum.at(day.soc, 17))
        }
      end

    year =
      Map.new(
        [:use, :backup, :grid, :day, :night, :export, :sun, :lost, :cost],
        &{&1, Enum.sum(Enum.map(months, fn m -> Map.fetch!(m, &1) end))}
      )

    %{
      months: months,
      year: Map.put(year, :price, price(year.day, year.night, cents, night_cents)),
      system: sys,
      settings: settings,
      watts: sys.backup |> Enum.map(&Profile.watts/1) |> Enum.sum(),
      motors: Enum.filter(sys.backup, &Profile.motor?/1)
    }
  end

  # The mean price of one kWh from the grid, with the hours of the day and
  # of the night.
  defp price(day, night, cents, night_cents) when day + night > 0,
    do: (day * cents + night * night_cents) / (day + night)

  defp price(_day, _night, cents, _night_cents), do: cents / 1

  # The kWh of each item in each hour of an average day of a month.
  defp loads(items, m, settings) do
    for item <- items, data = m.items[item.id], data do
      kwh_day = data.kwh / m.days

      {item,
       Enum.map(Profile.shape(item, data.part, kwh_day, settings.night_from), &(&1 * kwh_day))}
    end
  end

  defp add_hours(loads) do
    Enum.reduce(loads, List.duplicate(0.0, 24), fn {_item, hours}, acc ->
      Enum.zip_with(acc, hours, &+/2)
    end)
  end

  @doc false
  # An average day: it starts with the charge that it gives back at its
  # end (`start`). `soc` has the charge at the end of each hour. The input
  # has a list of 24 values for each part.
  def day(input, sys, settings) do
    input = Map.new(input, fn {key, hours} -> {key, List.to_tuple(hours)} end)
    start = steady(&(end_charge(input, sys, settings, &1) - &1), 0.0, sys.kwh * @usable)
    input |> run_day(sys, settings, start) |> elem(1) |> Map.put(:start, start)
  end

  # The charge at the end of a day, for the bisection: no sums.
  defp end_charge(input, sys, settings, start) do
    Enum.reduce(Profile.hours(), start, fn h, soc ->
      elem(hour(h, soc, input, sys, settings), 0)
    end)
  end

  # The charge where the change of one day is zero. The change gets
  # smaller (or stays the same) when the start gets higher, so a
  # bisection finds it.
  defp steady(change, low, high) do
    cond do
      change.(high) >= -1.0e-9 -> high
      change.(low) <= 1.0e-9 -> low
      # 40 steps: the largest battery (300 kWh) ÷ 2^40 is under 1e-9 kWh.
      true -> bisect(change, low, high, 40)
    end
  end

  defp bisect(_change, low, high, 0), do: (low + high) / 2

  defp bisect(change, low, high, steps) do
    middle = (low + high) / 2

    if change.(middle) > 0,
      do: bisect(change, middle, high, steps - 1),
      else: bisect(change, low, middle, steps - 1)
  end

  defp run_day(input, sys, settings, start) do
    Enum.reduce(
      Profile.hours(),
      {start, %{day: 0.0, night: 0.0, export: 0.0, lost: 0.0, soc: []}},
      fn h, {soc, acc} ->
        {soc, hour} = hour(h, soc, input, sys, settings)
        night = night?(settings, h)

        {soc,
         %{
           acc
           | day: acc.day + if(night, do: 0.0, else: hour.grid),
             night: acc.night + if(night, do: hour.grid, else: 0.0),
             export: acc.export + hour.export,
             lost: acc.lost + hour.lost,
             soc: [soc | acc.soc]
         }}
      end
    )
    |> then(fn {soc, result} -> {soc, %{result | soc: Enum.reverse(result.soc)}} end)
  end

  # One hour: the sun, the battery and the grid (see the module doc).
  defp hour(h, soc, input, sys, settings) do
    capacity = sys.kwh * @usable
    floor = if settings.mode == "backup", do: capacity, else: capacity * settings.reserve / 100
    output = sys.output_w / 1_000
    need = elem(input.need, h)
    pv = elem(input.pv_station, h)

    # 1. The sun to the items of the station, through its outlets.
    from_sun = Enum.min([need, pv * @discharge, output])
    pv_left = pv - from_sun / @discharge
    need = need - from_sun

    # 2. The battery to the rest of these items.
    from_battery =
      if use_battery?(settings, h),
        do: Enum.min([need, output - from_sun, max(soc - floor, 0) * @discharge]),
        else: 0.0

    soc = soc - from_battery / @discharge
    need = need - from_battery

    # 3. The rest of the sun to the battery.
    sun_in = min(pv_left * @charge, capacity - soc)
    soc = soc + sun_in
    lost = pv_left - sun_in / @charge

    # 4. The grid to the battery.
    top = if settings.mode == "solar", do: floor, else: capacity

    grid_in =
      if charge_from_grid?(settings, h),
        do: min(sys.charge_w / 1_000, max(top - soc, 0) / @charge),
        else: 0.0

    soc = soc + grid_in * @charge

    # 5. The grid gives the rest, and the panels on the grid give first.
    grid = elem(input.other, h) + need + grid_in - elem(input.pv_grid, h)
    {soc, %{grid: max(grid, 0.0), export: max(-grid, 0.0), lost: lost}}
  end

  defp use_battery?(%{mode: "backup"}, _h), do: false
  defp use_battery?(%{mode: "night"} = settings, h), do: not night?(settings, h)
  defp use_battery?(%{mode: "solar"}, _h), do: true

  defp charge_from_grid?(%{mode: "night"} = settings, h), do: night?(settings, h)
  defp charge_from_grid?(_settings, _h), do: true

  @doc false
  # The hours that the stations run their items in an outage of a month:
  # from the charge of the battery at 18:00, with the sun of the next days.
  # `:days` when they run more than 7 days, and `nil` with no use on the
  # stations in the month.
  def outage(need, pv, sys, soc) do
    if Enum.sum(need) <= 0 or sys.kwh <= 0,
      do: nil,
      else: outage(need, pv, sys, min(soc, sys.kwh * @usable), 18, 0)
  end

  defp outage(_need, _pv, _sys, _soc, _h, hours) when hours >= @outage_hours, do: :days

  defp outage(need, pv, sys, soc, h, hours) do
    capacity = sys.kwh * @usable
    hour = rem(h, 24)
    want = Enum.at(need, hour)
    sun = Enum.at(pv, hour)
    from_sun = min(want, sun * @discharge)
    rest = want - from_sun
    stored = min(soc + (sun - from_sun / @discharge) * @charge, capacity)

    cond do
      rest <= stored * @discharge ->
        outage(need, pv, sys, stored - rest / @discharge, h + 1, hours + 1)

      true ->
        hours + stored * @discharge / rest
    end
  end

  @doc """
  The what-if of a build: the house of today (with no planned item) next
  to the house with the planned items, with the price of the day
  (`cents`). `today` is the power of the house of today (`run/4`), and
  `today_estimate` and `plan_estimate` are the estimates of the two houses
  (`DIY.Estimate.run/2`). It is `nil` with no planned item, or when a
  house has no estimate yet (for example, a house that I plan, with a
  planned AC).

  The result has the power and the bill (with its range, `DIY.Bill`) of
  each house, the planned items, and the warnings of the plan. The payback
  is for the planned equipment with a price (`@priced`): its price, the
  savings of one year (with their range), the years of the payback, and
  the years that the equipment lasts. The other planned items (a car, a
  freezer) have no price in the app: their result is their own
  (`others`), the change of the bill and the gas that a car saves.

  With two parts of equipment or more, `parts` has each part. The planned
  stations, and the panels that charge a station, are one part: they work
  together. Each other item is a part alone. A part has its items, its
  price, the savings that it adds to the plan, and its payback. It also
  has the years that it lasts: the shortest life of its items. So a
  battery of 8 years does not decide the payback of panels of 25 years on
  the grid. The savings that a part adds are the savings of the plan, less
  the savings of the plan with no such part.
  """
  def whatif(%Build{} = build, today, today_estimate, plan_estimate, climate, cents) do
    planned = Enum.filter(build.items, & &1.planned)

    with [_ | _] <- planned,
         %{ready: true} <- today_estimate,
         %{ready: true} <- plan_estimate do
      plan = run(build, plan_estimate, climate, cents)
      {equipment, others} = Enum.split_with(planned, &(&1.type in @priced))

      # The house with the planned equipment and no other planned item:
      # the savings of the equipment.
      {gear, gear_estimate} =
        cond do
          others == [] ->
            {plan, plan_estimate}

          equipment == [] ->
            {today, today_estimate}

          true ->
            gear_build = %{build | items: build.items -- others}
            gear_estimate = Estimate.run(gear_build, climate)
            {run(gear_build, gear_estimate, climate, cents), gear_estimate}
        end

      today_bill = Bill.run(today_estimate, today)
      gear_bill = Bill.run(gear_estimate, gear)
      savings = today.year.cost - gear.year.cost

      ends = [
        today_bill.cost_low - gear_bill.cost_low,
        today_bill.cost_high - gear_bill.cost_high
      ]

      price = equipment |> Enum.map(& &1.params["cost"]) |> Enum.sum()
      parts = parts(equipment, build, others, {gear, gear_estimate}, climate, cents)

      %{
        today: today,
        plan: plan,
        today_bill: today_bill,
        plan_bill: Bill.run(plan_estimate, plan),
        planned: planned,
        equipment: equipment,
        price: price,
        savings: savings,
        savings_low: Enum.min(ends),
        savings_high: Enum.max(ends),
        payback: if(equipment != [] and savings > 0, do: price / savings),
        life:
          equipment
          |> Enum.map(&@life[&1.type])
          |> Enum.reject(&is_nil/1)
          |> Enum.min(fn -> nil end),
        parts: parts,
        others: others(others, plan, gear, build.power, cents),
        warnings: warnings(plan)
      }
    else
      _ -> nil
    end
  end

  # The parts of the planned equipment, when there are two or more. The
  # equipment uses no kWh of the estimate: the estimate of the plan with
  # no other planned item is good for each part.
  defp parts(equipment, build, others, {gear, estimate}, climate, cents) do
    {together, alone} = Enum.split_with(equipment, &together?/1)
    groups = Enum.reject([together | Enum.map(alone, &[&1])], &(&1 == []))

    if length(groups) < 2 do
      []
    else
      for items <- groups do
        without = %{build | items: build.items -- (items ++ others)}
        adds = run(without, estimate, climate, cents).year.cost - gear.year.cost
        cost = items |> Enum.map(& &1.params["cost"]) |> Enum.sum()

        %{
          items: items,
          price: cost,
          savings: adds,
          # Less than 50 cents in one year is no savings.
          payback: if(adds >= 0.5, do: cost / adds),
          life:
            items
            |> Enum.map(&@life[&1.type])
            |> Enum.reject(&is_nil/1)
            |> Enum.min(fn -> nil end)
        }
      end
    end
  end

  # A station, and panels that charge a station, work together.
  defp together?(%{type: "power_station"}), do: true
  defp together?(%{type: "solar_panels", params: %{"to" => "station"}}), do: true
  defp together?(_item), do: false

  # The result of the other planned items: the change of the bill (the
  # bill with them, less the bill without them), and for the cars, the
  # cost of their home charge (`charge_year/3`) and the gas that they save.
  defp others([], _plan, _gear, _settings, _cents), do: nil

  defp others(items, plan, gear, settings, cents) do
    cars = Enum.filter(items, &(&1.type == "ev"))

    %{
      items: items,
      change: plan.year.cost - gear.year.cost,
      gas: cars |> Enum.map(&gas_year/1) |> Enum.sum(),
      charge: cars |> Enum.map(&charge_year(&1, settings, cents).cost) |> Enum.sum()
    }
  end

  @doc "The dollars of gas that a car of the same miles uses in one year."
  def gas_year(%{params: p}), do: p["miles"] * 365 / p["mpg"] * p["gas"]

  @doc """
  The cost of the home charge of a car in one year: its kWh at the price
  of the hours when it charges.
  """
  def charge_year(%{params: p} = item, settings, cents) do
    kwh = p["miles"] * 365 / p["mi_kwh"] / Estimate.charge_efficiency(p["charger"])

    # The part of the charge in the hours of the night, as in the day of a
    # month (DIY.Profile): a long charge goes past the end of the night.
    night =
      item
      |> Profile.shape(:other, kwh / 365, settings.night_from)
      |> Enum.with_index()
      |> Enum.filter(fn {_part, h} -> night?(settings, h) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sum()

    price = night * (settings.night_cents || cents) + (1 - night) * cents
    %{kwh: kwh, cost: kwh * price / 100, hours: Profile.charge_hours(item, kwh / 365)}
  end

  @doc """
  The warnings of the power of a build (`run/4`), for honesty rule 5 and
  the safety of the people who work on the lines of the utility:

  - `:backfeed`: a station that powers circuits of the house with no
    interlock and no transfer switch. Its power can go to the grid, and
    kill a worker on the lines (see `specs/Backfeed.tla`).
  - `:permit`: work that needs a permit in most cities (`permits/1`).
  - `:grid_tie`: panels on a grid-tie inverter, and a station that powers
    the panel. In an outage, the inverter can send its power into the
    output of the station.
  - `:overload`: the items on the stations need more watts than their
    outputs, when they all run at the same time.
  - `:surge`: a motor needs more power to start.
  """
  def warnings(%{system: sys, watts: watts, motors: motors}) do
    panel = panel?(sys)

    [
      (panel and is_nil(sys.switch)) && :backfeed,
      permits(sys) != [] && :permit,
      (panel and sys.grid_panels_w > 0) && :grid_tie,
      (sys.stations != [] and watts > sys.output_w) && :overload,
      motors != [] && :surge
    ]
    |> Enum.filter(& &1)
  end

  @doc """
  The work of a build that needs a permit in most cities: `:panel` (an
  inlet, an interlock, a transfer switch or a subpanel), `:grid_tie`
  (panels on a grid-tie inverter: the utility must also approve them), and
  `:charger` (a Level 2 charger needs a new circuit of 240 V).
  """
  def permits(sys) do
    [
      (panel?(sys) or sys.switch != nil) && :panel,
      sys.grid_panels_w > 0 && :grid_tie,
      sys.chargers != [] && :charger
    ]
    |> Enum.filter(& &1)
  end

  @doc "True when a station powers circuits of the house through an inlet."
  def panel?(sys), do: Enum.any?(sys.stations, &(&1.params["feeds"] == "panel"))
end
