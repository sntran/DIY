defmodule DIYWeb.LessonPage do
  @moduledoc """
  The page of the plan lesson (`DIY.Lesson`): learn to compare the plans
  of the retail electric providers in Texas. It shows only for a house in
  an area with retail choice.

  The page does not pick a plan, and it does not rank plans (honesty rule
  4): the worksheet shows the plans in the order that the user added them.
  """
  use DIYWeb, :html

  alias DIY.Lesson
  alias DIYWeb.Format

  @steps [
    {1, "A worked example"},
    {2, "Your data, with help"},
    {3, "Fewer hints"},
    {4, "On your own"}
  ]

  @part_names %{
    energy: "Energy charge",
    base: "Base charge",
    tdu: "Delivery charges",
    credits: "Credits",
    fee: "Minimum usage fee",
    total: "The bill"
  }

  attr :build, :map, required: true
  attr :bill, :map, required: true
  attr :step, :integer, required: true
  attr :plan_id, :string, default: nil
  attr :efl, :map, default: nil
  attr :checks, :map, default: nil
  attr :hint, :boolean, default: false
  attr :shares, :map, default: %{}
  attr :tdu, :map, default: nil, doc: "the delivery charges of the utility (DIY.Plan.tdu/1)"

  def page(assigns) do
    {months, source} = Lesson.months(assigns.build, assigns.bill)
    assigns = assign(assigns, months: months, source: source, steps: @steps)

    ~H"""
    <section id="lesson" class="space-y-6">
      <div class="space-y-2">
        <h1 class="text-xl font-bold">Learn to compare plans</h1>
        <p class="text-sm">
          Your usage is not flat through the year. A plan that is cheap at 1,000 kWh can cost more in a 2,000 kWh summer month or in a 600 kWh spring month. The app shows the math of each bill for your months. You choose: the app does not pick a plan, and it does not rank plans.
        </p>
      </div>

      <nav aria-label="The steps of the lesson" class="flex flex-wrap gap-1">
        <.link
          :for={{n, name} <- @steps}
          :if={n <= @build.lesson}
          patch={~p"/plans?#{[step: n]}"}
          class={["btn btn-sm", if(n == @step, do: "btn-primary", else: "btn-ghost")]}
          aria-current={n == @step && "step"}
        >
          {n}. {name}
        </.link>
      </nav>

      <.example :if={@step == 1} />
      <.with_help
        :if={@step == 2}
        build={@build}
        months={@months}
        source={@source}
        plan={plan(@build, @plan_id)}
        checks={@checks}
        efl={@efl}
        shares={@shares}
      />
      <.fewer_hints
        :if={@step == 3}
        build={@build}
        months={@months}
        plan={second_plan(@build)}
        checks={@checks}
        hint={@hint}
        efl={@efl}
        shares={@shares}
        tdu={@tdu}
      />
      <.worksheet
        :if={@step == 4}
        build={@build}
        months={@months}
        source={@source}
        efl={@efl}
        shares={@shares}
        tdu={@tdu}
      />
    </section>
    """
  end

  # The plan of step 2: the plan that the user chose, else the plan that
  # the user did, else the first plan of the worksheet, else the example
  # plan.
  defp plan(build, id) do
    find = fn id -> Enum.find(build.plans, &(&1.id == id)) end

    find.(id) || find.(build.lesson_plan) || List.first(build.plans) || Lesson.example_plan()
  end

  # The plan of step 3: the last plan of the worksheet that is not the plan
  # that the user did in step 2, or nil.
  defp second_plan(build) do
    done = build.lesson_plan || plan(build, nil).id
    build.plans |> Enum.reverse() |> Enum.find(&(&1.id != done))
  end

  defp shares(shares, plan), do: fn month -> shares[{plan.id, month}] end

  ## Step 1

  defp example(assigns) do
    plan = Lesson.example_plan()
    months = Lesson.example_months()
    year = Lesson.rows(plan, months)
    july = Enum.find(year.rows, &(&1.month == 7))
    april = Enum.find(year.rows, &(&1.month == 4))
    assigns = assign(assigns, plan: plan, year: year, july: july, april: april)

    ~H"""
    <div id="example" class="space-y-3">
      <h2 class="text-lg font-bold">1. A worked example</h2>
      <p class="text-sm">
        A sample house, and the numbers of a real EFL (Electricity Facts Label) of October 2026 in the Oncor area. Each plan in Texas has an EFL. It gives the parts of the bill:
      </p>
      <.plan_numbers plan={@plan} />
      <p class="text-sm">
        The EFL says that the plan costs 11.3¢ for each kWh at 1,000 kWh in one month. Here is the bill of each month of the sample house:
      </p>
      <.year_table year={@year} />
      <p class="text-sm font-semibold">
        In one year: {Format.money(@year.total)} for {Format.kwh(@year.kwh)}: {Format.cents(
          @year.cents
        )} for each kWh, not 11.3¢.
      </p>
      <p class="text-sm">
        In April, the house uses {Format.kwh(@april.kwh)}: less than 1,000 kWh, so it gets no credit, and it pays {Format.cents(
          @april.cents
        )} for each kWh.
      </p>
      <div class="card card-border p-3 text-sm space-y-1">
        <p class="font-semibold">Each step of the bill of July ({Format.kwh(@july.kwh)})</p>
        <ol class="list-decimal pl-5 space-y-1">
          <li>
            Energy charge: {Format.int(@july.kwh)} kWh × 13.7¢ ÷ 100 = {money(@july.energy)}.
          </li>
          <li>Base charge: {money(@july.base)}.</li>
          <li>
            Delivery charges of Oncor: $4.06 + {Format.int(@july.kwh)} kWh × 6.8673¢ ÷ 100 = {money(
              @july.tdu
            )}.
          </li>
          <li>
            Credits: $100 for 1,000 kWh or more, and $25 more in July: −{money(@july.credits)}.
          </li>
          <li>
            The bill: {money(@july.energy)} + {money(@july.base)} + {money(@july.tdu)} − {money(
              @july.credits
            )} = {money(@july.total)}.
          </li>
        </ol>
      </div>
      <button type="button" phx-click="lesson" phx-value-step="2" class="btn btn-primary btn-sm">
        Next: your data
      </button>
    </div>
    """
  end

  ## Step 2

  attr :build, :map, required: true
  attr :months, :list, required: true
  attr :source, :atom, required: true
  attr :plan, :map, required: true
  attr :checks, :map, default: nil
  attr :efl, :map, default: nil
  attr :shares, :map, required: true

  defp with_help(assigns) do
    month = Lesson.exercise_month(assigns.months)
    bill = Lesson.bill(assigns.plan, month, assigns.shares[{assigns.plan.id, month.month}])

    done = assigns.checks != nil and Lesson.done?(assigns.checks)
    assigns = assign(assigns, month: month, bill: bill, done: done)

    ~H"""
    <div id="with-help" class="space-y-3">
      <h2 class="text-lg font-bold">2. Your data, with help</h2>
      <.your_months months={@months} source={@source} />

      <div class="space-y-2">
        <h3 class="font-semibold">Your plan</h3>
        <form :if={@build.plans != []} id="lesson-plan" phx-change="lesson_plan">
          <fieldset class="space-y-1">
            <legend class="sr-only">The plan of the exercise</legend>
            <label :for={p <- @build.plans} class="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="plan"
                value={p.id}
                checked={p.id == @plan.id}
                class="radio radio-sm"
              />
              {p.name}
            </label>
          </fieldset>
        </form>
        <p :if={@build.plans == []} class="text-sm">
          The exercise uses the example plan. Open the EFL of a plan that you want to check: the exercise then uses it.
        </p>
        <.efl_reader efl={@efl} />
        <.plan_numbers plan={@plan} />
      </div>

      <form id="exercise" phx-submit="exercise" class="card card-border p-3 space-y-2">
        <input type="hidden" name="plan" value={@plan.id || "example"} />
        <p class="font-semibold">
          The bill of {@month.name}, your month with the most use: {Format.kwh(@month.kwh)}
        </p>
        <p class="text-sm opacity-80">Give each part in dollars. The app checks each one.</p>
        <.answer
          :for={part <- Lesson.parts(@plan)}
          part={part}
          check={@checks && @checks[part]}
          hint={hint(part, @plan, @month, @bill)}
        />
        <button class="btn btn-sm">Check</button>
        <.result checks={@checks} />
      </form>

      <div :if={@done} id="exercise-done" class="space-y-2">
        <p class="font-semibold">
          Each step is right. The app does the other 11 months:
        </p>
        <.year_table year={Lesson.rows(@plan, @months, shares(@shares, @plan))} />
        <button type="button" phx-click="lesson" phx-value-step="3" class="btn btn-primary btn-sm">
          Next: fewer hints
        </button>
      </div>
    </div>
    """
  end

  attr :part, :atom, required: true
  attr :check, :atom, default: nil
  attr :hint, :string, default: nil

  defp answer(assigns) do
    assigns = assign(assigns, :name, part_name(assigns.part))

    ~H"""
    <label class="block text-sm">
      <span class="font-semibold">{@name}</span>
      <span :if={@check == :ok} class="font-semibold">✓ right</span>
      <span :if={@check == :wrong} class="text-error">✗ check it</span>
      <span :if={@check == :invalid} class="text-error">
        ✗ give a number of dollars, for example 12.34
      </span>
      <input
        name={"answer[#{@part}]"}
        id={"answer-#{@part}"}
        inputmode="decimal"
        placeholder="$"
        class={["input input-sm w-32 block", @check in [:wrong, :invalid] && "input-error"]}
      />
      <span :if={@hint} class="text-xs opacity-80">{@hint}</span>
    </label>
    """
  end

  defp part_name(part), do: Map.fetch!(@part_names, part)

  attr :checks, :map, default: nil

  # The result of a check, for a screen reader too.
  defp result(assigns) do
    ~H"""
    <p role="status" class="text-sm">
      {if @checks,
        do:
          "#{Enum.count(@checks, fn {_part, check} -> check == :ok end)} of #{map_size(@checks)} right."}
    </p>
    """
  end

  # The help of each part, with the numbers of the plan and of the month.
  defp hint(:energy, %{night: nil, energy: [{0, cents}]}, month, _bill),
    do: "#{Format.int(month.kwh)} kWh × #{num(cents)}¢ ÷ 100"

  defp hint(:energy, %{night: nil}, _month, _bill),
    do: "Each part of the kWh at the price of its tier, ÷ 100."

  defp hint(:energy, %{night: night, energy: [{0, cents}]}, month, bill),
    do:
      "Day: #{Format.int(month.kwh - bill.night_kwh)} kWh × #{num(cents)}¢ ÷ 100, and night: " <>
        "#{Format.int(bill.night_kwh)} kWh × #{num(night.cents)}¢ ÷ 100. " <>
        night_text(night, bill)

  defp hint(:energy, %{night: night}, month, bill),
    do:
      "The price of the tiers for all #{Format.int(month.kwh)} kWh, for the #{Format.int(month.kwh - bill.night_kwh)} kWh of the day, and " <>
        "#{Format.int(bill.night_kwh)} kWh × #{num(night.cents)}¢ ÷ 100 for the night. " <>
        night_text(night, bill)

  defp hint(:base, plan, _month, _bill), do: "The base charge of the plan: #{money(plan.base)}."

  defp hint(:tdu, plan, month, _bill),
    do:
      "#{money(plan.tdu_base || 0)} + #{Format.int(month.kwh)} kWh × #{num(plan.tdu_cents || 0)}¢ ÷ 100"

  defp hint(:credits, %{credits: []}, _month, _bill), do: "The plan has no credit: $0."

  defp hint(:credits, plan, month, _bill),
    do:
      "The credits for #{Format.kwh(month.kwh)} in #{month.name}: " <>
        Enum.map_join(plan.credits, ", ", &credit_text/1) <> "."

  defp hint(:fee, plan, _month, _bill),
    do: "#{money(plan.min_fee.dollars)} for a month under #{Format.kwh(plan.min_fee.below_kwh)}."

  defp hint(:total, _plan, _month, _bill),
    do: "Energy + base + delivery − credits (+ the minimum usage fee)."

  # Where the kWh at night come from.
  defp night_text(night, %{night_from: :house}),
    do:
      "The kWh at night (#{night.from}:00 to #{night.to}:00) come from the day of your house (the page Power), not from the EFL."

  defp night_text(night, %{night_from: :efl}),
    do: "The kWh at night: #{round(night.share * 100)}% of the month, as the EFL says."

  defp credit_text(%{dollars: d, min_kwh: 0, months: nil}), do: "#{money(d)} each month"

  defp credit_text(%{dollars: d, min_kwh: kwh, months: nil}),
    do: "#{money(d)} for #{Format.kwh(kwh)} or more"

  defp credit_text(%{dollars: d, min_kwh: kwh, months: months}),
    do:
      "#{money(d)} for #{Format.kwh(kwh)} or more in " <>
        Enum.map_join(months, ", ", &Enum.at(DIY.Estimate.month_names(), &1 - 1))

  ## Step 3

  attr :build, :map, required: true
  attr :months, :list, required: true
  attr :plan, :map, default: nil
  attr :checks, :map, default: nil
  attr :hint, :boolean, default: false
  attr :efl, :map, default: nil
  attr :shares, :map, required: true
  attr :tdu, :map, default: nil

  defp fewer_hints(assigns) do
    month = Lesson.exercise_month(assigns.months)

    bill =
      assigns.plan &&
        Lesson.bill(assigns.plan, month, assigns.shares[{assigns.plan.id, month.month}])

    assigns = assign(assigns, month: month, bill: bill)

    ~H"""
    <div id="fewer-hints" class="space-y-3">
      <h2 class="text-lg font-bold">3. Fewer hints</h2>
      <%= if @plan do %>
        <.plan_numbers plan={@plan} />
        <form id="exercise" phx-submit="exercise" class="card card-border p-3 space-y-2">
          <input type="hidden" name="plan" value={@plan.id} />
          <input type="hidden" name="parts" value="total" />
          <p class="font-semibold">
            The bill of {@month.name} with {@plan.name}: {Format.kwh(@month.kwh)}
          </p>
          <.answer part={:total} check={@checks && @checks[:total]} />
          <button class="btn btn-sm">Check</button>
          <.result checks={@checks} />
          <button :if={not @hint} type="button" phx-click="hint" class="btn btn-sm btn-ghost">
            Show a hint
          </button>
          <ul :if={@hint} class="list-disc pl-5 text-xs opacity-80">
            <li :for={part <- Lesson.parts(@plan) -- [:total]}>
              {part_name(part)}: {hint(part, @plan, @month, @bill)}
            </li>
          </ul>
        </form>
        <div :if={@checks && Lesson.done?(@checks)} id="exercise-done" class="space-y-2">
          <p class="font-semibold">
            Right: {money(@bill.total)}. You can compare any plan now.
          </p>
          <button type="button" phx-click="lesson" phx-value-step="4" class="btn btn-primary btn-sm">
            Next: on your own
          </button>
        </div>
      <% else %>
        <p class="text-sm">
          Add a second plan: open its EFL, or give its numbers. A plan from a broker or a neighbor is good too.
        </p>
        <.efl_reader efl={@efl} />
        <.plan_form tdu={@tdu} />
      <% end %>
    </div>
    """
  end

  ## Step 4

  attr :build, :map, required: true
  attr :months, :list, required: true
  attr :source, :atom, required: true
  attr :efl, :map, default: nil
  attr :shares, :map, required: true
  attr :tdu, :map, default: nil

  defp worksheet(assigns) do
    years =
      for p <- assigns.build.plans,
          do: {p, Lesson.rows(p, assigns.months, shares(assigns.shares, p))}

    assigns = assign(assigns, :years, years)

    ~H"""
    <div id="worksheet" class="space-y-3">
      <h2 class="text-lg font-bold">4. On your own: the worksheet</h2>
      <p class="text-sm">
        Each plan with your months, in the order that you added them. The app shows the math. You choose.
      </p>
      <div
        :if={@years != []}
        class="overflow-x-auto"
        tabindex="0"
        role="region"
        aria-label="The worksheet"
      >
        <table class="table table-xs sm:table-sm" id="worksheet-table">
          <thead>
            <tr>
              <th>Month</th>
              <th class="text-right">kWh</th>
              <th :if={@source == :estimate} class="text-right">Range</th>
              <th :for={{p, _year} <- @years} class="text-right">{p.name}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @months}>
              <td>{m.name}</td>
              <td class="text-right">{Format.int(m.kwh)}</td>
              <td :if={@source == :estimate} class="text-right">
                {Format.int(m.low)} to {Format.int(m.high)}
              </td>
              <td :for={{_p, year} <- @years} class="text-right">
                {money(Enum.at(year.rows, m.month - 1).total)}
              </td>
            </tr>
          </tbody>
          <tfoot>
            <tr>
              <th>Year</th>
              <th class="text-right">{Format.int(Enum.sum(Enum.map(@months, & &1.kwh)))}</th>
              <td :if={@source == :estimate}></td>
              <th :for={{_p, year} <- @years} class="text-right">{Format.money(year.total)}</th>
            </tr>
            <tr :if={@source == :estimate}>
              <th>Range of the year</th>
              <td></td>
              <td></td>
              <td :for={{_p, year} <- @years} class="text-right">
                {Format.money(year.total_low)} to {Format.money(year.total_high)}
              </td>
            </tr>
            <tr>
              <th>For each kWh</th>
              <td></td>
              <td :if={@source == :estimate}></td>
              <th :for={{_p, year} <- @years} class="text-right">{cents(year.cents)}</th>
            </tr>
            <tr>
              <th>Remove</th>
              <td></td>
              <td :if={@source == :estimate}></td>
              <td :for={{p, _year} <- @years} class="text-right">
                <button
                  type="button"
                  phx-click="delete_plan"
                  phx-value-id={p.id}
                  class="btn btn-xs btn-ghost"
                  aria-label={"Remove #{p.name}"}
                >
                  ✕
                </button>
              </td>
            </tr>
          </tfoot>
        </table>
      </div>
      <p :if={@source == :estimate} class="text-xs opacity-80">
        The range: the kWh of each month from the weather of 10 years and the limits of the model, and the least and the most bill in that range.
      </p>
      <p
        :for={{p, year} <- @years}
        :if={p.night}
        id={"night-#{p.id}"}
        class="text-xs opacity-80"
      >
        {p.name}: the kWh at night ({p.night.from}:00 to {p.night.to}:00) of each month: {Enum.map_join(
          year.rows,
          ", ",
          &"#{String.slice(&1.name, 0, 3)} #{Format.int(&1.night_kwh)}"
        )}. {night_source(hd(year.rows))}
      </p>
      <p :if={@years == []} class="text-sm">
        No plan yet. Open an EFL, or give the numbers of a plan.
      </p>
      <.efl_reader efl={@efl} />
      <.plan_form tdu={@tdu} />
    </div>
    """
  end

  defp night_source(%{night_from: :house}),
    do: "They come from the day of your house (the page Power), not from the EFL."

  defp night_source(%{night_from: :efl}), do: "They come from the part that the EFL says."

  ## The parts of the steps

  attr :months, :list, required: true
  attr :source, :atom, required: true

  defp your_months(assigns) do
    ~H"""
    <div class="space-y-1">
      <h3 class="font-semibold">Your 12 months</h3>
      <p class="text-xs opacity-80">
        {if @source == :meter,
          do: "From the file of your meter.",
          else:
            "From the estimate of your house, with its range: a file of your meter gives the real months."}
      </p>
      <ul class="grid grid-cols-3 sm:grid-cols-4 gap-1 text-xs" id="your-months">
        <li :for={m <- @months}>
          {String.slice(m.name, 0, 3)}: {Format.int(m.kwh)}
          <span :if={@source == :estimate} class="block opacity-70">
            {Format.int(m.low)} to {Format.int(m.high)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr :plan, :map, required: true

  # The numbers of a plan, in the words of an EFL.
  defp plan_numbers(assigns) do
    ~H"""
    <ul class="text-sm list-disc pl-5" id="plan-numbers">
      <li>Base charge: {money(@plan.base)} each month.</li>
      <li :for={{from, cents} <- @plan.energy}>
        Energy charge: {num(cents)}¢ for each kWh{if from > 0, do: " above #{Format.kwh(from)}"}{if @plan.night,
          do: " in the day"}.
      </li>
      <li :if={@plan.night}>
        At night ({@plan.night.from}:00 to {@plan.night.to}:00): {num(@plan.night.cents)}¢ for each kWh.
      </li>
      <li>
        Delivery charges of the utility: {money(@plan.tdu_base || 0)} each month and {num(
          @plan.tdu_cents || 0
        )}¢ for each kWh.
      </li>
      <li :for={c <- @plan.credits}>Credit: {credit_text(c)}.</li>
      <li :if={@plan.min_fee}>
        Minimum usage fee: {money(@plan.min_fee.dollars)} for a month under {Format.kwh(
          @plan.min_fee.below_kwh
        )}.
      </li>
    </ul>
    """
  end

  attr :year, :map, required: true

  defp year_table(assigns) do
    assigns =
      assign(assigns,
        night: Enum.any?(assigns.year.rows, & &1.night_kwh),
        range: Enum.any?(assigns.year.rows, &(&1.total_low != &1.total_high))
      )

    ~H"""
    <div class="overflow-x-auto" tabindex="0" role="region" aria-label="The bill of each month">
      <table class="table table-xs sm:table-sm">
        <thead>
          <tr>
            <th>Month</th>
            <th class="text-right">kWh</th>
            <th :if={@night} class="text-right">At night</th>
            <th class="text-right">Energy</th>
            <th class="text-right">Base</th>
            <th class="text-right">Delivery</th>
            <th class="text-right">Credits</th>
            <th class="text-right">Bill</th>
            <th :if={@range} class="text-right">Range</th>
            <th class="text-right">¢/kWh</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @year.rows}>
            <td>{r.name}</td>
            <td class="text-right">{Format.int(r.kwh)}</td>
            <td :if={@night} class="text-right">{Format.int(r.night_kwh)}</td>
            <td class="text-right">{money(r.energy)}</td>
            <td class="text-right">{money(r.base)}</td>
            <td class="text-right">{money(r.tdu)}</td>
            <td class="text-right">{if r.credits > 0, do: "−" <> money(r.credits), else: "$0.00"}</td>
            <td class="text-right font-semibold">{money(r.total)}</td>
            <td :if={@range} class="text-right">
              {money(r.total_low)} to {money(r.total_high)}
            </td>
            <td class="text-right">{if r.cents, do: num(Float.round(r.cents, 1)), else: "–"}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :efl, :map, default: nil

  # The reader of an EFL: the file input (the hook EflFile reads the PDF in
  # the browser), and the numbers that it found, each with its line.
  defp efl_reader(assigns) do
    ~H"""
    <div class="card card-border p-3 space-y-2">
      <label class="block text-sm">
        <span class="font-semibold">Open the EFL of a plan (PDF)</span>
        <input
          id="efl-file"
          type="file"
          accept="application/pdf,.pdf"
          phx-hook="EflFile"
          data-pdf={~p"/assets/js/pdf.js"}
          class="file-input file-input-sm w-full mt-1"
        />
      </label>
      <p class="text-xs opacity-80">
        Power to Choose (powertochoose.org) has the plans of your ZIP code, each with a link to its EFL. The browser reads the PDF. It sends only the text of an EFL to the app, and the PDF stays on this device.
      </p>
      <div :if={@efl} id="efl-result" phx-hook="EflLinks" class="space-y-2 text-sm">
        <p class="font-semibold">The numbers of {@efl.name}</p>
        <ul class="space-y-1">
          <li :for={{label, value, line} <- efl_rows(@efl)}>
            {label}: <span class="font-semibold">{value}</span>
            <span :if={line} class="block text-xs opacity-70">
              “{line.text}”
              <a data-efl-page={line.page} class="link" target="_blank">page {line.page}</a>
            </span>
          </li>
        </ul>
        <table class="table table-xs" id="efl-check">
          <thead>
            <tr>
              <th>kWh in one month</th>
              <th class="text-right">EFL</th>
              <th class="text-right">With these numbers</th>
              <th><span class="sr-only">The same</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @efl.check.rows}>
              <td>{Format.int(r.kwh)}</td>
              <td class="text-right">{num(r.efl)}¢</td>
              <td class="text-right">{num(Float.round(r.app, 2))}¢</td>
              <td>
                <span aria-hidden="true">{if r.ok, do: "✓", else: "✗"}</span>
                <span class="sr-only">{if r.ok, do: "the same", else: "not the same"}</span>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@efl.sources.tdu_from == :averages} class="text-xs">
          The EFL gives no delivery charges: the app finds them from the averages at 500 and 2,000 kWh. So only the average at 1,000 kWh checks these numbers.
        </p>
        <%= if @efl.check.ok do %>
          <form id="efl-add" phx-submit="add_efl_plan" class="flex gap-2 items-end">
            <label class="text-sm">
              Name <input name="name" value={@efl.name} class="input input-sm block" maxlength="60" />
            </label>
            <button class="btn btn-sm btn-primary">Add this plan</button>
          </form>
        <% else %>
          <p class="text-warning">
            These numbers do not give the averages of the EFL. The app cannot read each number of this EFL: give the numbers of the plan with the form.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  # The rows of the numbers that the reader found, with their lines.
  defp efl_rows(%{plan: plan, sources: sources}) do
    energy_line = List.first(sources.energy)

    [
      {"Average prices (500, 1,000 and 2,000 kWh)",
       Enum.map_join([500, 1000, 2000], ", ", &"#{num(plan.averages[&1])}¢"), sources.averages},
      {"Base charge",
       if(sources.base,
         do: money(plan.base) <> " each month",
         else: "the EFL gives no base charge: $0.00"
       ), sources.base},
      {"Energy charge",
       Enum.map_join(plan.energy, ", ", fn {_from, cents} -> "#{num(cents)}¢" end), energy_line},
      {"Delivery charges",
       "#{money(plan.tdu_base || 0)} and #{num(plan.tdu_cents || 0)}¢" <>
         tdu_from(sources.tdu_from), List.first(sources.tdu)}
    ] ++
      for(
        {c, line} <- Enum.zip(plan.credits, sources.credits),
        do: {"Credit", credit_text(c), line}
      ) ++
      if(plan.night,
        do: [{"At night", "#{num(plan.night.cents)}¢", List.first(sources.night)}],
        else: []
      ) ++
      if(plan.min_fee,
        do: [{"Minimum usage fee", money(plan.min_fee.dollars), sources.min_fee}],
        else: []
      )
  end

  defp tdu_from({:table, name}),
    do: " (the EFL gives no number: the table of the app, #{name}, October 2026)"

  defp tdu_from(:averages), do: " (from the averages of the EFL)"
  defp tdu_from(:none), do: " (the EFL gives no number)"
  defp tdu_from(:efl), do: ""

  attr :tdu, :map, default: nil

  # The form of a plan from its numbers: for a plan with no EFL, or an EFL
  # that the app cannot read. The delivery charges of a utility that the
  # app knows are in the form; for an other utility, the user gives them.
  defp plan_form(assigns) do
    ~H"""
    <form id="plan-form" phx-submit="add_plan" class="card card-border p-3 grid grid-cols-2 gap-2">
      <p class="col-span-2 font-semibold">Give the numbers of a plan</p>
      <label class="col-span-2 text-sm">
        Name <input name="plan[name]" class="input input-sm w-full" maxlength="60" />
      </label>
      <label class="text-sm">
        Base charge ($ each month)
        <input name="plan[base]" inputmode="decimal" class="input input-sm w-full" />
      </label>
      <label class="text-sm">
        Energy charge (¢ for each kWh)
        <input name="plan[energy]" inputmode="decimal" class="input input-sm w-full" />
      </label>
      <label class="text-sm">
        Delivery ($ each month)
        <input
          name="plan[tdu_base]"
          value={@tdu && @tdu.base}
          required={is_nil(@tdu)}
          inputmode="decimal"
          class="input input-sm w-full"
        />
      </label>
      <label class="text-sm">
        Delivery (¢ for each kWh)
        <input
          name="plan[tdu_cents]"
          value={@tdu && @tdu.cents}
          required={is_nil(@tdu)}
          inputmode="decimal"
          class="input input-sm w-full"
        />
      </label>
      <label class="text-sm">
        Credit ($) <input name="plan[credit]" inputmode="decimal" class="input input-sm w-full" />
      </label>
      <label class="text-sm">
        For a month of (kWh or more)
        <input name="plan[credit_kwh]" inputmode="numeric" class="input input-sm w-full" />
      </label>
      <label class="text-sm">
        Minimum usage fee ($)
        <input name="plan[fee]" inputmode="decimal" class="input input-sm w-full" />
      </label>
      <label class="text-sm">
        For a month under (kWh)
        <input name="plan[fee_kwh]" inputmode="numeric" class="input input-sm w-full" />
      </label>
      <p class="col-span-2 text-xs opacity-70">
        {if @tdu,
          do: "The delivery charges of #{@tdu.name} in October 2026.",
          else:
            "Give the delivery charges of your utility: the EFL of a plan of your area gives them."}
      </p>
      <button class="btn btn-sm col-span-2">Add the plan</button>
    </form>
    """
  end

  defp money(dollars), do: "$" <> :erlang.float_to_binary(dollars / 1, decimals: 2)

  defp cents(nil), do: "–"
  defp cents(cents), do: Format.cents(cents)

  defp num(number) when is_float(number) and number == trunc(number),
    do: Integer.to_string(trunc(number))

  defp num(number), do: to_string(number)
end
