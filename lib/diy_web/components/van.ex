defmodule DIYWeb.VanPage do
  @moduledoc """
  The build of a camper van (`DIY.Van`). The page shows the inside of the
  van at scale (`DIYWeb.VanCutaway`). It shows the two budgets: the weight
  on each axle, and the days off the grid. It also shows the safety notes,
  and the power stations that go from the house to the van.

  The inside of the van is cut open, as the house on the page Rooms. A
  drag moves an item, also to a different zone. A tap on a zone chooses
  it: a zone that is not fixed has handles on its walls. A list of the
  zones and their items gives the same facts to a screen reader and to a
  keyboard.

  `?id=ID` chooses a van. `?item=ID` opens an item of the van (or the van
  itself, for its numbers), and `?add=ZONE` the list of the items for a
  zone. `?room=ZONE` chooses a zone (with `&sheet=zone`, its sheet).
  """
  use DIYWeb, :html

  alias DIY.{Build, Catalog, Van}
  alias DIYWeb.{Cutaway, Format, Icon, Inside, Scene}

  attr :build, :map, required: true
  attr :van_id, :string, default: nil
  attr :item, :string, default: nil
  attr :add, :string, default: nil
  attr :climate, :map, default: nil
  attr :item_error, :string, default: nil
  attr :scene, :map, required: true, doc: "the parts of the picture (`DIYWeb.Scene.van_parts/2`)"
  attr :view, :map, default: nil, doc: "the van cut open (`DIYWeb.VanCutaway.view/2`)"
  attr :room, :string, default: nil, doc: "the zone that the person chose"
  attr :sheet, :string, default: nil, doc: "\"zone\": the sheet of the chosen zone"
  attr :status, :string, default: nil, doc: "a text for a screen reader after a move"

  def page(assigns) do
    vans = Van.vans(assigns.build)
    van = Enum.find(vans, &(&1.id == assigns.van_id)) || List.first(vans)
    zones = if van, do: Build.zones(assigns.build, van.id), else: []

    assigns =
      assign(assigns,
        vans: vans,
        van: van,
        zone: Enum.find(zones, &(&1.id == assigns.room and &1.plan != nil)),
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

        <.plan
          :if={@view}
          build={@build}
          van={@van}
          view={@view}
          zone={@zone}
          status={@status}
        />
        <.weight weight={@weight} />
        <.power power={@power} />
        <.notes warnings={Van.warnings(@build, @van)} />
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
        <.zone_sheet :if={@zone && @sheet == "zone" && movable?(@zone)} van={@van} zone={@zone} />
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
          The people sit at the middle of the cab, and the gear is at the middle of the bed. The place of each item on the plan of the van gives its weight on each axle. A truck scale gives the real weight of each axle.
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
  attr :view, :map, required: true
  attr :zone, :map, default: nil
  attr :status, :string, default: nil

  # The inside of the van, cut open: the plan of its zones and its items
  # (the hook Plan). Then the bar of the chosen zone, and the list.
  defp plan(assigns) do
    ~H"""
    <div class="space-y-1">
      <h2 class="text-lg font-bold">Inside the van</h2>
      <div id={"van-plan-#{@van.id}"} phx-hook="Plan" class="space-y-2">
        <div class="flex items-center gap-2 overflow-x-auto pb-1">
          <button
            :for={level <- Enum.reverse(@view.levels)}
            type="button"
            data-focus={level.id}
            class="btn btn-sm btn-ghost shrink-0 px-2"
          >
            {level.name}
          </button>
        </div>
        <div class="relative h-[min(60dvh,95vw)] overflow-hidden rounded-box border border-base-300">
          <Cutaway.cutaway view={@view} selected={@zone && @zone.id} />
          <Inside.zoom all="Show all the van" />
        </div>
        <.zone_bar :if={@zone} van={@van} zone={@zone} />
        <.list build={@build} van={@van} />
        <p id="plan-status" class="sr-only" aria-live="polite">{@status}</p>
      </div>
    </div>
    """
  end

  # The cab and the roof of a van do not move (`DIY.Build.move_room/4`).
  defp movable?(zone), do: zone.place not in [:cab, :van_roof]

  attr :van, :map, required: true
  attr :zone, :map, required: true

  # The bar of the chosen zone: its name, its size, and its buttons.
  defp zone_bar(assigns) do
    ~H"""
    <div id="zone-bar" class="card card-border bg-base-100 p-3 gap-2">
      <div class="flex items-center gap-2">
        <div class="grow min-w-0">
          <p class="font-semibold truncate">{@zone.name}</p>
          <p class="text-xs opacity-70">
            {Inside.feet(@zone.plan.w)} by {Inside.feet(@zone.plan.d)}{if not movable?(@zone),
              do: ". It stays where it is."}
          </p>
        </div>
        <.link
          patch={~p"/van?#{[id: @van.id, add: @zone.id, room: @zone.id]}"}
          id="bar-add"
          class="btn btn-sm btn-primary"
          aria-label={"Add an item to #{@zone.name}"}
        >
          <.icon name="hero-plus" class="size-4" /> Item
        </.link>
        <.link
          :if={movable?(@zone)}
          patch={~p"/van?#{[id: @van.id, room: @zone.id, sheet: "zone"]}"}
          id="bar-change"
          class="btn btn-sm"
        >
          Change
        </.link>
        <.link
          patch={~p"/van?#{[id: @van.id]}"}
          class="btn btn-sm btn-ghost btn-square"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.link>
      </div>
      <Inside.moves
        :if={movable?(@zone)}
        id="move-room"
        event="nudge_room"
        target={@zone.id}
        step={6}
        what="the zone"
      />
    </div>
    """
  end

  attr :van, :map, required: true
  attr :zone, :map, required: true

  # The sheet of a zone: its size in feet. The zone stays in the van.
  defp zone_sheet(assigns) do
    ~H"""
    <Inside.sheet
      id="zone-sheet"
      title={@zone.name}
      close={~p"/van?#{[id: @van.id, room: @zone.id]}"}
    >
      <form id={"size-#{@zone.id}"} phx-submit="room_size" class="space-y-2">
        <input type="hidden" name="room_id" value={@zone.id} />
        <p class="text-sm font-semibold">Size, in feet</p>
        <div class="flex items-end gap-2">
          <label :for={
            {key, label, inches} <- [
              {"w", "Across the van", @zone.plan.w},
              {"d", "Along the van", @zone.plan.d}
            ]
          }>
            <span class="text-xs">{label}</span>
            <input
              name={key}
              type="number"
              step="any"
              min="2"
              inputmode="decimal"
              value={Format.value(Float.round(inches / 12, 2))}
              class="input input-sm w-24"
            />
          </label>
          <button class="btn btn-sm">Set the size</button>
        </div>
        <p class="text-xs opacity-70">
          The walls at the front move. The zone stays in the van, and it does not go over a different zone.
        </p>
      </form>
    </Inside.sheet>
    """
  end

  attr :build, :map, required: true
  attr :van, :map, required: true

  # The zones and their items, as a list: for a screen reader, and for a
  # keyboard (it shows when it has the focus). The arrow keys move an item
  # or a zone (the hook Plan).
  defp list(assigns) do
    assigns = assign(assigns, :zones, Build.zones(assigns.build, assigns.van.id))

    ~H"""
    <section
      id="van-list"
      aria-label="The zones and their items"
      class="sr-only focus-within:not-sr-only focus-within:card focus-within:card-border focus-within:p-3"
    >
      <p class="text-sm">
        The arrow keys move the item or the zone that has the focus: 6 inches, or 2 feet with Shift. The Left key moves it to the left side of the van, and the Up key to the back.
      </p>
      <ul>
        <li :for={zone <- @zones} id={"zone-#{zone.id}"}>
          <h3>
            {zone.name}{if zone.plan,
              do: " (#{Inside.feet(zone.plan.w)} across, #{Inside.feet(zone.plan.d)} along the van)"}
          </h3>
          <ul>
            <li :if={zone.plan}>
              <.link
                patch={~p"/van?#{[id: @van.id, room: zone.id]}"}
                id={"choose-#{zone.id}"}
                data-nudge-room={movable?(zone) && zone.id}
                class="link"
              >
                Choose {zone.name}
              </.link>
            </li>
            <li :for={item <- Build.items_in(@build, zone.id)}>
              <.link
                patch={~p"/van?#{[id: @van.id, item: item.id]}"}
                id={"van-item-#{item.id}"}
                data-nudge={item.at && item.id}
                class="link"
              >
                {Catalog.name(item)}: {lb(Van.weight(item))}{if Van.wh_day(item, 7) > 0,
                  do: ", #{Format.int(Van.wh_day(item, 7))} Wh in a day of July"}
              </.link>
            </li>
            <li>
              <.link
                patch={~p"/van?#{[id: @van.id, add: zone.id]}"}
                id={"add-#{zone.id}"}
                class="link"
                aria-label={"Add an item to #{zone.name}"}
              >
                Add an item
              </.link>
            </li>
          </ul>
        </li>
      </ul>
    </section>
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

      <Inside.place
        :if={not @van? and @item.at}
        item={@item}
        room={elem(Build.room(@build, @item.room), 1)}
      />

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
            class="btn btn-block justify-start h-auto py-2 text-left"
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
