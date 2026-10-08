defmodule DIY.PlanTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Plan

  defp plan(changes \\ %{}) do
    Map.merge(
      %{Plan.new("A plan") | base: 9.95, energy: [{0, 10.0}], tdu_base: 4.06, tdu_cents: 6.8673},
      changes
    )
  end

  test "the parts of a bill" do
    bill = Plan.bill(plan(), 1000)
    assert_in_delta bill.energy, 100.0, 1.0e-9
    assert_in_delta bill.tdu, 4.06 + 68.673, 1.0e-9
    assert bill.base == 9.95 and bill.credits == 0 and bill.fee == 0.0
    assert_in_delta bill.total, 9.95 + 100 + 72.733, 1.0e-9
    assert_in_delta bill.cents, bill.total / 10, 1.0e-9
    assert Plan.bill(plan(), 0).cents == nil

    # Delivery charges that the plan does not have count as 0.
    assert Plan.bill(plan(%{tdu_base: nil, tdu_cents: nil}), 100).tdu == 0.0
  end

  test "tiers, the night, credits and a minimum usage fee" do
    tiers = plan(%{energy: [{0, 0.0}, {1000, 14.0}, {1500, 20.0}]})
    assert_in_delta Plan.bill(tiers, 800).energy, 0.0, 1.0e-9
    assert_in_delta Plan.bill(tiers, 1200).energy, 28.0, 1.0e-9
    assert_in_delta Plan.bill(tiers, 2000).energy, 70.0 + 100.0, 1.0e-9

    night = plan(%{night: %{cents: 0.0, from: 23, to: 6, share: 0.35}})
    assert_in_delta Plan.bill(night, 1000).energy, 65.0, 1.0e-9
    assert_in_delta Plan.bill(night, 1000, 7, 0.5).energy, 50.0, 1.0e-9

    credits =
      plan(%{
        credits: [
          %{dollars: 100.0, min_kwh: 1000, months: nil},
          %{dollars: 24.0, min_kwh: 1000, months: [7, 8, 9]}
        ]
      })

    assert Plan.bill(credits, 999).credits == 0
    assert Plan.bill(credits, 1000, 1).credits == 100.0
    assert Plan.bill(credits, 1000, 8).credits == 124.0
    # An average month of an EFL spreads the credit of 3 months.
    assert Plan.bill(credits, 1000).credits == 106.0

    fee = plan(%{min_fee: %{dollars: 9.95, below_kwh: 1000}})
    assert Plan.bill(fee, 999).fee == 9.95
    assert Plan.bill(fee, 1000).fee == 0.0
  end

  test "the check of the averages of an EFL" do
    # 500 kWh: $9.95 + $50 + $4.06 + $34.34 = $98.35, 19.67¢.
    good = plan(%{averages: %{500 => 19.7, 1000 => 18.3, 2000 => 17.6}})
    assert %{ok: true, rows: [%{kwh: 500, ok: true} | _]} = Plan.check(good)

    bad = plan(%{averages: %{500 => 19.7, 1000 => 18.3, 2000 => 12.0}})
    assert %{ok: false} = Plan.check(bad)
  end

  # Averages as an EFL gives them: rounded to 0.1¢.
  defp averages(plan) do
    Map.new([500, 1000, 2000], &{&1, Float.round(Plan.bill(plan, &1).cents, 1)})
  end

  property "the delivery charges from the averages give the averages back" do
    check all(
            base <- float(min: 0.0, max: 20.0),
            energy <- float(min: 2.0, max: 20.0),
            tdu_base <- float(min: 0.0, max: 10.0),
            tdu_cents <- float(min: 0.0, max: 10.0)
          ) do
      truth = plan(%{base: base, energy: [{0, energy}], tdu_base: tdu_base, tdu_cents: tdu_cents})
      efl = %{truth | tdu_base: nil, tdu_cents: nil, averages: averages(truth)}

      case Plan.fit_tdu(efl) do
        # The averages are round numbers: a charge can come a little under 0.
        nil ->
          assert tdu_base < 0.6 or tdu_cents < 0.1

        # The fit gives the averages at 500 and 2,000 kWh. At 1,000 kWh,
        # the error of the two round averages adds to the error of the
        # third.
        fitted ->
          [r500, r1000, r2000] = Plan.check(fitted).rows
          assert r500.ok and r2000.ok
          assert abs(r1000.app - r1000.efl) <= 0.1 + 1.0e-6
      end
    end
  end

  # A plan of any form: tiers, the night, credits of some months, and a
  # minimum usage fee.
  defp any_plan do
    gen all(
          base <- float(min: 0.0, max: 50.0),
          cents <- list_of(float(min: 0.0, max: 50.0), min_length: 1, max_length: 4),
          night <- one_of([constant(nil), float(min: 0.0, max: 30.0)]),
          share <- float(min: 0.0, max: 1.0),
          credits <-
            list_of(
              fixed_map(%{
                dollars: float(min: 0.0, max: 200.0),
                min_kwh: integer(0..2500),
                months:
                  one_of([
                    constant(nil),
                    map(list_of(integer(1..12), min_length: 1), &Enum.uniq/1)
                  ])
              }),
              max_length: 3
            ),
          fee <- one_of([constant(nil), float(min: 0.0, max: 20.0)])
        ) do
      energy = cents |> Enum.with_index() |> Enum.map(fn {c, i} -> {i * 500, c} end)

      plan(%{
        base: base,
        energy: energy,
        night: night && %{cents: night, from: 23, to: 6, share: share},
        credits: credits,
        min_fee: fee && %{dollars: fee, below_kwh: 1000}
      })
    end
  end

  property "the parts of a bill give its total, and more kWh never cost less energy" do
    check all(plan <- any_plan(), kwh <- integer(0..5000), more <- integer(0..1000)) do
      for month <- [nil | Enum.to_list(1..12)] do
        bill = Plan.bill(plan, kwh, month)

        assert_in_delta bill.total,
                        bill.base + bill.energy + bill.tdu - bill.credits + bill.fee,
                        1.0e-6

        assert Plan.bill(plan, kwh + more, month).energy >= bill.energy - 1.0e-9
      end

      # An average month of an EFL: the mean credit of the 12 months.
      mean = Enum.sum(for m <- 1..12, do: Plan.bill(plan, kwh, m).credits) / 12
      assert_in_delta Plan.bill(plan, kwh).credits, mean, 1.0e-6
    end
  end

  test "averages that no delivery charges can give" do
    efl =
      plan(%{tdu_base: nil, tdu_cents: nil, averages: %{500 => 1.0, 1000 => 1.0, 2000 => 1.0}})

    assert Plan.fit_tdu(efl) == nil
  end

  test "the delivery charges of a utility" do
    assert %{name: "Oncor", base: 4.06, cents: 6.8673} = Plan.tdu("ONCOR ELECTRIC DELIVERY")
    assert Plan.tdu("AEP Texas") == nil
  end

  defp stored(changes \\ %{}) do
    plan(
      Map.merge(
        %{
          id: "p1",
          night: %{cents: 1.5, from: 23, to: 6, share: 0.35},
          credits: [%{dollars: 25.0, min_kwh: 1000, months: [7, 8]}],
          min_fee: %{dollars: 5.0, below_kwh: 500},
          averages: %{500 => 20.0, 1000 => 15.0, 2000 => 14.0}
        },
        changes
      )
    )
  end

  property "to_map and read give the same plan" do
    check all(
            base <- float(min: 0.0, max: 100.0),
            cents <- list_of(float(min: 0.0, max: 50.0), min_length: 1, max_length: 4),
            night <- boolean()
          ) do
      energy = cents |> Enum.with_index() |> Enum.map(fn {c, i} -> {i * 500, c} end)
      plan = stored(%{base: base, energy: energy, night: if(night, do: stored().night)})
      json = plan |> Plan.to_map() |> Jason.encode!() |> Jason.decode!()
      assert Plan.read(json) == {:ok, plan}
    end
  end

  test "read refuses a plan that it cannot read in full" do
    good = stored() |> Plan.to_map() |> Jason.encode!() |> Jason.decode!()
    plain = stored(%{night: nil, min_fee: nil, averages: nil, tdu_base: nil, tdu_cents: nil})
    assert {:ok, _} = Plan.read(plain |> Plan.to_map() |> Jason.encode!() |> Jason.decode!())

    for {key, value} <- [
          {"id", 5},
          {"id", String.duplicate("p", 21)},
          {"name", ""},
          {"name", String.duplicate("n", 61)},
          {"base", -1},
          {"base", 10 ** 400},
          {"energy", []},
          {"energy", [[1, 10.0]]},
          {"energy", [[0, 10.0], [0, 12.0]]},
          {"energy", [[0, 10.0], [1000, 12.0], [500, 11.0]]},
          {"energy", [[0, 300]]},
          {"energy", [[0, 10.0], [-1, 1.0]]},
          {"energy", [[0, 10.0], "tier"]},
          {"energy", List.duplicate([0, 1.0], 11)},
          {"night", %{"cents" => 1, "from" => 24, "to" => 6, "share" => 0.3}},
          {"night", %{"cents" => -1, "from" => 23, "to" => 6, "share" => 0.3}},
          {"night", "nights"},
          {"tdu_base", "4.06"},
          {"tdu_cents", 300},
          {"credits", "none"},
          {"credits", [%{"dollars" => 1}]},
          {"credits", [%{"dollars" => 1, "min_kwh" => 1.5}]},
          {"credits", [%{"dollars" => 1, "min_kwh" => 0, "months" => [13]}]},
          {"credits", [%{"dollars" => 1, "min_kwh" => 0, "months" => [7, 7]}]},
          {"credits", [%{"dollars" => 1, "min_kwh" => 0, "months" => []}]},
          {"credits", List.duplicate(%{"dollars" => 1, "min_kwh" => 0}, 11)},
          {"min_fee", %{"dollars" => 5}},
          {"min_fee", %{"dollars" => -5, "below_kwh" => 500}},
          {"averages", %{"500" => 1}},
          {"averages", %{"500" => 1, "1000" => 1, "2000" => -1}}
        ] do
      assert Plan.read(Map.put(good, key, value)) == :error, inspect({key, value})
    end

    assert Plan.read("plan") == :error
  end
end
