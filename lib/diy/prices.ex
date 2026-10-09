defmodule DIY.Prices do
  @moduledoc """
  The price of one kWh for the estimate, in cents, and where it comes
  from (honesty rule 1: each number shows where it comes from).

  The order:

  1. The price that the user gives.
  2. In a Texas area with retail choice: the median price of the plans of
     the ZIP code on Power to Choose, at 1,000 kWh (`DIY.Market`).
  3. The average price for homes in the state, from the US Energy
     Information Administration.
  """

  # EIA, Electric Power Monthly, Table 5.6.B: the average price of
  # electricity to the residential sector by state, January to July 2026
  # (cents for one kWh). Release of September 24, 2026.
  @eia %{
    "AL" => 16.54,
    "AK" => 27.09,
    "AZ" => 15.44,
    "AR" => 13.61,
    "CA" => 33.25,
    "CO" => 16.72,
    "CT" => 27.97,
    "DE" => 17.86,
    "DC" => 24.66,
    "FL" => 15.30,
    "GA" => 15.40,
    "HI" => 46.28,
    "ID" => 12.96,
    "IL" => 19.22,
    "IN" => 17.04,
    "IA" => 14.20,
    "KS" => 15.21,
    "KY" => 14.27,
    "LA" => 13.35,
    "ME" => 29.99,
    "MD" => 21.30,
    "MA" => 30.14,
    "MI" => 21.53,
    "MN" => 16.25,
    "MS" => 15.19,
    "MO" => 13.96,
    "MT" => 13.95,
    "NE" => 12.90,
    "NV" => 13.53,
    "NH" => 26.79,
    "NJ" => 23.98,
    "NM" => 15.08,
    "NY" => 29.38,
    "NC" => 14.94,
    "ND" => 12.36,
    "OH" => 18.70,
    "OK" => 13.58,
    "OR" => 15.40,
    "PA" => 21.04,
    "RI" => 29.22,
    "SC" => 15.93,
    "SD" => 14.50,
    "TN" => 13.87,
    "TX" => 16.06,
    "UT" => 13.16,
    "VT" => 23.95,
    "VA" => 16.83,
    "WA" => 14.40,
    "WV" => 15.47,
    "WI" => 19.00,
    "WY" => 13.95
  }
  @us 18.19
  @eia_source "the average price for homes in STATE, January to July 2026 (US Energy Information Administration, Electric Power Monthly, table 5.6.B)"

  @type t :: %{cents: float(), source: String.t(), kind: atom()}

  @doc "The price for the estimate of a build."
  @spec price(DIY.Build.t()) :: t()
  def price(%{price: price}) when is_number(price),
    do: %{cents: price, source: "the price that you gave", kind: :user}

  def price(%{market: %{choice: true, median: median, plans: plans, date: date}})
      when is_number(median) do
    %{
      cents: median,
      source:
        "the middle price (the median) of #{plans} plans for your ZIP code on Power to Choose (#{date}). It is the price at 1,000 kWh in one month, with the delivery charges",
      kind: :market
    }
  end

  def price(%{zip: zip}) when is_binary(zip) do
    {:ok, %{state: state}} = DIY.Zip.lookup(zip)

    case Map.fetch(@eia, state) do
      {:ok, cents} ->
        %{
          cents: cents,
          source: String.replace(@eia_source, "STATE", DIY.Zip.state_name(state)),
          kind: :state
        }

      :error ->
        %{cents: @us, source: String.replace(@eia_source, "STATE", "the US"), kind: :country}
    end
  end
end
