defmodule DIY.EstimateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, Estimate, House, Stubs, Weather}
  alias DIYWeb.{Format, Front}

  # The weather of Plano, Texas, 2016 to 2025 (a real answer of NASA POWER).
  defp climate do
    {:ok, climate} = Weather.parse(Stubs.power(), 33.25, -96.75, 2016, 2025)
    climate
  end

  defp build(house \\ %{}, door \\ "my_house") do
    house = Map.merge(%{size: 2000, year: 2005, floors: 2, heat: "gas", lot: nil}, house)
    {house, rooms, items} = House.preset(house)
    {:ok, build} = Build.choose_door(Build.new(), door)
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id

  defp add(build, room, type, params \\ %{}) do
    {:ok, build, id} = Build.add_item(build, room(build, room), type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  test "the estimate waits for the ZIP code, the house and the weather" do
    assert %{ready: false, missing: [:zip, :house, :weather]} = Estimate.run(Build.new(), nil)
    assert %{ready: false, missing: [:weather]} = Estimate.run(build(), nil)
  end

  test "a house that I plan needs an AC" do
    {house, rooms, []} =
      House.scratch(%{size: 1800, year: 2026, floors: 1, heat: "gas", lot: nil})

    {:ok, plan} = Build.choose_door(Build.new(), "planning")
    {:ok, plan} = Build.set_zip(plan, "75070")
    plan = Build.put_house(plan, house, rooms, [])
    assert %{ready: false, missing: [:ac]} = Estimate.run(plan, climate())

    {plan, _id} = add(plan, "Backyard", "ac")
    assert %{ready: true} = Estimate.run(plan, climate())

    {plan, _id} = add(Build.put_house(plan, house, rooms, []), "Living room", "mini_split")
    assert %{ready: true} = Estimate.run(plan, climate())
  end

  # The check of phase 1: a typical house of the size of a Texas average
  # gives a year near the average of Texas homes (EIA: near 13,500 kWh), and
  # the summer gives the largest bills.
  test "a typical house in Plano gives a plausible year" do
    for {heat, low, high} <- [
          {"gas", 8_000, 14_000},
          {"heat_pump", 12_000, 20_000},
          {"electric", 15_000, 26_000}
        ] do
      estimate = Estimate.run(build(%{heat: heat}), climate())
      assert estimate.kwh > low and estimate.kwh < high, "#{heat}: #{estimate.kwh}"
      august = Enum.at(estimate.months, 7)
      april = Enum.at(estimate.months, 3)
      assert august.kwh > april.kwh
    end
  end

  test "the parts of a month add up, and each item has its year" do
    estimate = Estimate.run(build(), climate())

    for month <- estimate.months do
      assert_in_delta month.cooling + month.heating + month.other, month.kwh, 0.001
    end

    assert_in_delta Enum.sum(Enum.map(estimate.items, fn {_id, item} -> item.year end)),
                    estimate.kwh,
                    0.01

    assert %{first: 2016, last: 2025, lat: 33.25, lon: -96.75, t_year: t_year} = estimate.climate
    assert t_year > 60
    assert estimate.notes == []
  end

  test "an AC that is too small for the house runs all the time, and has a note" do
    build = build()
    ac = Enum.find(build.items, &(&1.type == "ac"))
    {:ok, build} = Build.update_item(build, ac.id, %{"tons" => "1"})
    estimate = Estimate.run(build, climate())
    assert [{id, note}] = estimate.notes
    assert id == ac.id
    assert note =~ "small"
  end

  test "electric heat that is too small runs all the time, and has a note" do
    build = build(%{heat: "electric"})
    strips = Enum.find(build.items, &(&1.type == "heat_strips"))
    {:ok, build} = Build.update_item(build, strips.id, %{"kw" => "1"})
    estimate = Estimate.run(build, climate())
    assert Enum.any?(estimate.notes, fn {id, _note} -> id == strips.id end)
  end

  test "the share of the cooling and the heating" do
    build = build(%{heat: "heat_pump"})

    {build, split} =
      add(build, "Bedroom 1", "mini_split", %{"area" => "500", "heat_pump" => "true"})

    ac = Enum.find(build.items, &(&1.type == "ac"))
    cooling = Estimate.cooling_split(build.items, 2000)
    heating = Estimate.heating_split(build.items, 2000)
    assert cooling[split] == 0.25 and cooling[ac.id] == 0.75
    assert heating[split] == 0.25 and heating[ac.id] == 0.75

    # Two central ACs share the rest by their size.
    {build, second} = add(build, "Backyard", "ac", %{"tons" => "1.5"})
    cooling = Estimate.cooling_split(build.items, 2000)
    assert_in_delta cooling[ac.id] + cooling[second], 0.75, 0.0001
    assert cooling[ac.id] > cooling[second]

    # A mini split that is larger than the house cools all of it.
    {build, big} = add(build(), "Bedroom 1", "mini_split", %{"area" => "3000"})
    assert Estimate.cooling_split(build.items, 2000)[big] == 1.0
  end

  test "a heat pump comes before a furnace, and a furnace before electric heat" do
    build = build()
    {build, strips} = add(build, "Attic", "heat_strips")
    furnace = Enum.find(build.items, &(&1.type == "furnace"))
    heating = Estimate.heating_split(build.items, 2000)
    assert heating[furnace.id] == 1.0
    refute Map.has_key?(heating, strips)
  end

  ## The arithmetic of a step of the math

  # The page rounds its numbers. So the test reads each number as the range
  # of the values that it can show: a number with a decimal is within half
  # of its last decimal, an integer of 100 or more within 0.5, and a
  # smaller integer is exact (24 hours, 31 days, 7 days). The arithmetic of
  # these ranges gives the range of a step.
  defp evaluate(text) do
    tokens =
      ~r/(?<![\p{L}\d.,])\d[\d,]*(?:\.\d+)?%?|[×÷+−()]/u
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.map(&token/1)
      |> drop_empty()

    {range, rest} = sum(tokens)
    assert rest == [], text
    range
  end

  defp token(op) when op in ["×", "÷", "+", "−", "(", ")"], do: op

  defp token(text) do
    {low, high} = range(String.trim_trailing(text, "%"))
    if String.ends_with?(text, "%"), do: {low / 100, high / 100}, else: {low, high}
  end

  # The values that a number of the page can be.
  defp range(text) do
    {value, ""} = text |> String.replace(",", "") |> Float.parse()

    half =
      case String.split(text, ".") do
        [_, decimals] -> 0.5 / 10 ** String.length(decimals)
        [_] when value >= 100 -> 0.5
        [_] -> 0.0
      end

    {value - half, value + half}
  end

  defp drop_empty(tokens) do
    case Enum.chunk_every(tokens, 2, 1) |> Enum.find_index(&(&1 == ["(", ")"])) do
      nil -> tokens
      i -> tokens |> List.delete_at(i) |> List.delete_at(i) |> drop_empty()
    end
  end

  defp sum(tokens) do
    {value, rest} = product(tokens)
    sum_rest(value, rest)
  end

  defp sum_rest({a, b}, ["+" | rest]) do
    {{c, d}, rest} = product(rest)
    sum_rest({a + c, b + d}, rest)
  end

  defp sum_rest({a, b}, ["−" | rest]) do
    {{c, d}, rest} = product(rest)
    sum_rest({a - d, b - c}, rest)
  end

  defp sum_rest(value, rest), do: {value, rest}

  defp product(tokens) do
    {value, rest} = factor(tokens)
    product_rest(value, rest)
  end

  defp product_rest({a, b}, ["×" | rest]) do
    {{c, d}, rest} = factor(rest)
    product_rest(Enum.min_max([a * c, a * d, b * c, b * d]), rest)
  end

  defp product_rest({a, b}, ["÷" | rest]) do
    {{c, d}, rest} = factor(rest)
    product_rest(Enum.min_max([a / c, a / d, b / c, b / d]), rest)
  end

  defp product_rest(value, rest), do: {value, rest}

  defp factor(["(" | rest]) do
    {value, [")" | rest]} = sum(rest)
    {value, rest}
  end

  defp factor([{_low, _high} = range | rest]), do: {range, rest}
  # A text with no number: 0 (for example, "The fans are off in January.").
  defp factor([]), do: {{0.0, 0.0}, []}

  # The range of the number after "=" in a step, and the word after it.
  defp result(line) do
    case Regex.run(~r/= ([\d,]+(?:\.\d+)?) (\p{L}+)/u, line) do
      [_, number, unit] -> {range(number), unit}
      nil -> nil
    end
  end

  # Two ranges have a value in common. The left side can be 1% off: the
  # page rounds the UA, which can be under 100.
  defp meet?({a, b}, {c, d}), do: a * 0.99 <= d and c <= b * 1.01

  # The checks of the math of one item in one month:
  #
  # - Each step with "=" gives a value of its left side.
  # - The last step gives the kWh of the item.
  # - The kWh of the last step come from the steps before it: the last kWh
  #   that a step gives, or the kWh of cooling and of heat, or the value of
  #   the step before it (an item with no "=").
  defp check_math(lines, kwh, label) do
    for line <- lines, String.contains?(line, "=") do
      [left | _] = String.split(line, "=")
      {right, _unit} = result(line)
      assert meet?(evaluate(left), right), "#{label}: #{line}"
    end

    {steps, [last]} = Enum.split(lines, -1)
    {final, "kWh"} = result(last) || {last_range(last), "kWh"}
    assert meet?(final, {kwh, kwh}), "#{label}: #{last} (#{kwh})"

    results = for line <- steps, r = result(line), r, do: r

    cond do
      String.contains?(last, "kWh of cooling +") ->
        for [_, number] <- Regex.scan(~r/([\d,.]+) kWh of (?:cooling|heat)/, last) do
          assert Enum.any?(results, fn {r, _} -> meet?(r, range(number)) end), label
        end

      Enum.any?(results, &(elem(&1, 1) == "kWh")) ->
        {r, "kWh"} = results |> Enum.filter(&(elem(&1, 1) == "kWh")) |> List.last()
        assert meet?(r, final), "#{label}: #{inspect(lines)}"

      true ->
        assert meet?(evaluate(List.last(steps)), final), "#{label}: #{inspect(lines)}"
    end
  end

  defp last_range(line) do
    [number | _] = ~r/[\d,]*\.?\d+/ |> Regex.scan(line) |> List.flatten() |> Enum.reverse()
    range(number)
  end

  test "the arithmetic of the math of the tests" do
    {low, high} = evaluate("2 × (12 °F − 6.4 °F) × 30 days ÷ 10 (May to September)")
    assert_in_delta low, 33.3, 1.0e-9
    assert_in_delta high, 33.9, 1.0e-9

    assert evaluate("1 + 2 × 3 − 4 ÷ 2 × 45%") == {6.1, 6.1}
    assert evaluate("90 ÷ (9.5 SEER2 × 10)") == {90 / 95.5, 90 / 94.5}
    assert evaluate("2.5 × 2") == {4.9, 5.1}
    assert evaluate("It is off in January.") == {0.0, 0.0}
    assert result("a = 1,234.5 kWh of heat.") == {{1234.45, 1234.55}, "kWh"}
    assert result("no result") == nil
  end

  test "the explanation of each item gives its kWh in each month" do
    build =
      Enum.reduce(DIY.Kinds.house(), build(), fn kind, build ->
        room = Enum.find(build.rooms, &Catalog.fits?(kind, &1))
        {:ok, build, _id} = Build.add_item(build, room.id, kind.type)
        build
      end)

    {build, _id} = add(build, "Garage", "water_heater", %{"fuel" => "heat_pump"})
    {build, _id} = add(build, "Garage", "water_heater", %{"fuel" => "electric"})
    {build, _id} = add(build, "Kitchen", "range", %{"fuel" => "gas"})
    {build, _id} = add(build, "Kitchen", "range", %{"fuel" => "electric"})
    {build, _id} = add(build, "Laundry", "dryer", %{"fuel" => "gas"})
    {build, _id} = add(build, "Laundry", "dryer", %{"fuel" => "electric"})
    {build, _id} = add(build, "Laundry", "washer_dryer", %{"dry" => "heater"})
    {build, _id} = add(build, "Backyard", "ac", %{"heat_pump" => "true", "tons" => "1"})

    {build, _id} =
      add(build, "Bedroom 2", "mini_split", %{"area" => "100", "heat_pump" => "true"})

    {build, _id} = add(build, "Backyard", "pool_pump", %{"season" => "summer"})
    {build, _id} = add(build, "Living room", "ceiling_fan", %{"season" => "summer"})
    {build, _id} = add(build, "Living room", "ceiling_fan", %{"season" => "all"})
    {build, _id} = add(build, "Driveway", "ev", %{"charger" => "l1", "miles" => "45"})
    {build, _id} = add(build, "Garage", "fridge", %{"kwh_year" => "600"})
    {build, _id} = add(build, "Garage", "freezer", %{"kwh_year" => "400"})
    estimate = Estimate.run(build, climate())
    check_all(build, estimate)

    # A house with no heat pump: the furnace heats, and burns gas.
    plain = build()
    plain_estimate = Estimate.run(plain, climate())
    furnace = Enum.find(plain.items, &(&1.type == "furnace"))
    assert hd(plain_estimate.months).items[furnace.id].therms > 50
    check_all(plain, plain_estimate)

    ac = Enum.find(build.items, &(&1.type == "ac" and &1.params["heat_pump"]))
    assert Enum.any?(Estimate.explain(ac, 7, estimate), &(&1 =~ "% (its share of the house)"))
    assert Enum.any?(Estimate.explain(ac, 1, estimate), &(&1 =~ "60% of"))
    fan = Enum.find(build.items, &(&1.type == "ceiling_fan" and &1.params["season"] == "summer"))
    assert Enum.any?(Estimate.explain(fan, 1, estimate), &(&1 =~ "The fans are off in January"))
    pump = Enum.find(build.items, &(&1.type == "pool_pump"))
    assert Enum.any?(Estimate.explain(pump, 1, estimate), &(&1 =~ "It is off in January"))
    strips = Enum.find(build.items, &(&1.type == "heat_strips"))
    assert Enum.any?(Estimate.explain(strips, 7, estimate), &(&1 =~ "The house has other heat"))
  end

  # The checks of the math of each item of a build in each month.
  defp check_all(build, estimate) do
    for item <- build.items, month <- 1..12 do
      lines = Estimate.explain(item, month, estimate)
      assert Enum.all?(lines, &is_binary/1)
      m = Enum.at(estimate.months, month - 1)
      kwh = m.items[item.id].kwh
      assert List.last(lines) =~ "#{Estimate.number_text(kwh)} kWh in #{m.name}."
      check_math(lines, kwh, "#{item.type} in #{m.name}")

      # A gas item gives its therms in a step.
      therms = m.items[item.id].therms

      if therms > 0,
        do: assert(Enum.any?(lines, &(&1 =~ "= #{Estimate.number_text(therms)} therms")))
    end
  end

  test "a gas furnace, a gas water heater, a gas stove and a gas dryer burn gas, with a range" do
    {build, dryer} = add(build(), "Laundry", "dryer", %{"fuel" => "gas", "loads" => "5"})
    estimate = Estimate.run(build, climate())
    [january, july] = [hd(estimate.months), Enum.at(estimate.months, 6)]
    of = fn type -> Enum.find(build.items, &(&1.type == type)).id end

    furnace = january.items[of.("furnace")]
    assert_in_delta furnace.therms, furnace.heat_btu / 0.8 / 100_000, 1.0e-9
    assert july.items[of.("furnace")].therms < furnace.therms
    assert_in_delta january.items[of.("range")].therms, 0.055 * 31, 1.0e-9
    assert_in_delta january.items[dryer].therms, 5 * 31 / 7 * 0.073, 1.0e-9
    # The water comes in colder in January.
    assert january.items[of.("water_heater")].therms > july.items[of.("water_heater")].therms
    assert january.items[of.("fridge")].therms == 0.0

    # The sums: each month, the year, and each item in the year.
    for m <- estimate.months do
      assert_in_delta m.therms,
                      m.items |> Map.values() |> Enum.map(& &1.therms) |> Enum.sum(),
                      1.0e-9

      assert m.therms_low <= m.therms and m.therms <= m.therms_high
    end

    assert_in_delta estimate.therms,
                    estimate.months |> Enum.map(& &1.therms) |> Enum.sum(),
                    1.0e-6

    assert_in_delta estimate.items[dryer].therms,
                    estimate.months |> Enum.map(& &1.items[dryer].therms) |> Enum.sum(),
                    1.0e-9

    assert estimate.therms_low < estimate.therms and estimate.therms < estimate.therms_high
    assert estimate.items[of.("fridge")].therms == 0.0

    # A house with no gas item burns no gas.
    electric = build(%{heat: "electric"})
    estimate = Estimate.run(electric, climate())
    assert {estimate.therms, estimate.therms_low, estimate.therms_high} == {0.0, 0.0, 0.0}

    # A gas stove alone: the weather does not change it. So its range is
    # only the part of the model: 10% for an item that the user checked.
    stove = Enum.find(electric.items, &(&1.type == "range"))
    {:ok, electric} = Build.update_item(electric, stove.id, %{"fuel" => "gas"})
    refute Enum.find(electric.items, &(&1.type == "range")).typical
    estimate = Estimate.run(electric, climate())
    assert_in_delta estimate.therms, 0.055 * 365, 1.0e-9
    assert_in_delta estimate.therms_low, 0.9 * estimate.therms, 1.0e-9
    assert_in_delta estimate.therms_high, 1.1 * estimate.therms, 1.0e-9
  end

  test "a heat pump gives at most its size, and the heat strips give the rest" do
    {house, rooms, items} =
      House.preset(%{size: 3500, year: 1970, floors: 1, heat: "heat_pump", lot: nil})

    {:ok, build} = Build.set_zip(Build.new(), "75070")
    build = Build.put_house(build, house, rooms, items)
    ac = Enum.find(build.items, &(&1.type == "ac"))
    {:ok, build} = Build.update_item(build, ac.id, %{"tons" => "1"})
    ac = Enum.find(build.items, &(&1.id == ac.id))
    alone = Estimate.run(build, climate())
    data = hd(alone.months).items[ac.id]
    limit = Estimate.capacity(ac, 31)

    # Alone, it runs all the time, and the house is cold.
    assert data.heat_btu > limit
    assert_in_delta data.kwh, limit / (ac.params["hspf2"] * 1_000), 0.01
    assert Enum.any?(alone.notes, &match?({_, "Central AC is small" <> _}, &1))
    assert Enum.any?(Estimate.explain(ac, 1, alone), &(&1 =~ "the most heat that it gives"))

    # With heat strips, the strips give the rest.
    {build, strips} = add(build, "Attic", "heat_strips", %{"kw" => "30"})
    both = Estimate.run(build, climate())
    rest = hd(both.months).items[strips]
    assert_in_delta rest.heat_btu, data.heat_btu - limit, 1
    assert_in_delta rest.kwh, (data.heat_btu - limit) / 3_412, 0.01
    strips = Enum.find(build.items, &(&1.id == strips))
    assert Enum.any?(Estimate.explain(strips, 1, both), &(&1 =~ "The heat pump cannot give"))

    # Small heat strips give at most their size.
    {:ok, build} = Build.update_item(build, strips.id, %{"kw" => "1"})
    strips = Enum.find(build.items, &(&1.id == strips.id))
    small = Estimate.run(build, climate())
    assert Enum.any?(Estimate.explain(strips, 1, small), &(&1 =~ "1 kW × 3,412"))
  end

  test "an AC that is too small for July gives at most its size" do
    build = build(%{size: 4000, year: 1970, floors: 1})
    ac = Enum.find(build.items, &(&1.type == "ac"))
    {:ok, build} = Build.update_item(build, ac.id, %{"tons" => "1"})
    ac = Enum.find(build.items, &(&1.id == ac.id))
    estimate = Estimate.run(build, climate())
    assert Enum.any?(Estimate.explain(ac, 7, estimate), &(&1 =~ "the most cooling that it gives"))
  end

  test "a fridge or a freezer around the house uses more in the heat, and its label in the cold" do
    climate = climate()

    {build, garage} =
      add(build(), "Garage", "fridge", %{"kwh_year" => "500"})

    {build, freezer} = add(build, "Garage", "freezer", %{"kwh_year" => "300"})
    {build, kitchen} = add(build, "Kitchen", "fridge", %{"kwh_year" => "500"})

    # A room that the user adds around the house: the level decides, not
    # the name.
    {:ok, build, shed} = Build.add_room(build, "Workshop", "outside", :indoor)
    {:ok, build, shed_fridge} = Build.add_item(build, shed, "fridge")
    estimate = Estimate.run(build, climate)
    month = fn m, id -> Enum.at(estimate.months, m - 1).items[id].kwh end

    # In the kitchen: the label, in each month.
    assert_in_delta month.(7, kitchen), 500 * 31 / 365, 1.0e-9

    # In the garage: the mean air outside of July, against 72 °F.
    t = climate.months[7].t
    assert_in_delta month.(7, garage), 500 * 31 / 365 * (t - 39) / (72 - 39), 1.0e-9
    assert month.(7, garage) > month.(7, kitchen)
    assert_in_delta month.(7, freezer), 300 * 31 / 365 * t / 72, 1.0e-9
    assert month.(7, shed_fridge) > month.(7, kitchen) * 1.3
    # In January: the label, not less.
    assert_in_delta month.(1, garage), month.(1, kitchen), 1.0e-9
    assert estimate.items[garage].year > estimate.items[kitchen].year

    # The math tells it.
    item = fn id -> elem(Build.item(build, id), 1) end
    [label, air, heat, _all] = Estimate.explain(item.(garage), 7, estimate)
    assert label =~ "= 42.5 kWh: the label, for a kitchen near 72 °F."

    assert air ==
             "Around the house, the app uses the mean air outside: #{Estimate.number_text(t)} °F in July."

    assert heat =~
             "42.5 kWh × (#{Estimate.number_text(t)} °F − 39 °F in the fridge) ÷ (72 °F − 39 °F) ="

    [cold, _days, _all] = Estimate.explain(item.(garage), 1, estimate)
    assert cold =~ "It is not hotter than a kitchen: the app uses the label."
    assert length(Estimate.explain(item.(kitchen), 7, estimate)) == 2
    assert Estimate.air_factor("freezer", %{around: false, t: 100.0}) == 1.0
  end

  property "around the house, a warmer month never lowers a fridge, and it never goes under its label" do
    check all(
            type <- member_of(["fridge", "freezer"]),
            a <- float(min: -40.0, max: 120.0),
            b <- float(min: -40.0, max: 120.0)
          ) do
      [cold, warm] = Enum.sort([a, b])
      low = Estimate.air_factor(type, %{around: true, t: cold})
      assert low >= 1.0
      assert Estimate.air_factor(type, %{around: true, t: warm}) >= low
    end
  end

  test "a real bill fits the model: the estimate of its month is the bill" do
    climate = climate()
    plain = Estimate.run(build(), climate)
    july = Enum.at(plain.months, 6).kwh
    assert plain.fit == nil

    fit = fn build, month, kwh ->
      {:ok, build} = Build.set_bill(build, %{month: month, kwh: kwh})
      Estimate.run(build, climate)
    end

    # A bill under the model: a factor under 1, and the estimate of July is
    # the bill. The other months change with the same factor.
    low = fit.(build(), 7, july * 0.7)
    assert low.fit.factor < 1 and low.fit.result == :fit
    assert low.fit.before == july
    assert_in_delta Enum.at(low.months, 6).kwh, july * 0.7, july * 0.005
    assert Enum.at(low.months, 7).kwh < Enum.at(plain.months, 7).kwh
    assert_in_delta low.ua.ua, plain.ua.ua * low.fit.factor, 1.0e-6

    assert Front.fit_text(low) ==
             "The app changed its model to fit your bill of July: #{Format.kwh(july * 0.7)}. Before, the estimate of July was #{Format.kwh(july)}."

    # A bill over the model: a factor over 1.
    high = fit.(build(), 7, july * 1.3)
    assert high.fit.factor > 1
    assert_in_delta Enum.at(high.months, 6).kwh, july * 1.3, july * 0.005

    # The math tells the factor in a separate sentence.
    ac = Enum.find(build().items, &(&1.type == "ac"))

    assert Enum.any?(
             Estimate.explain(ac, 7, low),
             &(&1 =~
                 ". The app also multiplies by #{:erlang.float_to_binary(low.fit.factor, decimals: 2)} to fit your bill of July.")
           )

    refute Enum.any?(Estimate.explain(ac, 7, plain), &(&1 =~ "to fit your bill"))

    # Too low a bill: the factor 0.25, and the page tells the least
    # estimate of the month.
    small = fit.(build(), 7, 10)
    assert small.fit.result == :limit and small.fit.factor < 0.26
    assert_in_delta Enum.at(small.months, 6).kwh, small.fit.after, 1.0

    assert Front.fit_text(small) ==
             "Your bill of July is 10 kWh, but the estimate of July cannot be less than #{Format.kwh(small.fit.after)}. Before, the estimate of July was #{Format.kwh(july)}. Check the items and the numbers of the bill."

    # Too high a bill: the AC runs at its capacity before the factor 4. The
    # factor is the least one that gives the most kWh, so the other months
    # change less.
    large = fit.(build(), 7, 100_000)
    assert large.fit.result == :limit and large.fit.factor < 4.0
    assert_in_delta Enum.at(large.months, 6).kwh, large.fit.after, 1.0

    {:ok, top} = Build.set_bill(build(), %{month: 7, kwh: 100_000})
    {:ok, top} = Build.update_house(top, %{size: 8000})
    assert Enum.at(Estimate.run(top, climate).months, 6).kwh < large.fit.after * 1.02
    assert Front.fit_text(large) =~ "cannot be more than #{Format.kwh(large.fit.after)}."

    # An AC at its capacity at the factor 1: a bill over the model keeps
    # the factor 1, and the estimate does not go down.
    old = build(%{size: 4000, year: 1975, floors: 1})
    full = Enum.at(Estimate.run(old, climate).months, 6).kwh
    over = fit.(old, 7, full * 1.05)
    assert %{factor: 1.0, result: :limit, after: ^full} = over.fit
    assert Enum.at(over.months, 6).kwh == full

    assert Front.fit_text(over) ==
             "Your bill of July is #{Format.kwh(full * 1.05)}, but the estimate of July cannot be more than #{Format.kwh(full)}. Check the items and the numbers of the bill."

    # A bill in 2% of the model keeps the model.
    near = fit.(build(), 7, july * 1.015)
    assert %{factor: 1.0, result: :fit, after: ^july} = near.fit

    # A small AC at its capacity at the factor 0.25 too: a bill under the
    # model keeps the factor 1. So the winter does not change.
    tiny = build(%{size: 4000, year: 1975, floors: 1, heat: "electric"})
    ac = Enum.find(tiny.items, &(&1.type == "ac"))
    {:ok, tiny} = Build.update_item(tiny, ac.id, %{"tons" => "1"})
    tiny_plain = Estimate.run(tiny, climate)
    tiny_july = Enum.at(tiny_plain.months, 6).kwh
    under = fit.(tiny, 7, tiny_july * 0.9)
    assert %{factor: 1.0, result: :limit} = under.fit
    assert under.kwh == tiny_plain.kwh
    refute Front.fit_text(under) =~ "Before"

    # A mild month (April), and the winter of a house with gas heat: the
    # model stays. The page names the month with the most cooling.
    for month <- [4, 1] do
      mild = fit.(build(), month, 700)
      assert %{factor: 1.0, result: :mild, best: 8} = mild.fit
      assert mild.kwh == plain.kwh
      assert Front.fit_text(mild) =~ "a small part of the bill, so the app keeps its model: "
      assert Front.fit_text(mild) =~ ". The bill of August can change the model."
    end

    # A planned item does not change the fit: it is not in the bill.
    backyard = room(build(), "Backyard")
    {:ok, planned, pump} = Build.add_item(build(), backyard, "ac")
    {:ok, planned} = Build.update_item(planned, pump, %{"heat_pump" => "true", "tons" => "3"})
    {:ok, planned} = Build.flag_item(planned, pump, :planned, true)
    assert fit.(planned, 7, july * 0.7).fit.factor == low.fit.factor
  end

  test "a bill fits a house with heat strips, and not a house with solar panels or no item" do
    climate = climate()

    fit = fn build, month, kwh ->
      {:ok, build} = Build.set_bill(build, %{month: month, kwh: kwh})
      Estimate.run(build, climate)
    end

    # A small heat pump and heat strips: the kWh of January increase fast
    # with the factor, and the fit still gives the bill.
    {strips, _id} = add(build(%{heat: "heat_pump"}), "Attic", "heat_strips", %{"kw" => "10"})
    ac = Enum.find(strips.items, &(&1.type == "ac"))
    {:ok, strips} = Build.update_item(strips, ac.id, %{"tons" => "2"})

    for kwh <- [2_827, 3_533] do
      january = fit.(strips, 1, kwh)
      assert january.fit.result == :fit
      assert_in_delta Enum.at(january.months, 0).kwh, kwh, kwh * 0.02
    end

    # Solar panels: the bill does not show all the use.
    {solar, _id} = add(build(), "Roof", "solar_panels", %{"watts" => "6000", "to" => "grid"})
    sun = fit.(solar, 7, 800)
    assert %{factor: 1.0, result: :solar} = sun.fit
    assert Front.fit_text(sun) =~ "Your solar panels give a part of your power"

    # No item of today: no heat and no cooling, and no month can fit.
    empty =
      Enum.reduce(build().items, build(), &elem(Build.flag_item(&2, &1.id, :planned, true), 1))

    none = fit.(empty, 7, 800)
    assert %{factor: 1.0, result: :mild, best: nil} = none.fit

    assert Front.fit_text(none) ==
             "In your home, the heat and the cooling are a small part of each bill, so the app keeps its model: 0 kWh in July."

    # A house that the person plans: the bill is of another home.
    {:ok, plan} = Build.set_bill(build(%{}, "planning"), %{month: 7, kwh: 900})
    assert %{ready: true, fit: nil} = Estimate.run(plan, climate)
  end

  test "a washer and dryer in one: the wash, and the dry of a heat pump or of a heater" do
    {build, pump} = add(build(), "Laundry", "washer_dryer", %{"loads" => "7"})
    {build, heater} = add(build, "Laundry", "washer_dryer", %{"loads" => "7", "dry" => "heater"})
    estimate = Estimate.run(build, climate())

    # 7 loads in one week: one load each day. The kWh to dry have two
    # decimals: 8.45 lb ÷ 6.00 is 1.41 kWh, and 8.45 lb ÷ 3.93 is 2.15 kWh.
    assert_in_delta estimate.items[pump].year, 365 * (0.25 + 1.41), 1.0e-6
    assert_in_delta estimate.items[heater].year, 365 * (0.25 + 2.15), 1.0e-6

    # The math gives the numbers that it uses, so it adds up on the page.
    {:ok, item} = Build.item(build, pump)
    assert [cef, line, _last] = Estimate.explain(item, 1, estimate)
    assert cef =~ "GE Profile PFQ97HS*V"
    assert cef =~ "÷ 6.00 lb for each kWh = 1.41 kWh to dry one load."

    assert line =~
             "7 loads in one week × 31 days ÷ 7 × (0.25 kWh to wash + 1.41 kWh to dry) = 51.5 kWh."

    assert DIY.Profile.watts(item) == 1_320.0

    {:ok, item} = Build.item(build, heater)
    assert [cef, line, _last] = Estimate.explain(item, 1, estimate)
    assert cef =~ "÷ 3.93 lb for each kWh = 2.15 kWh to dry one load."
    assert line =~ "(0.25 kWh to wash + 2.15 kWh to dry) = 74.4 kWh."
    assert DIY.Profile.watts(item) == 5_000.0

    # A combo does not stack: it goes on no item, and it takes no item.
    refute DIY.Stack.goes_on?(item)
    refute DIY.Stack.takes?(item)
  end

  test "a dehumidifier and a water dispenser" do
    {build, dry} = add(build(), "Kitchen", "dehumidifier")
    {build, all} = add(build, "Kitchen", "dehumidifier", %{"season" => "all"})
    {build, water} = add(build, "Kitchen", "water_dispenser")
    {build, winter} = add(build, "Kitchen", "water_dispenser", %{"season" => "winter"})
    estimate = Estimate.run(build, climate())

    # A dehumidifier: 480 W for 8.9 hours in one day, from April to
    # October (214 days). This is near the 1,000 kWh of the study for 8
    # months. All year gives more.
    assert_in_delta estimate.items[dry].year, 480 * 8.9 * 214 / 1_000, 1.0e-6
    assert estimate.items[dry].year > 900 and estimate.items[dry].year < 1_000
    assert_in_delta estimate.items[all].year, 480 * 8.9 * 365 / 1_000, 1.0e-6
    # A water dispenser of hot and cold water: 0.87 kWh in one day.
    assert_in_delta estimate.items[water].year, 0.87 * 365, 1.0e-6
    assert_in_delta estimate.items[winter].year, 0.87 * 90, 1.0e-6

    {:ok, item} = Build.item(build, dry)
    assert [line | _] = Estimate.explain(item, 7, estimate)
    assert line =~ "480 W × 8.9 hours in one day × 31 days ÷ 1,000"
    assert [line | _] = Estimate.explain(item, 1, estimate)
    assert line =~ "It is off in January"
    assert DIY.Profile.watts(item) == 480.0
    assert DIY.Profile.motor?(item)

    {:ok, item} = Build.item(build, water)
    assert [line | _] = Estimate.explain(item, 1, estimate)
    assert line =~ "0.87 kWh in one day × 31 days (all year)."
    assert DIY.Profile.watts(item) == 500.0
    assert DIY.Profile.motor?(item)

    {:ok, item} = Build.item(build, winter)
    assert [line | _] = Estimate.explain(item, 7, estimate)
    assert line =~ "It is off in July"
  end

  test "the format of a number" do
    assert Estimate.fmt(1_234_567.4) == "1,234,567"
    assert Estimate.fmt(999) == "999"
    assert Estimate.fmt(-1500) == "-1,500"
  end

  test "the water from the ground stays between 40 and 90 °F" do
    assert Estimate.inlet(%{t: -40, t_year: 0}) == 40
    assert Estimate.inlet(%{t: 130, t_year: 120}) == 90
    assert Estimate.inlet(%{t: 80, t_year: 60}) == 70.0
  end

  # A random house with random items.
  defp house_build do
    gen all(
          size <- integer(800..4000),
          year <- integer(1950..2026),
          floors <- integer(1..3),
          heat <- member_of(Build.heats()),
          added <- list_of({member_of(Catalog.types()), integer(0..30)}, max_length: 5)
        ) do
      build = build(%{size: size, year: year, floors: floors, heat: heat})

      Enum.reduce(added, build, fn {type, index}, build ->
        room = Enum.at(build.rooms, rem(index, length(build.rooms)))

        case Build.add_item(build, room.id, type) do
          {:ok, build, _id} -> build
          {:error, _reason} -> build
        end
      end)
    end
  end

  property "no item uses less than nothing, and each month is in its range" do
    climate = climate()

    check all(build <- house_build()) do
      estimate = Estimate.run(build, climate)

      for month <- estimate.months do
        assert month.low <= month.kwh + 1.0e-6 and month.kwh <= month.high + 1.0e-6
        assert month.low >= 0
        assert Enum.all?(month.items, fn {_id, item} -> item.kwh >= 0 end)
      end

      assert estimate.low <= estimate.kwh + 1.0e-6 and estimate.kwh <= estimate.high + 1.0e-6
    end
  end

  property "one more item never lowers the estimate" do
    climate = climate()

    check all(
            build <- house_build(),
            kind <- member_of(DIY.Kinds.house())
          ) do
      before = Estimate.run(build, climate).kwh
      room = Enum.find(build.rooms, &Catalog.fits?(kind, &1))
      {:ok, more, _id} = Build.add_item(build, room.id, kind.type)
      # A second cooling or heating item shares the load: it can lower it.
      if kind.type not in ["ac", "mini_split", "furnace", "heat_strips"] do
        assert Estimate.run(more, climate).kwh >= before - 1.0e-6
      end
    end
  end

  property "a better SEER2 never raises the estimate, and more degree days never lower it" do
    climate = climate()

    check all(
            build <- house_build(),
            seer2 <- float(min: 8.0, max: 29.0)
          ) do
      ac = Enum.find(build.items, &(&1.type == "ac"))
      {:ok, worse} = Build.update_item(build, ac.id, %{"seer2" => seer2})
      {:ok, better} = Build.update_item(build, ac.id, %{"seer2" => seer2 + 1})
      assert Estimate.run(better, climate).kwh <= Estimate.run(worse, climate).kwh + 1.0e-6

      hotter = %{
        climate
        | months:
            Map.new(climate.months, fn {m, w} -> {m, %{w | cdd: w.cdd + 50, hdd: w.hdd + 50}} end)
      }

      assert Estimate.run(build, hotter).kwh >= Estimate.run(build, climate).kwh - 1.0e-6
    end
  end

  test "a house with no items has no range of the weather" do
    {house, rooms, _items} =
      House.preset(%{size: 2000, year: 2005, floors: 1, heat: "gas", lot: nil})

    {:ok, build} = Build.set_zip(Build.new(), "75070")
    build = Build.put_house(build, house, rooms, [])
    estimate = Estimate.run(build, climate())
    assert {estimate.kwh, estimate.low, estimate.high} == {0, 0, 0}
  end
end
