defmodule DIY.EstimateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, Estimate, House, Stubs, Weather}

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

    assert estimate.climate == %{first: 2016, last: 2025, lat: 33.25, lon: -96.75}
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

  test "the explanation of each kind of item" do
    build =
      Enum.reduce(Catalog.kinds(), build(), fn kind, build ->
        room = Enum.find(build.rooms, &(&1.place in kind.places))
        {:ok, build, _id} = Build.add_item(build, room.id, kind.type)
        build
      end)

    {build, _id} = add(build, "Garage", "water_heater", %{"fuel" => "heat_pump"})
    {build, _id} = add(build, "Garage", "water_heater", %{"fuel" => "electric"})
    {build, _id} = add(build, "Kitchen", "range", %{"fuel" => "gas"})
    {build, _id} = add(build, "Laundry", "dryer", %{"fuel" => "gas"})
    {build, _id} = add(build, "Backyard", "ac", %{"heat_pump" => "true"})
    {build, _id} = add(build, "Bedroom 2", "mini_split", %{"area" => "100"})
    estimate = Estimate.run(build, climate())

    for item <- build.items, month <- [1, 7] do
      lines = Estimate.explain(item, month, estimate)
      assert [_ | _] = lines
      assert Enum.all?(lines, &is_binary/1)
    end

    ac = Enum.find(build.items, &(&1.type == "ac" and &1.params["heat_pump"]))
    assert Enum.any?(Estimate.explain(ac, 7, estimate), &(&1 =~ "% (its share of the house)"))
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
            kind <- member_of(Catalog.kinds())
          ) do
      before = Estimate.run(build, climate).kwh
      room = Enum.find(build.rooms, &(&1.place in kind.places))
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
