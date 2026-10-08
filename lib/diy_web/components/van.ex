defmodule DIYWeb.VanPage do
  @moduledoc """
  The build of a camper van (`DIY.Van`): its two budgets (the weight on
  each axle, and the days off the grid), the safety notes, its zones in a
  row (like the rooms of the house), and the power stations that go from
  the house to the van.

  `?id=ID` chooses a van, `?item=ID` opens an item of the van (or the van
  itself, for its numbers), and `?add=ZONE` the list of the items for a
  zone.
  """
  use DIYWeb, :html

  alias DIY.{Build, Catalog, Van}
  alias DIYWeb.{Format, Inside}

  attr :build, :map, required: true
  attr :van_id, :string, default: nil
  attr :item, :string, default: nil
  attr :add, :string, default: nil
  attr :climate, :map, default: nil
  attr :item_error, :string, default: nil

  def page(assigns) do
    vans = Van.vans(assigns.build)
    van = Enum.find(vans, &(&1.id == assigns.van_id)) || List.first(vans)
    assigns = assign(assigns, vans: vans, van: van)

    ~H"""
    <section id="van" class="space-y-4">
      <h1 class="text-xl font-bold">Van</h1>

      <p :if={is_nil(@van)} id="no-van" class="text-sm">
        No van yet. A camper van goes in the driveway or the garage: add it to a room outside.
        <.link patch={~p"/inside"} class="link">Go to the rooms</.link>
      </p>

      <%= if @van do %>
        <nav :if={length(@vans) > 1} aria-label="The vans" class="flex flex-wrap gap-1">
          <.link
            :for={{v, i} <- Enum.with_index(@vans, 1)}
            patch={~p"/van?#{[id: v.id]}"}
            class={["btn btn-sm", if(v.id == @van.id, do: "btn-primary", else: "btn-ghost")]}
            aria-current={v.id == @van.id && "page"}
          >
            Van {i}
          </.link>
        </nav>

        <div class="flex items-center justify-between gap-2">
          <p class="text-sm">{model_name(@van)}</p>
          <.link patch={~p"/van?#{[id: @van.id, item: @van.id]}"} id="van-numbers" class="btn btn-sm">
            The numbers of the van
          </.link>
        </div>
        <p :if={@van.typical} class="alert alert-warning text-sm">
          These numbers are typical of the model. The label in the door frame gives the ratings, and a truck scale gives the weight of each axle.
        </p>

        <.weight weight={Van.weight(@build, @van)} />
        <.power power={Van.power(@build, @van, @climate)} />
        <.notes warnings={Van.warnings(@build, @van)} />
        <.zones build={@build} van={@van} />
        <.stations build={@build} van={@van} />

        <.item_sheet
          :if={@item && match?({:ok, _}, van_item(@build, @van, @item))}
          build={@build}
          van={@van}
          item={elem(van_item(@build, @van, @item), 1)}
          error={@item_error}
        />
        <.add_sheet
          :if={@add && match?(%{}, Enum.find(Build.zones(@build, @van.id), &(&1.id == @add)))}
          van={@van}
          zone={Enum.find(Build.zones(@build, @van.id), &(&1.id == @add))}
        />
      <% end %>
    </section>
    """
  end

  defp model_name(van) do
    {_key, name, _numbers} = List.keyfind(Catalog.van_models(), van.params["model"], 0)
    name
  end

  # The van itself, or an item in a zone of the van.
  defp van_item(_build, %{id: id} = van, id), do: {:ok, van}

  defp van_item(build, van, id) do
    case Enum.find(Van.items(build, van.id), fn {_zone, item} -> item.id == id end) do
      {_zone, item} -> {:ok, item}
      nil -> {:error, :item}
    end
  end

  attr :weight, :map, required: true

  # The weight budget: the van in all, and each axle.
  defp weight(assigns) do
    ~H"""
    <div id="van-weight" class="card card-border p-4 space-y-2">
      <h2 class="text-lg font-bold">Weight</h2>
      <.bar id="weight-total" label="In all" value={@weight.total} limit={@weight.gvwr} />
      <.bar id="weight-front" label="Front axle" value={@weight.front} limit={@weight.front_gawr} />
      <.bar id="weight-rear" label="Rear axle" value={@weight.rear} limit={@weight.rear_gawr} />
      <p class="text-sm">
        The van can take {lb(@weight.payload)} (its rating, less its empty weight of {lb(
          @weight.empty
        )}). The build, the people and the gear take {lb(@weight.load)}: {if @weight.payload >=
                                                                               @weight.load,
                                                                             do:
                                                                               "#{lb(@weight.payload - @weight.load)} is left.",
                                                                             else:
                                                                               "#{lb(@weight.load - @weight.payload)} more than the van can take."}
      </p>
      <p :if={@weight.front_gawr == 0 or @weight.rear_gawr == 0} class="text-xs">
        The app does not know the rating of an axle of this model: give it from the label in the door frame.
      </p>
      <details class="text-sm">
        <summary class="cursor-pointer">The weight of each zone, from the front to the back</summary>
        <ul class="list-disc pl-5">
          <li :for={{zone, pounds} <- @weight.zones}>
            {Keyword.fetch!(Catalog.zones(), zone)}: {lb(pounds)}
          </li>
        </ul>
        <p class="text-xs opacity-80">
          The cab has the people, and the bed has the gear. Each zone has a typical place from the front axle to the rear axle: the bed and the electrical bay are over the rear axle. A truck scale gives the real weight of each axle.
        </p>
      </details>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :float, required: true
  attr :limit, :integer, required: true

  defp bar(assigns) do
    ~H"""
    <div id={@id} class="text-sm">
      <div class="flex justify-between">
        <span>{@label}</span>
        <span class={[(@limit > 0 and @value > @limit) && "font-bold"]}>
          {lb(@value)}{if @limit > 0, do: " of #{lb(@limit)}"}{if @limit > 0 and @value > @limit,
            do: ": over"}
        </span>
      </div>
      <progress
        :if={@limit > 0}
        class={[
          "progress w-full",
          if(@value > @limit, do: "progress-error", else: "progress-primary")
        ]}
        value={min(@value, @limit)}
        max={@limit}
        aria-label={"#{@label}: #{lb(@value)} of #{lb(@limit)}"}
      ></progress>
    </div>
    """
  end

  attr :power, :map, default: nil

  # The power budget: the days off the grid in each month.
  defp power(assigns) do
    ~H"""
    <div id="van-power" class="card card-border p-4 space-y-2">
      <h2 class="text-lg font-bold">Power</h2>
      <p :if={is_nil(@power)} class="text-sm opacity-70">
        The power shows when the app has the weather of your place.
      </p>
      <%= if @power do %>
        <p class="text-sm">
          The batteries keep {Format.int(@power.storage)} Wh. {days_text(@power.months)}
        </p>
        <div class="overflow-x-auto" tabindex="0" role="region" aria-label="The power of each month">
          <table class="table table-xs" id="van-months">
            <thead>
              <tr>
                <th>Month</th>
                <th class="text-right">Use</th>
                <th class="text-right">Sun</th>
                <th class="text-right">Engine</th>
                <th class="text-right">Days off the grid</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={m <- @power.months}>
                <td>{m.name}</td>
                <td class="text-right">{Format.int(m.use)}</td>
                <td class="text-right">{Format.int(m.sun)}</td>
                <td class="text-right">{Format.int(m.drive)}</td>
                <td class="text-right">{days(m.days)}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-xs opacity-80">
          Wh in one day. The sun is the sun of NASA POWER at your house: a trip to a different place has a different sun. The panels give 80% of their watts in full sun. The engine: the amps of the alternator charger at 12.8 V, for the hours of driving. A lithium battery gives 90% of its label, a lead acid battery 50%, and a power station 95%. An item on an outlet of 120 V loses 10% in the inverter.
        </p>
      <% end %>
    </div>
    """
  end

  defp days_text(months) do
    case Enum.map(months, & &1.days) do
      [nil | _] ->
        "The van has no battery yet."

      days ->
        if Enum.all?(days, &(&1 == :unlimited)),
          do: "The sun and the engine give more than the van uses: no limit off the grid.",
          else:
            "Off the grid: #{days(Enum.min_by(days, &if(&1 == :unlimited, do: :infinity, else: &1)))} in the month with the least sun."
    end
  end

  defp days(nil), do: "–"
  defp days(:unlimited), do: "no limit"
  defp days(days) when days >= 30, do: "30 days or more"
  defp days(days), do: "#{:erlang.float_to_binary(days / 1, decimals: 1)} days"

  attr :warnings, :list, required: true

  # The safety notes, where they apply.
  defp notes(assigns) do
    ~H"""
    <div :if={@warnings != []} id="van-notes" class="space-y-2">
      <h2 class="text-lg font-bold">Safety</h2>
      <div :for={warning <- @warnings} class="alert alert-warning text-sm">
        <span>{note(warning)}</span>
      </div>
    </div>
    """
  end

  defp note({:fuse, _battery}),
    do:
      "Put a fuse near the positive post of each battery. The ABYC standard E-11 for boats, which many van builders use, puts it within 7 inches of the battery. A short circuit with no fuse can start a fire. Then mark the battery: \"It has a fuse near its positive post\"."

  defp note(:co),
    do:
      "A stove or a heater that burns fuel makes carbon monoxide. Add a carbon monoxide alarm, and let fresh air in when it burns. A diesel heater takes its air from outside the van, and sends its gas out."

  defp note(:propane),
    do:
      "Propane and butane are heavier than air: put the propane alarm low, near the floor, and keep the tank in a box with a vent to the outside."

  defp note(:inverter),
    do:
      "An item on an outlet of 120 V needs an inverter or a power station. Add one to the electrical bay."

  defp note(:no_battery),
    do: "The items of the van use power, and the van has no battery and no power station."

  attr :build, :map, required: true
  attr :van, :map, required: true

  # The zones of the van in a row, like the rooms of the house.
  defp zones(assigns) do
    assigns = assign(assigns, :zones, Build.zones(assigns.build, assigns.van.id))

    ~H"""
    <div class="space-y-1">
      <h2 class="text-lg font-bold">Zones</h2>
      <div id="van-zones" class="flex snap-x snap-mandatory overflow-x-auto gap-3 pb-2">
        <article
          :for={{zone, i} <- Enum.with_index(@zones)}
          id={"zone-#{zone.id}"}
          class="card card-border bg-base-100 snap-center shrink-0 w-[85%] p-4 space-y-3"
          aria-label={zone.name}
        >
          <header class="flex items-start justify-between gap-2">
            <h3 class="text-lg font-bold">{zone.name}</h3>
            <span class="text-xs opacity-70">Zone {i + 1} of {length(@zones)}</span>
          </header>
          <ul class="grid grid-cols-2 gap-2">
            <li :for={item <- Build.items_in(@build, zone.id)}>
              <.link
                patch={~p"/van?#{[id: @van.id, item: item.id]}"}
                id={"van-item-#{item.id}"}
                class="card card-border p-2 h-full hover:bg-base-200"
              >
                <span class="text-2xl" aria-hidden="true">{Catalog.kind(item.type).emoji}</span>
                <span class="text-sm font-semibold leading-tight">{Catalog.name(item)}</span>
                <span class="text-xs opacity-80">{lb(Van.weight(item))}</span>
                <span :if={Van.wh_day(item, 7) > 0} class="text-xs opacity-80">
                  {Format.int(Van.wh_day(item, 7))} Wh in a day of July
                </span>
              </.link>
            </li>
            <li>
              <.link
                patch={~p"/van?#{[id: @van.id, add: zone.id]}"}
                id={"add-#{zone.id}"}
                class="card card-border border-dashed p-2 h-full items-center justify-center hover:bg-base-200"
                aria-label={"Add an item to #{zone.name}"}
              >
                <span class="text-2xl" aria-hidden="true">＋</span>
                <span class="text-sm">Add</span>
              </.link>
            </li>
          </ul>
        </article>
      </div>
    </div>
    """
  end

  attr :build, :map, required: true
  attr :van, :map, required: true

  # The power stations of the house that can go in the van, and back: the
  # house loses their capacity while the van has them.
  defp stations(assigns) do
    assigns = assign(assigns, :stations, Van.stations(assigns.build))

    ~H"""
    <div
      :if={@stations.at_home != [] or @stations.away != []}
      id="van-stations"
      class="card card-border p-4 space-y-2"
    >
      <h2 class="text-lg font-bold">Stations of the house</h2>
      <p class="text-sm">
        A power station can go from the house to the van for a trip. While it is in the van, the house does not have it.
      </p>
      <ul class="space-y-1 text-sm">
        <li :for={station <- @stations.at_home} class="flex items-center justify-between gap-2">
          <span>{Catalog.name(station)}: {station.params["kwh"] + station.params["extra_kwh"]} kWh, at home</span>
          <button
            type="button"
            phx-click="take_to_van"
            phx-value-item={station.id}
            phx-value-van={@van.id}
            class="btn btn-xs"
          >
            Take it in this van
          </button>
        </li>
        <li :for={{station, van} <- @stations.away} class="flex items-center justify-between gap-2">
          <span>
            {Catalog.name(station)}: {station.params["kwh"] + station.params["extra_kwh"]} kWh, {if van.id ==
                                                                                                      @van.id,
                                                                                                    do:
                                                                                                      "in this van",
                                                                                                    else:
                                                                                                      "in another van"}
          </span>
          <button
            type="button"
            phx-click="bring_home"
            phx-value-item={station.id}
            class="btn btn-xs"
          >
            Bring it home
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :build, :map, required: true
  attr :van, :map, required: true
  attr :item, :map, required: true
  attr :error, :string, default: nil

  # The numbers of an item of the van (or of the van itself).
  defp item_sheet(assigns) do
    kind = Catalog.kind(assigns.item.type)
    assigns = assign(assigns, kind: kind, van?: assigns.item.id == assigns.van.id)

    ~H"""
    <Inside.sheet
      id="item-sheet"
      title={"#{@kind.emoji} #{Catalog.name(@item)}"}
      close={~p"/van?#{[id: @van.id]}"}
    >
      <div :if={@item.typical} class="alert alert-warning text-sm">
        <span>These numbers are a guess. Check them on the label.</span>
        <button type="button" phx-click="check_item" phx-value-id={@item.id} class="btn btn-xs">Correct</button>
      </div>

      <form id="item-form" phx-change="item" phx-submit="item" class="space-y-3">
        <input type="hidden" name="item_id" value={@item.id} />
        <Inside.param
          :for={param <- @kind.params}
          param={param}
          value={@item.params[param.key]}
          error={@error == param.key}
        />
      </form>

      <button
        :if={@van?}
        type="button"
        id="van-model"
        phx-click="van_model"
        phx-value-id={@item.id}
        class="btn btn-sm"
      >
        Use the numbers of the model
      </button>

      <p :if={not @van?} class="text-sm">
        {lb(Van.weight(@item))}{if Van.wh_day(@item, 7) > 0,
          do: " · #{Format.int(Van.wh_day(@item, 7))} Wh in a day of July"}{if Van.wh_day(@item, 1) >
                                                                                 0,
                                                                               do:
                                                                                 " · #{Format.int(Van.wh_day(@item, 1))} Wh in a day of January"}
      </p>

      <p :if={not @van?} class="text-sm">
        <span class="font-semibold">It counts in:</span> {Inside.features(@kind)}.
      </p>

      <button
        :if={@item.type == "power_station" and @item.home}
        type="button"
        phx-click="bring_home"
        phx-value-item={@item.id}
        class="btn btn-sm"
      >
        Bring it home
      </button>

      <button
        :if={not @van?}
        type="button"
        id="delete-item"
        phx-click="delete_item"
        phx-value-id={@item.id}
        data-confirm="Remove this item?"
        class="btn btn-sm btn-error btn-outline"
      >
        Remove the item
      </button>
    </Inside.sheet>
    """
  end

  attr :van, :map, required: true
  attr :zone, :map, required: true

  # The kinds of items that can go in a zone.
  defp add_sheet(assigns) do
    assigns = assign(assigns, :kinds, Catalog.kinds_for(assigns.zone.place))

    ~H"""
    <Inside.sheet id="add-sheet" title={"Add to #{@zone.name}"} close={~p"/van?#{[id: @van.id]}"}>
      <ul class="grid grid-cols-2 gap-2">
        <li :for={kind <- @kinds}>
          <button
            type="button"
            id={"add-#{kind.type}"}
            phx-click="add_item"
            phx-value-room={@zone.id}
            phx-value-type={kind.type}
            class="btn btn-block justify-start h-auto py-2"
          >
            <span aria-hidden="true">{kind.emoji}</span> {kind.name}
          </button>
        </li>
      </ul>
    </Inside.sheet>
    """
  end

  defp lb(pounds), do: "#{Format.int(pounds)} lb"
end
