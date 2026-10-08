defmodule DIY.Bill do
  @moduledoc """
  The bill of a house: the power from the grid of `DIY.Power` at the
  prices of the house, with the range of the estimate of its use
  (`DIY.Estimate`).

  The equipment changes the power from the grid, not the range of the use:
  the range of the bill is the power from the grid, less or more the
  distance from the use to the ends of its range, at the mean price of the
  power of the grid. The power from the grid is never under zero.
  """

  @doc "The bill of each month and of the year."
  def run(%{ready: true} = estimate, power) do
    months =
      Enum.zip_with(estimate.months, power.months, fn e, p ->
        Map.merge(range(e, p), %{month: p.month, name: p.name})
      end)

    estimate |> range(power.year) |> Map.put(:months, months)
  end

  defp range(%{kwh: use, low: low, high: high}, power) do
    %{
      kwh: power.grid,
      export: power.export,
      low: max(power.grid - (use - low), 0.0),
      high: power.grid + (high - use),
      cost: power.cost,
      cost_low: power.cost - min(use - low, power.grid) * power.price / 100,
      cost_high: power.cost + (high - use) * power.price / 100
    }
  end
end
