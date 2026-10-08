defmodule DIYWeb.Front do
  @moduledoc """
  The front of the house: a picture of the house, the user in front of it,
  and the bill estimate. The door goes in (`DIYWeb.Inside`).
  """
  use DIYWeb, :html

  alias DIY.Zip
  alias DIYWeb.Format

  attr :build, :map, required: true
  attr :estimate, :map, required: true
  attr :bill, :map, default: nil
  attr :whatif, :map, default: nil
  attr :price, :map, required: true
  attr :weather, :map, required: true
  attr :market, :map, required: true

  def front(assigns) do
    {:ok, place} = Zip.lookup(assigns.build.zip)
    assigns = assign(assigns, :place, place)

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

      <.house build={@build} />

      <.bill estimate={@estimate} bill={@bill} price={@price} weather={@weather} build={@build} />

      <.whatif :if={@whatif} whatif={@whatif} />

      <.real build={@build} price={@price} />

      <.market build={@build} market={@market} place={@place} />

      <.link patch={~p"/inside"} id="go-in" class="btn btn-primary btn-lg w-full">
        <span aria-hidden="true">🚪</span> Go in
      </.link>
    </section>
    """
  end

  attr :build, :map, required: true

  # The picture of the house: one band for each floor, the roof, the door,
  # and the items outside.
  defp house(assigns) do
    floors = assigns.build.house.floors
    types = MapSet.new(assigns.build.items, & &1.type)

    assigns =
      assigns
      |> assign(:floors, floors)
      |> assign(:top, 200 - floors * 46)
      |> assign(:ac, MapSet.member?(types, "ac"))
      |> assign(:pool, MapSet.member?(types, "pool_pump"))

    ~H"""
    <.link
      patch={~p"/inside"}
      class="block"
      aria-label={"Go in: a house with #{Format.count(@floors, "floor")}, and you in front of the door"}
    >
      <svg
        viewBox="0 0 360 230"
        class="w-full rounded-box bg-sky-100 dark:bg-slate-800"
        aria-hidden="true"
      >
        <rect x="0" y="200" width="360" height="30" class="fill-green-600/70" />
        <polygon points={"80,#{@top} 180,#{@top - 50} 280,#{@top}"} class="fill-red-800/80" />
        <rect x="95" y={@top} width="170" height={200 - @top} class="fill-amber-100 stroke-amber-900" />
        <line
          :for={floor <- 1..(@floors - 1)//1}
          :if={@floors > 1}
          x1="95"
          x2="265"
          y1={200 - floor * 46}
          y2={200 - floor * 46}
          class="stroke-amber-900/40"
        />
        <rect
          :for={{floor, x} <- for(f <- 1..@floors, x <- [110, 225], do: {f, x})}
          x={x}
          y={200 - floor * 46 + 10}
          width="25"
          height="20"
          class="fill-sky-300 stroke-amber-900/60"
        />
        <rect x="165" y="164" width="30" height="36" class="fill-amber-800" />
        <circle cx="189" cy="183" r="2" class="fill-yellow-300" />
        <text x="200" y="222" font-size="26" aria-hidden="true">🧍</text>
        <g :if={@ac}>
          <rect x="285" y="180" width="30" height="20" rx="2" class="fill-slate-300 stroke-slate-600" />
          <circle cx="300" cy="190" r="7" class="fill-none stroke-slate-600" />
        </g>
        <rect :if={@pool} x="10" y="205" width="60" height="18" rx="6" class="fill-sky-400" />
      </svg>
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
          <.link patch={~p"/inside"} class="btn btn-sm">Go in and add an AC</.link>
        <% not @estimate.ready -> %>
          <p class="opacity-70">The page gets the weather history of your ZIP code from NASA.</p>
        <% true -> %>
          <.numbers estimate={@estimate} bill={@bill} price={@price} />
      <% end %>
    </div>
    """
  end

  attr :estimate, :map, required: true
  attr :bill, :map, required: true
  attr :price, :map, required: true

  # The money comes from the bill: the power from the grid, at the prices
  # of the house (DIY.Bill).
  defp numbers(assigns) do
    assigns =
      assigns
      |> assign(:cents, assigns.price.cents)
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
    <p class="text-xs opacity-80">
      At {Format.cents(@cents)} for each kWh: {@price.source}.
      <.link patch={~p"/settings"} class="link">Change the price</.link>
    </p>
    <ul :if={@estimate.notes != []} class="text-sm text-warning">
      <li :for={{_id, note} <- @estimate.notes}>{note}</li>
    </ul>
    <.link patch={~p"/estimate"} class="link text-sm">How the app gets these numbers</.link>
    """
  end

  attr :whatif, :map, required: true

  # The what-if: the bill with the planned items, next to the bill of today.
  defp whatif(assigns) do
    ~H"""
    <div id="whatif-card" class="card card-border border-dashed bg-base-100 p-4 space-y-1">
      <p class="text-sm opacity-70">With your plan, in an average month</p>
      <p class="text-2xl font-bold">
        {Format.money(@whatif.plan.year.cost / 12)}
        <span class="text-base font-normal">· today {Format.money(@whatif.today.year.cost / 12)}</span>
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
            A next small step: add your smart meter (it is outside, on a wall), and open its file. The app then shows your real usage.
            <.link :if={@room} patch={~p"/inside?#{[add: @room.id]}"} class="link">Add the meter</.link>
          </p>
      <% end %>
    </div>
    """
  end

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
            Your area has retail choice: you choose a retail plan, and {@build.market.utility ||
              "a utility"} delivers the power.
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
