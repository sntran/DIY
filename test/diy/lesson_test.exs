defmodule DIY.LessonTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Lesson, Plan, Usage}

  test "the example plan gives the averages of its EFL" do
    plan = Lesson.example_plan()
    assert Plan.check(plan).ok

    year = Lesson.rows(plan, Lesson.example_months())
    assert length(year.rows) == 12
    assert_in_delta year.total, year.rows |> Enum.map(& &1.total) |> Enum.sum(), 1.0e-9
    # The months of the example have no range.
    assert year.total_low == year.total and year.total_high == year.total
    # The lesson of the example: the year costs more than 11.3¢ for each
    # kWh, because the months under 1,000 kWh get no credit.
    assert year.cents > 11.3
    april = Enum.at(year.rows, 3)
    assert april.credits == 0 and april.cents > 20
    # April misses the credit of $100. It is not July: the credit of $25
    # is only for July, August and September.
    assert april.missed == 100.0
    # July has 2,050 kWh: it gets both credits.
    assert Enum.at(year.rows, 6).missed == 0.0
    # A July under 1,000 kWh misses both.
    [july] = Lesson.rows(plan, [%{Enum.at(Lesson.example_months(), 6) | kwh: 900.0}]).rows
    assert july.missed == 125.0
  end

  defp bill(kwh) do
    %{
      months:
        for(
          m <- 1..12,
          do: %{month: m, kwh: kwh * m + 0.4, low: kwh * m - 50.6, high: kwh * m + 80.2}
        )
    }
  end

  test "the 12 months of the user: the meter, else the estimate, in whole kWh" do
    build = Build.new()
    assert {months, :estimate} = Lesson.months(build, bill(100))
    assert [%{month: 1, name: "January", kwh: 100.0, low: 49.0, high: 180.0} | _] = months

    months_of = fn count ->
      for m <- 1..count,
          do: %{
            "month" => "2025-#{String.pad_leading("#{m}", 2, "0")}",
            "kwh" => 300.4,
            "export" => 0,
            "days" => Usage.days_in("2025-#{String.pad_leading("#{m}", 2, "0")}")
          }
    end

    {:ok, year} = Usage.read(%{"source" => "smt", "months" => months_of.(12)})

    assert {[%{kwh: 300.0, low: 300.0, high: 300.0} | _], :meter} =
             Lesson.months(Build.set_usage(build, year), bill(100))

    {:ok, part} = Usage.read(%{"source" => "smt", "months" => months_of.(6)})
    assert {_months, :estimate} = Lesson.months(Build.set_usage(build, part), bill(100))
  end

  test "the exercise: the month with the most use, its parts, and the check" do
    {months, _source} = Lesson.months(Build.new(), bill(100))
    assert %{month: 12, kwh: 1200.0} = month = Lesson.exercise_month(months)

    plan = Lesson.example_plan()
    parts = Lesson.parts(plan)
    assert parts == [:energy, :base, :tdu, :credits, :total]
    assert :fee in Lesson.parts(%{plan | min_fee: %{dollars: 5.0, below_kwh: 500}})

    bill = Lesson.bill(plan, month)

    answers = %{
      "energy" => "$164.40",
      "base" => "9.95",
      "tdu" => "86.47",
      "credits" => "−$100",
      "total" => "1,000"
    }

    checks = Lesson.check(bill, answers, parts)
    assert checks == %{energy: :ok, base: :ok, tdu: :ok, credits: :ok, total: :wrong}
    refute Lesson.done?(checks)
    assert Lesson.check(bill, %{}, [:total]) == %{total: :empty}
    assert Lesson.check(bill, %{"total" => " "}, [:total]) == %{total: :empty}
    assert Lesson.check(bill, %{"total" => "about 160"}, [:total]) == %{total: :invalid}
    # A crafted answer that is not text.
    assert Lesson.check(bill, %{"total" => %{"a" => 1}}, [:total]) == %{total: :invalid}
    # A credit with no sign, or with its sign.
    assert Lesson.check(bill, %{"credits" => "100"}, [:credits]) == %{credits: :ok}
    assert Lesson.check(bill, %{"credits" => "-100.00"}, [:credits]) == %{credits: :ok}

    right = Map.put(answers, "total", :erlang.float_to_binary(bill.total, decimals: 2))
    assert Lesson.done?(Lesson.check(bill, right, parts))
  end

  test "the forms of a number of dollars" do
    for {text, value} <- [
          {" $1,234.5 ", 1234.5},
          {"$ 125", 125.0},
          {"−125", -125.0},
          {"−$125", -125.0},
          {"$-125", -125.0},
          {"5.", 5.0},
          {".5", 0.5},
          {"12", 12.0}
        ] do
      assert Lesson.dollars(text) == value, text
    end

    for text <- ["ten", "1,2,3", "12,34", "$", "", "1.2.3", "--5"] do
      assert Lesson.dollars(text) == nil, text
    end

    assert Lesson.dollars(5) == nil
  end

  test "the kWh at night: a whole number, from the house or from the EFL" do
    plan = %{
      Lesson.example_plan()
      | credits: [],
        energy: [{0, 5.79}],
        night: %{cents: 0.0, from: 23, to: 6, share: 0.35}
    }

    month = %{month: 8, name: "August", kwh: 1586.0, low: 1586.0, high: 1586.0}

    house = Lesson.bill(plan, month, 0.078)
    assert house.night_kwh == 124.0 and house.night_from == :house
    assert_in_delta house.energy, (1586 - 124) * 5.79 / 100, 1.0e-9

    efl = Lesson.bill(plan, month)
    assert efl.night_kwh == 555.0 and efl.night_from == :efl

    assert %{night_kwh: nil} = Lesson.bill(Lesson.example_plan(), month)
  end

  test "the range of a bill: the ends of the kWh, and a limit of a credit in it" do
    plan = Lesson.example_plan()
    month = %{month: 4, name: "April", kwh: 980.0, low: 900.0, high: 1100.0}
    [row] = Lesson.rows(plan, [month]).rows

    # At 999 kWh the bill has no credit; at 1,000 kWh it has $100 less.
    no_credit = Plan.bill(plan, 999, 4).total
    with_credit = Plan.bill(plan, 1000, 4).total
    assert row.total_high == no_credit
    assert row.total_low == min(Plan.bill(plan, 900, 4).total, with_credit)
    assert row.total_low <= row.total and row.total <= row.total_high
  end

  # A plan of the form of the lesson: one price, a price at night or none,
  # credits, and a fee.
  defp plan_gen do
    gen all(
          base <- float(min: 0.0, max: 30.0),
          cents <- float(min: 0.0, max: 30.0),
          night <- one_of([constant(nil), float(min: 0.0, max: 10.0)]),
          share <- float(min: 0.0, max: 0.6),
          credits <-
            list_of(
              fixed_map(%{
                dollars: float(min: 0.0, max: 150.0),
                min_kwh: integer(0..2000),
                months: constant(nil)
              }),
              max_length: 2
            ),
          fee <- one_of([constant(nil), float(min: 0.0, max: 15.0)])
        ) do
      %{
        Plan.new("A plan")
        | base: Float.round(base, 2),
          energy: [{0, Float.round(cents, 4)}],
          night: night && %{cents: Float.round(night, 2), from: 22, to: 6, share: share},
          tdu_base: 4.06,
          tdu_cents: 6.8673,
          credits: Enum.map(credits, &%{&1 | dollars: Float.round(&1.dollars, 2)}),
          min_fee: fee && %{dollars: Float.round(fee, 2), below_kwh: 1000}
      }
    end
  end

  # The answers of a user who does the math of the page: the numbers that
  # the page shows (whole kWh, the kWh at night), each part rounded to the
  # cent, and the total from the rounded parts.
  defp page_answers(plan, month, bill) do
    cent = &(Float.round(&1 * 100) / 100)
    [{0, cents}] = plan.energy

    energy =
      if plan.night,
        do:
          cent.(
            (month.kwh - bill.night_kwh) * cents / 100 + bill.night_kwh * plan.night.cents / 100
          ),
        else: cent.(month.kwh * cents / 100)

    tdu = cent.(plan.tdu_base + month.kwh * plan.tdu_cents / 100)

    credits =
      plan.credits
      |> Enum.filter(&(month.kwh >= &1.min_kwh))
      |> Enum.map(& &1.dollars)
      |> Enum.sum()

    fee =
      if plan.min_fee && month.kwh < plan.min_fee.below_kwh, do: plan.min_fee.dollars, else: 0.0

    total = energy + plan.base + tdu - credits + fee

    %{energy: energy, base: plan.base, tdu: tdu, credits: credits, fee: fee, total: total}
  end

  property "an answer from the numbers of the page is right, and one 6 cents off is wrong" do
    check all(
            plan <- plan_gen(),
            kwh <- integer(0..4000),
            share <- one_of([constant(nil), float(min: 0.0, max: 0.6)])
          ) do
      month = %{month: 8, name: "August", kwh: kwh / 1, low: kwh / 1, high: kwh / 1}
      bill = Lesson.bill(plan, month, share)
      parts = Lesson.parts(plan)
      answers = page_answers(plan, month, bill)

      text = fn changes ->
        Map.new(parts, &{Atom.to_string(&1), "#{answers[&1] + (changes[&1] || 0)}"})
      end

      assert Lesson.done?(Lesson.check(bill, text.(%{}), parts))

      for part <- parts do
        assert Lesson.check(bill, text.(%{part => 0.06}), parts)[part] == :wrong
      end
    end
  end

  test "a plan from the form of the worksheet" do
    form = %{
      "name" => " Broker plan ",
      "base" => "4.95",
      "energy" => "9.5",
      "tdu_base" => "4.06",
      "tdu_cents" => "6.8673",
      "credit" => "50",
      "credit_kwh" => "1000",
      "fee" => "10",
      "fee_kwh" => "500"
    }

    assert {:ok, plan} = Lesson.plan_from_form(form, true)
    assert plan.name == "Broker plan"
    assert plan.energy == [{0, 9.5}]
    assert plan.credits == [%{dollars: 50.0, min_kwh: 1000, months: nil}]
    assert plan.min_fee == %{dollars: 10.0, below_kwh: 500}

    # Empty fields are 0: no credit and no fee.
    assert {:ok, %{credits: [], min_fee: nil, base: +0.0}} =
             Lesson.plan_from_form(%{"name" => "Simple", "energy" => "12"}, false)

    # The delivery charges of a utility that the app does not know.
    assert Lesson.plan_from_form(%{form | "tdu_base" => " "}, true) == {:error, :tdu_base}
    assert Lesson.plan_from_form(Map.delete(form, "tdu_cents"), true) == {:error, :tdu_cents}

    # A fee needs its kWh.
    assert Lesson.plan_from_form(%{form | "fee_kwh" => ""}, false) == {:error, :fee_kwh}

    assert Lesson.plan_from_form(%{"name" => " "}, false) == {:error, :name}
    assert Lesson.plan_from_form(%{}, false) == {:error, :name}
    assert Lesson.plan_from_form(%{"name" => "x", "energy" => "300"}, false) == {:error, :energy}
    assert Lesson.plan_from_form(%{"name" => "x", "base" => "five"}, false) == {:error, :base}
    assert Lesson.plan_from_form(%{"name" => "x", "fee_kwh" => "-1"}, false) == {:error, :fee_kwh}
  end
end
