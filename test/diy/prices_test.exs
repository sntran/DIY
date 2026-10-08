defmodule DIY.PricesTest do
  use ExUnit.Case, async: true

  alias DIY.{Build, Prices}

  defp build(zip, fields \\ %{}), do: struct(%Build{revision: 0, zip: zip}, fields)

  test "the price that the user gives comes first" do
    assert %{cents: 12.5, kind: :user} = Prices.price(build("75070", %{price: 12.5}))
  end

  test "a Texas area with retail choice uses the median of Power to Choose" do
    market = %{
      choice: true,
      utility: "Oncor",
      median: 13.4,
      plans: 168,
      date: "2026-10-08",
      source: "ptc"
    }

    assert %{cents: 13.4, kind: :market, source: source} =
             Prices.price(build("75070", %{market: market}))

    assert source =~ "168 plans"
  end

  test "an area with no retail choice, or no median, uses the average of the state" do
    no_choice = %{
      choice: false,
      utility: nil,
      median: nil,
      plans: 0,
      date: "2026-10-08",
      source: "ptc"
    }

    assert %{cents: 16.06, kind: :state, source: source} =
             Prices.price(build("78701", %{market: no_choice}))

    assert source =~ "Texas"
    assert %{cents: 29.38, kind: :state} = Prices.price(build("10001"))
  end

  test "a place with no average of its own uses the average of the US" do
    assert %{cents: 18.19, kind: :country, source: source} = Prices.price(build("00601"))
    assert source =~ "the US"
  end
end
