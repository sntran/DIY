defmodule DIY.UsageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Estimate, House, Stubs, Usage, Weather}

  defp climate do
    {:ok, climate} = Weather.parse(Stubs.power(), 33.25, -96.75, 2016, 2025)
    climate
  end

  defp month(name, kwh, days \\ nil) do
    %{"month" => name, "kwh" => kwh, "export" => 0, "days" => days || Usage.days_in(name)}
  end

  defp usage(months), do: elem(Usage.read(%{"source" => "smt", "months" => months}), 1)

  test "read accepts the sums of the months, in order" do
    assert {:ok, %{source: "green_button", months: [first, second]}} =
             Usage.read(%{
               "source" => "green_button",
               "months" => [
                 month("2025-08", 900),
                 Map.put(month("2025-07", 1000, 30), "hours", [1])
               ]
             })

    # An older build had the hours of each month: the usage forgets them.
    assert first == %{month: "2025-07", kwh: 1000.0, export: 0.0, days: 30}
    assert second.month == "2025-08"
    assert Usage.source_name("smt") == "Smart Meter Texas"
    assert Usage.source_name("green_button") == "Green Button"
    assert Usage.source_name("csv") == "A CSV file"

    assert {:ok, %{source: "csv"}} =
             Usage.read(%{
               "source" => "csv",
               "months" => [first |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)]
             })
  end

  test "read refuses a usage that it cannot read in full" do
    good = month("2025-07", 1000)

    for bad <- [
          %{"source" => "x", "months" => [good]},
          %{"source" => "smt", "months" => []},
          %{"source" => "smt", "months" => List.duplicate(good, 25)},
          %{"source" => "smt", "months" => [good, good]},
          %{"source" => "smt", "months" => [%{good | "month" => "2025-13"}]},
          %{"source" => "smt", "months" => [%{good | "month" => 7}]},
          %{"source" => "smt", "months" => [%{good | "kwh" => -1}]},
          %{"source" => "smt", "months" => [%{good | "export" => "0"}]},
          %{"source" => "smt", "months" => [%{good | "days" => 0}]},
          # A name that is not "YYYY-MM" of 2000 to 2099, or more days than
          # the month has.
          %{"source" => "smt", "months" => [%{good | "month" => "-2025-07"}]},
          %{"source" => "smt", "months" => [%{good | "month" => "+2025-01"}]},
          %{"source" => "smt", "months" => [%{good | "month" => "0000-01"}]},
          %{"source" => "smt", "months" => [%{good | "month" => "2025-7"}]},
          %{"source" => "smt", "months" => [%{month("2025-02", 100) | "days" => 29}]},
          %{"source" => "smt", "months" => [%{good | "days" => 32}]},
          %{"source" => "smt", "months" => ["July"]},
          "usage"
        ] do
      assert Usage.read(bad) == :error, inspect(bad)
    end
  end

  @names for y <- 2023..2025, m <- 1..12, do: "#{y}-#{String.pad_leading("#{m}", 2, "0")}"

  property "to_map and read give the same usage" do
    check all(
            first <- member_of(@names),
            flags <- list_of(boolean(), length: length(@names)),
            kwh <- float(min: 0.0, max: 5000.0)
          ) do
      # The first month, and the other months with a true flag: 24 at most.
      others = for {name, true} <- Enum.zip(@names, flags), name != first, do: name
      months = Enum.take([first | others], 24)
      raw = for name <- months, do: month(name, kwh, 10)

      {:ok, usage} = Usage.read(%{"source" => "smt", "months" => raw})
      assert Usage.read(Usage.to_map(usage)) == {:ok, usage}
    end
  end

  test "a partial month counts the mean of its days for the other days" do
    assert Usage.days_in("2024-02") == 29
    assert Usage.full(%{month: "2025-07", kwh: 100.0, days: 10}) == 310.0
  end

  # Any month, with any days and kWh: the reader accepts it or not, and an
  # accepted usage never makes the pages raise.
  property "an accepted usage never makes the math raise" do
    name =
      one_of([
        member_of(@names),
        string(:ascii, max_length: 8),
        map({integer(-10..2200), integer(-2..14)}, fn {y, m} -> "#{y}-#{m}" end)
      ])

    check all(
            raw <-
              list_of(
                fixed_map(%{
                  "month" => name,
                  "kwh" => float(min: 0.0, max: 3000.0),
                  "export" => constant(0),
                  "days" => integer(0..32)
                }),
                min_length: 1,
                max_length: 24
              )
          ) do
      with {:ok, usage} <- Usage.read(%{"source" => "smt", "months" => raw}) do
        estimate = Estimate.run(build(1800, "gas"), climate())
        assert %{rows: _} = Usage.compare(usage, estimate)
        assert Usage.year(usage) == nil or is_float(Usage.year(usage))
        assert Usage.fit(usage, climate()) == nil or is_map(Usage.fit(usage, climate()))
        assert Enum.all?(usage.months, &(Usage.full(&1) >= 0))
      end
    end
  end

  test "the real month of each month of the year, and one year" do
    usage = usage([month("2024-07", 900), month("2025-07", 1000), month("2025-08", 1100)])
    assert %{7 => %{month: "2025-07"}, 8 => %{month: "2025-08"}} = Usage.by_month(usage)

    # A file of 12 months from the 8th: the month with the most days, not
    # the newest one.
    usage = usage([month("2024-10", 800, 24), month("2025-10", 300, 7)])
    assert %{10 => %{month: "2024-10"}} = Usage.by_month(usage)
    assert Usage.year(usage) == nil

    year = usage(for m <- 1..12, do: month("2025-#{String.pad_leading("#{m}", 2, "0")}", 1000))
    assert Usage.year(year) == 12_000.0
  end

  test "the real months next to the estimate" do
    estimate = %{
      ready: true,
      months: [
        %{month: 7, name: "July", kwh: 1500.0, low: 1200.0, high: 1800.0},
        %{month: 8, name: "August", kwh: 1500.0, low: 1200.0, high: 1800.0}
      ]
    }

    usage = usage([month("2025-07", 1700), month("2025-08", 500, 10)])
    assert %{inside: 2, rows: [july, august]} = Usage.compare(usage, estimate)
    assert %{name: "July", real: 1700.0, inside: true, partial: false, from: "2025-07"} = july
    assert %{real: 1550.0, inside: true, partial: true} = august

    usage = usage([month("2025-07", 3000)])
    assert %{inside: 0, rows: [%{inside: false}]} = Usage.compare(usage, estimate)
  end

  # Months from known numbers of a house and the real weather of Plano.
  defp made(climate, base, cool, heat, months) do
    usage(
      for {year, m} <- months do
        name = "#{year}-#{String.pad_leading("#{m}", 2, "0")}"
        w = climate.series[{year, m}]
        month(name, base * Usage.days_in(name) + cool * w.cdd + heat * w.hdd)
      end
    )
  end

  defp year_months, do: for(m <- 7..12, do: {2024, m}) ++ for(m <- 1..6, do: {2025, m})

  property "the fit finds the numbers of a house from its months" do
    climate = climate()

    check all(
            base <- float(min: 5.0, max: 60.0),
            cool <- float(min: 0.0, max: 3.0),
            heat <- float(min: 0.0, max: 3.0)
          ) do
      fit = Usage.fit(made(climate, base, cool, heat, year_months()), climate)
      assert_in_delta fit.base, base, 0.01
      assert_in_delta fit.cool, cool, 0.001
      assert_in_delta fit.heat, heat, 0.001
      assert fit.months == 12
      assert fit.r2 > 0.999 or (cool == 0 and heat == 0)
    end
  end

  test "the fit keeps each number at zero or more" do
    climate = climate()
    # More usage in the mild months than in the hot months: a negative
    # cooling number fits best, so the fit keeps it at zero.
    months =
      for {year, m} <- year_months() do
        name = "#{year}-#{String.pad_leading("#{m}", 2, "0")}"
        w = climate.series[{year, m}]
        month(name, max(2000 - w.cdd * 2 + w.hdd * 0.5, 10))
      end

    fit = Usage.fit(usage(months), climate)
    assert fit.cool == 0.0
    assert fit.base >= 0 and fit.heat >= 0
  end

  test "the fit needs 6 full months with weather" do
    climate = climate()
    assert Usage.fit(made(climate, 20, 1, 1, Enum.take(year_months(), 5)), climate) == nil

    # Months with few days, or with no weather yet, do not count.
    short =
      usage(
        for {y, m} <- year_months(),
            do: month("#{y}-#{String.pad_leading("#{m}", 2, "0")}", 900, 10)
      )

    assert Usage.fit(short, climate) == nil
    future = usage(for m <- 1..9, do: month("2026-0#{m}", 900))
    assert Usage.fit(future, climate) == nil
  end

  test "the fit of months with the same usage each day has no heat and no cooling" do
    flat =
      usage(
        for {y, m} <- year_months(),
            name = "#{y}-#{String.pad_leading("#{m}", 2, "0")}",
            do: month(name, 20 * Usage.days_in(name))
      )

    fit = Usage.fit(flat, climate())
    assert_in_delta fit.base, 20.0, 1.0e-6
    assert fit.cool < 1.0e-6 and fit.heat < 1.0e-6

    # A number of 0 has no sign on the page.
    zero =
      usage(
        for {y, m} <- year_months(), do: month("#{y}-#{String.pad_leading("#{m}", 2, "0")}", 0)
      )

    assert %{base: base, cool: cool, heat: heat} = Usage.fit(zero, climate())
    assert Enum.all?([base, cool, heat], &(:erlang.float_to_binary(&1, decimals: 2) == "0.00"))
  end

  test "with no degree days, the fit has only the base" do
    # No month has degree days: the columns of cooling and heat are zero,
    # and the sets with them have no solution.
    climate = %{series: Map.new(1..9, &{{2025, &1}, %{cdd: 0.0, hdd: 0.0}})}
    usage = usage(for m <- 1..9, do: month("2025-0#{m}", 30 * Usage.days_in("2025-0#{m}")))

    assert %{base: base, cool: +0.0, heat: +0.0, months: 9, r2: r2} = Usage.fit(usage, climate)
    assert_in_delta base, 30.0, 1.0e-9
    assert_in_delta r2, 1.0, 1.0e-9

    # More kWh in the short months: the fit is worse than the mean of the
    # months, and explains none of the change.
    short =
      usage(for m <- 1..9, do: month("2025-0#{m}", 4100 - 100 * Usage.days_in("2025-0#{m}")))

    assert %{r2: +0.0} = Usage.fit(short, climate)
  end

  # The check of phase 2: the estimate falls in its own range for test
  # houses with meter data. It is a check of the app with itself, on
  # synthetic meter data: each test house comes from the same model as the
  # estimate (DIY.Estimate), with other numbers, so the check cannot find a
  # fault of the model itself (docs/design.md).
  #
  # - The estimate of each preset uses the weather of 2016 to 2023 only.
  #   The months of each test house come from the weather of July 2024 to
  #   June 2025 (degree days and temperature of each month), out of that
  #   history, with 5% noise.
  # - Each test house is its preset with other numbers that the estimate
  #   does not know: a heat loss up to 10% larger or smaller, an AC of one
  #   SEER2 more or less, a furnace blower and other items up to 20% more
  #   or less, and one person more or less at the water heater.
  test "the estimate falls in its range for test houses with synthetic meter data" do
    {:ok, history} = Weather.parse(Stubs.power(), 33.25, -96.75, 2016, 2023)
    climate = climate()
    :rand.seed(:exsss, {1, 2, 3})

    results =
      for size <- [1200, 1800, 2500, 3500], heat <- ["gas", "heat_pump", "electric"], _ <- 1..2 do
        preset = build(size, heat)
        truth = vary(preset)
        estimate = Estimate.run(preset, history)

        months =
          for {year, m} <- year_months() do
            w = climate.series[{year, m}]

            weather = %{
              climate
              | months:
                  Map.put(climate.months, m, %{climate.months[m] | cdd: w.cdd, hdd: w.hdd, t: w.t})
            }

            real =
              Enum.at(Estimate.run(truth, weather).months, m - 1).kwh *
                (0.95 + :rand.uniform() * 0.1)

            month("#{year}-#{String.pad_leading("#{m}", 2, "0")}", real)
          end

        Usage.compare(usage(months), estimate).inside
      end

    # Each house has 10 of its 12 months in the range at least, and the
    # houses together have 90% of their months in it (in October 2026: 269
    # of 288 months, 93%).
    assert Enum.all?(results, &(&1 >= 10)), inspect(results)
    assert Enum.sum(results) / (12 * length(results)) >= 0.9, inspect(results)
  end

  defp build(size, heat) do
    {house, rooms, items} =
      House.preset(%{size: size, year: 2005, floors: 2, heat: heat, lot: nil})

    {:ok, build} = Build.set_zip(Build.new(), "75070")
    Build.put_house(build, house, rooms, items)
  end

  # A test house like the preset: a heat loss up to 10% larger or smaller,
  # an AC of one SEER2 more or less, a furnace blower and other items up to
  # 20% more or less, and one person more or less at the water heater.
  defp vary(build) do
    size = round(build.house.size * (0.9 + :rand.uniform() * 0.2))

    items =
      Enum.map(build.items, fn item ->
        case item.type do
          "ac" ->
            %{
              item
              | params: %{item.params | "seer2" => item.params["seer2"] + :rand.uniform() * 2 - 1}
            }

          "heat_strips" ->
            item

          "water_heater" ->
            people = max(item.params["people"] + Enum.random(-1..1), 1)
            %{item | params: %{item.params | "people" => people}}

          "furnace" ->
            factor = 0.8 + :rand.uniform() * 0.4
            %{item | params: %{item.params | "blower" => round(item.params["blower"] * factor)}}

          _ ->
            factor = 0.8 + :rand.uniform() * 0.4
            %{item | params: Map.new(item.params, fn {k, v} -> {k, scale(k, v, factor)} end)}
        end
      end)

    %{build | house: %{build.house | size: size}, items: items}
  end

  defp scale(key, value, factor) when key in ["watts", "kwh_year", "bulbs"],
    do: max(round(value * factor), 1)

  defp scale(_key, value, _factor), do: value
end
