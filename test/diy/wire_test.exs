defmodule DIY.WireTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Wire

  # A wire with nothing that the person has yet.
  defp wire(system, amps, feet, two_way \\ false) do
    %{
      system: system,
      amps: amps / 1,
      feet: feet / 1,
      two_way: two_way,
      awg: nil,
      from_ocpd: nil,
      to_ocpd: nil,
      from_dc: nil,
      to_dc: nil
    }
  end

  @none %{from_min: 0, to_min: 0}

  # The tables of the NEC, written again for the tests. The first is the
  # largest breaker of each size (240.4(B) and (D)). The second is the DC
  # resistance of stranded copper (Chapter 9, Table 8, ohms for 1000 ft).
  @largest Enum.zip(
             ~w(14 12 10 8 6 4 3 2 1 1/0 2/0 3/0 4/0),
             [15, 20, 30, 50, 70, 90, 100, 125, 150, 150, 175, 200, 250]
           )
           |> Map.new()

  @ohms Enum.zip(
          ~w(14 12 10 8 6 4 3 2 1 1/0 2/0 3/0 4/0),
          [
            3.14,
            1.98,
            1.24,
            0.778,
            0.491,
            0.308,
            0.245,
            0.194,
            0.154,
            0.122,
            0.0967,
            0.0766,
            0.0608
          ]
        )
        |> Map.new()

  # The drop of the test: two times the run, at the volts of the system.
  defp drop(awg, amps, feet, system),
    do: amps * @ohms[awg] * 2 * feet / 1000 / String.to_integer(system) * 100

  test "the tables of the NEC" do
    assert Wire.sizes() == ~w(14 12 10 8 6 4 3 2 1 1/0 2/0 3/0 4/0)
    assert Wire.systems() == ~w(12 24 48 120 240)

    # The 75 °C column of Table 310.16, for copper.
    assert Enum.map(Wire.sizes(), &Wire.ampacity/1) ==
             [20, 25, 35, 50, 65, 85, 100, 115, 130, 150, 175, 200, 230]

    # 240.4(D) for small wire, else the ampacity or the next standard
    # rating (240.4(B)).
    assert Map.new(Wire.sizes(), &{&1, Wire.largest(&1)}) == @largest

    # Table 240.6(A), with 10 A (the edition of 2023).
    assert Wire.ratings() ==
             [10, 15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100, 110, 125, 150, 175] ++
               [200, 225, 250, 300, 350, 400, 450, 500, 600, 700, 800, 1000, 1200, 1600] ++
               [2000, 2500, 3000, 4000, 5000, 6000]

    assert Wire.rating(37.5) == 40
    assert Wire.rating(10) == 10
    assert Wire.rating(0.5) == 10
    assert Wire.rating(6000) == 6000
    assert Wire.rating(6001) == nil

    # Chapter 9, Table 8: 12 A on 12 V over 500 ft (1000 ft of copper)
    # drops the resistance of 1000 ft, in percent.
    for awg <- Wire.sizes() do
      assert_in_delta Wire.drop(awg, 12, 500, "12") / 100, @ohms[awg], 1.0e-12, awg
    end

    # 2 × 6 ft of 10 AWG (1.24 ohms for 1000 ft) with 30 A on 12 V: 3.72%.
    assert_in_delta Wire.drop("10", 30, 6, "12"), 3.72, 1.0e-9
    assert_raise ArgumentError, fn -> Wire.ampacity("5") end

    # The systems: the volts, and the cells of a LiFePO4 battery at 3.65 V.
    assert Enum.map(Wire.systems(), &Wire.dc?/1) == [true, true, true, false, false]
    assert Enum.map(Wire.systems(), &Wire.volts/1) == [12, 24, 48, 120, 240]
    assert Enum.map(Wire.systems(), &Wire.cells/1) == [4, 8, 16, nil, nil]
    assert Enum.map(Wire.systems(), &Wire.highest/1) == [14.6, 29.2, 58.4, nil, nil]
  end

  test "the limits of the rules" do
    # 40 A needs 50 A: 8 AWG carries 50 A, and it takes a breaker of 50 A.
    at = wire("120", 40, 6)
    assert %{need: 50.0, from: 50, awg: "8"} = Wire.advise(at, @none)
    assert Wire.check(%{at | awg: "8", from_ocpd: 50}) == []
    assert Wire.check(%{at | awg: "10", from_ocpd: 50}) |> hd() == {:wire_small, nil, 50.0}

    # A breaker at the need is enough. A breaker at the largest of the
    # wire protects it.
    assert Wire.check(%{at | awg: "6", from_ocpd: 50}) == []
    assert Wire.check(%{at | awg: "6", from_ocpd: 49}) == [{:ocpd_small, :from, 50.0}]
    assert Wire.check(%{at | awg: "6", from_ocpd: 70}) == []
    assert Wire.check(%{at | awg: "6", from_ocpd: 80}) == [{:ocpd_big, :from, 70}]

    # A DC rating at the highest volts is enough.
    dc = %{wire("12", 8, 1) | awg: "14", from_ocpd: 10}
    assert Wire.check(%{dc | from_dc: 15}) == []
    assert Wire.check(%{dc | from_dc: 14}) == [{:dc_rating, :from, 14.6}]

    # 10 A on 12 V over 9 ft of 12 AWG drops 2.97%: no fault. Over 9.2 ft,
    # it drops 3.04%: a fault.
    assert Wire.check(%{wire("12", 10, 9) | awg: "12", from_ocpd: 15}) == []
    assert [{:drop, nil, drop}] = Wire.check(%{wire("12", 10, 9.2) | awg: "12", from_ocpd: 15})
    assert_in_delta drop, 3.036, 1.0e-9
  end

  test "the example of the owner: a power station on 48 V to a busbar with MEGA fuses" do
    # The port gives 30 A. The busbar takes no fuse less than 40 A (the
    # smallest MEGA fuse of Victron for 48 V). So the wire must carry 40 A:
    # 8 AWG.
    station = wire("48", 30, 6, true)
    advice = Wire.advise(station, %{from_min: 0, to_min: 40})
    assert %{need: 37.5, from: 40, to: 40, awg: "8", highest: 58.4} = advice
    assert_in_delta advice.drop, drop("8", 30, 6, "48"), 1.0e-12

    # With a fuse of 60 A in the busbar, the wire must carry 60 A: 6 AWG.
    assert %{from: 40, to: 60, awg: "6"} = Wire.advise(station, %{from_min: 0, to_min: 60})

    # The advice passes its own check.
    ok = %{station | awg: "8", from_ocpd: 40, from_dc: 60, to_ocpd: 40, to_dc: 80}
    assert Wire.check(ok) == []

    # A wire of 10 AWG with a breaker of 30 A rated 48 V DC, and a fuse of
    # 40 A at the busbar.
    bad = %{station | awg: "10", from_ocpd: 30, from_dc: 48, to_ocpd: 40, to_dc: 80}

    assert Wire.check(bad) == [
             {:wire_small, nil, 37.5},
             {:ocpd_small, :from, 37.5},
             {:dc_rating, :from, 58.4},
             {:ocpd_big, :to, 30}
           ]

    # The breaker is not known yet: the check names only what it knows.
    assert Wire.check(%{bad | from_ocpd: nil, from_dc: nil, to_ocpd: nil}) == [
             {:wire_small, nil, 37.5},
             {:no_ocpd, :from, nil},
             {:no_ocpd, :to, nil}
           ]

    # A DC rating that is not known gives no fault: the advice tells it.
    assert Wire.check(%{ok | from_dc: nil, to_dc: nil}) == []
  end

  test "a wire with one way, a wire on AC, and the voltage drop" do
    # On AC, the far end has no breaker, and the DC rating does not count.
    inlet = wire("120", 30, 50, true)
    refute Wire.two_way?(inlet)
    advice = Wire.advise(inlet, %{from_min: 0, to_min: 60})
    assert %{from: 40, to: nil, awg: "8", highest: nil} = advice
    assert Wire.check(%{inlet | awg: "8", from_ocpd: 40, from_dc: 1}) == []

    # 100 A on 12 V over 15 ft: 1 AWG carries the current, but its drop is
    # more than 3%. 2/0 has 2.42%.
    long = wire("12", 100, 15)
    assert %{from: 125, to: nil, awg: "2/0"} = Wire.advise(long, @none)
    assert [{:drop, nil, drop}] = Wire.check(%{long | awg: "1", from_ocpd: 125})
    assert_in_delta drop, 3.85, 1.0e-9

    # No wire of 4/0 or less is enough.
    assert %{awg: nil, drop: nil} = Wire.advise(wire("12", 1000, 6), @none)
    assert %{awg: nil} = Wire.advise(wire("12", 30, 500), @none)

    # A small wire: 240.4(D) and a fuse of a busbar at the source end.
    assert %{from: 15, awg: "14"} = Wire.advise(wire("120", 10, 10), @none)
    assert %{from: 60, awg: "6"} = Wire.advise(wire("24", 10, 1), %{from_min: 60, to_min: 0})
  end

  test "the typical numbers of a new wire, and the ends" do
    battery = %{type: "van_battery", params: %{"volts" => "24"}}
    bus = %{type: "dc_bus", params: %{"fuse_min" => 80}}
    station = %{type: "power_station", params: %{}}
    switch = %{type: "transfer_switch", params: %{}}
    inverter = %{type: "inverter", params: %{}}
    shore = %{type: "shore_power", params: %{}}

    assert Wire.defaults(station, battery) == %{
             system: "24",
             amps: 30.0,
             feet: 6.0,
             two_way: true,
             awg: nil,
             from_ocpd: nil,
             to_ocpd: nil,
             from_dc: nil,
             to_dc: nil
           }

    assert %{system: "24", two_way: false} = Wire.defaults(battery, inverter)
    assert %{system: "12", two_way: true} = Wire.defaults(station, bus)
    assert %{system: "120", two_way: false} = Wire.defaults(station, switch)
    assert %{system: "12", two_way: false} = Wire.defaults(bus, inverter)
    # A busbar is on DC: the wire of the charger of a shore power inlet to
    # a busbar has two ways.
    assert %{system: "12", two_way: true} = Wire.defaults(shore, bus)
    assert %{system: "120", two_way: false} = Wire.defaults(shore, inverter)

    # The system from the ends: a battery, else the battery of a busbar,
    # else DC at a busbar.
    bus = Map.put(bus, :id, "i9")
    assert Wire.end_system("120", station, battery, %{}) == "24"
    assert Wire.end_system("12", bus, inverter, %{"i9" => "48"}) == "48"
    # A battery of 24 V on a busbar of 48 V: the higher voltage.
    assert Wire.end_system("24", battery, bus, %{"i9" => "48"}) == "48"
    assert Wire.end_system("24", battery, bus, %{"i9" => "12"}) == "24"
    assert Wire.end_system("120", shore, bus, %{}) == "12"
    assert Wire.end_system("24", shore, bus, %{"i8" => "48"}) == "24"
    assert Wire.end_system("240", station, switch, %{"i9" => "48"}) == "240"

    # The system of a battery at an end.
    assert Wire.battery_system(station, battery) == "24"
    assert Wire.battery_system(battery, inverter) == "24"
    assert Wire.battery_system(station, bus) == nil

    assert Wire.ends(station, bus) == %{from_min: 0, to_min: 80, free: [], bank: nil}
    assert Wire.ends(bus, inverter) == %{from_min: 80, to_min: 0, free: [], bank: nil}
  end

  test "the wire of a bank to a busbar: only its end at the bank needs a breaker" do
    bank = %{id: "b", type: "van_battery", params: %{"volts" => "48"}}
    switch = %{id: "s", type: "battery_switch", params: %{}}
    monitor = %{id: "m", type: "battery_monitor", params: %{}}
    lynx = %{id: "l", type: "dc_bus", params: %{"fuse_min" => 40}}

    fuse = %{fuse: 200, least: 200}
    assert Wire.ends(bank, switch, fuse).free == [:to]
    assert Wire.ends(switch, bank, fuse).free == [:from]
    assert Wire.ends(switch, monitor, fuse).free == [:from, :to]

    assert Wire.ends(monitor, lynx, fuse) == %{
             from_min: 0,
             to_min: 40,
             free: [:from, :to],
             bank: fuse
           }

    # With no battery on the chain, each end needs a breaker.
    assert Wire.ends(switch, monitor) == %{from_min: 0, to_min: 0, free: [], bank: nil}
    # A wire with no switch and no monitor is not on the chain.
    assert Wire.ends(bank, lynx, fuse) == %{from_min: 0, to_min: 40, free: [], bank: nil}

    # The chain of the owner: a class T fuse of 200 A at the bank, wire of
    # 4/0 AWG (230 A), 150 A. The other ends have no fuse: no fault.
    chain = [{bank, switch}, {switch, monitor}, {monitor, lynx}]

    for {from, to} <- chain do
      wire = %{Wire.defaults(from, to) | system: "48", amps: 150.0, feet: 3.0, awg: "4/0"}
      wire = if from.type == "van_battery", do: %{wire | from_ocpd: 200, from_dc: 125}, else: wire
      assert wire.two_way
      ends = Wire.ends(from, to, fuse)
      assert Wire.check(wire, ends) == []

      # The advice asks for a breaker only at the bank.
      advice = Wire.advise(wire, ends)
      assert advice.from == if(from.type == "van_battery", do: 200)
      assert advice.to == nil
      assert advice.awg
      assert advice.bank == 200

      # With no ends, the same wire asks for a breaker at each end.
      assert Enum.any?(Wire.check(wire), &match?({:no_ocpd, _, _}, &1))
    end
  end

  test "each wire of the chain of a bank carries the fuse at the bank" do
    switch = %{id: "s", type: "battery_switch", params: %{}}
    monitor = %{id: "m", type: "battery_monitor", params: %{}}
    station = %{id: "p", type: "power_station", params: %{}}

    # A class T fuse of 250 A, and a wire of 30 A from the switch to the
    # monitor. The advice is a wire that takes 250 A, not 8 AWG (50 A).
    ends = Wire.ends(switch, monitor, %{fuse: 250, least: 40})
    wire = %{Wire.defaults(switch, monitor) | system: "48"}
    advice = Wire.advise(wire, ends)
    assert advice.awg == "4/0"
    assert advice.bank == 250

    # A fuse of 300 A is more than 4/0 AWG takes (250 A): no single wire.
    assert Wire.advise(wire, Wire.ends(switch, monitor, %{fuse: 300, least: 40})).awg == nil

    # A wire of 10 AWG (30 A at most) at 20 A: the fuse does not protect it.
    thin = %{wire | amps: 20.0, awg: "10"}
    assert Wire.check(thin, ends) == [{:bank_big, nil, 250}]
    assert Wire.check(%{thin | awg: "4/0"}, ends) == []
    # With no wire size, there is nothing to check.
    assert Wire.check(%{thin | awg: nil}, ends) == []

    # With no fuse at the bank yet, the advice uses the smallest fuse for
    # the wire of the bank, and the check waits for the fuse.
    ends = Wire.ends(switch, monitor, %{fuse: nil, least: 200})
    assert Wire.advise(wire, ends).awg == "3/0"
    assert Wire.check(thin, ends) == []

    # A station wired only to a switch: no battery on the chain, so the
    # wire needs its breakers.
    ends = Wire.ends(station, switch)
    assert Wire.advise(wire, ends).from == 40
    assert {:no_ocpd, :from, nil} in Wire.check(thin, ends)
  end

  property "a wire of the chain of a bank carries the fuse at the bank" do
    check all(
            fuse <- member_of(Wire.ratings() |> Enum.filter(&(&1 <= 400))),
            least <- member_of([30, 100, 200]),
            known <- boolean(),
            amps <- integer(1..150),
            awg <- member_of(Wire.sizes())
          ) do
      switch = %{id: "s", type: "battery_switch", params: %{}}
      monitor = %{id: "m", type: "battery_monitor", params: %{}}
      bank = %{fuse: if(known, do: fuse), least: least}
      ends = Wire.ends(switch, monitor, bank)
      wire = %{Wire.defaults(switch, monitor) | system: "48", amps: amps / 1, feet: 3.0}

      advice = Wire.advise(wire, ends)
      guard = if known, do: fuse, else: least
      assert advice.bank == guard
      assert advice.awg == nil or Wire.largest(advice.awg) >= guard

      faults = Wire.check(%{wire | awg: awg}, ends)
      assert {:bank_big, nil, fuse} in faults == (known and fuse > Wire.largest(awg))
      refute Enum.any?(faults, &match?({:no_ocpd, _, _}, &1))
    end
  end

  test "the numbers of a wire from a form or from JSON" do
    base = wire("12", 30, 6)

    assert Wire.read(%{}, base) == {:ok, base}

    assert {:ok, read} =
             Wire.read(
               %{
                 "system" => "48",
                 "amps" => " 27.5 ",
                 "feet" => 10,
                 "two_way" => "true",
                 "awg" => "1/0",
                 "from_ocpd" => "40",
                 "to_ocpd" => 60,
                 "from_dc" => "",
                 "to_dc" => nil
               },
               base
             )

    assert read == %{
             base
             | system: "48",
               amps: 27.5,
               feet: 10.0,
               two_way: true,
               awg: "1/0",
               from_ocpd: 40,
               to_ocpd: 60
           }

    assert {:ok, %{two_way: false, awg: nil}} =
             Wire.read(%{"two_way" => false, "awg" => " "}, %{read | two_way: true})

    assert {:ok, %{two_way: false}} = Wire.read(%{"two_way" => "false"}, read)

    # The highest numbers, and a text of 32 bytes.
    assert {:ok, %{feet: 500.0, to_ocpd: 2000, to_dc: 1500, amps: 27.5}} =
             Wire.read(
               %{
                 "feet" => "500",
                 "to_ocpd" => "2000",
                 "to_dc" => "1500",
                 "amps" => String.pad_leading("27.5", 32)
               },
               base
             )

    # The first number that is not valid.
    for {values, key} <- [
          {%{"system" => "36"}, :system},
          {%{"system" => 12}, :system},
          {%{"amps" => "0"}, :amps},
          {%{"amps" => "1001"}, :amps},
          {%{"amps" => "abc"}, :amps},
          {%{"amps" => "1e400"}, :amps},
          {%{"amps" => nil}, :amps},
          {%{"feet" => 0.5}, :feet},
          {%{"feet" => "500.1"}, :feet},
          {%{"amps" => String.duplicate("1", 33)}, :amps},
          {%{"amps" => String.pad_leading("27.5", 33)}, :amps},
          {%{"amps" => "0." <> String.duplicate("1", 31)}, :amps},
          {%{"two_way" => "yes"}, :two_way},
          {%{"awg" => "5"}, :awg},
          {%{"from_ocpd" => "40.5"}, :from_ocpd},
          {%{"from_ocpd" => 2001}, :from_ocpd},
          {%{"to_ocpd" => 0}, :to_ocpd},
          {%{"to_ocpd" => "2001"}, :to_ocpd},
          {%{"from_dc" => "1501"}, :from_dc},
          {%{"to_dc" => 48.0}, :to_dc},
          {%{"amps" => "0", "feet" => "0"}, :amps}
        ] do
      assert Wire.read(values, base) == {:error, key}, inspect(values)
    end
  end

  # The numbers of a wire in their ranges, with what the person has.
  defp wires do
    gen all(
          system <- member_of(Wire.systems()),
          amps <- float(min: 1.0, max: 1000.0),
          feet <- float(min: 1.0, max: 500.0),
          two_way <- boolean(),
          from_min <- member_of([0, 0, 40, 60, 125]),
          to_min <- member_of([0, 0, 40, 60, 125, 2000])
        ) do
      {wire(system, amps, feet, two_way), %{from_min: from_min, to_min: to_min}}
    end
  end

  property "the advice meets the rules, and it is the smallest wire that does" do
    check all({wire, ends} <- wires()) do
      advice = Wire.advise(wire, ends)
      assert advice.from >= advice.need and advice.from >= ends.from_min
      assert advice.from in Wire.ratings()
      assert Wire.two_way?(wire) == (advice.to != nil)
      if advice.to, do: assert(advice.to >= advice.need and advice.to >= ends.to_min)

      fits? = fn awg ->
        Wire.ampacity(awg) >= advice.need and Wire.largest(awg) >= advice.from and
          Wire.largest(awg) >= (advice.to || 0) and
          Wire.drop(awg, wire.amps, wire.feet, wire.system) <= 3.0
      end

      case advice.awg do
        nil ->
          refute Enum.any?(Wire.sizes(), fits?)

        awg ->
          assert fits?.(awg)
          smaller = Enum.take_while(Wire.sizes(), &(&1 != awg))
          refute Enum.any?(smaller, fits?)

          # What the person has, as the advice says: no fault.
          dc = advice.highest && ceil(advice.highest)

          has = %{
            wire
            | awg: awg,
              from_ocpd: advice.from,
              to_ocpd: advice.to,
              from_dc: dc,
              to_dc: dc
          }

          assert Wire.check(has) == []
      end
    end
  end

  property "more current never gives a smaller wire or a smaller breaker" do
    index = fn awg -> Enum.find_index(Wire.sizes(), &(&1 == awg)) || 99 end

    check all(
            {wire, ends} <- wires(),
            more <- float(min: 0.0, max: 500.0)
          ) do
      a = Wire.advise(wire, ends)
      b = Wire.advise(%{wire | amps: min(wire.amps + more, 1000.0)}, ends)
      assert index.(a.awg) <= index.(b.awg)
      assert a.from <= b.from
    end
  end

  property "a fault for each rule that the numbers break" do
    check all(
            {wire, _ends} <- wires(),
            awg <- one_of([constant(nil), member_of(Wire.sizes())]),
            from_ocpd <- one_of([constant(nil), integer(1..400)]),
            to_ocpd <- one_of([constant(nil), integer(1..400)]),
            from_dc <- one_of([constant(nil), integer(1..100)]),
            to_dc <- one_of([constant(nil), integer(1..100)])
          ) do
      has = %{
        wire
        | awg: awg,
          from_ocpd: from_ocpd,
          to_ocpd: to_ocpd,
          from_dc: from_dc,
          to_dc: to_dc
      }

      faults = Wire.check(has)
      need = wire.amps * 1.25
      ends = if Wire.two_way?(wire), do: [:from, :to], else: [:from]
      ocpd = %{from: from_ocpd, to: to_ocpd}
      dc = %{from: from_dc, to: to_dc}
      highest = Wire.highest(wire.system)

      expected =
        Enum.filter(
          [awg && Wire.ampacity(awg) < need && {:wire_small, nil, need}] ++
            Enum.flat_map(ends, fn side ->
              cond do
                is_nil(ocpd[side]) and awg != nil ->
                  [{:no_ocpd, side, nil}]

                is_nil(ocpd[side]) ->
                  []

                true ->
                  [
                    ocpd[side] < need && {:ocpd_small, side, need},
                    awg && ocpd[side] > @largest[awg] && {:ocpd_big, side, @largest[awg]},
                    highest && dc[side] && dc[side] < highest && {:dc_rating, side, highest}
                  ]
              end
            end) ++
            [
              awg && drop(awg, wire.amps, wire.feet, wire.system) > 3.0 &&
                {:drop, nil, drop(awg, wire.amps, wire.feet, wire.system)}
            ],
          & &1
        )

      # The drop of the app and of the test can differ in the last bit.
      assert length(faults) == length(expected)

      for {fault, model} <- Enum.zip(faults, expected) do
        case {fault, model} do
          {{:drop, nil, a}, {:drop, nil, b}} -> assert_in_delta a, b, 1.0e-9
          _other -> assert fault == model
        end
      end
    end
  end

  property "the numbers of a wire read back from their text" do
    check all({wire, _ends} <- wires(), awg <- one_of([constant(nil), member_of(Wire.sizes())])) do
      wire = %{wire | awg: awg, from_ocpd: 40, to_dc: 58}

      text =
        Map.new(wire, fn
          {key, nil} -> {Atom.to_string(key), ""}
          {key, value} -> {Atom.to_string(key), to_string(value)}
        end)

      assert Wire.read(text, wire(hd(Wire.systems()), 1, 1)) == {:ok, wire}
      assert Wire.read(Jason.decode!(Jason.encode!(wire)), wire("12", 1, 1)) == {:ok, wire}
    end
  end
end
