defmodule DIY.MarketTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Market, Stubs}

  @today ~D[2026-10-08]

  test "a ZIP code with plans has retail choice, a utility and a median price" do
    Stubs.market()
    assert {:ok, market} = Market.fetch("75070", @today)

    assert %{choice: true, utility: "Oncor", plans: 168, date: "2026-10-08", source: "ptc"} =
             market

    assert market.median > 5 and market.median < 30
  end

  test "a ZIP code with no plans has no retail choice" do
    Stubs.market(%{"success" => true, "data" => []})

    assert {:ok, %{choice: false, utility: nil, median: nil, plans: 0}} =
             Market.fetch("78701", @today)
  end

  test "an unknown utility keeps its name, in title case" do
    plans = [%{"company_tdu_name" => "NEW TEXAS POWER", "price_kwh1000" => 12}, "junk"]

    assert {:ok, %{utility: "New Texas Power", median: 12.0, plans: 1}} =
             Market.parse(%{"success" => true, "data" => plans}, @today)
  end

  test "the errors of the service" do
    Stubs.market(500)
    assert Market.fetch("75001", @today) == {:error, "Power to Choose answered 500."}
    Stubs.market(:down)
    assert {:error, "Power to Choose did not answer" <> _} = Market.fetch("75002", @today)
    Stubs.market(%{"success" => false})

    assert Market.fetch("75006", @today) ==
             {:error, "Power to Choose gave an answer that the app cannot read."}
  end

  test "the median" do
    assert Market.median([]) == nil
    assert Market.median([3.0, 1.0, 2.0]) == 2.0
    assert Market.median([4.0, 1.0, 2.0, 3.0]) == 2.5
  end

  property "the median is between the smallest and the largest value" do
    check all(values <- list_of(float(min: 0.0, max: 100.0), min_length: 1)) do
      median = Market.median(values)
      assert median >= Enum.min(values) and median <= Enum.max(values)
    end
  end

  test "the user can say that the area has no retail choice, or has it" do
    oncor = %{
      choice: true,
      utility: "Oncor",
      median: 13.4,
      plans: 168,
      date: "2026-10-08",
      source: "ptc"
    }

    assert %{choice: false, utility: nil, median: nil, source: "user", plans: 168} =
             Market.by_user(oncor, false, @today)

    assert %{choice: true, utility: "Oncor", median: 13.4, source: "user"} =
             Market.by_user(oncor, true, @today)

    assert %{choice: true, utility: nil, median: nil, plans: 0} =
             Market.by_user(nil, true, @today)
  end

  test "a market of Power to Choose gets old after 7 days; a market of the user does not" do
    today = ~D[2026-10-28]
    market = fn date, source -> %{date: Date.to_iso8601(date), source: source} end

    refute Market.old?(market.(today, "ptc"), today)
    refute Market.old?(market.(Date.add(today, -6), "ptc"), today)
    assert Market.old?(market.(Date.add(today, -7), "ptc"), today)
    assert Market.old?(market.(Date.add(today, -400), "ptc"), today)
    refute Market.old?(market.(Date.add(today, -400), "user"), today)
    refute Market.old?(market.(Date.utc_today(), "ptc"))
  end

  property "a market is old from its seventh day" do
    check all(days <- integer(-30..400)) do
      today = ~D[2026-10-28]
      market = %{date: Date.to_iso8601(Date.add(today, -days)), source: "ptc"}
      assert Market.old?(market, today) == days >= 7
    end
  end

  test "from_map reads a stored market, and refuses a bad one" do
    good = %{
      "choice" => true,
      "utility" => "Oncor",
      "median" => 13,
      "plans" => 3,
      "date" => "2026-10-08",
      "source" => "ptc"
    }

    assert {:ok, %{median: 13.0, utility: "Oncor"}} = Market.from_map(good)

    assert {:ok, %{median: nil, utility: nil}} =
             Market.from_map(%{good | "median" => nil, "utility" => nil})

    for bad <- [
          %{good | "date" => "yesterday"},
          %{good | "utility" => 5},
          %{good | "median" => -1},
          %{good | "median" => 10 ** 400},
          %{good | "date" => 5},
          %{good | "source" => "x"},
          %{good | "plans" => -1},
          "market"
        ] do
      assert Market.from_map(bad) == :error
    end
  end
end
