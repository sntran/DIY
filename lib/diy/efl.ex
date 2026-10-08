defmodule DIY.EFL do
  @moduledoc """
  The reader of an EFL (Electricity Facts Label): the label that each
  retail electric provider in Texas gives for each plan. The browser reads
  the PDF (`assets/js/efl.js`) and sends its lines. This module finds the
  numbers of the plan (`DIY.Plan`) in them, and the line of each number:
  the page shows each number with the line where it came from.

  An EFL gives the average prices at 500, 1,000 and 2,000 kWh. The reader
  checks its numbers with them (`DIY.Plan.check/1`). When the EFL does not
  give the delivery charges of the utility (TDU), the reader takes them
  from the table of `DIY.Plan.tdu/1`, or finds them from the averages
  (`DIY.Plan.fit_tdu/1`).

  The EFLs of the providers are not all the same. The reader knows the
  forms of the test EFLs (`test/fixtures/efl`). For a different form, the
  check shows which average does not agree, and the user can change each
  number.
  """

  alias DIY.Plan

  @money ~r/\$\s*(\d[\d,]*(?:\.\d+)?)|(\d[\d,]*\.\d+)\s*\$/u
  @cents ~r/(\d+(?:\.\d+)?)\s*¢/u
  @months ~w(january february march april may june july august september october november december)

  @doc """
  Reads the lines of an EFL (`%{"page" => n, "text" => text}` from the
  browser). The result has the plan, the line of each number (`sources`),
  and the check of the averages.
  """
  @spec read(term()) :: {:ok, map()} | {:error, atom()}
  def read(lines) when is_list(lines) and length(lines) in 1..2000 do
    with {:ok, lines} <- lines(lines),
         {:averages, {averages, averages_line}} <- {:averages, averages(lines)} do
      energy = energy(lines)
      night = night(lines)
      {tdu, tdu_lines} = tdu(lines)
      {credits, credit_lines} = credits(lines)
      {min_fee, fee_line} = min_fee(lines)
      {base, base_line} = base(lines)

      plan = %{
        Plan.new("")
        | base: base,
          energy: elem(energy, 0),
          night: elem(night, 0),
          tdu_base: tdu[:base],
          tdu_cents: tdu[:cents],
          credits: credits,
          min_fee: min_fee,
          averages: averages
      }

      {plan, tdu_source} = fill_tdu(plan, lines)

      sources =
        %{
          averages: averages_line,
          base: base_line,
          energy: elem(energy, 1),
          night: elem(night, 1),
          tdu: tdu_lines,
          credits: credit_lines,
          min_fee: fee_line
        }
        |> Map.merge(tdu_source)

      {:ok, %{plan: plan, sources: sources, check: Plan.check(plan)}}
    else
      {:averages, nil} -> {:error, :averages}
      :error -> {:error, :lines}
    end
  end

  def read(_lines), do: {:error, :lines}

  defp lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn
      %{"page" => page, "text" => text}, {:ok, acc}
      when is_integer(page) and page > 0 and is_binary(text) and byte_size(text) <= 2000 ->
        {:cont, {:ok, [%{page: page, text: text} | acc]}}

      _line, _acc ->
        {:halt, :error}
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end)
  end

  defp number(text), do: text |> String.replace(",", "") |> Float.parse() |> elem(0)

  defp money(text) do
    case Regex.run(@money, text) do
      [_, dollars] -> number(dollars)
      [_, "", dollars] -> number(dollars)
      nil -> nil
    end
  end

  defp cents(text) do
    case Regex.run(@cents, text) do
      [_, cents] -> number(cents)
      nil -> nil
    end
  end

  # The line and the next line, for a name with its number on the next
  # line ("Energy Charge: Per kWh (¢)", then "All kWh 13.7000¢").
  defp with_next(lines, fun) do
    lines
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.find_value(fn [line, next] -> fun.(line, next) end)
  end

  # A number on the next line, with that line.
  defp on_next(nil, _fun), do: nil

  defp on_next(next, fun) do
    case fun.(next.text) do
      nil -> nil
      value -> {value, next}
    end
  end

  ## The averages

  defp averages(lines) do
    with_next(lines, fn line, next ->
      if line.text =~ ~r/average\s+price/i do
        case numbers(line.text) do
          [a, b, c | _] -> {%{500 => a, 1000 => b, 2000 => c}, line}
          _ -> next && averages_next(next)
        end
      end
    end)
  end

  defp averages_next(next) do
    case numbers(next.text) do
      [a, b, c | _] -> {%{500 => a, 1000 => b, 2000 => c}, next}
      _ -> nil
    end
  end

  # The cents of a line: "15.4 ¢ 15.0 ¢ 14.8 ¢", or "¢ per kWh 13.8 13.4
  # 13.2" (the numbers with a decimal).
  defp numbers(text) do
    case Regex.scan(@cents, text) do
      [_, _, _ | _] = found ->
        Enum.map(found, fn [_, n] -> number(n) end)

      _ ->
        ~r/(?<![\d.])\d+\.\d+(?![\d.])/ |> Regex.scan(text) |> Enum.map(fn [n] -> number(n) end)
    end
  end

  ## The base charge

  # "Base Charge", "Base Monthly Charge", "Base Usage Charge", and "ae Charge"
  # (a PDF with no "B" and no "s" in its text).
  defp base_line?(text),
    do:
      text =~ ~r/\b(base|ase|ae)\s+(monthly\s+|usage\s+)?charge/i and
        not (text =~ ~r/consists? of|deliver/i)

  defp base(lines) do
    with_next(lines, fn line, next ->
      if base_line?(line.text) do
        case money(line.text) do
          nil -> on_next(next, &money/1)
          dollars -> {dollars, line}
        end
      end
    end) || {0.0, nil}
  end

  ## The energy charge

  # "Energy Charge", "Energy Rate", "Usage Charge", and "nerg Charge" (a
  # PDF with no "E" and no "y" in its text).
  defp energy_line?(text),
    do:
      text =~ ~r/(energy|nerg|usage)\s+(charge|rate)/i and not base_line?(text) and
        not (text =~ ~r/deliver|consists? of|night/i)

  # A price for each kWh: "6.8673¢", or "$0.068673 per kWh" (under $1).
  defp per_kwh(text) do
    case {cents(text), money(text)} do
      {nil, dollars} when is_number(dollars) and dollars < 1 -> Float.round(dollars * 100, 6)
      {cents, _dollars} -> cents
    end
  end

  defp energy(lines) do
    found =
      with_next(lines, fn line, next ->
        if energy_line?(line.text) do
          case per_kwh(line.text) do
            nil -> on_next(next, &per_kwh/1)
            cents -> {cents, line}
          end
        end
      end)

    case found do
      {cents, line} ->
        # "The Energy Charge is only applicable to usage above 1000 kWh."
        case Enum.find_value(lines, &above/1) do
          {kwh, above_line} -> {[{0, 0.0}, {kwh, cents}], [line, above_line]}
          nil -> {[{0, cents}], [line]}
        end

      nil ->
        {[{0, 0.0}], []}
    end
  end

  defp above(line) do
    case Regex.run(
           ~r/energy charge is only applicable to usage above (\d[\d,]*)\s*kWh/i,
           line.text
         ) do
      [_, kwh] -> {round(number(kwh)), line}
      nil -> nil
    end
  end

  ## The price of the night

  defp night(lines) do
    with %{} = line <-
           Enum.find(lines, &(&1.text =~ ~r/night.*energy charge|energy charge.*night/i)),
         cents when is_number(cents) <- cents(line.text),
         {share, share_line} <- share(lines),
         {from, to, hours_line} <- hours(lines) do
      {%{cents: cents, from: from, to: to, share: share}, [line, share_line, hours_line]}
    else
      _ -> {nil, []}
    end
  end

  # "assumes that 35% of the Average Monthly Use occurs during the ... hours"
  defp share(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/assumes that (\d+)% of/i, line.text) do
        [_, percent] -> {number(percent) / 100, line}
        nil -> nil
      end
    end)
  end

  # "... hours are 11:00 PM to 06:00 AM"
  defp hours(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(
             ~r/hours are (\d{1,2}):\d\d\s*([AP]M) to (\d{1,2}):\d\d\s*([AP]M)/i,
             line.text
           ) do
        [_, from, from_half, to, to_half] -> {hour(from, from_half), hour(to, to_half), line}
        nil -> nil
      end
    end)
  end

  defp hour(text, half) do
    hour = String.to_integer(text)

    case String.upcase(half) do
      "PM" when hour < 12 -> hour + 12
      "AM" when hour == 12 -> 0
      _ -> hour
    end
  end

  ## The delivery charges

  defp tdu_line?(text),
    do:
      text =~ ~r/deliver|\bTDU\b|\bTDSP\b|\boncor charges/i and
        not (text =~ ~r/include|consists? of|passed through|updated/i)

  defp tdu(lines) do
    lines
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.reduce({%{}, []}, fn [line, next], {tdu, found} ->
      if tdu_line?(line.text) do
        {tdu, found} = tdu_numbers(line, tdu, found)

        # The numbers on the next line: "Oncor Delivery Charges:", then
        # "$4.06 per billing cycle and 6.8673¢ per kwh".
        if next != nil and not tdu_line?(next.text) and not (next.text =~ ~r/charge/i),
          do: tdu_numbers(next, tdu, found),
          else: {tdu, found}
      else
        {tdu, found}
      end
    end)
  end

  defp tdu_numbers(line, tdu, found) do
    # "$0.068673 per kWh" is a price for each kWh; "$0.00 per bill month" is
    # not.
    {cents, dollars} =
      case {cents(line.text), money(line.text)} do
        {nil, d} when is_number(d) and d < 1 ->
          if line.text =~ ~r/kwh/i, do: {Float.round(d * 100, 6), nil}, else: {nil, d}

        found ->
          found
      end

    tdu =
      tdu
      |> then(&if(cents && !&1[:cents], do: Map.put(&1, :cents, cents), else: &1))
      |> then(&if(dollars && !&1[:base], do: Map.put(&1, :base, dollars), else: &1))

    found = if cents || dollars, do: found ++ [line], else: found
    {tdu, Enum.uniq(found)}
  end

  # An EFL with no delivery charges: the charges of its utility, else the
  # charges from its averages.
  defp fill_tdu(%{tdu_base: base, tdu_cents: cents} = plan, _lines)
       when is_number(base) and is_number(cents),
       do: {plan, %{}}

  defp fill_tdu(plan, lines) do
    case Enum.find_value(lines, &Plan.tdu(&1.text)) do
      %{base: base, cents: cents, name: name} ->
        {%{plan | tdu_base: plan.tdu_base || base, tdu_cents: plan.tdu_cents || cents},
         %{tdu_from: {:table, name}}}

      nil ->
        case Plan.fit_tdu(plan) do
          nil -> {plan, %{tdu_from: :none}}
          fitted -> {fitted, %{tdu_from: :averages}}
        end
    end
  end

  ## The credits and the minimum usage fee

  # The sentences of the lines: a line can have more than one sentence,
  # and a sentence can go on in the next line (when the next line starts
  # with a small letter).
  defp sentences(lines) do
    {done, open} =
      Enum.reduce(lines, {[], nil}, fn line, {done, open} ->
        {done, start, text} =
          case open do
            {start, open_text} ->
              if line.text =~ ~r/^[a-z]/,
                do: {done, start, open_text <> " " <> line.text},
                else: {done ++ [{start, open_text}], line, line.text}

            nil ->
              {done, line, line.text}
          end

        {whole, [last]} =
          ~r/(?<=[a-z0-9)%]\.)\s+(?=[A-Z$])/ |> Regex.split(text) |> Enum.split(-1)

        # After a split, the last part starts on this line.
        {done ++ Enum.map(whole, &{start, &1}), {if(whole == [], do: start, else: line), last}}
      end)

    done ++ [open]
  end

  defp credits(lines) do
    found =
      for {line, text} <- sentences(lines),
          text =~ ~r/credit/i,
          not (text =~ ~r/deposit|card|check|late|not be applied|fee of/i),
          dollars = money(text),
          dollars && dollars > 0 do
        {%{dollars: dollars, min_kwh: min_kwh(text), months: months(text)}, line}
      end

    {Enum.map(found, &elem(&1, 0)), Enum.map(found, &elem(&1, 1))}
  end

  defp min_kwh(text) do
    case Regex.run(
           ~r/(?:>=|≥|at least|greater than or equal to)\s*(\d[\d,]*)\s*kWh|(\d[\d,]*)\s*kWh or more/i,
           text
         ) do
      [_, kwh] -> round(number(kwh))
      [_, "", kwh] -> round(number(kwh))
      nil -> 0
    end
  end

  defp months(text) do
    case for(
           {name, i} <- Enum.with_index(@months, 1),
           String.contains?(String.downcase(text), name),
           do: i
         ) do
      [] -> nil
      months -> months
    end
  end

  defp min_fee(lines) do
    Enum.find_value(sentences(lines), {nil, nil}, fn {line, text} ->
      with true <- text =~ ~r/minimum usage/i,
           dollars when is_number(dollars) and dollars > 0 <- money(text),
           [_, kwh] <- Regex.run(~r/(?:<|less than|below|under)\s*(\d[\d,]*)\s*kWh/i, text) do
        {%{dollars: dollars, below_kwh: round(number(kwh))}, line}
      else
        _ -> nil
      end
    end)
  end
end
