defmodule DIYWeb.PlanChartTest do
  use ExUnit.Case, async: true

  alias DIY.Plan
  alias DIYWeb.PlanChart

  defp credit_plan do
    %{
      Plan.new("8.9¢ with a $125 credit")
      | energy: [{0, 14.4}],
        tdu_base: 4.9,
        tdu_cents: 6.5333,
        credits: [%{dollars: 125.0, min_kwh: 1000, months: nil}],
        min_fee: %{dollars: 4.99, below_kwh: 400}
    }
  end

  defp flat_plan,
    do: %{
      Plan.new("14.9¢ with no credit")
      | energy: [{0, 7.88}],
        tdu_base: 4.9,
        tdu_cents: 6.5333
    }

  test "the line of a plan drops at its credit and jumps at its fee" do
    points = Map.new(PlanChart.points(credit_plan()))
    assert {200, 2500} == PlanChart.range()
    assert points |> Map.keys() |> Enum.min() == 200
    assert points |> Map.keys() |> Enum.max() == 2500

    # 999 kWh pays no credit: 21.4¢. 1,000 kWh gets $125 back: 8.9¢.
    assert_in_delta points[999], 21.42, 0.01
    assert_in_delta points[1000], 8.92, 0.01
    # Under 400 kWh, the fee of $4.99 adds 1.25¢ at 399 kWh.
    assert_in_delta points[399] - points[400], 1.25, 0.01

    assert PlanChart.limits(credit_plan()) == [400, 1000]
    assert PlanChart.limits(flat_plan()) == []
    # A credit of each month (0 kWh) has no limit.
    each = %{flat_plan() | credits: [%{dollars: 5.0, min_kwh: 0, months: nil}]}
    assert PlanChart.limits(each) == []
    # A limit out of the chart adds no point.
    far = %{flat_plan() | credits: [%{dollars: 5.0, min_kwh: 3000, months: nil}]}
    assert length(PlanChart.points(far)) == length(PlanChart.points(flat_plan()))
  end

  test "the table has 500 to 2,000 kWh and the kWh at each limit" do
    assert PlanChart.table_kwh([flat_plan()]) == [500, 1000, 1500, 2000]

    assert PlanChart.table_kwh([credit_plan(), flat_plan()]) == [
             399,
             400,
             500,
             999,
             1000,
             1500,
             2000
           ]
  end

  test "the chart of a page: a line for each plan, and a dot for each month" do
    months = [
      %{name: "January", kwh: 399.0},
      %{name: "July", kwh: 1545.0},
      %{name: "Big", kwh: 4000.0}
    ]

    svg = PlanChart.svg([credit_plan(), flat_plan()], months, "test")

    assert svg =~ ~s(<svg viewBox="0 0 480 300")
    assert svg =~ ~s(<clipPath id="pc-clip-test">)
    assert [_, _] = Regex.scan(~r/<polyline /, svg)
    assert svg =~ ~s(class="pc-line pc-1" stroke-dasharray="")
    assert svg =~ ~s(class="pc-line pc-2" stroke-dasharray="9 5")
    # A month out of the chart has no dot.
    assert [_, _] = Regex.scan(~r/<circle /, svg)
    assert svg =~ "<title>July: 1,545 kWh</title>"
    # The page gives the colors: the chart has none.
    refute svg =~ "#2a78d6"
    # The prices are up to 30¢ (the highest is 25.9¢ at 200 kWh), each 5¢.
    assert svg =~ ">30¢</text>"
    refute svg =~ ">35¢</text>"
    assert svg =~ ~s(text-anchor="end" class="pc-text">2,500</text>)
  end

  test "the top of the chart is 60¢ at most, each 10¢ above 30¢" do
    high = %{flat_plan() | base: 200.0}
    svg = PlanChart.svg([high], [], "high")
    assert svg =~ ">60¢</text>"
    assert svg =~ ">10¢</text>"
    refute svg =~ ">5¢</text>"

    # A low price still has a chart of 10¢.
    low = %{flat_plan() | energy: [{0, 0.0}], tdu_base: 0.0, tdu_cents: 1.0}
    assert PlanChart.svg([low], [], "low") =~ ">10¢</text>"
  end

  test "the picture of a link: the title, the chart and a key with the names" do
    svg = PlanChart.picture([credit_plan(), flat_plan()])
    assert svg =~ ~s(width="1200" height="630")
    assert svg =~ "The price for each kWh of 2 plans"
    assert svg =~ "8.9¢ with a $125 credit"
    assert svg =~ ~s(stroke="#2a78d6" stroke-dasharray="")
    assert svg =~ ~s(stroke="#eb6834" stroke-dasharray="9 5")
    refute svg =~ "class="

    assert PlanChart.picture([flat_plan()]) =~ "The price for each kWh of a plan"
    assert PlanChart.title([flat_plan()]) == "A plan: the price for each kWh at each use"

    assert PlanChart.title([flat_plan(), flat_plan()]) ==
             "2 plans: the price for each kWh at each use"

    # A long name is cut. A name is text: its marks are escaped.
    long = %{flat_plan() | name: "A plan <b>with</b> a very long name that does not fit"}
    svg = PlanChart.picture([long])
    assert svg =~ ">A plan &lt;b&gt;with&lt;/b&gt; a ve…<"
    refute svg =~ "<b>"
    # A name of wide letters is cut too.
    assert PlanChart.picture([%{flat_plan() | name: String.duplicate("W", 60)}]) =~ "…"

    # Six plans: the key has two rows of three.
    six = for n <- 1..6, do: %{flat_plan() | name: "Plan #{n}"}
    svg = PlanChart.picture(six)
    assert svg =~ ~s(stroke="#008300" stroke-dasharray="14 3 2 3 2 3")
    assert svg =~ ~s(<text x="826" y="598")
  end

  test "the picture is a PNG" do
    assert {:ok, <<0x89, "PNG", _rest::binary>>} = PlanChart.png([credit_plan()])
  end
end
