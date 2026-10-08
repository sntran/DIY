defmodule DIY.Usage do
  @moduledoc """
  The real usage of a house, from the file of its smart meter. The browser
  reads the file (`assets/js/usage.js`), and sends only the sums of each
  month. The usage stays in the build, on the device.

  A usage is a map:

  - `source`: `"smt"` (Smart Meter Texas) or `"green_button"`.
  - `months`: for each month (`"YYYY-MM"`), the kWh from the grid, the kWh
    to the grid (`export`), the days with data, and the mean kWh of each
    hour of the day (24 numbers, or `nil` for daily data).

  `compare/2` puts the real months next to the estimate, and `fit/2` finds
  the numbers of the house from the meter and the weather: the kWh of one
  day with no heat and no cooling, and the kWh of one degree day of cooling
  and of heating.
  """

  @sources ~w(smt green_button)
  @max_months 24

  @type month :: %{
          month: String.t(),
          kwh: float(),
          export: float(),
          days: pos_integer(),
          hours: [float()] | nil
        }
  @type t :: %{source: String.t(), months: [month()]}

  @doc "The name of a source."
  def source_name("smt"), do: "Smart Meter Texas"
  def source_name("green_button"), do: "Green Button"

  @doc """
  Reads a usage from the browser or from a stored build. It accepts only
  a usage that it can read in full.
  """
  @spec read(term()) :: {:ok, t()} | :error
  def read(%{"source" => source, "months" => months})
      when source in @sources and is_list(months) do
    with true <- length(months) in 1..@max_months,
         {:ok, months} <- all(months),
         names = Enum.map(months, & &1.month),
         true <- names == Enum.uniq(names) do
      {:ok, %{source: source, months: Enum.sort_by(months, & &1.month)}}
    else
      _ -> :error
    end
  end

  def read(_usage), do: :error

  defp all(months) do
    Enum.reduce_while(months, {:ok, []}, fn month, {:ok, acc} ->
      case month(month) do
        {:ok, month} -> {:cont, {:ok, [month | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp month(%{"month" => name, "kwh" => kwh, "export" => export, "days" => days} = month)
       when is_binary(name) and is_number(kwh) and kwh >= 0 and kwh < 1_000_000 and
              is_number(export) and export >= 0 and export < 1_000_000 and
              is_integer(days) and days in 1..31 do
    with {:ok, _date} <- Date.from_iso8601(name <> "-01"),
         {:ok, hours} <- hours(month["hours"]) do
      {:ok, %{month: name, kwh: kwh / 1, export: export / 1, days: days, hours: hours}}
    else
      _ -> :error
    end
  end

  defp month(_month), do: :error

  defp hours(nil), do: {:ok, nil}

  defp hours(hours) when is_list(hours) and length(hours) == 24 do
    if Enum.all?(hours, &(is_number(&1) and &1 >= 0 and &1 < 10_000)),
      do: {:ok, Enum.map(hours, &(&1 / 1))},
      else: :error
  end

  defp hours(_hours), do: :error

  @doc "The usage as a map for JSON."
  def to_map(%{source: source, months: months}) do
    %{
      "source" => source,
      "months" =>
        Enum.map(months, fn m ->
          %{
            "month" => m.month,
            "kwh" => m.kwh,
            "export" => m.export,
            "days" => m.days,
            "hours" => m.hours
          }
        end)
    }
  end

  @doc "The days of a month of a year."
  def days_in(name) do
    {:ok, date} = Date.from_iso8601(name <> "-01")
    Date.days_in_month(date)
  end

  @doc """
  The kWh of a month for the full month: a month with fewer days of data
  gets the mean of its days for the other days.
  """
  def full(%{month: name, kwh: kwh, days: days}), do: kwh * days_in(name) / days

  @doc """
  The last real month of each month of the year (January is 1), for the
  months of the usage.
  """
  def by_month(%{months: months}) do
    months
    |> Enum.group_by(&(&1.month |> String.slice(5, 2) |> String.to_integer()))
    |> Map.new(fn {month, list} -> {month, Enum.max_by(list, & &1.month)} end)
  end

  @doc """
  The real months next to the estimate: for each month of the year with
  real data, the real kWh (for the full month), the estimate and its
  range, and true when the real kWh is in the range. `inside` counts the
  months in the range.
  """
  def compare(usage, %{ready: true, months: estimate}) do
    real = by_month(usage)

    rows =
      for m <- estimate, real_month = real[m.month], real_month do
        kwh = full(real_month)

        %{
          month: m.month,
          name: m.name,
          real: kwh,
          from: real_month.month,
          partial: real_month.days < days_in(real_month.month),
          estimate: m.kwh,
          low: m.low,
          high: m.high,
          inside: kwh >= m.low and kwh <= m.high
        }
      end

    %{rows: rows, inside: Enum.count(rows, & &1.inside)}
  end

  @doc """
  The kWh of one year from the meter: the sum of the last real month of
  each month of the year, or `nil` with fewer than 12 months.
  """
  def year(usage) do
    real = by_month(usage)
    if map_size(real) == 12, do: real |> Map.values() |> Enum.map(&full/1) |> Enum.sum()
  end

  @doc """
  The numbers of the house from the meter and the weather of the same
  months (least squares, with no number under zero):

      kWh of a month = base × days + cool × cooling degree days + heat × heating degree days

  It uses the months with 20 days of data or more, and with the weather of
  NASA POWER. It needs 6 such months, else it gives `nil`.
  """
  def fit(usage, climate) do
    points =
      for m <- usage.months,
          m.days >= 20,
          [year, month] = m.month |> String.split("-") |> Enum.map(&String.to_integer/1),
          weather = climate.series[{year, month}],
          weather do
        {[days_in(m.month), weather.cdd, weather.hdd], full(m)}
      end

    if length(points) >= 6, do: best(points)
  end

  # The least squares of each set of the three numbers, with the others at
  # zero, and the best one with no number under zero.
  defp best(points) do
    for set <- [[0, 1, 2], [0, 1], [0, 2], [1, 2], [0], [1], [2]],
        coef = solve(points, set),
        coef != nil,
        Enum.all?(coef, &(&1 >= 0)) do
      full =
        Enum.reduce(Enum.zip(set, coef), [0.0, 0.0, 0.0], fn {i, c}, acc ->
          List.replace_at(acc, i, c)
        end)

      {error(points, full), full}
    end
    # The base alone always has a solution: its column (the days) is never
    # zero, and the kWh are never under zero.
    |> Enum.min_by(&elem(&1, 0))
    |> then(fn {_error, [base, cool, heat]} ->
      %{
        base: base,
        cool: cool,
        heat: heat,
        months: length(points),
        r2: r2(points, [base, cool, heat])
      }
    end)
  end

  defp error(points, coef) do
    points |> Enum.map(fn {x, y} -> :math.pow(y - dot(x, coef), 2) end) |> Enum.sum()
  end

  defp r2(points, coef) do
    ys = Enum.map(points, &elem(&1, 1))
    mean = Enum.sum(ys) / length(ys)
    total = ys |> Enum.map(&:math.pow(&1 - mean, 2)) |> Enum.sum()
    # A fit can be worse than the mean of the months: then it explains none
    # of the change (0, not a number under zero).
    if total == 0, do: 1.0, else: max(1 - error(points, coef) / total, 0.0)
  end

  defp dot(x, coef), do: x |> Enum.zip(coef) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()

  # The normal equations (XᵀX) c = Xᵀy for the columns of a set, with
  # Gauss-Jordan elimination. A singular system gives nil.
  defp solve(points, set) do
    rows = Enum.map(points, fn {x, y} -> {Enum.map(set, &Enum.at(x, &1)), y} end)
    n = length(set)

    matrix =
      for i <- 0..(n - 1) do
        row =
          for j <- 0..(n - 1),
              do: rows |> Enum.map(fn {x, _} -> Enum.at(x, i) * Enum.at(x, j) end) |> Enum.sum()

        row ++ [rows |> Enum.map(fn {x, y} -> Enum.at(x, i) * y end) |> Enum.sum()]
      end

    gauss(matrix, n)
  end

  defp gauss(matrix, n) do
    Enum.reduce_while(0..(n - 1), matrix, fn col, m ->
      pivot = Enum.max_by(col..(n - 1), fn r -> abs(Enum.at(Enum.at(m, r), col)) end)
      value = Enum.at(Enum.at(m, pivot), col)

      if abs(value) < 1.0e-9 do
        {:halt, nil}
      else
        m = m |> swap(col, pivot)
        row = Enum.map(Enum.at(m, col), &(&1 / value))

        m =
          m
          |> Enum.with_index()
          |> Enum.map(fn
            {_r, ^col} ->
              row

            {r, _i} ->
              factor = Enum.at(r, col)
              Enum.zip_with(r, row, fn a, b -> a - factor * b end)
          end)

        {:cont, m}
      end
    end)
    |> case do
      nil -> nil
      m -> Enum.map(m, &List.last/1)
    end
  end

  defp swap(m, i, i), do: m

  defp swap(m, i, j) do
    a = Enum.at(m, i)
    b = Enum.at(m, j)
    m |> List.replace_at(i, b) |> List.replace_at(j, a)
  end
end
