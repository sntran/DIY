defmodule DIY.LessonTest do
  use ExUnit.Case, async: true

  alias DIY.{Build, Lesson, Plan, Usage}

  test "the example plan gives the averages of its EFL" do
    plan = Lesson.example_plan()
    assert Plan.check(plan).ok

    year = Lesson.rows(plan, Lesson.example_months())
    assert length(year.rows) == 12
    assert_in_delta year.total, year.rows |> Enum.map(& &1.total) |> Enum.sum(), 1.0e-9
    # The lesson of the example: the year costs more than 11.3¢ for each
    # kWh, because the months under 1,000 kWh get no credit.
    assert year.cents > 11.3
    april = Enum.at(year.rows, 3)
    assert april.credits == 0 and april.cents > 20
  end

  defp bill(kwh), do: %{months: for(m <- 1..12, do: %{month: m, kwh: kwh * m / 1})}

  test "the 12 months of the user: the meter, else the estimate" do
    build = Build.new()
    assert {months, :estimate} = Lesson.months(build, bill(100))
    assert [%{month: 1, name: "January", kwh: 100.0} | _] = months

    months_of = fn count ->
      for m <- 1..count,
          do: %{
            "month" => "2025-#{String.pad_leading("#{m}", 2, "0")}",
            "kwh" => 300,
            "export" => 0,
            "days" => Usage.days_in("2025-#{String.pad_leading("#{m}", 2, "0")}"),
            "hours" => nil
          }
    end

    {:ok, year} = Usage.read(%{"source" => "smt", "months" => months_of.(12)})
    assert {[%{kwh: 300.0} | _], :meter} = Lesson.months(Build.set_usage(build, year), bill(100))

    {:ok, part} = Usage.read(%{"source" => "smt", "months" => months_of.(6)})
    assert {_months, :estimate} = Lesson.months(Build.set_usage(build, part), bill(100))
  end

  test "the exercise: the month with the most use, its parts, and the check" do
    {months, _source} = Lesson.months(Build.new(), bill(100))
    assert %{month: 12} = Lesson.exercise_month(months)

    plan = Lesson.example_plan()
    assert Lesson.parts(plan) == [:energy, :base, :tdu, :credits, :total]
    assert :fee in Lesson.parts(%{plan | min_fee: %{dollars: 5.0, below_kwh: 500}})

    bill = Plan.bill(plan, 1200, 12)

    answers = %{
      "energy" => "$164.40",
      "base" => "9.95",
      "tdu" => "86.47",
      "credits" => "100",
      "total" => "1,000"
    }

    checks = Lesson.check(bill, answers)
    assert checks == %{energy: :ok, base: :ok, tdu: :ok, credits: :ok, total: :wrong}
    refute Lesson.done?(checks)
    assert Lesson.check(bill, %{}, [:total]) == %{total: :empty}

    right = Map.put(answers, "total", :erlang.float_to_binary(bill.total, decimals: 2))
    assert Lesson.done?(Lesson.check(bill, right))

    assert Lesson.dollars(" $1,234.5 ") == 1234.5
    assert Lesson.dollars("ten") == nil
    assert Lesson.dollars(5) == nil
  end

  test "a plan from the form of the worksheet" do
    assert {:ok, plan} =
             Lesson.plan_from_form(%{
               "name" => " Broker plan ",
               "base" => "4.95",
               "energy" => "9.5",
               "tdu_base" => "4.06",
               "tdu_cents" => "6.8673",
               "credit" => "50",
               "credit_kwh" => "1000",
               "fee" => "10",
               "fee_kwh" => "500"
             })

    assert plan.name == "Broker plan"
    assert plan.energy == [{0, 9.5}]
    assert plan.credits == [%{dollars: 50.0, min_kwh: 1000, months: nil}]
    assert plan.min_fee == %{dollars: 10.0, below_kwh: 500}

    # Empty fields are 0: no credit and no fee.
    assert {:ok, %{credits: [], min_fee: nil, base: +0.0}} =
             Lesson.plan_from_form(%{"name" => "Simple", "energy" => "12"})

    assert Lesson.plan_from_form(%{"name" => " "}) == {:error, :name}
    assert Lesson.plan_from_form(%{}) == {:error, :name}
    assert Lesson.plan_from_form(%{"name" => "x", "energy" => "300"}) == {:error, :energy}
    assert Lesson.plan_from_form(%{"name" => "x", "base" => "five"}) == {:error, :base}
    assert Lesson.plan_from_form(%{"name" => "x", "fee_kwh" => "-1"}) == {:error, :fee_kwh}
  end
end
