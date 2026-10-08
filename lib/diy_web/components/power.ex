defmodule DIYWeb.PowerPage do
  @moduledoc """
  The page of the power of a house (`DIY.Power`): the what-if (the house
  of today next to the house with the planned items), the power view (what
  feeds what), the hours of backup in an outage, the cars, and how the
  stations use their batteries.

  The page shows only the parts that apply to the house: a house with no
  station has no hours of backup, and a house with no car has no cars.
  """
  use DIYWeb, :html

  alias DIY.{Catalog, Power}
  alias DIYWeb.Format

  attr :build, :map, required: true
  attr :estimate, :map, required: true
  attr :power, :map, default: nil
  attr :whatif, :map, default: nil
  attr :price, :map, default: nil

  def page(assigns) do
    ~H"""
    <section id="power" class="space-y-6">
      <h1 class="text-xl font-bold">Power</h1>

      <p :if={is_nil(@power)} class="opacity-70">
        The page shows the power when the house has its estimate.
      </p>

      <%= if @power do %>
        <.whatif :if={@whatif} whatif={@whatif} />
        <.view build={@build} power={@power} />
        <.outage :if={@power.system.stations != []} power={@power} />
        <.months power={@power} />
        <.cars build={@build} price={@price} />
        <.settings build={@build} power={@power} />
      <% end %>
    </section>
    """
  end

  attr :whatif, :map, required: true

  # The house of today next to the house with the planned items (honesty
  # rule 2: say when a step does not pay back on savings alone, and show
  # the backup as a different reason).
  defp whatif(assigns) do
    ~H"""
    <div id="plan" class="space-y-2">
      <h2 class="text-lg font-bold">Your plan</h2>
      <p class="text-sm">
        The planned items: {Enum.map_join(@whatif.planned, ", ", &Catalog.name/1)}. They cost {Format.money(
          @whatif.price
        )}.
      </p>
      <div class="overflow-x-auto">
        <table class="table table-xs sm:table-sm" id="plan-months">
          <thead>
            <tr>
              <th>Month</th>
              <th class="text-right">Today</th>
              <th class="text-right">With the plan</th>
              <th class="text-right">Change</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{today, plan} <- Enum.zip(@whatif.today.months, @whatif.plan.months)}>
              <td>{today.name}</td>
              <td class="text-right">{Format.money(today.cost)}</td>
              <td class="text-right">{Format.money(plan.cost)}</td>
              <td class="text-right">{Format.money(plan.cost - today.cost)}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr>
              <th>Year</th>
              <th class="text-right">{Format.money(@whatif.today.year.cost)}</th>
              <th class="text-right">{Format.money(@whatif.plan.year.cost)}</th>
              <th class="text-right">
                {Format.money(@whatif.plan.year.cost - @whatif.today.year.cost)}
              </th>
            </tr>
          </tfoot>
        </table>
      </div>
      <p :if={@whatif.plan.year.lost > 1} class="text-sm">
        With the plan, {Format.kwh(@whatif.plan.year.lost)} of sun is lost in one year: the battery is full, or the station takes less solar power than the panels give.
      </p>
      <p :if={@whatif.gas > 0} class="text-sm">
        The planned car saves {Format.money(@whatif.gas)} of gas in one year.
      </p>
      <p id="payback" class="font-semibold">
        <%= if @whatif.payback do %>
          The plan saves {Format.money(@whatif.savings)} in one year: it pays back in {payback(
            @whatif.payback
          )}.
        <% else %>
          On savings alone, the plan does not pay back: it costs {Format.money(-@whatif.savings)} more in one year.
        <% end %>
      </p>
      <p class="text-xs opacity-80">
        A battery lasts near 10 years, and a panel near 25 years. A payback after that time is not a payback.
      </p>
      <p :if={backup_hours(@whatif.plan)} class="text-sm">
        A different reason: in an outage, the stations of the plan run their items for {backup_hours(
          @whatif.plan
        )} in July.
      </p>
      <button type="button" phx-click="plan_done" class="btn btn-sm">I have the planned items now</button>
    </div>
    """
  end

  defp payback(years) when years < 1, do: "less than one year"
  defp payback(years), do: "#{:erlang.float_to_binary(years / 1, decimals: 1)} years"

  defp backup_hours(power) do
    case Enum.at(power.months, 6).outage do
      nil -> nil
      hours -> hours_text(hours)
    end
  end

  defp hours_text(:days), do: "more than 7 days"
  defp hours_text(hours), do: "#{:erlang.float_to_binary(hours / 1, decimals: 1)} hours"

  attr :build, :map, required: true
  attr :power, :map, required: true

  # The power view: what feeds what. A list, so that a screen reader reads
  # it in order.
  defp view(assigns) do
    sys = assigns.power.system
    items = Enum.reject(assigns.build.items, & &1.planned)
    panels = Enum.filter(items, &(&1.type == "solar_panels"))
    panel = Enum.any?(sys.stations, &(&1.params["feeds"] == "panel"))

    assigns =
      assign(assigns,
        sys: sys,
        others: length(items) - length(sys.backup),
        panels: panels,
        panel: panel,
        warnings: Power.warnings(assigns.power)
      )

    ~H"""
    <div id="view" class="space-y-2">
      <h2 class="text-lg font-bold">What feeds what</h2>
      <ul class="space-y-2 text-sm">
        <li class="card card-border p-3">
          <span class="font-semibold">⚡ The grid</span>
          → the main panel{if @sys.switch,
            do: ", with the #{String.downcase(Catalog.name(@sys.switch))} (#{device(@sys.switch)})"} → {Format.count(
            @others,
            "item"
          )} of the house.
        </li>
        <li
          :for={p <- Enum.filter(@panels, &(&1.params["to"] == "grid"))}
          class="card card-border p-3"
        >
          <span class="font-semibold">☀️ {Format.int(p.params["watts"])} W of panels</span>
          → the house first, and the rest to the grid.
        </li>
        <li :if={@sys.stations != []} class="card card-border p-3">
          <span class="font-semibold">
            🔋 {Format.count(length(@sys.stations), "power station")}: {:erlang.float_to_binary(
              @sys.kwh,
              decimals: 1
            )} kWh, {Format.int(@sys.output_w)} W
          </span>
          <span :if={@sys.station_panels_w > 0}>
            ← {Format.int(
              Enum.sum(for p <- @panels, p.params["to"] == "station", do: p.params["watts"])
            )} W of panels
          </span>
          → {if @panel, do: "an inlet → the backup circuits:", else: "by plug:"}
          {if @sys.backup == [],
            do: "no item yet (open an item, and choose \"A power station runs it\")",
            else: Enum.map_join(@sys.backup, ", ", &Catalog.name/1)}.
        </li>
      </ul>

      <div :if={:backfeed in @warnings} id="backfeed" role="alert" class="alert alert-error text-sm">
        <span>
          Danger: a station that powers circuits of the house needs an interlock or a transfer switch. With no device, one mistake sends its power to the lines of the utility, and it can kill a worker there. Never use a cord with a plug at each end. Add the interlock or the transfer switch to the plan.
        </span>
      </div>

      <div :if={:permit in @warnings} id="permit" class="card card-border p-3 space-y-1 text-sm">
        <p class="font-semibold">Before the work on the panel</p>
        <p>
          An inlet, an interlock or a transfer switch is work on the panel. Most cities need a permit for it. Ask your city first. A licensed electrician must do the work when the city does not let you do it.
        </p>
        <ul class="list-disc pl-5">
          <li>
            Dallas lets a homeowner do the electrical work of the house where the homeowner lives, after a Homestead Exemption Certificate.
            <a
              class="link"
              href="https://dallascityhall.com:443/departments/sustainabledevelopment/buildinginspection/DCH%20documents/pdf/How-to_electrical.pdf"
            >
              The rules of Dallas
            </a>
          </li>
          <li>
            New Braunfels does not let a homeowner do work on the main service.
            <a
              class="link"
              href="https://www.newbraunfels.gov/DocumentCenter/View/6654/Homeowner-General-Contractor"
            >
              The rules of New Braunfels
            </a>
          </li>
        </ul>
      </div>

      <div :if={@panel and @sys.switch} id="outage-steps" class="text-sm">
        <p class="font-semibold">The steps in an outage</p>
        <ol class="list-decimal pl-5">
          <li>Turn off the main breaker.</li>
          <li>Turn on the breaker of the inlet ({device(@sys.switch)}).</li>
          <li>Turn on the station.</li>
        </ol>
        <p class="font-semibold mt-1">When the grid comes back</p>
        <ol class="list-decimal pl-5" start="4">
          <li>Turn off the station.</li>
          <li>Turn off the breaker of the inlet.</li>
          <li>Turn on the main breaker.</li>
        </ol>
      </div>

      <p :if={:overload in @warnings} id="overload" class="text-sm text-warning">
        The items on the stations need {Format.int(@power.watts)} W when they all run at the same time, and the stations give {Format.int(
          @sys.output_w
        )} W. A station stops when it gets more than its output.
      </p>
      <p :if={:surge in @warnings} class="text-sm opacity-80">
        A motor ({Enum.map_join(@power.motors, ", ", &Catalog.name/1)}) needs 2 to 3 times its power for a moment when it starts. Check the surge watts of the station.
      </p>
    </div>
    """
  end

  defp device(%{params: %{"device" => "interlock"}}), do: "the interlock keeps them apart"

  defp device(%{params: %{"device" => "transfer"}}),
    do: "the switch moves from the grid to the station"

  attr :power, :map, required: true

  # The hours that the stations run their items in an outage, by month.
  defp outage(assigns) do
    ~H"""
    <div id="outage" class="space-y-1">
      <h2 class="text-lg font-bold">In an outage</h2>
      <%= if @power.system.backup == [] do %>
        <p class="text-sm">
          No item is on the stations. Open an item in a room, and choose "A power station runs it".
        </p>
      <% else %>
        <p class="text-sm">
          From a full battery, from 18:00, with the sun of the next days: the stations run {Enum.map_join(
            @power.system.backup,
            ", ",
            &Catalog.name/1
          )} for
        </p>
        <ul class="grid grid-cols-3 gap-1 text-sm">
          <li :for={m <- @power.months}>{String.slice(m.name, 0, 3)}: {hours_text(m.outage)}</li>
        </ul>
      <% end %>
    </div>
    """
  end

  attr :power, :map, required: true

  # The power of each month: the use, the power from the grid, and the sun.
  defp months(assigns) do
    settings = assigns.power.settings
    assigns = assign(assigns, :night, settings.night_cents != nil or settings.mode == "night")

    ~H"""
    <div class="space-y-1">
      <h2 class="text-lg font-bold">The power of each month</h2>
      <div class="overflow-x-auto">
        <table class="table table-xs sm:table-sm" id="power-months">
          <thead>
            <tr>
              <th>Month</th>
              <th class="text-right">Use</th>
              <th class="text-right">From the grid</th>
              <th :if={@night} class="text-right">At night</th>
              <th :if={@power.year.sun > 0} class="text-right">Sun</th>
              <th :if={@power.year.export > 0} class="text-right">To the grid</th>
              <th class="text-right">Cost</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @power.months}>
              <td>{m.name}</td>
              <td class="text-right">{Format.int(m.use)}</td>
              <td class="text-right">{Format.int(m.grid)}</td>
              <td :if={@night} class="text-right">{Format.int(m.night)}</td>
              <td :if={@power.year.sun > 0} class="text-right">{Format.int(m.sun)}</td>
              <td :if={@power.year.export > 0} class="text-right">{Format.int(m.export)}</td>
              <td class="text-right">{Format.money(m.cost)}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="text-xs opacity-80">
        kWh. The use comes from the estimate. The page Bill shows its math.
      </p>
      <p :if={@power.year.lost > 1} class="text-sm">
        {Format.kwh(@power.year.lost)} of sun is lost in one year: the battery is full, or the station takes less solar power than the panels give.
      </p>
      <p :if={shift_costs?(@power)} id="shift" class="text-sm">
        With one price at all hours, a charge at night does not save money: the station keeps near 85% of the power that goes into it. Its value is the backup.
      </p>
    </div>
    """
  end

  defp shift_costs?(%{
         system: %{stations: [_ | _]},
         settings: %{mode: "night", night_cents: nil}
       }),
       do: true

  defp shift_costs?(_power), do: false

  attr :build, :map, required: true
  attr :price, :map, required: true

  # The cars: the cost of the home charge next to the gas.
  defp cars(assigns) do
    cars =
      for car <- assigns.build.items,
          car.type == "ev",
          do: {car, Power.charge_year(car, assigns.build.power, assigns.price.cents)}

    assigns = assign(assigns, :cars, cars)

    ~H"""
    <div :if={@cars != []} id="cars" class="space-y-1">
      <h2 class="text-lg font-bold">Cars</h2>
      <p :for={{car, charge} <- @cars} class="text-sm">
        {car.params["miles"]} miles in one day: the home charge is {Format.kwh(charge.kwh)} and {Format.money(
          charge.cost
        )} in one year. The gas car uses {Format.money(Power.gas_year(car))} of gas.
        <span :if={charge.hours > 24} class="text-warning">
          The charger cannot give it in one day: it needs {round(charge.hours)} hours.
        </span>
      </p>
    </div>
    """
  end

  attr :build, :map, required: true
  attr :power, :map, required: true

  # How the stations use their batteries, and the price of the power to
  # the grid.
  defp settings(assigns) do
    assigns =
      assign(assigns,
        settings: assigns.build.power,
        stations: assigns.power.system.stations != [],
        grid_panels: assigns.power.system.grid_panels_w > 0
      )

    ~H"""
    <form
      :if={@stations or @grid_panels}
      id="power-form"
      phx-submit="power"
      class="card card-border p-3 space-y-2"
    >
      <h2 class="font-bold">How you use the power</h2>
      <fieldset :if={@stations} class="space-y-1">
        <legend class="text-sm font-semibold">The batteries</legend>
        <label :for={{key, label} <- Power.modes()} class="flex items-center gap-2 text-sm">
          <input
            type="radio"
            name="mode"
            value={key}
            checked={@settings.mode == key}
            class="radio radio-sm"
          />
          {label}
        </label>
      </fieldset>
      <label :if={@stations} class="block text-sm">
        Keep for an outage (the modes of the night and of the sun)
        <input
          name="reserve"
          type="text"
          inputmode="numeric"
          value={@settings.reserve}
          class="input input-sm w-20"
        /> %
      </label>
      <label :if={@grid_panels} class="block text-sm">
        The price that your plan pays for 1 kWh to the grid
        <input
          name="buyback_cents"
          type="text"
          inputmode="decimal"
          value={Format.value(@settings.buyback_cents)}
          class="input input-sm w-20"
        /> ¢
      </label>
      <button class="btn btn-sm">Save</button>
    </form>
    """
  end
end
