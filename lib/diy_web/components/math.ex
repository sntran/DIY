defmodule DIYWeb.Math do
  @moduledoc """
  The math of the estimate (honesty rule 1: each number shows where it
  comes from): the weather, the model of the house, each item, and the
  price, month by month, with the range of each month.
  """
  use DIYWeb, :html

  alias DIY.{Catalog, Usage}
  alias DIYWeb.{Format, Icon}

  attr :build, :map, required: true, doc: "the house of today (no planned item)"
  attr :planned, :integer, default: 0, doc: "the number of planned items"
  attr :estimate, :map, required: true
  attr :power, :map, default: nil, doc: "the power of the house of today (DIY.Power)"
  attr :bill, :map, default: nil, doc: "the bill of the house of today (DIY.Bill)"
  attr :price, :map, required: true
  attr :weather, :map, required: true

  def estimate(assigns) do
    assigns =
      assign(assigns,
        changed: assigns.power != nil and changed?(assigns.power),
        gas: DIY.Prices.gas(assigns.build)
      )

    ~H"""
    <section id="math" class="space-y-4">
      <h1 class="text-2xl font-bold">How the app gets your bill</h1>

      <p :if={not @estimate.ready} class="opacity-70">
        The estimate shows here when the house has its weather{if :ac in @estimate.missing,
          do: " and an AC"}.
      </p>

      <%= if @estimate.ready do %>
        <p>
          The estimate comes from the weather of your place and the items of your house. It is a range, not one number:
          the weather changes from year to year, and the numbers of the items are not exact.
          A file of your smart meter gives your real usage.
        </p>
        <p :if={@planned > 0} id="planned-note" class="text-sm">
          The planned items ({@planned}) are not in this bill.
          <.link patch={~p"/power"} class="link">The page Power shows the plan.</.link>
        </p>

        <div class="overflow-x-auto" tabindex="0" role="region" aria-label="The months">
          <table class="table table-xs sm:table-sm" id="months">
            <thead>
              <tr>
                <th>Month</th>
                <th class="text-right hidden sm:table-cell">°F-days cool / heat</th>
                <th class="text-right">kWh</th>
                <th class="text-right">Range</th>
                <th class="text-right">{if @changed, do: "kWh × price", else: "Bill"}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={m <- @estimate.months}>
                <td>{m.name}</td>
                <td class="text-right hidden sm:table-cell">
                  {Format.int(m.cdd)} / {Format.int(m.hdd)}
                </td>
                <td class="text-right">{Format.int(m.kwh)}</td>
                <td class="text-right">{Format.int(m.low)} to {Format.int(m.high)}</td>
                <td class="text-right">{Format.money(Format.cost(m.kwh, @price.cents))}</td>
              </tr>
            </tbody>
            <tfoot>
              <tr>
                <th>Year</th>
                <td class="hidden sm:table-cell"></td>
                <th class="text-right">{Format.int(@estimate.kwh)}</th>
                <th class="text-right">
                  {Format.int(@estimate.low)} to {Format.int(@estimate.high)}
                </th>
                <th class="text-right">{Format.money(Format.cost(@estimate.kwh, @price.cents))}</th>
              </tr>
            </tfoot>
          </table>
        </div>

        <.with_power :if={@changed} power={@power} bill={@bill} price={@price} />

        <.real :if={@build.usage} build={@build} estimate={@estimate} weather={@weather} />

        <h2 class="text-lg font-bold">The parts of the year</h2>
        <ul id="parts" class="space-y-1">
          <li :for={{label, kwh} <- parts(@estimate)}>
            {label}: {Format.kwh(kwh)} ({percent(kwh, @estimate.kwh)})
          </li>
        </ul>

        <h2 class="text-lg font-bold">Each item</h2>
        <ul id="items" class="space-y-1">
          <li :for={item <- by_size(@build.items, @estimate)} class="flex items-center gap-2">
            <Icon.item type={item.type} class="size-7" />
            <span>
              <.link patch={~p"/inside?#{[item: item.id]}"} class="link">{Catalog.name(item)}{room_of(
                  item,
                  @build
                )}</.link>: {Format.kwh(
                @estimate.items[item.id].year
              )}{if @estimate.items[item.id].therms > 0,
                do: " and #{Format.therms(@estimate.items[item.id].therms)} of gas"} in one year
              <span :if={item.typical} class="opacity-60">(typical)</span>
            </span>
          </li>
        </ul>

        <h2 class="text-lg font-bold">Where the numbers come from</h2>
        <ul class="list-disc pl-5 space-y-1 text-sm">
          <li>
            The weather: NASA POWER, the months of {@estimate.climate.first} to {@estimate.climate.last},
            near {@estimate.climate.lat}°, {@estimate.climate.lon}°. A degree day is one °F above (cooling) or
            below (heating) 65 °F for one day.
          </li>
          <li>
            The house: it gains {Format.int(@estimate.ua.ua)} BTU in one hour for each °F hotter outside
            ({Format.int(@build.house.size)} sq ft × {@estimate.ua.age} for its age × {@estimate.ua.floor} for its
            floors). In the cold, it loses {Format.int(@estimate.ua.heat)} BTU in one hour for each °F colder
            outside: 60%, because the sun and the people in the house help. These factors are a simple model of
            the app, not a measurement.
          </li>
          <li>The price: {Format.cents(@price.cents)} for each kWh, {@price.source}.</li>
          <li :if={@estimate.therms > 0} id="gas-price">
            The price of gas: a fixed charge near {Format.dollars(@gas.fixed)} each month, and near {Format.dollars(
              @gas.dollars
            )} for each therm. These numbers come from {@gas.source}.
          </li>
          <li>
            The range: for a month, the same month of each of the 10 years, with the least and the most kWh; for
            the year, the year with the least and the year with the most kWh. And the limits of the model: 15% for
            the heat and the cooling, 20% for a typical item, 10% for an item that you checked.
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  # True when the equipment or the prices make the bill different from the
  # use times the price.
  defp changed?(%{system: sys, settings: settings}) do
    sys.stations != [] or sys.grid_panels_w > 0 or settings.night_cents != nil
  end

  attr :power, :map, required: true
  attr :bill, :map, required: true
  attr :price, :map, required: true

  # The bill with the equipment and the prices of the house (DIY.Bill).
  defp with_power(assigns) do
    assigns = assign(assigns, :settings, assigns.power.settings)

    ~H"""
    <div id="bill-math" class="space-y-1">
      <h2 class="text-lg font-bold">Your bill with your equipment and prices</h2>
      <p class="text-sm">
        The equipment and the prices change the bill, not the use. For each month, the bill is the kWh from the grid in the day × {Format.cents(
          @price.cents
        )}{if @settings.night_cents,
          do:
            ", plus the kWh from the grid at night (#{@settings.night_from}:00 to #{@settings.night_to}:00) × #{Format.cents(@settings.night_cents)}"}{if @power.year.export >
                                                                                                                                                            0,
                                                                                                                                                          do:
                                                                                                                                                            ", less the kWh to the grid × #{Format.cents(@settings.buyback_cents)}"}.
        <.link patch={~p"/power"} class="link">The page Power shows how the app gets the kWh from the grid.</.link>
      </p>
      <div class="overflow-x-auto">
        <table class="table table-xs sm:table-sm" id="bill-months">
          <thead>
            <tr>
              <th>Month</th>
              <th class="text-right">From the grid</th>
              <th :if={@settings.night_cents} class="text-right">At night</th>
              <th :if={@power.year.export > 0} class="text-right">To the grid</th>
              <th class="text-right">Bill</th>
              <th class="text-right">Range</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{p, b} <- Enum.zip(@power.months, @bill.months)}>
              <td>{p.name}</td>
              <td class="text-right">{Format.int(p.grid)}</td>
              <td :if={@settings.night_cents} class="text-right">{Format.int(p.night)}</td>
              <td :if={@power.year.export > 0} class="text-right">{Format.int(p.export)}</td>
              <td class="text-right">{Format.money(b.cost)}</td>
              <td class="text-right">{Format.money(b.cost_low)} to {Format.money(b.cost_high)}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr>
              <th>Year</th>
              <th class="text-right">{Format.int(@power.year.grid)}</th>
              <th :if={@settings.night_cents} class="text-right">{Format.int(@power.year.night)}</th>
              <th :if={@power.year.export > 0} class="text-right">
                {Format.int(@power.year.export)}
              </th>
              <th class="text-right">{Format.money(@bill.cost)}</th>
              <th class="text-right">
                {Format.money(@bill.cost_low)} to {Format.money(@bill.cost_high)}
              </th>
            </tr>
          </tfoot>
        </table>
      </div>
      <p class="text-xs opacity-80">
        The range: the kWh from the grid, less or more the distance from the use to the ends of its range, at the mean price of the power from the grid.
      </p>
    </div>
    """
  end

  attr :build, :map, required: true
  attr :estimate, :map, required: true
  attr :weather, :map, required: true

  # The real months of the meter next to the estimate, and the numbers of
  # the house from the meter.
  defp real(assigns) do
    compare = Usage.compare(assigns.build.usage, assigns.estimate)
    fit = assigns.weather.climate && Usage.fit(assigns.build.usage, assigns.weather.climate)
    assigns = assign(assigns, compare: compare, fit: fit)

    ~H"""
    <h2 class="text-lg font-bold">Your real usage and the estimate</h2>
    <p id="inside-count">
      {@compare.inside} of {Format.count(length(@compare.rows), "real month")} in the range of the estimate.
    </p>
    <div class="overflow-x-auto" tabindex="0" role="region" aria-label="The real months">
      <table class="table table-xs sm:table-sm" id="real-months">
        <thead>
          <tr>
            <th>Month</th>
            <th class="text-right">Real kWh</th>
            <th class="text-right">Estimate</th>
            <th class="text-right">Range</th>
            <th>In it</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @compare.rows}>
            <td>{Format.month(row.from)}{if row.partial, do: " (part of the month)"}</td>
            <td class="text-right">{Format.int(row.real)}</td>
            <td class="text-right">{Format.int(row.estimate)}</td>
            <td class="text-right">{Format.int(row.low)} to {Format.int(row.high)}</td>
            <td>{if row.inside, do: "Yes", else: "No"}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <p :if={Enum.any?(@compare.rows, & &1.partial)} class="text-xs opacity-80">
      For a part of a month, the app gives the other days the mean of the days in the file.
    </p>
    <div :if={@fit} id="fit" class="text-sm space-y-1">
      <p class="font-semibold">
        Your house, from the meter and the weather of the same months ({@fit.months} months):
      </p>
      <ul class="list-disc pl-5">
        <li>{Format.kwh(@fit.base)} in one day with no heat and no cooling.</li>
        <li>{:erlang.float_to_binary(@fit.cool, decimals: 2)} kWh for each °F-day of cooling.</li>
        <li>{:erlang.float_to_binary(@fit.heat, decimals: 2)} kWh for each °F-day of heat.</li>
      </ul>
      <p class="text-xs opacity-80">
        The fit explains {round(@fit.r2 * 100)}% of the change from month to month.
      </p>
    </div>
    <p :if={is_nil(@fit) and @weather.climate} id="no-fit" class="text-sm opacity-80">
      To find the numbers of your house, the app needs 6 months of the file. Each month needs 20 days of data or more, and the weather of NASA POWER. The weather of the app ends with {@weather.climate.last}. A file with more months of {@weather.climate.last} or before gives the numbers of your house.
    </p>
    <button
      type="button"
      phx-click="clear_usage"
      data-confirm="Remove the real usage? The file stays on your device."
      class="btn btn-sm btn-ghost"
    >
      Remove the real usage
    </button>
    """
  end

  defp parts(estimate) do
    [
      {"Cooling", sum(estimate, :cooling)},
      {"Heat", sum(estimate, :heating)},
      {"The other items", sum(estimate, :other)}
    ]
  end

  defp sum(estimate, part), do: estimate.months |> Enum.map(&Map.fetch!(&1, part)) |> Enum.sum()

  defp percent(_kwh, total) when total == 0, do: "0%"
  defp percent(kwh, total), do: "#{round(kwh / total * 100)}%"

  defp by_size(items, estimate), do: Enum.sort_by(items, &(-estimate.items[&1.id].year))

  # Two items with the same name: each one has the name of its room.
  defp room_of(item, build) do
    same = Enum.count(build.items, &(Catalog.name(&1) == Catalog.name(item)))
    room = Enum.find(build.rooms, &(&1.id == item.room))
    if same > 1 and room, do: " (#{room.name})"
  end
end
