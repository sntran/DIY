defmodule DIYWeb.Format do
  @moduledoc """
  The numbers of the pages: money, kWh and other units, with a comma for
  thousands.
  """

  @doc "A whole number with commas: 12,345."
  def int(number) when is_number(number), do: DIY.Estimate.fmt(number)

  @doc "Dollars with no cents: $1,234."
  def money(dollars) when is_number(dollars) and dollars <= -0.5, do: "-$" <> int(-dollars)
  def money(dollars) when is_number(dollars), do: "$" <> int(dollars)

  @doc "Dollars with cents, for a price: $1.87."
  def dollars(dollars) when is_number(dollars),
    do: "$" <> :erlang.float_to_binary(dollars / 1, decimals: 2)

  @doc "kWh with no decimals: 1,234 kWh."
  def kwh(kwh) when is_number(kwh), do: int(kwh) <> " kWh"

  @doc "Therms of gas with no decimals: 1 therm, 24 therms."
  def therms(therms) when is_number(therms) and round(therms) == 1, do: "1 therm"
  def therms(therms) when is_number(therms), do: int(therms) <> " therms"

  @doc "Cents with one decimal: 16.1¢."
  def cents(cents) when is_number(cents),
    do: :erlang.float_to_binary(cents / 1, decimals: 1) <> "¢"

  @doc "A number for a form: an integer with no decimals, else as it is."
  def value(number) when is_float(number) and number == trunc(number),
    do: Integer.to_string(trunc(number))

  def value(number) when is_number(number), do: to_string(number)
  def value(value), do: value

  @doc "A count of a thing: 1 month, 2 months."
  def count(1, word), do: "1 " <> word
  def count(n, word) when is_integer(n), do: int(n) <> " " <> word <> "s"

  @doc "The name of a month of a year: \"2025-08\" is \"August 2025\"."
  def month(<<year::binary-size(4), "-", month::binary-size(2)>>),
    do: Enum.at(DIY.Estimate.month_names(), String.to_integer(month) - 1) <> " " <> year

  @doc "The cost of kWh at a price in cents, in dollars."
  def cost(kwh, cents), do: kwh * cents / 100
end
