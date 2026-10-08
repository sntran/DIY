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
  2026 in the Oncor area (`test/fixtures/efl/txu-smart-1000-select-12.pdf`),
  with a bill credit of $100 for a month of 1,000 kWh or more, and $25
  more in July, August and September.
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

  # The months of the sample house: a sample of the app, not a real house,
  # with the shape of a year of a house in Texas (most in the summer).
  @example_kwh [1180, 1010, 870, 820, 1150, 1650, 2050, 2100, 1600, 1050, 880, 1120]

  @doc "The 12 months of the sample house of the worked example."
  def example_months do
    for {kwh, m} <- Enum.with_index(@example_kwh, 1), do: month(m, kwh, kwh, kwh)
  end

  @doc """
  The 12 months of the user: the file of the meter when it has each month
  of the year (`:meter`), else the bill of the estimate (`:estimate`), with
  the range of each month (`low` and `high`). The kWh of a month are a
  whole number: the page shows them so, and the user does the math with
  them.
  """
  def months(build, bill) do
    real = build.usage && Usage.by_month(build.usage)

    if real && map_size(real) == 12 do
      {for(m <- 1..12, kwh = Usage.full(real[m]), do: month(m, kwh, kwh, kwh)), :meter}
    else
      {Enum.map(bill.months, &month(&1.month, &1.kwh, &1.low, &1.high)), :estimate}
    end
  end

  defp month(m, kwh, low, high) do
    %{
      month: m,
      name: Enum.at(Estimate.month_names(), m - 1),
      kwh: round(kwh) / 1,
      low: round(low) / 1,
      high: round(high) / 1
    }
  end

  @doc """
  The bill of a month for a plan (`DIY.Plan.bill/4`). For a plan with a
  price at night, the kWh at night are a whole number: the part of the
  month at night of the day of the house (`share`, from `DIY.Power`), else
  the part that the EFL gives. The bill has `night_kwh`, and `night_from`
  (`:house` or `:efl`).
  """
  def bill(plan, month, share \\ nil)

  def bill(%{night: nil} = plan, m, _share),
    do: Map.merge(Plan.bill(plan, m.kwh, m.month), %{night_kwh: nil, night_from: nil})

  def bill(%{night: night} = plan, m, share) do
    night_kwh = round(m.kwh * (share || night.share)) / 1
    part = if m.kwh > 0, do: night_kwh / m.kwh, else: 0.0

    plan
    |> Plan.bill(m.kwh, m.month, part)
    |> Map.merge(%{night_kwh: night_kwh, night_from: if(share, do: :house, else: :efl)})
  end

  @doc """
  The bill of each month of a plan, and of the year, with the range of the
  months (`total_low` and `total_high`). `shares` gives the part of the
  kWh of a month at night (for a plan with a price of the night), or
  `nil`.
  """
  def rows(plan, months, shares \\ fn _month -> nil end) do
    rows =
      for m <- months do
        share = shares.(m.month)
        {low, high} = range(plan, m, share)

        plan
        |> bill(m, share)
        |> Map.merge(%{month: m.month, name: m.name, total_low: low, total_high: high})
      end

    total = rows |> Enum.map(& &1.total) |> Enum.sum()
    kwh = rows |> Enum.map(& &1.kwh) |> Enum.sum()

    %{
      rows: rows,
      total: total,
      total_low: rows |> Enum.map(& &1.total_low) |> Enum.sum(),
      total_high: rows |> Enum.map(& &1.total_high) |> Enum.sum(),
      kwh: kwh,
      cents: if(kwh > 0, do: total / kwh * 100)
    }
  end

  # The least and the most bill of a month in the range of its kWh. A
  # credit or a fee changes the bill at its limit of kWh, so the bill is
  # not always more for more kWh: the app checks the ends of the range,
  # and each limit in the range.
  defp range(plan, %{low: low, high: high} = m, share) when low < high do
    limits =
      Enum.map(plan.credits, & &1.min_kwh) ++
        if(plan.min_fee, do: [plan.min_fee.below_kwh], else: [])

    points = [low, high] ++ for(l <- limits, k <- [l - 1, l], k > low and k < high, do: k / 1)
    totals = for k <- points, do: bill(plan, %{m | kwh: k}, share).total
    {Enum.min(totals), Enum.max(totals)}
  end

  defp range(plan, m, share) do
    total = bill(plan, m, share).total
    {total, total}
  end

  @doc "The month with the most kWh: the month of the exercise."
  def exercise_month(months), do: Enum.max_by(months, & &1.kwh)

  @doc """
  The parts of a bill that the user gives in step 2: the energy charge,
  the base charge, the delivery charges, the credits, the minimum usage
  fee (for a plan with one), and the total.
  """
  def parts(%{min_fee: nil}), do: [:energy, :base, :tdu, :credits, :total]
  def parts(_plan), do: [:energy, :base, :tdu, :credits, :fee, :total]

  @doc """
  The check of the answers of the user (text, in dollars) for the parts of
  the bill of a month: each part is right within 5 cents. A credit is
  right with its sign or with no sign. The result has, for each part,
  `:ok`, `:wrong`, `:empty`, or `:invalid` (a text that is not a number).
  """
  def check(bill, answers, parts) do
    Map.new(parts, fn part ->
      right = Map.fetch!(bill, part)

      {part,
       case answer(answers[Atom.to_string(part)]) do
         check when check in [:empty, :invalid] -> check
         value when part == :credits -> close(abs(value), right)
         value -> close(value, right)
       end}
    end)
  end

  defp answer(text) when text in [nil, ""], do: :empty

  defp answer(text) when is_binary(text),
    do: dollars(text) || if(String.trim(text) == "", do: :empty, else: :invalid)

  defp answer(_value), do: :invalid

  defp close(value, right), do: if(abs(value - right) <= 0.05, do: :ok, else: :wrong)

  @doc "True when each part is right."
  def done?(checks), do: Enum.all?(checks, fn {_part, check} -> check == :ok end)

  @doc """
  A number of dollars from the text of the user, or `nil`: "$1,234.50",
  "-125", "−$125" (the minus sign of the page), "$ 125", "5.". A comma
  must separate groups of 3 digits.
  """
  def dollars(text) when is_binary(text) do
    {sign, text} = sign(String.trim(text))

    {sign2, text} =
      case text do
        "$" <> rest -> rest |> String.trim() |> sign()
        _ -> {1, text}
      end

    if text =~ ~r/\A(\d{1,3}(,\d{3})+|\d+)(\.\d*)?\z|\A\.\d+\z/ do
      number = String.replace(text, ",", "")
      number = if String.ends_with?(number, "."), do: number <> "0", else: number
      {value, ""} = Float.parse("0" <> number)
      sign * sign2 * value
    end
  end

  def dollars(_text), do: nil

  defp sign("-" <> text), do: {-1, String.trim(text)}
  defp sign("−" <> text), do: {-1, String.trim(text)}
  defp sign(text), do: {1, text}

  @doc """
  A plan from the form of the worksheet (text): a name, the base charge
  ($), the energy charge (¢), the delivery charges ($ and ¢), one credit
  ($ for a month of some kWh or more), and a minimum usage fee ($ for a
  month under some kWh, and the fee needs its kWh). An empty field is 0
  (or no credit, no fee). With `tdu_needed` (a utility that the app does
  not know), the delivery charges must not be empty. The error names the
  first field that is not valid.
  """
  @spec plan_from_form(map(), boolean()) :: {:ok, map()} | {:error, atom()}
  def plan_from_form(form, tdu_needed) when is_map(form) do
    with {:ok, name} <- name(form["name"]),
         :ok <- needed(form, tdu_needed, ["tdu_base", "tdu_cents"]),
         {:ok, base} <- field(form, "base", 0..10_000),
         {:ok, energy} <- field(form, "energy", 0..200),
         {:ok, tdu_base} <- field(form, "tdu_base", 0..10_000),
         {:ok, tdu_cents} <- field(form, "tdu_cents", 0..200),
         {:ok, credit} <- field(form, "credit", 0..10_000),
         {:ok, credit_kwh} <- field(form, "credit_kwh", 0..100_000),
         {:ok, fee} <- field(form, "fee", 0..10_000),
         {:ok, fee_kwh} <- field(form, "fee_kwh", 0..100_000),
         true <- (fee == 0 or fee_kwh > 0) || {:error, :fee_kwh} do
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

  # The fields that the user must give (the delivery charges of a utility
  # that the app does not know).
  defp needed(_form, false, _keys), do: :ok

  defp needed(form, true, keys) do
    case Enum.find(keys, &(String.trim(form[&1] || "") == "")) do
      nil -> :ok
      key -> {:error, String.to_atom(key)}
    end
  end

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
