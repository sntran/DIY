defmodule DIYWeb.Front do
  @moduledoc """
  The front of the house: a picture of the house, the user in front of it,
  and the bill estimate. The door goes in (`DIYWeb.Inside`).
  """
  use DIYWeb, :html

  alias DIY.{Catalog, Prices, Van, Zip}
  alias DIYWeb.{Format, Scene}

  attr :build, :map, required: true
  attr :estimate, :map, required: true
  attr :bill, :map, default: nil
  attr :whatif, :map, default: nil
  attr :price, :map, required: true
  attr :weather, :map, required: true
  attr :market, :map, required: true
  attr :scene, :map, required: true, doc: "the parts of the picture (`DIYWeb.Scene.parts/1`)"

  def front(assigns) do
    {:ok, place} = Zip.lookup(assigns.build.zip)
    assigns = assign(assigns, place: place, gas: Prices.gas(assigns.build))

    ~H"""
    <section class="space-y-4">
      <div>
        <h1 class="text-2xl font-bold">
          {if @build.door == "planning", do: "The house I'm planning", else: "My house"}
        </h1>
        <p class="text-sm opacity-70">
          ZIP code {@build.zip}, {Zip.state_name(@place.state)} · {Format.int(@build.house.size)} sq ft · {Format.count(
            @build.house.floors,
            "floor"
          )}
        </p>
      </div>

      <.house scene={@scene} />

      <.bill estimate={@estimate} bill={@bill} price={@price} weather={@weather} build={@build} />

      <.gas
        :if={@estimate.ready && @estimate.therms > 0}
        estimate={@estimate}
        build={@build}
        gas={@gas}
      />

      <.whatif :if={@whatif} whatif={@whatif} gas={@gas} />

      <.real build={@build} price={@price} />

      <.van build={@build} />

      <.market build={@build} market={@market} place={@place} />

      <.link patch={~p"/inside"} id="go-in" class="btn btn-primary btn-lg w-full">
        <.icon name="hero-arrow-right-end-on-rectangle" class="size-6" /> See the rooms and the items
      </.link>
    </section>
    """
  end

  attr :scene, :map, required: true

  # The picture of the house, with its equipment (`DIYWeb.Scene`). The door
  # goes in.
  defp house(assigns) do
    ~H"""
    <.link
      patch={~p"/inside"}
      id="house-picture"
      class="block overflow-hidden rounded-box"
      aria-label={"See the rooms. The picture: #{Scene.label(@scene)}, and you in front of the door."}
    >
      <Scene.house id="front" parts={@scene} />
    </.link>
    """
  end

  attr :estimate, :map, required: true
  attr :bill, :map, required: true
  attr :price, :map, required: true
  attr :weather, :map, required: true
  attr :build, :map, required: true

  # The bill estimate, or why it is not there yet.
  defp bill(assigns) do
    ~H"""
    <div id="bill" class="card card-border bg-base-100 p-4 space-y-3">
      <%= cond do %>
        <% match?({:error, _}, @weather.status) -> %>
          <p class="text-error">{elem(@weather.status, 1)}</p>
          <button type="button" phx-click="retry" class="btn btn-sm">Try again</button>
        <% :ac in @estimate.missing -> %>
          <p class="font-semibold">Add an AC to see the estimate.</p>
          <p class="text-sm opacity-80">The cooling is the largest part of a bill in a hot place.</p>
          <.link patch={~p"/inside"} class="btn btn-sm">Add an AC in the rooms</.link>
        <% not @estimate.ready -> %>
          <p class="opacity-70">The page gets the weather history of your ZIP code from NASA.</p>
        <% true -> %>
          <.numbers estimate={@estimate} bill={@bill} price={@price} build={@build} />
      <% end %>
    </div>
    """
  end

  attr :estimate, :map, required: true
  attr :bill, :map, required: true
  attr :price, :map, required: true
  attr :build, :map, required: true

  # The money comes from the bill: the power from the grid, at the prices
  # of the house (DIY.Bill).
  defp numbers(assigns) do
    assigns =
      assigns
      |> assign(:cents, assigns.price.cents)
      |> assign(:power, assigns.build.power)
      |> assign(:month, Enum.at(assigns.bill.months, Date.utc_today().month - 1))

    ~H"""
    <div>
      <p class="text-sm opacity-70">Your power bill, in an average month</p>
      <p id="bill-average" class="text-4xl font-bold">
        {Format.money(@bill.cost / 12)}
      </p>
      <p class="text-sm">
        The range, with the weather of 10 years and the limits of the model: {Format.money(
          @bill.cost_low / 12
        )} to {Format.money(@bill.cost_high / 12)} · {Format.kwh(@bill.kwh / 12)}
      </p>
    </div>
    <p id="bill-month" class="text-sm">
      {@month.name}: {Format.money(@month.cost)} (between {Format.money(@month.cost_low)} and {Format.money(
        @month.cost_high
      )})
    </p>
    <DIYWeb.Front.chart bill={@bill} />
    <form
      :if={@price.kind != :user}
      id="my-bill"
      phx-submit="my_bill"
      class="rounded-box bg-base-200 p-3 space-y-2"
    >
      <p class="text-sm">
        <span class="font-semibold">Is this near your bill?</span>
        The app uses a typical price. Your last bill gives the price of your plan.
      </p>
      <div class="flex flex-wrap items-end gap-2">
        <label class="text-sm">
          The total of the bill ($)
          <input name="dollars" inputmode="decimal" class="input input-sm w-28 block" />
        </label>
        <label class="text-sm">
          The kWh of the bill
          <input name="kwh" inputmode="numeric" class="input input-sm w-28 block" />
        </label>
        <button class="btn btn-sm">Use the price of my bill</button>
      </div>
    </form>
    <p class="text-xs opacity-80">
      A kWh (a kilowatt-hour) is 1,000 watts for one hour. The bill counts your use in kWh.
      At {Format.cents(@cents)} for each kWh: {@price.source}.{if @power.night_cents,
        do:
          " At night (#{@power.night_from}:00 to #{@power.night_to}:00): #{Format.cents(@power.night_cents)}."}{if @bill.export >
                                                                                                                     0,
                                                                                                                   do:
                                                                                                                     " For each kWh to the grid, the plan pays #{Format.cents(@power.buyback_cents)}."}
      <.link patch={~p"/settings"} class="link">Change the price</.link>
    </p>
    <ul :if={@estimate.notes != []} class="text-sm text-warning">
      <li :for={{_id, note} <- @estimate.notes}>{note}</li>
    </ul>
    <.link patch={~p"/estimate"} class="link text-sm">How the app gets these numbers</.link>
    """
  end

  attr :estimate, :map, required: true
  attr :build, :map, required: true
  attr :gas, :map, required: true

  # The gas bill, for a house with a gas item. It has the same weather and
  # the same model as the power bill.
  defp gas(assigns) do
    names =
      for item <- assigns.build.items,
          data = assigns.estimate.items[item.id],
          data && data.therms > 0,
          uniq: true,
          do: String.downcase(Catalog.name(item))

    assigns =
      assign(assigns,
        names: names,
        month: Enum.max_by(assigns.estimate.months, & &1.therms),
        bill: &Format.money(Prices.gas_bill(assigns.gas, &1))
      )

    ~H"""
    <div id="gas-bill" class="card card-border bg-base-100 p-4 space-y-1">
      <p class="text-sm opacity-70">Your gas bill, in an average month</p>
      <p id="gas-average" class="text-2xl font-bold">
        {@bill.(@estimate.therms / 12)}
        <span class="text-base font-normal">· {Format.therms(@estimate.therms / 12)}</span>
      </p>
      <p id="gas-range" class="text-sm">
        The range: {@bill.(@estimate.therms_low / 12)} to {@bill.(@estimate.therms_high / 12)}.
        The month with the most gas: {@month.name}, {@bill.(@month.therms)} (between {@bill.(
          @month.therms_low
        )} and {@bill.(@month.therms_high)}).
      </p>
      <p class="text-xs opacity-80">
        The gas items: {Enum.join(@names, ", ")}. A therm is the unit of gas on the bill: 100,000 BTU.
        The bill has a fixed charge near {Format.dollars(@gas.fixed)} each month, and near {Format.dollars(
          @gas.dollars
        )} for each therm. These numbers come from {@gas.source}.
      </p>
    </div>
    """
  end

  attr :whatif, :map, required: true
  attr :gas, :map, required: true

  # The what-if: the bill with the planned items, next to the bill of today.
  # The gas bill shows when the plan changes it (a heat pump heats in place
  # of a furnace). A house with gas use pays the fixed charge. The plan
  # keeps the gas items of today, so it keeps the fixed charge too.
  defp whatif(assigns) do
    %{today: today, plan: plan} = assigns.whatif.therms
    plan_gas = today.therms > 0 or plan.therms > 0
    bill = &if(&2, do: round(Prices.gas_bill(assigns.gas, &1 / 12)), else: 0)

    assigns =
      assign(assigns,
        gas_today: bill.(today.therms, today.therms > 0),
        gas_plan: bill.(plan.therms, plan_gas),
        gas_range:
          if(plan.therms > 0,
            do:
              "between #{Format.money(bill.(plan.therms_low, true))} and #{Format.money(bill.(plan.therms_high, true))}",
            else: "the fixed charge: the house keeps its gas items"
          )
      )

    ~H"""
    <div id="whatif-card" class="card card-border border-dashed bg-base-100 p-4 space-y-1">
      <p class="text-sm opacity-70">With your plan, in an average month</p>
      <p class="text-2xl font-bold">
        {Format.money(@whatif.plan.year.cost / 12)}
        <span class="text-base font-normal">· today {Format.money(@whatif.today.year.cost / 12)}</span>
      </p>
      <p class="text-sm">
        The range with the plan: {Format.money(@whatif.plan_bill.cost_low / 12)} to {Format.money(
          @whatif.plan_bill.cost_high / 12
        )}.
      </p>
      <p :if={@gas_plan != @gas_today} id="whatif-gas" class="text-sm">
        The gas bill with the plan: {Format.money(@gas_plan)} ({@gas_range}) · today {Format.money(
          @gas_today
        )}.
      </p>
      <p
        :if={Enum.any?(@whatif.warnings, &(&1 in [:backfeed, :overload]))}
        class="text-sm font-semibold"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        The plan has a problem of safety or of size: see the plan.
      </p>
      <p class="text-sm">
        {Format.count(length(@whatif.planned), "planned item")}.
        <.link patch={~p"/power"} class="link">See the plan</.link>
      </p>
    </div>
    """
  end

  @doc "A bar for each month of a bill (`DIY.Bill`), with the range as a line."
  attr :bill, :map, required: true

  def chart(assigns) do
    top = Enum.max(Enum.map(assigns.bill.months, & &1.high)) |> max(1)
    scale = fn kwh -> 100 * kwh / top end
    assigns = assign(assigns, :scale, scale)

    ~H"""
    <svg
      viewBox="0 0 360 130"
      class="w-full"
      role="img"
      aria-label="The bill of each month, from January to December, with its range."
    >
      <g :for={{m, i} <- Enum.with_index(@bill.months)}>
        <rect
          x={8 + i * 29}
          y={110 - @scale.(m.kwh)}
          width="20"
          height={@scale.(m.kwh)}
          class="fill-primary/70"
        >
          <title>{m.name}: {Format.money(m.cost)}</title>
        </rect>
        <line
          x1={18 + i * 29}
          x2={18 + i * 29}
          y1={110 - @scale.(m.high)}
          y2={110 - @scale.(m.low)}
          class="stroke-base-content/60"
          stroke-width="2"
        />
        <text x={18 + i * 29} y="124" font-size="10" text-anchor="middle" class="fill-base-content">
          {String.first(m.name)}
        </text>
      </g>
    </svg>
    """
  end

  attr :build, :map, required: true
  attr :price, :map, required: true

  # The real usage from the meter, or the next step to get it.
  defp real(assigns) do
    meter = Enum.find(assigns.build.items, &(&1.type == "smart_meter"))
    # A room for the meter: outside, else inside.
    room =
      Enum.find(assigns.build.rooms, &(&1.place == :outdoor)) ||
        Enum.find(assigns.build.rooms, &(&1.place == :indoor))

    year = assigns.build.usage && DIY.Usage.year(assigns.build.usage)
    assigns = assign(assigns, meter: meter, room: room, year: year)

    ~H"""
    <div id="real" class="card card-border bg-base-100 p-4 space-y-1">
      <%= cond do %>
        <% @build.usage -> %>
          <p class="text-sm opacity-70">
            {cond do
              @year ->
                "From your meter, in an average month"

              length(@build.usage.months) == 1 ->
                "From your meter: the one month of the file"

              true ->
                "From your meter: the mean of the #{length(@build.usage.months)} months of the file"
            end}
          </p>
          <p id="real-average" class="text-2xl font-bold">
            {Format.money(Format.cost(DIYWeb.Front.average(@build.usage), @price.cents))}
            <span class="text-base font-normal">· {Format.kwh(DIYWeb.Front.average(@build.usage))}</span>
          </p>
          <p class="text-sm">
            {Format.count(length(@build.usage.months), "month")} of real usage.
            <.link patch={~p"/estimate"} class="link">See them next to the estimate</.link>
          </p>
        <% @meter -> %>
          <p class="text-sm">
            Open the file of your smart meter: the app then shows your real usage.
            <.link patch={~p"/inside?#{[item: @meter.id]}"} class="link">Open the meter</.link>
          </p>
        <% true -> %>
          <p class="text-sm">
            A next small step: see the real use of your house. Your smart meter (outside, on a wall) sends its use to your utility. {meter_site(
              @build
            )} Add the meter here, and open the file in it.
            <.link :if={@room} patch={~p"/inside?#{[add: @room.id]}"} class="link">Add the meter</.link>
          </p>
      <% end %>
    </div>
    """
  end

  attr :build, :map, required: true

  # A camper van goes in the driveway, else in a different room outside.
  # With no van yet, the page tells the person.
  defp van(assigns) do
    outside = Enum.filter(assigns.build.rooms, &(&1.place == :outdoor))
    room = Enum.find(outside, &(&1.name =~ ~r/driveway/i)) || List.first(outside)
    assigns = assign(assigns, room: room, none: Van.vans(assigns.build) == [])

    ~H"""
    <div :if={@room && @none} id="van-card" class="card card-border bg-base-100 p-4 space-y-2">
      <p class="text-sm">
        <span class="font-semibold">A camper van?</span>
        It goes in the {String.downcase(@room.name)}. The app then plans its weight, its power and its trips off the grid.
      </p>
      <button
        type="button"
        id="add-van"
        phx-click="add_item"
        phx-value-room={@room.id}
        phx-value-type="camper_van"
        class="btn btn-sm"
      >
        <.icon name="hero-truck" class="size-4" /> Add a camper van
      </button>
    </div>
    """
  end

  # The site that gives the file of the meter: Smart Meter Texas in an area
  # with retail choice, else the site of the utility.
  defp meter_site(%{market: %{choice: true}}),
    do: "The site smartmetertexas.com gives the file of this use."

  defp meter_site(_build),
    do:
      "The site of your utility gives the file of this use (\"Green Button\" or \"Download My Data\")."

  @doc """
  The kWh of an average month from the meter: one year divided by 12, or
  the mean of the full months of a file with fewer months (the page says
  so).
  """
  def average(usage) do
    case DIY.Usage.year(usage) do
      nil -> usage.months |> Enum.map(&DIY.Usage.full/1) |> then(&(Enum.sum(&1) / length(&1)))
      year -> year / 12
    end
  end

  attr :build, :map, required: true
  attr :market, :map, required: true
  attr :place, :map, required: true

  # The utility area of a Texas ZIP code.
  defp market(assigns) do
    ~H"""
    <div :if={@place.state == "TX"} id="market" class="text-sm">
      <%= cond do %>
        <% @build.market && @build.market.choice -> %>
          <p>
            Your area has retail choice: you choose the company that sells your power (a retail plan), and {@build.market.utility ||
              "a utility"} delivers the power on its wires. The delivery charges are the charges of the utility for its wires. Power to Choose (powertochoose.org) is the site of Texas for the plans.
          </p>
        <% @build.market -> %>
          <p>
            Your area has no retail choice: a city utility or a co-op sells the power. Give the price of your bill in the settings.
          </p>
        <% match?({:error, _}, @market.status) -> %>
          <p>
            {elem(@market.status, 1)} The estimate uses the average price of Texas.
            <button type="button" phx-click="retry" class="link">Try again</button>
          </p>
        <% true -> %>
          <p class="opacity-70">The page asks Power to Choose about the plans of your ZIP code.</p>
      <% end %>
    </div>
    """
  end
end
