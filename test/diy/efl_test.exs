defmodule DIY.EFLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, EFL, Plan}

  # The lines of a test EFL, as the browser gives them
  # (test/fixtures/efl/NAME.json, from scripts/efl_lines.mjs).
  defp lines(name) do
    "test/fixtures/efl/#{name}.json" |> File.read!() |> Jason.decode!()
  end

  defp read(name) do
    {:ok, result} = EFL.read(lines(name))
    result
  end

  @oncor {4.06, 6.8673}

  # The check of phase 4: the numbers of 10 EFLs of October 2026 (Oncor),
  # as a person reads them on each label. Each one: the base charge, the
  # energy charge (tiers), the delivery charges, the credits, the minimum
  # usage fee, the price of the night, and the averages of the label.
  @expected [
    {"discount-saver-18",
     %{base: 0.0, energy: [{0, 7.7174}], tdu: @oncor, credits: [], averages: {15.4, 15.0, 14.8}}},
    {"reliant-power-on-9",
     %{base: 5.0, energy: [{0, 6.6674}], tdu: @oncor, credits: [], averages: {15.3, 14.4, 14.0}}},
    {"gexa-eco-choice-3",
     %{base: 0.0, energy: [{0, 3.27}], tdu: @oncor, credits: [], averages: {10.9, 10.5, 10.3}}},
    {"txu-smart-1000-select-12",
     %{
       base: 9.95,
       energy: [{0, 13.7}],
       tdu: @oncor,
       credits: [
         %{dollars: 100.0, min_kwh: 1000, months: nil},
         %{dollars: 25.0, min_kwh: 1000, months: [7, 8, 9]}
       ],
       averages: {23.4, 11.3, 16.0}
     }},
    {"apge-bonus-saver-3",
     %{
       base: 0.0,
       energy: [{0, 6.43}],
       tdu: @oncor,
       credits: [%{dollars: 100.0, min_kwh: 2000, months: nil}],
       averages: {14.1, 13.7, 8.5}
     }},
    {"constellation-ac-protect-plus-12",
     %{
       base: 0.0,
       energy: [{0, 12.12}],
       tdu: @oncor,
       credits: [
         %{dollars: 35.0, min_kwh: 1000, months: nil},
         %{dollars: 15.0, min_kwh: 2000, months: nil}
       ],
       averages: {19.8, 15.9, 16.7}
     }},
    {"rhythm-digital-choice-24",
     %{
       base: 0.0,
       energy: [{0, 7.114}],
       tdu: @oncor,
       credits: [%{dollars: 5.0, min_kwh: 0, months: nil}],
       averages: {13.8, 13.9, 13.9}
     }},
    {"chariot-bright-nights-8",
     %{
       base: 9.95,
       energy: [{0, 5.79}],
       night: %{cents: 0.0, from: 23, to: 6, share: 0.35},
       tdu: @oncor,
       credits: [],
       averages: {13.4, 12.0, 11.3}
     }},
    {"texans-choice-instant-12",
     %{
       base: 125.0,
       energy: [{0, 0.0}, {1000, 14.0}],
       tdu: {0.0, 0.0},
       credits: [],
       averages: {25.0, 12.5, 13.3}
     }},
    {"bkv-daisy-24",
     %{base: 0.0, energy: [{0, 7.172}], tdu: @oncor, credits: [], averages: {14.9, 14.4, 14.2}}}
  ]

  for {name, expected} <- @expected do
    test "the numbers of the EFL #{name}" do
      expected = unquote(Macro.escape(expected))
      %{plan: plan, check: check} = read(unquote(name))
      assert plan.base == expected.base
      assert plan.energy == expected.energy
      assert {plan.tdu_base, plan.tdu_cents} == expected.tdu
      assert plan.credits == expected.credits
      assert plan.night == expected[:night]
      assert plan.min_fee == nil
      {a, b, c} = expected.averages
      assert plan.averages == %{500 => a, 1000 => b, 2000 => c}
      assert check.ok, inspect(check)
    end
  end

  # An EFL of CenterPoint, with a minimum usage fee and a credit of 1,000
  # kWh or more ("equal or greater than").
  test "an EFL of CenterPoint with a minimum usage fee" do
    %{plan: plan, check: check, sources: sources} = read("just-energy-smart-choice-12")
    assert plan.base == 0.0
    assert plan.energy == [{0, 15.4}]
    assert {plan.tdu_base, plan.tdu_cents} == {4.9, 6.5333}
    assert plan.credits == [%{dollars: 125.0, min_kwh: 1000, months: nil}]
    assert plan.min_fee == %{dollars: 4.99, below_kwh: 400}
    assert plan.averages == %{500 => 22.9, 1000 => 9.9, 2000 => 15.9}
    assert check.ok
    assert sources.min_fee.text =~ "A Minimum Usage Fee of $4.99"
    assert sources.tdu_from == :efl
  end

  test "each number has its line" do
    %{sources: sources} = read("txu-smart-1000-select-12")
    assert sources.averages.text =~ "Average Price per kWh"
    assert sources.base.text =~ "$9.95"
    assert [%{text: "Electricity  All kWh  13.7000¢"}] = sources.energy
    assert sources.tdu == []
    assert sources.tdu_from == {:table, "Oncor"}
    assert [first, summer] = sources.credits
    assert first.text =~ "A bill credit of $100.00"
    # The source of a credit is its full sentence, with its months.
    assert summer.text =~ "A $25.00 summer bill credit"
    assert summer.text =~ "July, August, and September"

    %{sources: sources} = read("chariot-bright-nights-8")
    assert [day] = sources.energy
    assert day.text =~ "Daytime Energy Charge"
    assert [night, share, hours] = sources.night
    assert night.text =~ "Bright Nights Energy Charge"
    assert share.text =~ "35%"
    assert hours.text =~ "11:00 PM to 06:00 AM"

    %{sources: sources} = read("texans-choice-instant-12")
    assert [_energy, above] = sources.energy
    assert above.text =~ "only applicable to usage above 1000 kWh"
  end

  test "a PDF that lost letters in its text, and a charge in dollars for each kWh" do
    # The font of this PDF has no Unicode for some letters: "nerg Charge".
    %{plan: plan, check: check} = read("ae-texas-smart-secure-9")
    assert plan.energy == [{0, 5.39}]
    assert {plan.tdu_base, plan.tdu_cents} == @oncor
    assert check.ok
  end

  test "an EFL of a form that the reader does not know fails its check" do
    # Its numbers are in columns under their names.
    %{check: check} = read("champion-champ-saver-24")
    refute check.ok
    assert Enum.any?(check.rows, &(not &1.ok))
  end

  test "the lines that are not an EFL" do
    assert EFL.read([%{"page" => 1, "text" => "A letter"}]) == {:error, :averages}
    assert EFL.read([%{"page" => 0, "text" => "x"}]) == {:error, :lines}
    # At most 64 KB of text in all.
    long = List.duplicate(%{"page" => 1, "text" => String.duplicate("x", 2000)}, 33)
    assert EFL.read(long) == {:error, :lines}
    assert EFL.read([]) == {:error, :lines}
    assert EFL.read("lines") == {:error, :lines}
  end

  defp efl(lines), do: EFL.read(Enum.map(lines, &%{"page" => 1, "text" => &1}))

  test "the forms of the numbers" do
    # Averages on the next line, a minimum usage fee, a credit of the
    # summer months, delivery charges with no utility in the table: from
    # the averages.
    {:ok, %{plan: plan, sources: sources}} =
      efl([
        "Average Price per kWh",
        "20.0¢  17.0¢  16.0¢",
        "Base Charge: $5.00 per month",
        "Energy Charge: $0.10 per kWh",
        "Minimum Usage Fee: $10.00 per month if usage is less than 1,000 kWh",
        "A $20.00 bill credit applies in June and July when usage is at least 1,500 kWh."
      ])

    assert plan.min_fee == %{dollars: 10.0, below_kwh: 1000}
    assert plan.credits == [%{dollars: 20.0, min_kwh: 1500, months: [6, 7]}]
    assert plan.energy == [{0, 10.0}]
    assert sources.tdu_from == :averages
    assert plan.tdu_base > 0 and plan.tdu_cents > 0

    # Averages that no delivery charges can give.
    {:ok, %{plan: plan, sources: sources}} =
      efl(["Average price per kWh 1.0¢ 1.0¢ 1.0¢", "Energy Charge 50¢ per kWh"])

    assert sources.tdu_from == :none
    assert plan.tdu_base == nil

    # No energy charge, a base charge on the next line, and a price of the
    # night with no hours.
    {:ok, %{plan: plan}} =
      efl([
        "Average price per kWh 12.0¢ 11.0¢ 10.5¢",
        "Base Charge:",
        "$4.95 per month",
        "Night Energy Charge 0¢ per kWh",
        "Oncor Delivery Charge 6.8673¢ per kWh and $4.06 per month"
      ])

    assert plan.base == 4.95
    assert plan.energy == [{0, 0.0}]
    assert plan.night == nil

    # Hours of the night at noon and at midnight.
    {:ok, %{plan: plan}} =
      efl([
        "Average price per kWh 12.0¢ 11.0¢ 10.5¢",
        "Free Nights Energy Charge 0¢ per kWh",
        "The price assumes that 40% of the use is at night.",
        "Free hours are 12:00 AM to 12:00 PM."
      ])

    assert plan.night == %{cents: 0.0, from: 0, to: 12, share: 0.4}

    assert %{tdu_from: {:table, "Oncor"}} =
             Map.take(elem(efl(["Oncor", "Average price per kWh 1.0¢ 1.0¢ 1.0¢"]), 1).sources, [
               :tdu_from
             ])
  end

  test "the months of a credit: names with a capital letter, and ranges" do
    averages = "Average price per kWh 12.0¢ 11.0¢ 10.5¢"

    credits = fn text ->
      {:ok, %{plan: plan}} = efl([averages, text])
      plan.credits
    end

    # "may" is not May.
    assert [%{months: nil}] =
             credits.(
               "You may get a bill credit of $100.00 in each billing cycle with usage of 1,000 kWh or more."
             )

    assert [%{months: [6, 7, 8, 9]}] =
             credits.("A bill credit of $30.00 applies from June through September.")

    assert [%{months: [1, 2, 11, 12]}] =
             credits.("A bill credit of $10.00 applies from November to February.")

    # "marches" is not March.
    assert [%{months: nil}] = credits.("A bill credit of $5.00 marches on each month.")
  end

  test "no fit of the delivery charges when the reader finds no energy charge" do
    {:ok, %{plan: plan, sources: sources}} =
      efl(["Average price per kWh 15.0¢ 14.5¢ 14.3¢", "Price per kWh: 10.0¢"])

    assert plan.energy == [{0, 0.0}]
    assert plan.tdu_base == nil and plan.tdu_cents == nil
    assert sources.tdu_from == :none
  end

  test "a name with no number on its line, as the last line" do
    {:ok, %{plan: plan}} = efl(["Average price per kWh 12.0¢ 11.0¢ 10.5¢", "Base Charge:"])
    assert plan.base == 0.0
  end

  test "the delivery charges of a utility" do
    assert Plan.tdu("Oncor Electric Delivery") == %{name: "Oncor", base: 4.06, cents: 6.8673}
    assert Plan.tdu("CenterPoint Energy") == %{name: "CenterPoint", base: 4.9, cents: 6.5333}
    assert Plan.tdu("AEP Texas Central") == nil
  end

  # The lines of all the test EFLs.
  @texts "test/fixtures/efl/*.json"
         |> Path.wildcard()
         |> Enum.flat_map(&(&1 |> File.read!() |> Jason.decode!()))
         |> Enum.map(& &1["text"])

  # A line of an EFL with other numbers in it.
  defp changed_line do
    bind(member_of(@texts), fn text ->
      number = one_of([integer(0..100_000), float(min: 0.0, max: 1000.0)])

      map(list_of(number, min_length: 1, max_length: 6), fn numbers ->
        ~r/\d+(?:\.\d+)?/
        |> Regex.split(text, include_captures: true)
        |> Enum.map_reduce(numbers, fn part, [n | rest] ->
          if part =~ ~r/\A\d/, do: {to_string(n), rest ++ [n]}, else: {part, [n | rest]}
        end)
        |> elem(0)
        |> Enum.join()
      end)
    end)
  end

  defp line do
    one_of([member_of(@texts), changed_line(), string(:printable, max_length: 80)])
  end

  # An EFL from parts of the test EFLs, with other numbers and other text:
  # the reader gives a result or an error, and the build keeps only a plan
  # that it can load again.
  property "the reader never raises, and a build with its plan loads again" do
    check all(texts <- list_of(line(), min_length: 1, max_length: 60)) do
      case EFL.read(Enum.map(texts, &%{"page" => 1, "text" => &1})) do
        {:ok, %{plan: plan, check: check}} ->
          assert check == nil or is_boolean(check.ok)

          case Build.add_plan(Build.new(), %{plan | name: "A plan"}) do
            {:ok, build, _id} -> assert {:ok, _} = Build.from_json(Build.to_json(build))
            {:error, :plan} -> :ok
          end

        {:error, reason} ->
          assert reason in [:averages, :lines]
      end
    end
  end
end
