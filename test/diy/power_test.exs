defmodule DIY.PowerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Estimate, House, Power, Profile, Stubs, Weather}

  defp climate do
    {:ok, climate} = Weather.parse(Stubs.power(), 33.25, -96.75, 2016, 2025)
    climate
  end

  defp house(door \\ "my_house") do
    {house, rooms, items} =
      House.preset(%{size: 2000, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), door)
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id
  defp of_type(build, type), do: Enum.find(build.items, &(&1.type == type))

  defp add(build, room, type, params \\ %{}) do
    {:ok, build, id} = Build.add_item(build, room(build, room), type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  defp flag(build, id, flag, value \\ true) do
    {:ok, build} = Build.flag_item(build, id, flag, value)
    build
  end

  defp power(build, changes), do: Build.set_power(build, Map.merge(build.power, changes))

  defp run(build, cents \\ 15.0) do
    climate = climate()
    Power.run(build, Estimate.run(build, climate), climate, cents)
  end

  # A station of 7.2 kWh in the laundry, that runs the fridge.
  defp station(build \\ house(), params \\ %{}) do
    {build, id} =
      add(
        build,
        "Laundry",
        "power_station",
        Map.merge(
          %{"kwh" => "3.6", "extra_kwh" => "3.6", "output_w" => "3600", "solar_w" => "1600"},
          params
        )
      )

    {flag(build, of_type(build, "fridge").id, :backup), id}
  end

  describe "settings" do
    test "the default settings, to JSON and back" do
      settings = Power.settings()
      assert settings.mode == "backup"
      assert Power.read(Power.to_map(settings)) == {:ok, settings}
      assert [{"backup", _}, {"night", _}, {"solar", _}] = Power.modes()
    end

    test "read refuses settings that are not valid" do
      good = Power.to_map(Power.settings())

      for {key, value} <- [
            {"mode", "turbo"},
            {"night_cents", -1},
            {"night_cents", 10 ** 400},
            {"night_from", 24},
            {"night_to", "6"},
            {"buyback_cents", nil},
            {"reserve", 101}
          ] do
        assert Power.read(Map.put(good, key, value)) == :error, key
      end

      assert {:ok, %{night_cents: 5.0}} = Power.read(%{good | "night_cents" => 5})
      assert Power.read("settings") == :error
    end

    test "update reads the text of a form" do
      settings = Power.settings()

      assert {:ok,
              %{
                mode: "night",
                night_cents: 2.5,
                night_from: 21,
                night_to: 7,
                buyback_cents: 3.0,
                reserve: 30
              }} =
               Power.update(settings, %{
                 "mode" => "night",
                 "night_cents" => " 2.5 ",
                 "night_from" => "21",
                 "night_to" => "7",
                 "buyback_cents" => "3",
                 "reserve" => "30"
               })

      {:ok, night} = Power.update(settings, %{"night_cents" => "4"})
      assert {:ok, %{night_cents: nil}} = Power.update(night, %{"night_cents" => " "})
      assert Power.update(settings, %{}) == {:ok, settings}

      for {key, value, error} <- [
            {"mode", "turbo", :mode},
            {"night_cents", "free", :night_cents},
            {"night_cents", 5, :night_cents},
            {"night_from", "25", :night_from},
            {"night_from", "ten", :night_from},
            {"night_to", 6, :night_to},
            {"buyback_cents", "-1", :buyback_cents},
            {"buyback_cents", 1, :buyback_cents},
            {"reserve", "half", :reserve},
            {"reserve", 20, :reserve}
          ] do
        assert Power.update(settings, %{key => value}) == {:error, error}, key
      end

      # A night with no hours.
      assert Power.update(settings, %{"night_from" => "6"}) == {:error, :night}
    end

    test "the hours of the night" do
      settings = Power.settings()

      assert Power.night?(settings, 23) and Power.night?(settings, 0) and
               Power.night?(settings, 5)

      refute Power.night?(settings, 6) or Power.night?(settings, 21)
      day = %{settings | night_from: 1, night_to: 5}
      assert Power.night?(day, 1) and Power.night?(day, 4)
      refute Power.night?(day, 5) or Power.night?(day, 0)
    end
  end

  describe "the system" do
    test "the stations work as one, and run only their items" do
      {build, _id} = station()
      {build, _id} = add(build, "Garage", "power_station", %{"kwh" => "1", "output_w" => "1000"})
      {build, _id} = add(build, "Roof", "solar_panels", %{"watts" => "1000", "facing" => "east"})
      {build, _id} = add(build, "Backyard", "solar_panels", %{"watts" => "400", "to" => "grid"})
      {build, _id} = add(build, "Garage", "transfer_switch")
      {build, _id} = add(build, "Driveway", "ev", %{"charger" => "l2"})
      {build, _id} = add(build, "Driveway", "ev", %{"charger" => "l1"})
      sys = Power.system(build.items)
      assert [%{params: %{"charger" => "l2"}}] = sys.chargers
      assert sys.kwh == 8.2
      assert sys.output_w == 4600.0
      assert sys.station_panels_w == 950.0
      assert_in_delta sys.grid_panels_w, 440.0, 1.0e-9
      assert %{type: "transfer_switch"} = sys.switch
      assert [%{type: "fridge"}] = sys.backup

      # With no station, no item is on a station.
      fridge = of_type(build, "fridge")
      assert Power.system([fridge]).backup == []
    end
  end

  describe "a battery bank on the busbar of a station" do
    # A bank of 4 batteries of 12.8 V and 280 Ah in series: 48 V, 280 Ah.
    # It goes to a busbar through a switch and a monitor, as in the house
    # of the owner.
    defp bank_build(joined?) do
      {build, station} = add(house(), "Garage", "power_station", %{"kwh" => "5.12"})
      {build, bank} = add(build, "Garage", "van_battery", %{"ah" => "280", "volts" => "48"})
      {build, switch} = add(build, "Garage", "battery_switch")
      {build, monitor} = add(build, "Garage", "battery_monitor")
      {build, lynx} = add(build, "Garage", "dc_bus")

      chain =
        [{bank, switch}, {switch, monitor}, {monitor, lynx}] ++
          if(joined?, do: [{station, lynx}], else: [])

      Enum.reduce(chain, build, fn {from, to}, build ->
        {:ok, build, _wire} = Build.add_wire(build, from, to)
        build
      end)
    end

    test "adds its kWh to the stations, through a switch and a monitor" do
      build = bank_build(true)
      sys = Power.system(build.items, build.wires)
      assert [%{type: "van_battery"}] = sys.banks
      # 280 Ah × 48 V × 90% (LiFePO4) ÷ 95% (the part of a station).
      assert_in_delta sys.kwh, 5.12 + 280 * 48 / 1_000 * 0.9 / 0.95, 1.0e-9

      # The wires of the chain have the voltage of the bank.
      assert Enum.all?(build.wires, &(&1.system == "48"))

      # The page Power runs with the bank: an outage gives more hours. A
      # station of 5.12 kWh runs a fridge for about 4 days. With the bank,
      # it runs it for more than the 7 days of the model.
      fridge = of_type(build, "fridge").id
      with_bank = run(flag(build, fridge, :backup)).months |> hd()
      without = run(flag(bank_build(false), fridge, :backup)).months |> hd()
      assert is_number(without.outage) and without.outage > 48
      assert with_bank.outage == :days
    end

    test "a wire to an item that is not in the house does not count" do
      build = bank_build(true)
      [lynx] = for i <- build.items, i.type == "dc_bus", do: i.id

      # A station in a van: the house has no item at that end of its wire.
      wires = build.wires ++ [%{id: "w99", from: "gone", to: lynx}]
      sys = Power.system(build.items, wires)
      assert [%{type: "van_battery"}] = sys.banks
      assert Power.banks(build.items, [%{id: "w98", from: "gone", to: "lost"}]) == []
    end

    test "with no wire to a station, a bank adds nothing" do
      build = bank_build(false)
      sys = Power.system(build.items, build.wires)
      assert sys.banks == []
      assert sys.kwh == 5.12

      # A bank and a station with no wires: nothing either.
      assert Power.system(build.items).banks == []
    end
  end

  property "a bank counts when a chain of wires joins it to a station" do
    types = ~w(power_station van_battery dc_bus battery_switch battery_monitor fridge)

    check all(
            kinds <- list_of(member_of(types), min_length: 2, max_length: 8),
            pairs <- list_of({integer(0..7), integer(0..7)}, max_length: 12),
            max_runs: 200
          ) do
      items =
        for {type, i} <- Enum.with_index(kinds),
            do: %{
              id: "i#{i}",
              type: type,
              params: %{
                "ah" => 100,
                "volts" => "12",
                "chemistry" => "lifepo4",
                "kwh" => 1.0,
                "extra_kwh" => 0.0
              }
            }

      n = length(items)
      wires = for {a, b} <- pairs, a < n, b < n, a != b, do: %{from: "i#{a}", to: "i#{b}"}

      # The reference: a search from each station that goes on only through
      # a part of a busbar, a station or a bank. A fridge stops it.
      pass = ~w(power_station van_battery dc_bus battery_switch battery_monitor)
      by_id = Map.new(items, &{&1.id, &1})

      step = fn seen ->
        for w <- wires,
            {a, b} <- [{w.from, w.to}, {w.to, w.from}],
            a in seen,
            by_id[b].type in pass,
            into: seen,
            do: b
      end

      start = MapSet.new(for i <- items, i.type == "power_station", do: i.id)
      joined = Enum.reduce(1..n, start, fn _, seen -> step.(seen) end)
      expected = for i <- items, i.type == "van_battery", MapSet.member?(joined, i.id), do: i.id

      assert Enum.map(Power.banks(items, wires), & &1.id) == expected
    end
  end

  describe "a month of power" do
    test "a house with no equipment takes its use from the grid" do
      result = run(house())

      for m <- result.months do
        assert_in_delta m.grid, m.use, 1.0e-6
        assert m.export == 0 and m.sun == 0 and m.lost == 0
        assert m.outage == nil
        assert_in_delta m.cost, m.grid * 0.15, 1.0e-6
      end

      assert_in_delta result.year.use, Estimate.run(house(), climate()).kwh, 1.0e-6
      assert result.watts == 0
    end

    test "a price of the night changes the bill with no equipment" do
      result = run(power(house(), %{night_cents: 5.0}))
      year = result.year
      assert_in_delta year.cost, (year.day * 15 + year.night * 5) / 100, 1.0e-6
      assert year.night > 0 and year.day > year.night
    end

    test "in the mode backup, the battery stays full" do
      {build, _id} = station()
      result = run(build)
      today = run(house())
      assert_in_delta result.year.grid, today.year.grid, 1.0e-6
      # 7.2 kWh run the fridge (1.4 kWh in one day) for more than 3 days.
      assert Enum.all?(result.months, &(&1.outage > 72))
    end

    test "in the mode night, the station takes power at night, and loses some" do
      {build, _id} = station()
      backup = run(build)
      night = run(power(build, %{mode: "night", night_cents: 5.0}))
      assert night.year.day < backup.year.day
      assert night.year.night > backup.year.night
      # The battery gives back 92% × 92% of the power that goes into it.
      assert night.year.grid > backup.year.grid
      assert night.year.cost < backup.year.cost

      # With one price, the shift costs money.
      same = run(power(build, %{mode: "night"}))
      assert same.year.cost > backup.year.cost
    end

    test "the sun of a station: used by its items, else stored, else lost" do
      {build, _id} = station(house(), %{"kwh" => "1", "extra_kwh" => "0"})
      {build, _id} = add(build, "Roof", "solar_panels", %{"watts" => "1600"})
      solar = run(power(build, %{mode: "solar"}))
      without = run(house())
      assert solar.year.sun > 0 and solar.year.lost > 0
      assert solar.year.grid < without.year.grid
      # The house can use at most the sun that the station does not lose.
      assert solar.year.grid >= without.year.grid - (solar.year.sun - solar.year.lost)

      # The input of the station cuts the sun: the panels give the same
      # sun, and the station loses more of it.
      small = run(power(station_input(build, 100), %{mode: "solar"}))
      assert_in_delta small.year.sun, solar.year.sun, 1.0e-6
      assert small.year.lost > solar.year.lost
      assert small.year.grid > solar.year.grid
    end

    test "panels on the grid give to the house first, and the rest goes to the grid" do
      {build, _id} = add(house(), "Roof", "solar_panels", %{"watts" => "8000", "to" => "grid"})
      paid = run(power(build, %{buyback_cents: 7.0}))
      free = run(build)
      assert paid.year.export > 0
      assert_in_delta free.year.cost - paid.year.cost, paid.year.export * 0.07, 1.0e-6
      assert Enum.at(paid.months, 6).grid > 0
    end

    # A check with the numbers of a label: a station of 2,048 Wh runs a
    # fridge of 400 kWh in one year (45.7 W on average). By hand: 2.048 kWh
    # × 95% of the battery × 92% out of it ÷ 0.0457 kW = 39.2 hours.
    test "a station of 2 kWh runs a fridge of 400 kWh in one year for near 39 hours" do
      {build, _id} =
        station(house(), %{
          "kwh" => "2.048",
          "extra_kwh" => "0",
          "output_w" => "2400",
          "solar_w" => "0"
        })

      fridge = of_type(build, "fridge")
      {:ok, build} = Build.update_item(build, fridge.id, %{"kwh_year" => "400"})
      hours = Enum.at(run(build).months, 6).outage
      assert_in_delta hours, 2.048 * 0.95 * 0.92 / (400 / 8760), 0.5
    end

    test "an outage: the hours fall with more items on the station" do
      {build, _id} = station(house(), %{"kwh" => "1", "extra_kwh" => "0", "solar_w" => "0"})
      fridge = run(build)
      july = Enum.at(fridge.months, 6).outage
      assert is_float(july) and july > 10

      build = flag(build, of_type(build, "ac").id, :backup)
      both = run(build)
      assert Enum.at(both.months, 6).outage < july
      assert both.watts > 3600
      assert Enum.any?(both.motors, &(&1.type == "ac"))
    end
  end

  defp station_input(build, watts) do
    station = of_type(build, "power_station")
    {:ok, build} = Build.update_item(build, station.id, %{"solar_w" => "#{watts}"})
    build
  end

  describe "warnings" do
    test "backfeed, permit, grid-tie, overload and surge" do
      assert Power.warnings(run(house())) == []
      {build, id} = station()
      assert Power.warnings(run(build)) == [:surge]
      {:ok, build} = Build.update_item(build, id, %{"feeds" => "panel"})
      assert Power.warnings(run(build)) == [:backfeed, :permit, :surge]
      {build, _id} = add(build, "Garage", "transfer_switch")
      assert Power.warnings(run(build)) == [:permit, :surge]
      assert Power.permits(run(build).system) == [:panel]
      {:ok, build} = Build.update_item(build, id, %{"output_w" => "100"})
      assert Power.warnings(run(build)) == [:permit, :overload, :surge]

      # Panels on a grid-tie inverter, and a station on the panel.
      {build, _id} = add(build, "Roof", "solar_panels", %{"to" => "grid"})
      assert :grid_tie in Power.warnings(run(build))
      assert Power.permits(run(build).system) == [:panel, :grid_tie]
    end

    test "panels on the grid, and a Level 2 charger, need a permit" do
      {build, _id} = add(house(), "Roof", "solar_panels", %{"to" => "grid"})
      assert Power.warnings(run(build)) == [:permit]
      assert Power.permits(run(build).system) == [:grid_tie]

      {build, _id} = add(house(), "Driveway", "ev", %{"charger" => "l2"})
      assert Power.permits(run(build).system) == [:charger]
      {build, _id} = add(house(), "Driveway", "ev", %{"charger" => "l1"})
      assert Power.warnings(run(build)) == []
    end

    test "an outage from the charge at 18:00, and a month with no use" do
      {build, _id} = station(house(), %{"kwh" => "2", "extra_kwh" => "0", "solar_w" => "0"})
      full = Enum.at(run(build).months, 6).outage

      # In the mode night, the battery gives power in the day: at 18:00, it
      # has less charge than in the mode backup.
      night = Enum.at(run(power(build, %{mode: "night", reserve: 10})).months, 6).outage
      assert night < full

      # The furnace blower has no use in July: no hours for that month.
      furnace = of_type(build, "furnace")

      build =
        build |> flag(of_type(build, "fridge").id, :backup, false) |> flag(furnace.id, :backup)

      months = run(build).months
      assert Enum.at(months, 6).outage == nil
      assert Enum.at(months, 0).outage > 0
    end
  end

  describe "the what-if" do
    defp whatif(build, cents \\ 15.0) do
      climate = climate()
      today = Build.today(build)
      today_estimate = Estimate.run(today, climate)

      Power.whatif(
        build,
        today_estimate.ready && Power.run(today, today_estimate, climate, cents),
        today_estimate,
        Estimate.run(build, climate),
        climate,
        cents
      )
    end

    test "no planned item: no what-if" do
      assert whatif(house()) == nil
    end

    test "planned panels: the savings, their range, the payback and the life" do
      {build, _id} = station()
      {build, panels} = add(build, "Roof", "solar_panels", %{"watts" => "1600", "cost" => "800"})
      build = build |> flag(panels, :planned) |> power(%{mode: "solar"})
      whatif = whatif(build)
      assert whatif.price == 800
      assert whatif.savings > 0
      assert whatif.savings_low <= whatif.savings_high
      assert_in_delta whatif.payback, 800 / whatif.savings, 1.0e-9
      assert whatif.life == 25
      assert whatif.others == nil
      assert whatif.today.year.sun == 0
      assert whatif.plan.year.sun > 0
      assert whatif.plan_bill.cost_low <= whatif.plan.year.cost
      assert whatif.plan.year.cost <= whatif.plan_bill.cost_high
    end

    test "two items of equipment: each one has the savings that it adds, and its own life" do
      {build, station} = station()

      {build, panels} =
        add(build, "Roof", "solar_panels", %{"watts" => "6000", "to" => "grid", "cost" => "15000"})

      whatif = whatif(build |> flag(station, :planned) |> flag(panels, :planned))
      # The battery of 8 years is the shortest life of the plan.
      assert whatif.life == 8

      [solar] = for %{items: [%{type: "solar_panels"}]} = part <- whatif.parts, do: part
      [battery] = for %{items: [%{type: "power_station"}]} = part <- whatif.parts, do: part
      assert solar.price == 15000 and solar.life == 25
      assert battery.life == 8
      # In the mode backup, the station adds no savings: the panels add all.
      assert_in_delta battery.savings, 0.0, 1.0e-6
      assert battery.payback == nil
      assert_in_delta solar.savings, whatif.savings, 1.0e-6
      assert_in_delta solar.payback, 15000 / solar.savings, 1.0e-9

      # One item of equipment: no parts.
      assert whatif(flag(build, panels, :planned)).parts == []

      # A planned freezer is out of the parts: each part adds the same.
      {build, freezer} = add(build, "Garage", "freezer")

      with_freezer =
        whatif(
          build
          |> flag(station, :planned)
          |> flag(panels, :planned)
          |> flag(freezer, :planned)
        )

      assert Enum.map(with_freezer.parts, & &1.savings) == Enum.map(whatif.parts, & &1.savings)
    end

    test "panels that charge a station are one part with the station" do
      {build, station} = station()
      {build, panels} = add(build, "Roof", "solar_panels", %{"watts" => "1600", "cost" => "800"})
      {build, switch} = add(build, "Garage", "transfer_switch", %{"cost" => "600"})

      whatif =
        whatif(
          build
          |> flag(station, :planned)
          |> flag(panels, :planned)
          |> flag(switch, :planned)
        )

      assert [
               %{items: together, life: 8, price: price},
               %{items: [%{type: "transfer_switch"}]} = alone
             ] =
               whatif.parts

      assert Enum.map(together, & &1.type) == ["power_station", "solar_panels"]
      assert price == 1500 + 800
      # A switch adds no savings, and no life.
      assert alone.payback == nil and alone.life == nil

      # A station with its panels alone: one part, so no parts.
      assert whatif(build |> flag(station, :planned) |> flag(panels, :planned)).parts == []
    end

    test "a plan that does not pay back on savings alone" do
      {build, id} = station()
      build = flag(build, id, :planned)
      whatif = whatif(build)
      assert whatif.savings <= 0
      assert whatif.payback == nil
      assert whatif.life == 8
    end

    test "a planned car: the cost of its charge and its gas, out of the payback" do
      {build, car} =
        add(house(), "Driveway", "ev", %{"miles" => "40", "mpg" => "25", "gas" => "3"})

      build = flag(build, car, :planned)
      whatif = whatif(build)
      assert_in_delta whatif.others.gas, 40 * 365 / 25 * 3, 1.0e-9
      assert_in_delta whatif.others.change, whatif.plan.year.cost - whatif.today.year.cost, 1.0e-6
      assert whatif.plan.year.use > whatif.today.year.use
      assert whatif.equipment == [] and whatif.price == 0
      assert whatif.payback == nil and whatif.life == nil
      assert_in_delta whatif.savings, 0.0, 1.0e-6

      # With a planned station too: the payback is for the station only.
      {build, station} = station(build)
      whatif = whatif(flag(build, station, :planned))
      assert [%{type: "power_station"}] = whatif.equipment
      assert whatif.others.gas > 0
      assert whatif.savings <= 0 and whatif.payback == nil
    end

    test "a planned freezer is out of the payback of the planned panels" do
      {build, freezer} = add(house(), "Garage", "freezer")
      {build, panels} = add(build, "Roof", "solar_panels", %{"to" => "grid", "cost" => "3000"})

      panels_only =
        whatif(
          flag(build, panels, :planned)
          |> Map.update!(:items, &List.delete(&1, of_type(build, "freezer")))
        )

      both = whatif(build |> flag(panels, :planned) |> flag(freezer, :planned))
      assert [%{type: "solar_panels"}] = both.equipment
      assert [%{type: "freezer"}] = both.others.items
      assert both.others.change > 0 and both.others.gas == 0
      assert_in_delta both.payback, panels_only.payback, 0.05

      # A planned car and a planned freezer: the charge of the car is its
      # own.
      {build, car} = add(build, "Driveway", "ev")
      mixed = whatif(build |> flag(car, :planned) |> flag(freezer, :planned))
      {:ok, ev} = Build.item(build, car)
      assert_in_delta mixed.others.charge, Power.charge_year(ev, build.power, 15.0).cost, 1.0e-9
      assert mixed.others.change > mixed.others.charge

      # A planned freezer alone: no equipment, no payback.
      alone = whatif(flag(build, freezer, :planned))
      assert alone.equipment == [] and alone.payback == nil
    end

    test "the warnings of the plan" do
      {build, id} = station()
      {:ok, build} = Build.update_item(build, id, %{"feeds" => "panel", "output_w" => "200"})
      build = build |> flag(of_type(build, "ac").id, :backup) |> flag(id, :planned)
      assert [:backfeed, :permit, :overload, :surge] = whatif(build).warnings
    end

    test "no what-if when a house has no estimate yet" do
      {house, rooms, []} =
        House.scratch(%{size: 1800, year: 2026, floors: 1, heat: "gas", lot: nil})

      {:ok, plan} = Build.choose_door(Build.new(), "planning")
      {:ok, plan} = Build.set_zip(plan, "75070")
      plan = Build.put_house(plan, house, rooms, [])
      {plan, ac} = add(plan, "Backyard", "ac")
      assert whatif(flag(plan, ac, :planned)) == nil
    end

    test "the cost of the home charge of a car" do
      {build, id} = add(house(), "Driveway", "ev", %{"miles" => "30", "when" => "night"})
      {:ok, car} = Build.item(build, id)
      settings = %{Power.settings() | night_cents: 5.0}
      night = Power.charge_year(car, settings, 15.0)
      assert_in_delta night.kwh, 30 * 365 / 3.5 / 0.9, 1.0e-9
      assert_in_delta night.cost, night.kwh * 0.05, 1.0e-9
      assert night.hours < 2

      evening =
        Power.charge_year(%{car | params: %{car.params | "when" => "evening"}}, settings, 15.0)

      assert_in_delta evening.cost, night.kwh * 0.15, 1.0e-9

      assert_in_delta Power.charge_year(car, Power.settings(), 15.0).cost,
                      night.kwh * 0.15,
                      1.0e-9

      assert Power.gas_year(car) > night.cost

      # A long charge at night goes past the end of the night: Level 1, 60
      # miles, 14.4 hours from 22:00, 8 of them at night.
      long = %{car | params: %{car.params | "miles" => 60, "charger" => "l1"}}
      charge = Power.charge_year(long, settings, 15.0)
      hours = charge.kwh / 365 / 1.4
      night_part = 8 / hours

      assert_in_delta charge.cost,
                      charge.kwh * (night_part * 5 + (1 - night_part) * 15) / 100,
                      1.0e-6
    end
  end

  # A random average day: the items of a station, the other items, and the
  # sun, in kWh for each hour.
  defp day_input do
    hours = list_of(float(min: 0.0, max: 3.0), length: 24)

    gen all(
          need <- hours,
          other <- hours,
          pv <- hours,
          grid_pv <- hours
        ) do
      %{need: need, other: other, pv_station: pv, pv_grid: grid_pv}
    end
  end

  defp system_gen do
    gen all(
          kwh <- float(min: 0.0, max: 20.0),
          output <- integer(100..10_000),
          charge <- integer(50..5_000)
        ) do
      %{kwh: kwh, output_w: output / 1, charge_w: charge / 1}
    end
  end

  defp settings_gen do
    gen all(
          mode <- member_of(["backup", "night", "solar"]),
          from <- integer(0..23),
          to <- integer(0..23),
          reserve <- integer(0..100)
        ) do
      %{Power.settings() | mode: mode, night_from: from, night_to: to, reserve: reserve}
    end
  end

  property "an average day ends with the charge of its start, and keeps the power in balance" do
    check all(input <- day_input(), sys <- system_gen(), settings <- settings_gen()) do
      day = Power.day(input, sys, settings)
      capacity = sys.kwh * 0.95
      assert Enum.all?(day.soc, &(&1 >= -1.0e-9 and &1 <= capacity + 1.0e-9))
      assert day.day >= 0 and day.night >= 0 and day.export >= 0 and day.lost >= -1.0e-9

      # The day of many days in a row: the charge at its end is the charge
      # at its start.
      assert_in_delta List.last(day.soc), day.start, 1.0e-6

      # The grid gives at least the use, less the sun that is not lost.
      use = Enum.sum(input.need) + Enum.sum(input.other)
      sun = Enum.sum(input.pv_station) + Enum.sum(input.pv_grid)
      assert day.day + day.night - day.export >= use - (sun - day.lost) - 1.0e-6

      # And at most the other items, and the items of the station through
      # the battery (92% in, 92% out).
      assert day.day + day.night <=
               Enum.sum(input.other) + Enum.sum(input.need) / (0.92 * 0.92) + 1.0e-6
    end
  end

  # A large battery in the mode night, with a slow charge: the steady day
  # takes from the grid near the use, not 3 to 11 times more.
  test "a large battery in the mode night finds its steady day" do
    need = List.duplicate(0.05, 24)
    zero = List.duplicate(0.0, 24)
    input = %{need: need, other: zero, pv_station: zero, pv_grid: zero}
    settings = %{Power.settings() | mode: "night"}

    for {kwh, charge} <- [{22.0, 500.0}, {102.0, 1800.0}] do
      day = Power.day(input, %{kwh: kwh, output_w: 3600.0, charge_w: charge}, settings)
      assert day.day + day.night <= 1.2 / (0.92 * 0.92) + 1.0e-6
    end
  end

  property "more battery never gives fewer hours in an outage" do
    check all(
            need <- list_of(float(min: 0.0, max: 2.0), length: 24),
            pv <- list_of(float(min: 0.0, max: 1.0), length: 24),
            kwh <- float(min: 0.1, max: 20.0),
            more <- float(min: 0.0, max: 20.0)
          ) do
      small = Power.outage(need, pv, %{kwh: kwh}, kwh)
      large = Power.outage(need, pv, %{kwh: kwh + more}, kwh + more)

      case {small, large} do
        {nil, nil} -> assert Enum.sum(need) == 0
        {_, :days} -> :ok
        {:days, other} -> flunk("#{inspect(other)}")
        {a, b} -> assert b >= a - 1.0e-9
      end
    end
  end

  test "the least battery for 48 hours: a CPAP needs two nights" do
    need =
      Enum.map(
        Profile.shape(%{type: "cpap", params: %{"hours" => 8.0}}, :other, 0.4),
        &(&1 * 0.4)
      )

    sun = List.duplicate(0.0, 24)
    kwh = Power.kwh_for(need, sun, 48)
    # Two nights of 0.4 kWh, with the losses of the battery.
    assert_in_delta kwh, 0.8 / (Power.usable() * 0.92), 0.001
    assert Power.outage(need, sun, %{kwh: kwh}, kwh * Power.usable()) >= 48
    assert Power.outage(need, sun, %{kwh: kwh * 0.99}, kwh * 0.99 * Power.usable()) < 48
    # A straight line of the hours gives too little.
    hours = Power.outage(need, sun, %{kwh: 0.5}, 0.5 * Power.usable())
    assert 0.5 * 48 / hours < kwh
    assert Power.kwh_for(List.duplicate(0.0, 24), sun, 48) == nil
  end

  test "the shapes of the day" do
    for kind <- DIY.Kinds.house(), part <- [:cooling, :heating, :other] do
      item = %{type: kind.type, params: DIY.Catalog.defaults(kind.type)}
      shape = Profile.shape(item, part, 10.0)
      assert length(shape) == 24
      assert_in_delta Enum.sum(shape), 1.0, 1.0e-9
      assert Enum.all?(shape, &(&1 >= 0))
      assert Profile.watts(item) >= 0
    end

    car = %{type: "ev", params: DIY.Catalog.defaults("ev")}
    night = Profile.shape(car, :other, 14.4, 22)
    assert Enum.at(night, 22) > 0 and Enum.at(night, 23) > 0 and Enum.at(night, 0) == 0
    evening = Profile.shape(%{car | params: %{car.params | "when" => "evening"}}, :other, 7.2, 22)
    assert Enum.at(evening, 18) == 1.0
    assert Profile.shape(car, :other, 0.0) == List.duplicate(1 / 24, 24)
    assert Profile.charge_hours(car, 14.4) == 2.0

    # A CPAP runs for its hours from 22:00. With 24 hours, the shape is
    # flat. With no hours, it uses no power, and the shape is flat too.
    cpap = &Profile.shape(%{type: "cpap", params: %{"hours" => &1}}, :other, 0.4)
    assert Enum.at(cpap.(8.0), 22) == 1 / 8 and Enum.at(cpap.(8.0), 5) == 1 / 8
    assert Enum.at(cpap.(8.0), 6) == 0 and Enum.at(cpap.(8.0), 21) == 0
    assert Enum.at(cpap.(10.5), 7) == 1 / 10.5 and Enum.at(cpap.(10.5), 8) == 0.5 / 10.5
    assert Enum.at(cpap.(10.5), 9) == 0
    assert cpap.(24.0) == List.duplicate(1 / 24, 24)
    assert cpap.(0.0) == List.duplicate(1 / 24, 24)
    assert Profile.charger_kw("l1") == 1.4

    assert_in_delta Profile.day_length(0, 3), 12.0, 0.1
    assert Profile.day_length(33.25, 6) > 14 and Profile.day_length(33.25, 12) < 10.5
    assert Profile.day_length(80, 6) == 24.0 and Profile.day_length(80, 12) == 0.0
    sun = Profile.sun(33.25, 7)
    assert_in_delta Enum.sum(sun), 1.0, 1.0e-9
    assert Enum.at(sun, 2) == 0 and Enum.at(sun, 13) > Enum.at(sun, 9)
    # No sun in the night of the pole.
    assert Profile.sun(80, 12) == List.duplicate(0.0, 24)
  end
end
