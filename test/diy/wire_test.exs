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

  test "the tables of the NEC" do
    assert Wire.sizes() == ~w(14 12 10 8 6 4 3 2 1 1/0 2/0 3/0 4/0)
    assert Wire.systems() == ~w(12 24 48 120 240)

    # The 75 °C column of Table 310.16, for copper.
    assert Enum.map(Wire.sizes(), &Wire.ampacity/1) ==
             [20, 25, 35, 50, 65, 85, 100, 115, 130, 150, 175, 200, 230]

    # 240.4(D) for small wire, else the ampacity or the next standard
    # rating (240.4(B)).
    assert Enum.map(Wire.sizes(), &Wire.largest/1) ==
             [15, 20, 30, 50, 70, 90, 100, 125, 150, 150, 175, 200, 250]

    # Table 240.6(A).
    assert Wire.rating(37.5) == 40
    assert Wire.rating(10) == 10
    assert Wire.rating(0.5) == 10
    assert Wire.rating(6000) == 6000
    assert Wire.rating(6001) == nil

    assert Wire.dc?("48") and not Wire.dc?("120")
    assert Wire.volts("24") == 24
    assert Wire.highest("12") == 14.6
    assert Wire.highest("48") == 58.4
    assert Wire.highest("240") == nil

    # 2 × 6 ft of 10 AWG (1.24 ohms for 1000 ft) with 30 A on 12 V: 3.72%.
    assert_in_delta Wire.drop("10", 30, 6, "12"), 3.72, 1.0e-9
    assert_raise ArgumentError, fn -> Wire.ampacity("5") end
  end

  test "the example of the owner: a power station on 48 V to a busbar with MEGA fuses" do
    # The port gives 30 A. The busbar takes no fuse less than 60 A (the
    # smallest MEGA fuse for 48 V). So the wire must carry 60 A: 6 AWG.
    station = wire("48", 30, 6, true)
    advice = Wire.advise(station, %{from_min: 0, to_min: 60})
    assert %{need: 37.5, from: 40, to: 60, awg: "6", highest: 58.4} = advice
    assert_in_delta advice.drop, Wire.drop("6", 30, 6, "48"), 1.0e-12

    # The advice passes its own check.
    ok = %{station | awg: "6", from_ocpd: 40, from_dc: 60, to_ocpd: 60, to_dc: 80}
    assert Wire.check(ok) == []

    # A wire of 10 AWG with a breaker of 30 A rated 48 V DC, and a fuse of
    # 60 A at the busbar.
    bad = %{station | awg: "10", from_ocpd: 30, from_dc: 48, to_ocpd: 60, to_dc: 80}

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

    assert %{system: "24", amps: 30.0, feet: 6.0, two_way: true, awg: nil} =
             Wire.defaults(station, battery)

    assert %{system: "24", two_way: false} = Wire.defaults(battery, inverter)
    assert %{system: "12", two_way: true} = Wire.defaults(station, bus)
    assert %{system: "120", two_way: false} = Wire.defaults(station, switch)
    assert %{system: "12", two_way: false} = Wire.defaults(bus, inverter)

    assert Wire.ends(station, bus) == %{from_min: 0, to_min: 80}
    assert Wire.ends(bus, inverter) == %{from_min: 80, to_min: 0}
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
          {%{"two_way" => "yes"}, :two_way},
          {%{"awg" => "5"}, :awg},
          {%{"from_ocpd" => "40.5"}, :from_ocpd},
          {%{"from_ocpd" => 2001}, :from_ocpd},
          {%{"to_ocpd" => 0}, :to_ocpd},
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
          from_min <- member_of([0, 0, 60, 125]),
          to_min <- member_of([0, 0, 60, 125, 2000])
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
                    awg && ocpd[side] > Wire.largest(awg) &&
                      {:ocpd_big, side, Wire.largest(awg)},
                    highest && dc[side] && dc[side] < highest && {:dc_rating, side, highest}
                  ]
              end
            end) ++
            [
              awg && Wire.drop(awg, wire.amps, wire.feet, wire.system) > 3.0 &&
                {:drop, nil, Wire.drop(awg, wire.amps, wire.feet, wire.system)}
            ],
          & &1
        )

      assert faults == expected
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
