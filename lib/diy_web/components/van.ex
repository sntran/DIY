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
  alias DIYWeb.{Format, Icon, Inside, Scene}

  attr :build, :map, required: true
  attr :van_id, :string, default: nil
  attr :item, :string, default: nil
  attr :add, :string, default: nil
  attr :climate, :map, default: nil
  attr :item_error, :string, default: nil
  attr :scene, :map, required: true, doc: "the parts of the picture (`DIYWeb.Scene.van_parts/2`)"

  def page(assigns) do
    vans = Van.vans(assigns.build)
    van = Enum.find(vans, &(&1.id == assigns.van_id)) || List.first(vans)

    assigns =
      assign(assigns,
        vans: vans,
        van: van,
        weight: van && Van.weight(assigns.build, van),
        power: van && Van.power(assigns.build, van, assigns.climate)
      )

    ~H"""
    <section id="van" class="space-y-4">
      <h1 class="text-xl font-bold">Van</h1>

      <p :if={is_nil(@van)} id="no-van" class="text-sm">
        No van yet. A camper van goes in the driveway or the garage: add it there.
        <.link patch={~p"/inside"} class="link">Go to the rooms</.link>
      </p>

      <%= if @van do %>
        <nav :if={length(@vans) > 1} aria-label="The vans" class="flex flex-wrap gap-1">
          <.link
            :for={{v, i} <- Enum.with_index(@vans, 1)}
            patch={~p"/van?#{[id: v.id]}"}
            class={["btn btn-sm", if(v.id == @van.id, do: "btn-primary", else: "btn-ghost")]}
            aria-current={v.id == @van.id && "page"}
            aria-label={"Van #{i}: #{model_name(v)}"}
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
          {if @van.params["model"] == "other",
            do:
              "The app does not have the numbers of this van: the numbers now are of the last model. The label in the door frame gives the ratings, and a truck scale gives the weight of each axle.",
            else:
              "These numbers are typical of the model. The label in the door frame gives the ratings, and a truck scale gives the weight of each axle."}
        </p>
        <p :if={@van.typical and source(@van)} id="van-source" class="text-xs opacity-80">
          The numbers of the model: {source(@van)}
        </p>

        <div id="van-picture" class="overflow-hidden rounded-box">
          <Scene.van id="van-scene" parts={@scene} />
        </div>

        <.weight weight={@weight} />
        <.power power={@power} />
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

  defp model_name(van), do: van |> model() |> elem(1)
  defp source(van), do: van |> model() |> elem(3)
  defp model(van), do: List.keyfind(Catalog.van_models(), van.params["model"], 0)

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
      <p :if={@weight.payload > 0} class="text-sm">
        The van can take {lb(@weight.payload)} (its rating, less its empty weight of {lb(
          @weight.empty
        )}). The build, the people and the gear take {lb(@weight.load)}: {left(@weight)}
      </p>
      <p :if={@weight.payload <= 0} class="alert alert-warning text-sm">
        The empty weight ({lb(@weight.empty)}) is not less than the rating ({lb(@weight.gvwr)}). Check the numbers of the van.
      </p>
      <p :if={@weight.front_gawr == 0 or @weight.rear_gawr == 0} class="text-xs">
        The app does not know the rating of an axle of this model: give it from the label in the door frame.
      </p>
      <details class="text-sm">
        <summary class="cursor-pointer">The weight of each zone</summary>
        <ul class="list-disc pl-5">
          <li :for={{zone, pounds} <- @weight.zones}>
            {Keyword.fetch!(Catalog.zones(), zone)}: {lb(pounds)}
          </li>
        </ul>
        <p class="text-xs opacity-80">
          The cab has the people, and the bed has the gear. Each zone has a typical place from the front axle to the rear axle. The bed and the electrical bay are over the rear axle. A truck scale gives the real weight of each axle.
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
          {if @power.storage > 0, do: "The batteries keep #{Format.int(@power.storage)} Wh. "}{days_text(
            @power.months
          )}
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
          Wh in one day. The sun is the sun of NASA POWER at your house: a trip to a different place has a different sun. The panels give 80% of their watts in full sun. The engine: the amps of the alternator charger at the voltage of the batteries (12.8 V for each 12 V), for the hours that you drive. A lithium battery gives 90% of its label, a lead acid battery 50%, and a power station 95%. An item on an outlet of 120 V loses 10% in the inverter. The app does not count the loss of the outlets of a station.
        </p>
      <% end %>
    </div>
    """
  end

  defp days_text([%{days: nil} | _]), do: "The van has no battery yet."

  defp days_text(months) do
    if Enum.all?(months, &(&1.days == :unlimited)),
      do: "The sun and the engine give more than the van uses: no limit off the grid.",
      else: fewest(Enum.min_by(months, &if(&1.days == :unlimited, do: :infinity, else: &1.days)))
  end

  defp fewest(month),
    do: "Off the grid: #{days(month.days)} in #{month.name}, the month with the fewest days."

  defp left(%{payload: payload, load: load}) when payload >= load,
    do: "#{lb(payload - load)} is left."

  defp left(%{payload: payload, load: load}),
    do: "#{lb(load - payload)} more than the van can take."

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

  defp note({:fuse, %{params: p}, n}),
    do:
      "Battery #{n} (#{p["ah"]} Ah, #{p["volts"]} V) has no fuse near its positive post. Put a fuse there. The ABYC standard E-11 for boats, which many van builders use, puts it within 7 inches of the battery. A short circuit with no fuse can start a fire. Then mark the battery: \"It has a fuse near its positive post\"."

  defp note(:air),
    do:
      "A stove or a heater that burns fuel needs fresh air. Open a window or a vent when it burns."

  defp note(:co),
    do: "A stove or a heater that burns fuel makes carbon monoxide. Add a carbon monoxide alarm."

  defp note(:heater),
    do:
      "Put the diesel heater so that it takes its air from outside the van, and sends its gas out."

  defp note({:output, load, output}),
    do:
      "The items on 120 V need #{Format.int(load)} W, and the inverters and the stations give #{Format.int(output)} W. Use a larger inverter, or use fewer items at the same time."

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
                <Icon.item type={item.type} />
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
                <.icon name="hero-plus" class="size-6" />
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
          <span>{station_name(station)}, at home</span>
          <button
            type="button"
            phx-click="take_to_van"
            phx-value-item={station.id}
            phx-value-van={@van.id}
            class="btn btn-xs"
            aria-label={"Take it in this van: #{station_name(station)}"}
          >
            Take it in this van
          </button>
        </li>
        <li :for={{station, van} <- @stations.away} class="flex items-center justify-between gap-2">
          <span>
            {station_name(station)}, {if van.id == @van.id, do: "in this van", else: "in another van"}
          </span>
          <button
            type="button"
            phx-click="bring_home"
            phx-value-item={station.id}
            class="btn btn-xs"
            aria-label={"Bring it home: #{station_name(station)}"}
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
      title={Catalog.name(@item)}
      icon={@item.type}
      close={~p"/van?#{[id: @van.id]}"}
    >
      <div :if={@item.typical} class="alert alert-warning text-sm">
        <span>
          {if @van?,
            do: "These numbers are typical of the model. Check them on the label in the door frame.",
            else: "These numbers are a guess. Check them on the label."}
        </span>
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
        :if={@van? and @item.params["model"] != "other"}
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
        <span class="font-semibold">It counts in:</span> {Inside.features(
          Enum.filter(@kind.features, &(&1 in [:weight, :van_power, :safety]))
        )}.
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
            <Icon.item type={kind.type} class="size-8" /> {kind.name}
          </button>
        </li>
      </ul>
    </Inside.sheet>
    """
  end

  defp lb(pounds), do: "#{Format.int(pounds)} lb"

  defp station_name(%{params: p} = station),
    do:
      "#{Catalog.name(station)} (#{Format.value(Float.round(p["kwh"] + p["extra_kwh"], 3))} kWh)"
end
