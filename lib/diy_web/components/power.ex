defmodule DIYWeb.PowerPage do
  @moduledoc """
  The page of the power of a house (`DIY.Power`): the what-if (the house
  of today next to the house with the planned items), the power view (what
  feeds what), the hours of backup in an outage, the cars, how the
  stations use their batteries, and the math of these numbers.

  The page shows only the parts that apply to the house: a house with no
  station has no hours of backup, and a house with no car has no cars. A
  station of the house that is in a van now (`DIY.Van.stations/1`) is not
  in the numbers of the house: the page tells it.
  """
  use DIYWeb, :html

  alias DIY.{Build, Catalog, Power}
  alias DIYWeb.{Format, Scene}

  attr :build, :map, required: true
  attr :power, :map, default: nil
  attr :whatif, :map, default: nil
  attr :price, :map, default: nil
  attr :away, :list, default: [], doc: "the stations of the house in a van: {item, van}"

  attr :scene, :map, required: true, doc: "the parts of the picture (`DIYWeb.Scene.parts/1`)"

  def page(assigns) do
    ~H"""
    <section id="power" class="space-y-6">
      <h1 class="text-xl font-bold">Power</h1>

      <ul :if={@away != []} id="power-away" class="space-y-2">
        <li :for={{item, van} <- @away} class="alert alert-info text-sm">
          <span>
            {Catalog.name(item)} ({Format.value(
              Float.round((item.params["kwh"] + item.params["extra_kwh"]) / 1, 3)
            )} kWh) is in the van now. In an outage, the house has no backup from it. The numbers of the house do not count it until it comes home.
            <.link patch={~p"/van?#{[id: van.id]}"} class="link">Open the van</.link>
          </span>
        </li>
      </ul>

      <p :if={is_nil(@power)} class="opacity-70">
        The page shows the power when the house has its estimate.
      </p>

      <%= cond do %>
        <% is_nil(@power) -> %>
        <% not equipment?(@build) and @away != [] -> %>
        <% not equipment?(@build) -> %>
          <p id="no-equipment" class="text-sm">
            The house has no power equipment yet. Add a power station, solar panels, an interlock or an electric car in a room.
            <.link patch={~p"/inside"} class="link">Go to the rooms</.link>
          </p>
        <% true -> %>
          <.backup
            :if={top(@power, @whatif).system.stations != []}
            power={top(@power, @whatif)}
            planned={@whatif != nil}
            mode={@build.power.mode}
          />
          <div id="power-picture" class="overflow-hidden rounded-box">
            <Scene.house id="power-scene" parts={@scene} />
          </div>
          <.whatif :if={@whatif} whatif={@whatif} build={@build} />
          <.view
            build={if @whatif, do: @build, else: Build.today(@build)}
            power={top(@power, @whatif)}
            today={@power}
            planned={@whatif != nil}
          />
          <.outage
            :if={top(@power, @whatif).system.backup != []}
            power={top(@power, @whatif)}
            planned={@whatif != nil}
          />
          <.months power={@power} />
          <.cars build={@build} price={@price} />
          <.settings build={@build} power={@power} />
          <.math />
      <% end %>
    </section>
    """
  end

  @power_types ~w(power_station solar_panels transfer_switch ev)

  @doc """
  The hours of backup in an outage (the month with the fewest hours), in
  one sentence for the sheet of an item, or nil. With a plan, the hours of
  the plan.
  """
  def outage_text(nil, _whatif), do: nil

  def outage_text(power, whatif) do
    power = top(power, whatif)

    cond do
      is_nil(low_month(power)) ->
        nil

      :overload in Power.warnings(power) ->
        "In an outage, the items on the stations need more watts than the stations give."

      true ->
        "In an outage, the stations#{if whatif, do: " of the plan"} run their items for #{low_text(power)}."
    end
  end

  # The power of the plan when there is one, else the power of today.
  defp top(power, nil), do: power
  defp top(_power, whatif), do: whatif.plan

  attr :power, :map, required: true
  attr :planned, :boolean, default: false
  attr :mode, :string, required: true, doc: "the mode of the stations (`DIY.Power.modes/0`)"

  # The first question of a person with a station: how long its items run
  # in an outage. The answer is at the top of the page. In the mode that
  # keeps the batteries full, the page also gives the size for 2 days: the
  # hours grow with the kWh. In the other modes, the charge at the start of
  # an outage changes with the use of the day.
  defp backup(assigns) do
    low = low_month(assigns.power)
    sys = assigns.power.system

    assigns =
      assign(assigns,
        sys: sys,
        low: low,
        overload: :overload in Power.warnings(assigns.power),
        need:
          assigns.mode == "backup" && low && is_number(low.outage) && low.outage >= 1 &&
            low.outage < 48 && sys.kwh * 48 / low.outage
      )

    ~H"""
    <div id="backup" class="card card-border bg-base-100 p-4 space-y-1">
      <p class="text-sm opacity-70">In an outage{if @planned, do: ", with the plan"}</p>
      <%= cond do %>
        <% @sys.backup == [] -> %>
          <p class="text-sm">
            No item is on the stations yet. Open an item in a room. Then choose "A power station runs it".
            <.link patch={~p"/inside"} class="link">Go to the rooms</.link>
          </p>
        <% @overload -> %>
          <p class="text-sm font-semibold">
            The items on the stations need more watts than the stations give. A station stops when it gets more than its output: see the warning below.
          </p>
        <% is_nil(@low) -> %>
          <p class="text-sm">The items on the stations use no power.</p>
        <% true -> %>
          <p id="backup-hours" class="text-3xl font-bold">{hours_text(@low.outage)}</p>
          <p class="text-sm">
            The stations run {Enum.map_join(@sys.backup, ", ", &Catalog.name/1)} for {low_text(@power)}.
          </p>
          <p :if={@low.outage == 0} class="text-sm">
            In this mode, the batteries can be empty at 18:00. The mode "Keep the batteries full for an outage" gives more hours.
          </p>
          <p :if={@need} id="backup-size" class="text-sm">
            For 2 days (48 hours), the stations need near {Format.value(Float.round(@need, 1))} kWh. {if @planned,
              do: "With the plan, they have",
              else: "They have"} {Format.value(Float.round(@sys.kwh / 1, 1))} kWh. Extra batteries of a station add kWh.
          </p>
      <% end %>
    </div>
    """
  end

  # The month with the fewest hours of backup, or nil when no month has a
  # use.
  defp low_month(power) do
    case Enum.filter(power.months, & &1.outage) do
      [] -> nil
      months -> Enum.min_by(months, &if(&1.outage == :days, do: :infinity, else: &1.outage))
    end
  end

  # The hours of the month with the fewest hours, in words. When each month
  # has the same hours, the words say so.
  defp low_text(power) do
    low = low_month(power)

    if Enum.all?(power.months, &(&1.outage == low.outage)),
      do: "#{hours_text(low.outage)} in each month",
      else: "#{hours_text(low.outage)} in #{low.name}, the month with the fewest hours"
  end

  defp equipment?(build), do: Enum.any?(build.items, &(&1.planned or &1.type in @power_types))

  attr :whatif, :map, required: true
  attr :build, :map, required: true

  # The house of today next to the house with the planned items (honesty
  # rule 2: say when a step does not pay back on savings alone, and show
  # the backup as a different reason; rule 3: a range).
  defp whatif(assigns) do
    types = Enum.map(assigns.whatif.equipment, & &1.type)

    assigns =
      assign(assigns,
        station: "power_station" in types,
        panels: "solar_panels" in types,
        warnings: assigns.whatif.warnings
      )

    ~H"""
    <div id="plan" class="space-y-2">
      <h2 class="text-lg font-bold">Your plan</h2>
      <p class="text-sm">
        The planned items: {Enum.map_join(@whatif.planned, ", ", &Catalog.name/1)}.
        <span :if={@whatif.equipment != []}>
          The planned equipment costs {Format.money(@whatif.price)}.
        </span>
      </p>
      <div class="overflow-x-auto" tabindex="0" role="region" aria-label="Today and the plan">
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
      <p id="plan-range" class="text-sm">
        With the weather of 10 years and the limits of the model, the bill of one year is {Format.money(
          @whatif.today_bill.cost_low
        )} to {Format.money(@whatif.today_bill.cost_high)} today, and {Format.money(
          @whatif.plan_bill.cost_low
        )} to {Format.money(@whatif.plan_bill.cost_high)} with the plan.
      </p>
      <p :if={@whatif.plan.year.lost > 1} class="text-sm">
        With the plan, {Format.kwh(@whatif.plan.year.lost)} of sun is lost in one year: the battery is full, or the station takes less solar power than the panels give.
      </p>

      <div :if={@whatif.others} id="plan-others" class="text-sm space-y-1">
        <p>
          {Enum.map_join(@whatif.others.items, ", ", &Catalog.name/1)}: {change_text(
            @whatif.others.change
          )}
        </p>
        <p :if={@whatif.others.gas > 0}>
          The planned car saves {Format.money(@whatif.others.gas)} of gas in one year. {gas_text(
            @whatif.others.gas - @whatif.others.charge
          )}
        </p>
      </div>

      <div :if={@whatif.equipment != []} id="payback" class="space-y-1">
        <p class="font-semibold">
          {payback_text(
            if @whatif.parts == [], do: @whatif, else: %{@whatif | life: longest(@whatif.parts)}
          )}
        </p>
        <p
          :if={
            @whatif.payback &&
              Format.money(@whatif.savings_low) != Format.money(@whatif.savings_high)
          }
          id="savings-range"
          class="text-sm"
        >
          With the range of the bill, the equipment saves {Format.money(@whatif.savings_low)} to {Format.money(
            @whatif.savings_high
          )} in one year.
        </p>
        <ul :if={@whatif.parts != []} id="parts" class="list-disc pl-5 text-sm space-y-1">
          <li :for={part <- @whatif.parts}>{part_text(part)}</li>
        </ul>
        <p :if={@station} class="text-xs opacity-80">
          A battery of 3,000 cycles (a cycle is one full charge and one full use) lasts near 8 years with one cycle each day. 3,000 cycles is a common label of the stations.
        </p>
        <p :if={@panels} class="text-xs opacity-80">A panel lasts 25 to 35 years.</p>
      </div>

      <%= cond do %>
        <% :overload in @warnings -> %>
          <p class="text-sm">
            In an outage, the stations of the plan cannot run all their items at the same time: see the warning below.
          </p>
        <% low_month(@whatif.plan) -> %>
          <p class="text-sm">
            A different reason: in an outage, the stations of the plan run their items for {low_text(
              @whatif.plan
            )}.
          </p>
        <% true -> %>
      <% end %>
      <.warnings id="plan" power={@whatif.plan} build={@build} except={@whatif.today} />
      <button type="button" phx-click="plan_done" class="btn btn-sm">I have the planned items now</button>
    </div>
    """
  end

  defp change_text(change),
    do: "they change the bill of one year by #{if change >= 0, do: "+"}#{Format.money(change)}."

  defp gas_text(difference) when difference >= 0,
    do: "The home charge costs #{Format.money(difference)} less than the gas."

  defp gas_text(difference),
    do: "The home charge costs #{Format.money(-difference)} more than the gas."

  defp payback_text(%{payback: nil, savings: savings}) when abs(savings) < 0.5,
    do: "On savings alone, the planned equipment saves no money."

  defp payback_text(%{payback: nil, savings: savings}),
    do:
      "On savings alone, the planned equipment does not pay back: it costs #{Format.money(-savings)} more in one year."

  defp payback_text(%{payback: years, savings: savings, life: life})
       when life != nil and years > life,
       do:
         "The planned equipment saves #{Format.money(savings)} in one year. It pays back in #{years(years)}: after its life of near #{life} years, so on savings alone it does not pay back."

  defp payback_text(%{payback: years, savings: savings}),
    do:
      "The planned equipment saves #{Format.money(savings)} in one year: it pays back in #{years(years)}."

  defp years(years) when years < 1, do: "less than one year"
  defp years(years), do: "#{:erlang.float_to_binary(years / 1, decimals: 1)} years"

  # The longest life of the parts of the equipment: the plan as one does
  # not pay back after it.
  defp longest(parts),
    do: parts |> Enum.map(& &1.life) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

  @doc """
  The line of a part of the planned equipment (the `parts` of
  `DIY.Power.whatif/6`). It gives the price, the savings that the part
  adds, and its payback in its own life. A station and the panels that
  charge it are one part.
  """
  def part_text(%{items: items, price: price, payback: nil}) do
    w = words(items)

    "#{w.name} (#{Format.money(price)}): #{w.adds} no savings. On savings alone, #{w.does} not pay back.#{reason(items)}"
  end

  def part_text(%{items: items, price: price, savings: savings, payback: years, life: life}) do
    w = words(items)

    "#{w.name} (#{Format.money(price)}): #{w.adds} #{Format.money(savings)} of savings in one year. #{w.pays} back in #{years(years)}#{life_text(years, life)}."
  end

  # The words of a part of one item, or of more items.
  defp words([item]),
    do: %{name: Catalog.name(item), adds: "it adds", does: "it does", pays: "It pays"}

  defp words([first | rest]),
    do: %{
      name:
        Enum.map_join(
          [Catalog.name(first) | Enum.map(rest, &String.downcase(Catalog.name(&1)))],
          " and ",
          & &1
        ),
      adds: "they add",
      does: "they do",
      pays: "They pay"
    }

  defp life_text(_years, nil), do: ""
  defp life_text(years, life) when years > life, do: ": after a life of near #{life} years"
  defp life_text(_years, life), do: ", in a life of near #{life} years"

  defp reason(items) do
    cond do
      Enum.any?(items, &(&1.type == "power_station")) ->
        " The reason is the backup in an outage."

      Enum.any?(items, &(&1.type == "transfer_switch")) ->
        " The reason is a safe backup of the circuits of the house."

      true ->
        ""
    end
  end

  defp hours_text(nil), do: "no use"
  defp hours_text(:days), do: "more than 7 days"
  defp hours_text(hours), do: "#{:erlang.float_to_binary(hours / 1, decimals: 1)} hours"

  attr :build, :map, required: true
  attr :power, :map, required: true
  attr :today, :map, required: true, doc: "the power of today, for its warnings"
  attr :planned, :boolean, default: false

  # The power view: what feeds what, with the planned items when there is
  # a plan. A list, so that a screen reader reads it in order.
  defp view(assigns) do
    sys = assigns.power.system

    others =
      Enum.count(
        assigns.build.items,
        &(&1.type not in ~w(power_station solar_panels transfer_switch smart_meter camper_van) and
            &1 not in sys.backup)
      )

    assigns =
      assign(assigns,
        sys: sys,
        others: others,
        panels: Enum.filter(assigns.build.items, &(&1.type == "solar_panels")),
        panel: Power.panel?(sys)
      )

    ~H"""
    <div id="view" class="space-y-2">
      <h2 class="text-lg font-bold">What feeds what</h2>
      <p :if={@planned} class="text-sm opacity-80">With the planned items.</p>
      <ul class="space-y-2 text-sm">
        <li class="card card-border p-3">
          <span class="font-semibold"><.icon name="hero-bolt" class="size-4" /> The grid</span>
          feeds the main panel{if @sys.switch,
            do: ", with the #{String.downcase(Catalog.name(@sys.switch))} (#{device(@sys.switch)})"}. The main panel feeds {Format.count(
            @others,
            "item"
          )} of the house.
        </li>
        <li
          :for={p <- Enum.filter(@panels, &(&1.params["to"] == "grid"))}
          class="card card-border p-3"
        >
          <span class="font-semibold">
            <.icon name="hero-sun" class="size-4" /> {Format.int(p.params["watts"])} W of panels
          </span>
          feed the house first, and the rest goes to the grid.
        </li>
        <li :if={@sys.stations != []} class="card card-border p-3">
          <span class="font-semibold">
            <.icon name="hero-battery-100" class="size-4" />
            {Format.count(length(@sys.stations), "power station")}: {:erlang.float_to_binary(
              @sys.kwh,
              decimals: 1
            )} kWh, {Format.int(@sys.output_w)} W
          </span>
          <span :if={@sys.station_panels_w > 0}>
            (with {Format.int(
              Enum.sum(for p <- @panels, p.params["to"] == "station", do: p.params["watts"])
            )} W of panels)
          </span>
          {if @panel,
            do: "feed the backup circuits through an inlet:",
            else: "feed the items that plug into them:"}
          {if @sys.backup == [],
            do: "no item yet",
            else: Enum.map_join(@sys.backup, ", ", &Catalog.name/1)}.
        </li>
      </ul>

      <p :if={@planned and Power.warnings(@today) != []} class="text-sm font-semibold">
        Today, with no planned item:
      </p>
      <.warnings id="today" power={@today} build={Build.today(@build)} />

      <div :if={@panel and @sys.switch} id="outage-steps" class="text-sm">
        <%= if @sys.switch.params["device"] == "interlock" do %>
          <p class="font-semibold">The steps in an outage</p>
          <ol class="list-decimal pl-5">
            <li :if={@sys.grid_panels_w > 0}>Turn off the breaker of the grid-tie inverter.</li>
            <li>Turn off the main breaker.</li>
            <li>Connect the station to the inlet.</li>
            <li>Turn on the breaker of the inlet (the interlock lets it on now).</li>
            <li>Turn on the station.</li>
          </ol>
          <p class="font-semibold mt-1">When the grid comes back</p>
          <ol class="list-decimal pl-5">
            <li>Turn off the station.</li>
            <li>Turn off the breaker of the inlet.</li>
            <li>Disconnect the station from the inlet.</li>
            <li>Turn on the main breaker.</li>
            <li :if={@sys.grid_panels_w > 0}>Turn on the breaker of the grid-tie inverter.</li>
          </ol>
        <% else %>
          <p class="font-semibold">The steps in an outage</p>
          <ol class="list-decimal pl-5">
            <li :if={@sys.grid_panels_w > 0}>Turn off the breaker of the grid-tie inverter.</li>
            <li>Connect the station to the inlet.</li>
            <li>Turn on the station.</li>
            <li>Move the transfer switch from the grid to the station. The main breaker stays on.</li>
          </ol>
          <p class="font-semibold mt-1">When the grid comes back</p>
          <ol class="list-decimal pl-5">
            <li>Move the transfer switch from the station to the grid.</li>
            <li>Turn off the station.</li>
            <li>Disconnect the station from the inlet.</li>
            <li :if={@sys.grid_panels_w > 0}>Turn on the breaker of the grid-tie inverter.</li>
          </ol>
        <% end %>
      </div>
    </div>
    """
  end

  defp device(%{params: %{"device" => "interlock"}}), do: "the interlock keeps them apart"

  defp device(%{params: %{"device" => "transfer"}}),
    do: "the switch moves the backup circuits from the grid to the station"

  defp device(%{params: %{"device" => "subpanel"}}),
    do: "the backup circuits are on the subpanel, and its switch moves them to the station"

  attr :id, :string, required: true
  attr :power, :map, required: true
  attr :build, :map, required: true
  attr :except, :map, default: nil, doc: "the power of today: the plan shows only new warnings"

  # The warnings of a house (honesty rule 5, and the safety of the
  # workers on the lines): for the house of today, or for the plan. The
  # plan shows only the warnings that the house of today does not have, so
  # that a screen reader reads each danger one time.
  defp warnings(assigns) do
    permits = Power.permits(assigns.power.system)
    warnings = Power.warnings(assigns.power)

    warnings =
      case assigns.except do
        nil ->
          warnings

        today ->
          # The overload of the plan shows again when its items need more
          # watts than the items of today.
          new = warnings -- Power.warnings(today)

          new =
            if :overload in warnings and assigns.power.watts > today.watts,
              do: Enum.uniq([:overload | new]),
              else: new

          # The permit shows again when the plan adds work.
          if :permit in warnings and permits -- Power.permits(today.system) != [],
            do: Enum.uniq([:permit | new]),
            else: new
      end

    assigns = assign(assigns, warnings: warnings, permits: permits)

    ~H"""
    <div class="space-y-2">
      <div
        :if={:backfeed in @warnings}
        id={"#{@id}-backfeed"}
        role="alert"
        class="alert alert-error text-sm"
      >
        <span>
          Danger: a station that powers circuits of the house needs an interlock or a transfer switch. With no device, one mistake sends its power to the lines of the utility, and it can kill a worker there. Never use a cord with a plug at each end. Add the interlock or the transfer switch to the plan.
        </span>
      </div>

      <div :if={:grid_tie in @warnings} id={"#{@id}-grid-tie"} class="alert alert-warning text-sm">
        <span>
          The house has panels on a grid-tie inverter, and a station that powers the panel. In an outage, the inverter can send its power into the output of the station, and this can damage the station. Turn off the breaker of the inverter before the backup, or ask the maker of the station.
        </span>
      </div>

      <div
        :if={:permit in @warnings}
        id={"#{@id}-permit"}
        class="card card-border p-3 space-y-1 text-sm"
      >
        <p class="font-semibold">Before the work</p>
        <ul class="list-disc pl-5">
          <li :if={:panel in @permits}>
            An inlet, an interlock, a transfer switch or a subpanel is work on the panel.
          </li>
          <li :if={:grid_tie in @permits}>
            Panels on a grid-tie inverter are work on the panel, and the utility must approve them before they connect.
          </li>
          <li :if={:charger in @permits}>A Level 2 charger needs a new circuit of 240 V.</li>
        </ul>
        <p>
          Most cities need a permit for this work. Ask your city first. A licensed electrician must do the work when the city does not let you do it. The rules are different in each city. Two examples:
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

      <div :if={:overload in @warnings} id={"#{@id}-overload"} class="alert alert-warning text-sm">
        <span>
          The items on the stations need {Format.int(@power.watts)} W when they all run at the same time, and the stations give {Format.int(
            @power.system.output_w
          )} W. A station stops when it gets more than its output.
        </span>
      </div>
      <p :if={:surge in @warnings} class="text-sm">
        A motor ({Enum.map_join(@power.motors, ", ", &Catalog.name/1)}) needs 3 to 8 times its running power for about one second when it starts. Its label gives the LRA (locked rotor amps: the amps when the motor starts). Check it against the surge watts of the station (the most watts for a short time).
      </p>
    </div>
    """
  end

  attr :power, :map, required: true
  attr :planned, :boolean, default: false

  # The hours that the stations run their items in an outage, by month.
  defp outage(assigns) do
    ~H"""
    <div id="outage" class="space-y-1">
      <h2 class="text-lg font-bold">In an outage{if @planned, do: ", with the plan"}</h2>
      <p class="text-sm">
        From the charge of the battery at 18:00 of an average day, with the sun of the next days: the stations run {Enum.map_join(
          @power.system.backup,
          ", ",
          &Catalog.name/1
        )} for
      </p>
      <ul class="grid grid-cols-3 gap-1 text-sm">
        <li :for={m <- @power.months}>{String.slice(m.name, 0, 3)}: {hours_text(m.outage)}</li>
      </ul>
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
      <div class="overflow-x-auto" tabindex="0" role="region" aria-label="The power of each month">
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
        kWh. The use comes from the estimate (the page Bill shows its math). The cost is the kWh from the grid in the day at the price of the day, and at night at the price of the night, less the kWh to the grid at the price that the plan pays for them.
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
      <div :for={{car, charge} <- @cars} class="space-y-1">
        <p class="text-sm">
          {car.params["miles"]} miles in one day: the home charge is {Format.kwh(charge.kwh)} and {Format.money(
            charge.cost
          )} in one year. The gas car uses {Format.money(Power.gas_year(car))} of gas.
        </p>
        <p :if={charge.hours > 24} class="alert alert-warning text-sm">
          The charger cannot give it in one day: it needs {round(charge.hours)} hours.
        </p>
      </div>
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

  # The math of the page (honesty rule 1): the steps and the numbers of the
  # model, with their sources (see DIY.Power).
  defp math(assigns) do
    ~H"""
    <details id="power-math" class="text-sm">
      <summary class="cursor-pointer font-semibold">How the app gets these numbers</summary>
      <ul class="list-disc pl-5 space-y-1 pt-1">
        <li>
          For each month, the app runs an average day, hour by hour: the sun of the panels, the battery of the stations, and the grid. The use of each item comes from the estimate, with a shape of the day for each kind of item (a simple model of the app).
        </li>
        <li>
          A station uses 95% of its battery and gives 92% of it at its outlets: 87% of its label. Tests of stations at a large load get 87.5% (The Solar Lab) to 89% (PCWorld). It stores 92% of the power that goes into it (a simple model of the app).
        </li>
        <li>
          Panels give 80% of their watts in full sun. PVWatts of NREL counts 14% of losses and an inverter of 96%: 83%. The app takes a little less for the heat. A south roof gives 110% of the sun on a flat surface (EIA, with PVWatts), south-east or south-west 105%, east or west 95% (CAFS, and a study of the UK).
        </li>
        <li>
          The sun of each month: NASA POWER, the same data as the weather. The sun above the solar input of a station is lost.
        </li>
        <li>
          An outage starts at 18:00, with the charge of the battery at that hour of an average day, and the sun of the next days, for 7 days at most.
        </li>
        <li>
          The payback: the price of the planned equipment, divided by the savings of one year. A planned car has no price in the app: the page shows its charge and its gas.
        </li>
        <li>
          With two parts of equipment or more, each part has its own payback. A part adds the savings of the plan, less the savings of the plan with no such part. A station and the panels that charge it are one part. The life of a part is the shortest life of its items.
        </li>
        <li>
          A car charger: Level 1 at 1.4 kW (12 A at 120 V), Level 2 at 7.2 kW (30 A at 240 V). The car gets 85% (Level 1) or 90% (Level 2) of the power from the wall: tests of Idaho National Laboratory got 84% to 89% for a Chevrolet Volt.
        </li>
      </ul>
    </details>
    """
  end
end
