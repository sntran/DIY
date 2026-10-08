defmodule DIY.Plan do
  @moduledoc """
  A plan of a retail electric provider in Texas, and the math of its bill.
  The numbers come from its EFL (Electricity Facts Label, `DIY.EFL`), or
  from the user (the worksheet of the plan lesson).

  A plan is a map:

  - `id`: the id of the plan in the build (the worksheet), or `nil`.
  - `name`: the name that the user gives.
  - `base`: the base charge, in dollars for each month.
  - `energy`: the energy charge in tiers, `[{from_kwh, cents}]` from 0 kWh
    (one tier for one price at all kWh).
  - `night`: `nil`, or a different energy charge at night: its `cents`, its
    hours (`from` and `to`), and `share`, the part of the use at night in
    the averages of the EFL.
  - `tdu_base` and `tdu_cents`: the delivery charges of the utility (TDU),
    in dollars for each month and in cents for each kWh.
  - `credits`: each credit has its `dollars`, the `min_kwh` of a month for
    it (0 for a credit of each month), and its `months` (1 to 12, or `nil`
    for each month).
  - `min_fee`: `nil`, or a fee (`dollars`) for a month under `below_kwh`.
  - `averages`: the average prices of the EFL at 500, 1,000 and 2,000 kWh
    (cents), or `nil`.

  The bill of a month:

      base + energy + TDU base + TDU cents × kWh − credits + minimum usage fee

  The averages of an EFL spread a credit of some months over the year: a
  credit of 3 months counts 3/12 of its dollars in each month.
  """

  @type t :: %{
          id: String.t() | nil,
          name: String.t(),
          base: float(),
          energy: [{non_neg_integer(), float()}],
          night: map() | nil,
          tdu_base: float() | nil,
          tdu_cents: float() | nil,
          credits: [map()],
          min_fee: map() | nil,
          averages: %{(500 | 1000 | 2000) => float()} | nil
        }

  # The delivery charges of the utilities, for an EFL that does not give
  # them: as the EFLs of October 2026 give them (Oncor: the EFLs of
  # Discount Power and Reliant in test/fixtures/efl; CenterPoint: the EFL
  # of Just Energy there).
  @tdus %{
    "oncor" => %{name: "Oncor", base: 4.06, cents: 6.8673},
    "centerpoint" => %{name: "CenterPoint", base: 4.9, cents: 6.5333}
  }

  @doc "The delivery charges of a utility (by its name in an EFL), or `nil`."
  def tdu(text) when is_binary(text) do
    Enum.find_value(@tdus, fn {key, tdu} ->
      if String.contains?(String.downcase(text), key), do: tdu
    end)
  end

  @doc """
  The parts of the bill of a month: the kWh of the month, its number
  (1 to 12, or `nil` for an average month of the EFL), and the part of the
  kWh at night.
  """
  def bill(plan, kwh, month \\ nil, night_share \\ nil) do
    energy = energy(plan, kwh, night_share)
    tdu = (plan.tdu_base || 0.0) + (plan.tdu_cents || 0.0) * kwh / 100
    credits = credits(plan, kwh, month)
    fee = if plan.min_fee && kwh < plan.min_fee.below_kwh, do: plan.min_fee.dollars, else: 0.0
    total = plan.base + energy + tdu - credits + fee

    %{
      kwh: kwh,
      base: plan.base / 1,
      energy: energy,
      tdu: tdu,
      credits: credits,
      fee: fee / 1,
      total: total,
      cents: if(kwh > 0, do: total / kwh * 100)
    }
  end

  # The energy charge: the price of the tiers, and with a price at night,
  # that price for the kWh of the night. The tiers are for the kWh of the
  # full month: the kWh of the day pay the mean price of the tiers for all
  # the kWh.
  defp energy(%{night: nil} = plan, kwh, _share), do: tiers(plan.energy, kwh)

  defp energy(%{night: night} = plan, kwh, share) do
    share = share || night.share
    tiers(plan.energy, kwh) * (1 - share) + kwh * share * night.cents / 100
  end

  defp tiers(tiers, kwh) do
    tiers
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn
      [{from, cents}, {to, _}] -> max(min(kwh, to) - from, 0) * cents / 100
      [{from, cents}] -> max(kwh - from, 0) * cents / 100
    end)
    |> Enum.sum()
  end

  # The credits of a month. An average month of an EFL (no month) counts a
  # credit of some months for its part of the year.
  defp credits(plan, kwh, month) do
    plan.credits
    |> Enum.filter(&(kwh >= &1.min_kwh))
    |> Enum.map(fn credit ->
      cond do
        is_nil(credit.months) -> credit.dollars
        is_nil(month) -> credit.dollars * length(credit.months) / 12
        month in credit.months -> credit.dollars
        true -> 0.0
      end
    end)
    |> Enum.sum()
  end

  @doc """
  The check of the numbers of a plan: the average prices of the plan at
  500, 1,000 and 2,000 kWh next to the averages of its EFL. An EFL rounds
  its averages to 0.1¢. `ok` is true when each one is within 0.05¢ (the
  rounding of the label).
  """
  def check(%{averages: averages} = plan) when is_map(averages) do
    rows =
      for kwh <- [500, 1000, 2000] do
        cents = bill(plan, kwh).cents
        efl = averages[kwh]
        %{kwh: kwh, efl: efl, app: cents, ok: abs(cents - efl) <= 0.05 + 1.0e-6}
      end

    %{ok: Enum.all?(rows, & &1.ok), rows: rows}
  end

  @doc """
  The delivery charges of a plan whose EFL does not give them, from its
  averages at 500 and 2,000 kWh: two prices give the two charges (the
  charge of each month and the charge of each kWh). `nil` when they are
  not plausible (under zero).
  """
  def fit_tdu(%{averages: %{500 => a500, 2000 => a2000}} = plan) do
    other = %{plan | tdu_base: 0.0, tdu_cents: 0.0}
    # The part of each bill that the delivery charges must give.
    rest500 = a500 * 5 - bill(other, 500).total
    rest2000 = a2000 * 20 - bill(other, 2000).total
    cents = (rest2000 - rest500) / 1500 * 100
    base = rest500 - cents * 5

    if cents >= 0 and base >= 0,
      do: %{plan | tdu_base: Float.round(base, 2), tdu_cents: Float.round(cents, 4)}
  end

  @doc "A plan with no numbers yet, for the worksheet."
  def new(name),
    do: %{
      id: nil,
      name: name,
      base: 0.0,
      energy: [{0, 0.0}],
      night: nil,
      tdu_base: nil,
      tdu_cents: nil,
      credits: [],
      min_fee: nil,
      averages: nil
    }

  ## JSON

  @doc "The plan as a map for JSON."
  def to_map(plan) do
    %{
      "id" => plan.id,
      "name" => plan.name,
      "base" => plan.base,
      "energy" => Enum.map(plan.energy, &Tuple.to_list/1),
      "night" => plan.night && Map.new(plan.night, fn {k, v} -> {Atom.to_string(k), v} end),
      "tdu_base" => plan.tdu_base,
      "tdu_cents" => plan.tdu_cents,
      "credits" =>
        Enum.map(plan.credits, fn c ->
          %{"dollars" => c.dollars, "min_kwh" => c.min_kwh, "months" => c.months}
        end),
      "min_fee" =>
        plan.min_fee &&
          %{"dollars" => plan.min_fee.dollars, "below_kwh" => plan.min_fee.below_kwh},
      "averages" =>
        plan.averages && Map.new(plan.averages, fn {k, v} -> {Integer.to_string(k), v} end)
    }
  end

  @doc "Reads a plan of a stored build. It accepts only a plan that it can read in full."
  @spec read(term()) :: {:ok, map()} | :error
  def read(%{"id" => id, "name" => name} = map) when is_binary(id) and is_binary(name) do
    with true <- byte_size(id) <= 20 and String.length(name) in 1..60,
         {:ok, base} <- dollars(map["base"]),
         {:ok, energy} <- energy(map["energy"]),
         {:ok, night} <- night(map["night"]),
         {:ok, tdu_base} <- maybe(map["tdu_base"], &dollars/1),
         {:ok, tdu_cents} <- maybe(map["tdu_cents"], &cents/1),
         {:ok, credits} <- credits(map["credits"]),
         {:ok, min_fee} <- maybe(map["min_fee"], &min_fee/1),
         {:ok, averages} <- maybe(map["averages"], &averages/1) do
      {:ok,
       %{
         id: id,
         name: name,
         base: base,
         energy: energy,
         night: night,
         tdu_base: tdu_base,
         tdu_cents: tdu_cents,
         credits: credits,
         min_fee: min_fee,
         averages: averages
       }}
    else
      _ -> :error
    end
  end

  def read(_map), do: :error

  defp maybe(nil, _read), do: {:ok, nil}
  defp maybe(value, read), do: read.(value)

  defp dollars(value) when is_number(value) and value >= 0 and value <= 10_000,
    do: {:ok, value / 1}

  defp dollars(_value), do: :error

  defp cents(value) when is_number(value) and value >= 0 and value <= 200, do: {:ok, value / 1}
  defp cents(_value), do: :error

  defp kwh(value) when is_integer(value) and value >= 0 and value <= 100_000, do: {:ok, value}
  defp kwh(_value), do: :error

  defp energy([[0, _] | _] = tiers) when length(tiers) <= 10 do
    tiers
    |> Enum.reduce_while({:ok, []}, fn
      [from, cents], {:ok, acc} ->
        with {:ok, from} <- kwh(from), {:ok, cents} <- cents(cents) do
          {:cont, {:ok, acc ++ [{from, cents}]}}
        else
          _ -> {:halt, :error}
        end

      _tier, _acc ->
        {:halt, :error}
    end)
    |> then(fn
      {:ok, tiers} = ok ->
        if(
          tiers == Enum.sort(tiers) and length(Enum.uniq_by(tiers, &elem(&1, 0))) == length(tiers),
          do: ok,
          else: :error
        )

      :error ->
        :error
    end)
  end

  defp energy(_tiers), do: :error

  defp night(nil), do: {:ok, nil}

  defp night(%{"cents" => cents, "from" => from, "to" => to, "share" => share})
       when from in 0..23 and to in 0..23 and is_number(share) and share >= 0 and share <= 1 do
    with {:ok, cents} <- cents(cents),
         do: {:ok, %{cents: cents, from: from, to: to, share: share / 1}}
  end

  defp night(_night), do: :error

  defp credits(credits) when is_list(credits) and length(credits) <= 10 do
    Enum.reduce_while(credits, {:ok, []}, fn
      %{"dollars" => dollars, "min_kwh" => min_kwh} = credit, {:ok, acc} ->
        with {:ok, dollars} <- dollars(dollars),
             {:ok, min_kwh} <- kwh(min_kwh),
             {:ok, months} <- months(credit["months"]) do
          {:cont, {:ok, acc ++ [%{dollars: dollars, min_kwh: min_kwh, months: months}]}}
        else
          _ -> {:halt, :error}
        end

      _credit, _acc ->
        {:halt, :error}
    end)
  end

  defp credits(_credits), do: :error

  defp months(nil), do: {:ok, nil}

  defp months([_ | _] = months) do
    if Enum.all?(months, &(&1 in 1..12)) and Enum.uniq(months) == months,
      do: {:ok, months},
      else: :error
  end

  defp months(_months), do: :error

  defp min_fee(%{"dollars" => dollars, "below_kwh" => below}) do
    with {:ok, dollars} <- dollars(dollars), {:ok, below} <- kwh(below) do
      {:ok, %{dollars: dollars, below_kwh: below}}
    end
  end

  defp min_fee(_fee), do: :error

  defp averages(%{"500" => a, "1000" => b, "2000" => c}) do
    with {:ok, a} <- cents(a), {:ok, b} <- cents(b), {:ok, c} <- cents(c) do
      {:ok, %{500 => a, 1000 => b, 2000 => c}}
    end
  end

  defp averages(_averages), do: :error
end
