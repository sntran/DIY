defmodule DIY.Lesson do
  @moduledoc """
  The plan lesson (Texas, in an area with retail choice): the user learns
  to compare plans, with the math of each bill, and the app gets the data
  fast. It does not pick a plan, and it does not rank plans (honesty rule
  4).

  1. A worked example: one sample house, one plan, 12 months. The page
     shows each step of the math of each bill.
  2. Your data, with help: the 12 months of the user, and the numbers of
     one plan (from its EFL). The user does each step of the bill of one
     month, and the app checks each step.
  3. Fewer hints: a second plan. The user gives the bill of one month, and
     the app checks it.
  4. On your own: the worksheet. Each plan next to the others, for the 12
     months of the user.
  """

  alias DIY.{Estimate, Plan, Usage}

  @doc """
  The plan of the worked example: the numbers of a real EFL of October
  2026 (Oncor), with a bill credit of $100 for a month of 1,000 kWh or
  more, and $25 more in July, August and September.
  """
  def example_plan do
    %{
      Plan.new("The example plan")
      | base: 9.95,
        energy: [{0, 13.7}],
        tdu_base: 4.06,
        tdu_cents: 6.8673,
        credits: [
          %{dollars: 100.0, min_kwh: 1000, months: nil},
          %{dollars: 25.0, min_kwh: 1000, months: [7, 8, 9]}
        ],
        averages: %{500 => 23.4, 1000 => 11.3, 2000 => 16.0}
    }
  end

  @example_kwh [1180, 1010, 870, 820, 1150, 1650, 2050, 2100, 1600, 1050, 880, 1120]

  @doc "The 12 months of the sample house of the worked example."
  def example_months do
    for {kwh, m} <- Enum.with_index(@example_kwh, 1),
        do: %{month: m, name: Enum.at(Estimate.month_names(), m - 1), kwh: kwh / 1}
  end

  @doc """
  The 12 months of the user: the file of the meter when it has each month
  of the year (`:meter`), else the bill of the estimate (`:estimate`).
  """
  def months(build, bill) do
    real = build.usage && Usage.by_month(build.usage)

    if real && map_size(real) == 12 do
      {for(m <- 1..12, do: month(m, Usage.full(real[m]))), :meter}
    else
      {Enum.map(bill.months, &month(&1.month, &1.kwh)), :estimate}
    end
  end

  defp month(m, kwh), do: %{month: m, name: Enum.at(Estimate.month_names(), m - 1), kwh: kwh}

  @doc """
  The bill of each month of a plan, and of the year. `shares` gives the
  part of the kWh of a month at night (for a plan with a price of the
  night), or `nil`.
  """
  def rows(plan, months, shares \\ fn _month -> nil end) do
    rows =
      for m <- months do
        Map.merge(Plan.bill(plan, m.kwh, m.month, shares.(m.month)), %{
          month: m.month,
          name: m.name
        })
      end

    total = rows |> Enum.map(& &1.total) |> Enum.sum()
    kwh = rows |> Enum.map(& &1.kwh) |> Enum.sum()
    %{rows: rows, total: total, kwh: kwh, cents: if(kwh > 0, do: total / kwh * 100)}
  end

  @doc "The month with the most kWh: the month of the exercise."
  def exercise_month(months), do: Enum.max_by(months, & &1.kwh)

  @parts [:energy, :base, :tdu, :credits, :total]

  @doc """
  The parts of a bill that the user gives in step 2: the energy charge,
  the base charge, the delivery charges, the credits, the minimum usage
  fee (for a plan with one), and the total.
  """
  def parts(%{min_fee: nil}), do: @parts
  def parts(_plan), do: [:energy, :base, :tdu, :credits, :fee, :total]

  @doc """
  The check of the answers of the user (text, in dollars) for the parts of
  the bill of a month: each part is right within 5 cents. The result has,
  for each part, `:ok`, `:wrong` or `:empty`.
  """
  def check(bill, answers, parts \\ @parts) do
    Map.new(parts, fn part ->
      {part,
       case dollars(answers[Atom.to_string(part)]) do
         nil -> :empty
         value -> if abs(value - Map.fetch!(bill, part)) <= 0.05, do: :ok, else: :wrong
       end}
    end)
  end

  @doc "True when each part is right."
  def done?(checks), do: Enum.all?(checks, fn {_part, check} -> check == :ok end)

  @doc "A number of dollars from the text of the user: \"$1,234.50\", or `nil`."
  def dollars(text) when is_binary(text) do
    case text
         |> String.trim()
         |> String.trim_leading("$")
         |> String.replace(",", "")
         |> Float.parse() do
      {value, ""} -> value
      _ -> nil
    end
  end

  def dollars(_text), do: nil

  @doc """
  A plan from the form of the worksheet (text): a name, the base charge
  ($), the energy charge (¢), the delivery charges ($ and ¢), one credit
  ($ for a month of some kWh or more), and a minimum usage fee ($ for a
  month under some kWh). An empty field is 0 (or no credit, no fee). The
  error names the first field that is not valid.
  """
  @spec plan_from_form(map()) :: {:ok, map()} | {:error, atom()}
  def plan_from_form(form) when is_map(form) do
    with {:ok, name} <- name(form["name"]),
         {:ok, base} <- field(form, "base", 0..10_000),
         {:ok, energy} <- field(form, "energy", 0..200),
         {:ok, tdu_base} <- field(form, "tdu_base", 0..10_000),
         {:ok, tdu_cents} <- field(form, "tdu_cents", 0..200),
         {:ok, credit} <- field(form, "credit", 0..10_000),
         {:ok, credit_kwh} <- field(form, "credit_kwh", 0..100_000),
         {:ok, fee} <- field(form, "fee", 0..10_000),
         {:ok, fee_kwh} <- field(form, "fee_kwh", 0..100_000) do
      {:ok,
       %{
         Plan.new(name)
         | base: base,
           energy: [{0, energy}],
           tdu_base: tdu_base,
           tdu_cents: tdu_cents,
           credits:
             if(credit > 0,
               do: [%{dollars: credit, min_kwh: round(credit_kwh), months: nil}],
               else: []
             ),
           min_fee: if(fee > 0 and fee_kwh > 0, do: %{dollars: fee, below_kwh: round(fee_kwh)})
       }}
    end
  end

  defp name(text) when is_binary(text) do
    case text |> String.trim() |> String.slice(0, 60) do
      "" -> {:error, :name}
      name -> {:ok, name}
    end
  end

  defp name(_text), do: {:error, :name}

  defp field(form, key, min..max//_) do
    case form[key] do
      empty when empty in [nil, ""] ->
        {:ok, 0.0}

      text ->
        case dollars(text) do
          value when is_number(value) and value >= min and value <= max -> {:ok, value}
          _ -> {:error, String.to_atom(key)}
        end
    end
  end
end
