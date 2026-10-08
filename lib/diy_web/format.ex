defmodule DIYWeb.Format do
  @moduledoc """
  The numbers of the pages: money, kWh and other units, with a comma for
  thousands.
  """

  @doc "A whole number with commas: 12,345."
  def int(number) when is_number(number), do: DIY.Estimate.fmt(number)

  @doc "Dollars with no cents: $1,234."
  def money(dollars) when is_number(dollars), do: "$" <> int(dollars)

  @doc "kWh with no decimals: 1,234 kWh."
  def kwh(kwh) when is_number(kwh), do: int(kwh) <> " kWh"

  @doc "Cents with one decimal: 16.1¢."
  def cents(cents) when is_number(cents),
    do: :erlang.float_to_binary(cents / 1, decimals: 1) <> "¢"

  @doc "A number for a form: an integer with no decimals, else as it is."
  def value(number) when is_float(number) and number == trunc(number),
    do: Integer.to_string(trunc(number))

  def value(number) when is_number(number), do: to_string(number)
  def value(value), do: value

  @doc "The cost of kWh at a price in cents, in dollars."
  def cost(kwh, cents), do: kwh * cents / 100
end
