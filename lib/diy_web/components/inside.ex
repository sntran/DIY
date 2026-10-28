defmodule DIYWeb.Inside do
  @moduledoc """
  The inside of the house: the plan at scale (`DIYWeb.Cutaway`). The house
  is cut open: each floor is a layer, from the ground up to the roof. Each
  item stands at its place in its room. The person drags an item to move
  it, also to a different room. A tap on an item brings it to the front
  (`DIYWeb.Stage`), and a tap on a room chooses it. A chosen room has
  handles on its walls, and a bar with its size and its buttons. The hook
  Plan (`assets/js/plan.js`) does the drag and the zoom. The panel of an
  item and the bar of a room have buttons that move them with no drag.

  The plan is for the eyes. A list of the rooms and their items gives the
  same facts to a screen reader and to a keyboard. It shows when it has
  the focus. In the list, the arrow keys move an item or a room.
  """
  use DIYWeb, :html

  alias DIY.{Build, Catalog, Estimate, Layout, Power, Prices, Solar}
  alias DIYWeb.{Camera, Cutaway, Format, HomeAssistant, Icon, MakerLink, Stage, Wires}

  @place_names %{indoor: "Inside", outdoor: "Outside", roof: "On the roof"}

  # The features of a van: a house with no van does not show them.
  @van_features [:weight, :van_power, :safety]

  attr :build, :map, required: true
  attr :estimate, :map, required: true, doc: "the estimate with the planned items"
  attr :bill, :map, default: nil, doc: "the bill of today (DIY.Bill)"
  attr :price, :map, required: true
  attr :view, :map, required: true, doc: "the layers of the plan (`DIYWeb.Cutaway.view/1`)"
  attr :item, :string, default: nil
  attr :add, :string, default: nil
  attr :add_query, :string, default: "", doc: "the text of the search of the sheet Add"
  attr :room, :string, default: nil, doc: "the room that the person chose"

  attr :sheet, :string,
    default: nil,
    doc: "\"room\" (change the room), \"new_room\" or \"ha_rooms\" (`DIYWeb.HomeAssistant`)"

  attr :item_error, :any,
    default: nil,
    doc: "the key of a number that is not valid, or `{:wire, id, key}`"

  attr :item_said, :string, default: nil, doc: "the new value after − or +, for a screen reader"

  attr :item_frames, :map,
    default: nil,
    doc: "the frames of the open item (`DIYWeb.Stage.frames/2`)"

  attr :status, :string, default: nil, doc: "a text for a screen reader after a move"
  attr :away, :list, default: [], doc: "the stations of the house in a van: {item, van}"
  attr :ha, :map, required: true, doc: "the link to Home Assistant (`DIYWeb.HomeAssistant`)"
  attr :ha_rooms, :map, default: nil, doc: "the floors and the areas of Home Assistant"
  attr :ha_sync, :map, default: nil, doc: "what the last match of the rooms did"

  attr :ha_devices, :map,
    default: nil,
    doc: "the devices and the areas of Home Assistant (`DIYWeb.HomeAssistant`)"

  attr :ha_energy, :map,
    default: nil,
    doc: "the energy data of Home Assistant (`DIYWeb.HomeAssistant.read_energy/1`)"

  attr :ha_states, :map,
    default: %{},
    doc: "the state of each device that the app turns on and off (`DIYWeb.HomeAssistant`)"

  attr :ha_control, :map,
    default: %{},
    doc: "the controls of the devices that wait, and their errors (`DIYWeb.HomeAssistant`)"

  attr :ha_stations, :map,
    default: %{},
    doc: "the parts of each power station (`DIYWeb.HomeAssistant`)"

  attr :makers, :map,
    default: %{},
    doc: "the direct links to the clouds of the makers (`DIYWeb.MakerLink`)"

  attr :maker_control, :map,
    default: %{},
    doc: "the controls of the stations of the makers that wait, and their errors"

  attr :ghosts, :list,
    default: [],
    doc: "the ghosts of the devices of Home Assistant (`DIY.HomeAssistant.ghosts/4`)"

  attr :ha_count, :integer,
    default: 0,
    doc: "the count of all the ghosts: the plan shows some of them (`DIY.HomeAssistant.ghosts/4`)"

  attr :ha_away, :integer,
    default: 0,
    doc: "the count of the devices in an area with no room (`DIY.HomeAssistant.away/3`)"

  attr :outage, :string,
    default: nil,
    doc: "the hours of backup (`DIYWeb.PowerPage.outage_text/2`)"

  def inside(assigns) do
    room =
      case assigns.room && Build.room(assigns.build, assigns.room) do
        {:ok, room} -> room
        _none -> nil
      end

    # The card of the link to Home Assistant is on the panel of a hub.
    # Sometimes no hub is on the stage: for example, the hub went away in a
    # different tab. Then the page shows the error of a sign-in that came
    # back, or of a session that ended. The other errors come from the card
    # itself, or from the store for each page (the device error tells it).
    hub_open =
      match?(
        {:ok, %{type: "home_assistant"}},
        assigns.item && Build.item(assigns.build, assigns.item)
      )

    assigns =
      assign(assigns,
        chosen: room,
        levels: Build.levels(assigns.build.house.floors),
        ha_alert:
          assigns.ha.error in ~w(state denied token unreachable signed_out) and not hub_open,
        devices_error:
          if(assigns.ha.state == "connected" and match?(%{error: _}, assigns.ha_devices),
            do: assigns.ha_devices.error
          ),
        item_states: HomeAssistant.item_states(assigns),
        power: HomeAssistant.power(assigns, assigns.item),
        station: HomeAssistant.station(assigns, assigns.item),
        unit: assigns.makers != %{} && MakerLink.station(assigns, assigns.item),
        unit_choices: unit_choices(assigns, assigns.item),
        energy: HomeAssistant.item_energy(assigns, assigns.item),
        ha_meter: HomeAssistant.meter_offer(assigns)
      )

    ~H"""
    <section id="inside" class="space-y-2" data-ha={@ha.state}>
      <div :if={@ha_alert} id="ha-alert" role="alert" class="alert alert-warning text-sm">
        <span>Home Assistant: {HomeAssistant.message(@ha.error)}</span>
        <.link patch={~p"/settings"} class="link">Open Settings</.link>
      </div>
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-bold">Rooms</h1>
        <.link
          :if={@bill}
          patch={~p"/estimate"}
          id="pill"
          class="badge badge-lg badge-primary"
        >
          {Format.money(@bill.cost / 12)} a month
        </.link>
      </div>

      <div :if={"plan" not in @build.hints} id="plan-hint" class="alert alert-info text-sm">
        <.icon name="hero-hand-raised" class="size-6" />
        <span>
          Drag an item to move it. Tap an item to open it. Tap a room to change it. Pinch or use the buttons to zoom.
        </span>
        <button type="button" phx-click="hint" phx-value-hint="plan" class="btn btn-sm">OK</button>
      </div>

      <%!-- A screen reader reads a new text in the status: the status is on
        the page before its text. --%>
      <div id="ha-ghosts" role="status">
        <div
          :if={@ha_count > 0 or @ha_away > 0 or @devices_error != nil}
          class="rounded-box border border-base-300 bg-base-200 p-3 text-sm space-y-1"
        >
          <p :if={@ha_count > 0}>
            {ghost_text(@ha_count)} Tap a ghost on the plan to put it in the house. With a keyboard, use the list of the rooms.
            <span :if={@ha_count > length(@ghosts)}>
              The plan shows {length(@ghosts)} of them now. The next ones come when you add them.
            </span>
          </p>
          <p :if={@ha_away > 0}>
            {away_text(@ha_away)}
            <.link patch={~p"/inside?#{[sheet: "ha_rooms"]}"} class="link">
              Match the rooms with Home Assistant
            </.link>
          </p>
          <p :if={@devices_error}>{devices_message(@devices_error)}</p>
        </div>
      </div>

      <div id="house-plan" phx-hook="Plan" class="space-y-2">
        <div class="flex items-center gap-2 overflow-x-auto pb-1">
          <button
            :for={level <- Enum.reverse(@view.levels)}
            type="button"
            data-focus={level.id}
            class="btn btn-sm btn-ghost shrink-0 px-2 aria-pressed:bg-base-300 aria-pressed:shadow-[inset_0_-3px_0_var(--color-base-content)]"
          >
            {level.name}
          </button>
        </div>

        <%!-- Under the plan: the bar of the chosen room, or the button to add a room. --%>
        <div class={[
          "relative overflow-hidden rounded-box border border-base-300",
          if(@chosen, do: "h-[calc(100dvh-24rem)]", else: "h-[calc(100dvh-17rem)]"),
          "min-h-48"
        ]}>
          <%!-- Only an item of the house: the hook puts its id in a selector. --%>
          <Cutaway.cutaway
            view={@view}
            selected={@chosen && @chosen.id}
            open={if match?({:ok, _}, Build.item(@build, @item)), do: @item}
            states={@item_states}
          />
          <.zoom all="Show all the house" />
        </div>
        <div :if={!@chosen} class="flex justify-end">
          <.link
            patch={~p"/inside?#{[sheet: "new_room"]}"}
            id="add-room"
            class="btn btn-sm btn-primary"
          >
            <.icon name="hero-plus" class="size-4" /> Add a room
          </.link>
        </div>

        <.room_bar :if={@chosen} room={@chosen} build={@build} />

        <.list
          build={@build}
          levels={@levels}
          estimate={@estimate}
          price={@price}
          away={@away}
          chosen={@chosen && @chosen.id}
          ghosts={@ghosts}
          states={@item_states}
        />
        <p id="plan-status" class="sr-only" aria-live="polite">{@status}</p>
      </div>

      <.item_stage
        :if={@item && @item_frames && match?({:ok, _}, house_item(@build, @item))}
        frames={@item_frames}
        close={if @chosen, do: ~p"/inside?#{[room: @chosen.id]}", else: ~p"/inside"}
        build={@build}
        item={elem(house_item(@build, @item), 1)}
        estimate={@estimate}
        price={@price}
        error={@item_error}
        said={@item_said}
        outage={@outage}
        ha={@ha}
        ha_devices={@ha_devices}
        power={@power}
        station={@station}
        unit={@unit || nil}
        unit_choices={@unit_choices}
        energy={@energy}
        ha_meter={@ha_meter}
      />
      <.add_sheet
        :if={@add && match?({:ok, _}, Build.room(@build, @add))}
        room={elem(Build.room(@build, @add), 1)}
        query={@add_query}
      />
      <.room_sheet
        :if={@chosen && @sheet == "room"}
        room={@chosen}
        next={next_rooms(@build, @chosen)}
        open={Build.open_to(@build, @chosen.id)}
      />
      <.new_room_sheet :if={@sheet == "new_room"} levels={@levels} />
      <HomeAssistant.rooms_sheet
        :if={@sheet == "ha_rooms"}
        build={@build}
        ha={@ha}
        ha_rooms={@ha_rooms}
        ha_sync={@ha_sync}
      />
    </section>
    """
  end

  attr :all, :string, required: true, doc: "the label of the button that shows all the plan"

  @doc """
  The buttons of the zoom of a plan, at its top right (the hook Plan). At
  its top left, a note tells how to zoom with the mouse wheel. It shows
  after the wheel with no Ctrl.
  """
  def zoom(assigns) do
    ~H"""
    <p
      data-hint
      aria-hidden="true"
      class="absolute top-2 left-2 rounded-box bg-base-100 px-2 py-1 text-sm shadow opacity-0 transition-opacity pointer-events-none"
    >
      Use Ctrl and the mouse wheel to zoom.
    </p>
    <div class="absolute top-2 right-2 flex flex-col gap-2">
      <button type="button" data-zoom="in" class="btn btn-sm btn-square shadow" aria-label="Zoom in">
        <.icon name="hero-plus" class="size-4" />
      </button>
      <button type="button" data-zoom="out" class="btn btn-sm btn-square shadow" aria-label="Zoom out">
        <.icon name="hero-minus" class="size-4" />
      </button>
      <button type="button" data-zoom="fit" class="btn btn-sm btn-square shadow" aria-label={@all}>
        <.icon name="hero-arrows-pointing-out" class="size-4" />
      </button>
    </div>
    """
  end

  attr :room, :map, required: true
  attr :build, :map, required: true

  # The bar of the chosen room: its name, its size, and its buttons. The
  # arrows go to the room before it and to the next room, in the order of
  # the list (`neighbors/2`). The plan zooms in to the room (the hook).
  defp room_bar(assigns) do
    assigns = assign(assigns, :neighbors, neighbors(assigns.build, assigns.room))

    ~H"""
    <div id="room-bar" class="card card-border bg-base-100 p-3 gap-2">
      <%!-- The name of the room between its arrows. A screen reader hears the new name. --%>
      <div class="flex items-center gap-1">
        <.link
          :if={@neighbors}
          patch={~p"/inside?#{[room: elem(@neighbors, 0).id]}"}
          replace
          id="room-before"
          class="btn btn-sm btn-ghost btn-square"
          aria-label={"Go to the room before: #{elem(@neighbors, 0).name}"}
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>
        <div class="grow min-w-0 text-center" aria-live="polite" aria-atomic="true">
          <p class="font-semibold truncate">{@room.name}</p>
          <p class="text-xs opacity-70">
            <span class="whitespace-nowrap">{Build.level_name(@room.level)}</span>
            · <span class="whitespace-nowrap">{feet(@room.plan.w)}</span>
            by <span class="whitespace-nowrap">{feet(@room.plan.d)}</span>
          </p>
        </div>
        <.link
          :if={@neighbors}
          patch={~p"/inside?#{[room: elem(@neighbors, 1).id]}"}
          replace
          id="room-next"
          class="btn btn-sm btn-ghost btn-square"
          aria-label={"Go to the next room: #{elem(@neighbors, 1).name}"}
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </.link>
        <.link patch={~p"/inside"} class="btn btn-sm btn-ghost btn-square" aria-label="Close">
          <.icon name="hero-x-mark" class="size-4" />
        </.link>
      </div>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <.moves
          id="move-room"
          event="nudge_room"
          target={@room.id}
          step={24}
          what="the room"
          blocked={blocked(@build, @room.id, 24)}
        />
        <div class="flex gap-2">
          <.link
            patch={~p"/inside?#{[add: @room.id, room: @room.id]}"}
            id="bar-add"
            class="btn btn-sm btn-primary"
            aria-label={"Add an item to #{@room.name}"}
          >
            <.icon name="hero-plus" class="size-4" /> Item
          </.link>
          <.link
            patch={~p"/inside?#{[room: @room.id, sheet: "room"]}"}
            id="bar-change"
            class="btn btn-sm"
          >
            Change
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The room before a room of the house and the next room, in the order of
  the list. The list goes from the roof down to the floors, and then
  around the house. After the last room comes the first room. A house
  with one room gives `nil`.
  """
  def neighbors(build, room) do
    rooms =
      for level <- Build.levels(build.house.floors), r <- Build.rooms_on(build, level), do: r

    i = Enum.find_index(rooms, &(&1.id == room.id))

    if length(rooms) > 1,
      do: {Enum.at(rooms, i - 1), Enum.at(rooms, rem(i + 1, length(rooms)))}
  end

  @doc """
  The place of an item in its room, in words. In the house, the Left key
  goes to the left wall, and the Up key to the back wall. In a van, the Up
  key goes to its right side, and the Right key to its back. An item on
  an item (`DIY.Stack`) also tells the item under it, from `items`.
  """
  def where(item, %{level: "van:" <> _} = zone, _items),
    do:
      "#{feet(item.at.x)} from the right side of #{zone.name}, #{feet(item.at.y)} from its back."

  def where(item, room, items) do
    place =
      "#{feet(item.at.x)} from the left wall of #{room.name}, #{feet(item.at.y)} from the back wall."

    case Enum.find(items, &(&1.id == DIY.Stack.on(item))) do
      nil -> place
      base -> "#{place} Under it: #{Catalog.name(base)}."
    end
  end

  @doc "A length in inches as feet and inches, for example 12 ft 6 in."
  def feet(inches) do
    case {div(inches, 12), rem(inches, 12)} do
      {0, in_} -> "#{in_} in"
      {ft, 0} -> "#{ft} ft"
      {ft, in_} -> "#{ft} ft #{in_} in"
    end
  end

  attr :build, :map, required: true
  attr :levels, :list, required: true
  attr :estimate, :map, required: true
  attr :price, :map, required: true
  attr :away, :list, default: []
  attr :chosen, :string, default: nil, doc: "the chosen room: it stays when an item opens"
  attr :ghosts, :list, default: [], doc: "the ghosts of the devices of Home Assistant"

  attr :states, :map,
    default: %{},
    doc: "the state of each item of a device (`on`, `off` or `unavailable`)"

  # The rooms and their items, as a list: for a screen reader, and for a
  # keyboard (it shows when it has the focus). The arrow keys move an item
  # or a room (the hook Plan).
  defp list(assigns) do
    assigns = assign(assigns, place_names: @place_names, gas: Prices.gas(assigns.build))

    ~H"""
    <section
      id="plan-list"
      aria-label="The rooms and their items"
      class="sr-only focus-within:not-sr-only focus-within:card focus-within:card-border focus-within:p-3"
    >
      <p class="text-sm">
        The arrow keys move the item or the room that has the focus: 6 inches, or 2 feet with Shift. Each key moves it as it points on the plan: the Up key moves it to the back of the house.
      </p>
      <section :for={level <- @levels} id={"list-#{level}"}>
        <h2 class="font-semibold">{Build.level_name(level)}</h2>
        <ul>
          <li :for={room <- Build.rooms_on(@build, level)} id={"room-#{room.id}"}>
            <h3>
              {room.name} ({@place_names[room.place]}, {feet(room.plan.w)} by {feet(room.plan.d)})
            </h3>
            <ul>
              <li>
                <.link
                  patch={~p"/inside?#{[room: room.id]}"}
                  id={"choose-#{room.id}"}
                  data-nudge-room={room.id}
                  class="link"
                >
                  Choose {room.name}
                </.link>
              </li>
              <li :for={item <- Build.items_in(@build, room.id)}>
                <.link
                  patch={~p"/inside?#{[item: item.id] ++ if(@chosen, do: [room: @chosen], else: [])}"}
                  id={"item-#{item.id}"}
                  data-nudge={item.id}
                  class="link"
                >
                  {Catalog.name(item)}{item_note(item, @build, @estimate, @price, @gas)}{state_note(
                    @states[item.id]
                  )}
                </.link>
              </li>
              <li :for={{ghost, i} <- Enum.with_index(@ghosts, 1)} :if={ghost.room == room.id}>
                <button
                  type="button"
                  id={"ghost-g#{i}"}
                  phx-click="ha_add_device"
                  phx-value-id={ghost.device}
                  class="link text-left"
                >
                  Add {ghost.name} from Home Assistant ({Catalog.kind(ghost.type).name})
                </button>
              </li>
              <li :for={{item, van} <- @away} :if={item.home == room.id}>
                <.link patch={~p"/van?#{[id: van.id]}"} id={"away-#{item.id}"} class="link">
                  {Catalog.name(item)}: in the van now
                </.link>
              </li>
              <li>
                <.link
                  patch={~p"/inside?#{[add: room.id] ++ if(@chosen, do: [room: @chosen], else: [])}"}
                  id={"add-#{room.id}"}
                  class="link"
                  aria-label={"Add an item to #{room.name}"}
                >
                  Add an item
                </.link>
              </li>
            </ul>
          </li>
        </ul>
      </section>
      <.link patch={~p"/inside?#{[sheet: "new_room"]}"} class="link">Add a room</.link>
    </section>
    """
  end

  # The ghosts on the plan, and the devices in an area with no room, in
  # words.
  defp ghost_text(1), do: "1 device of Home Assistant is not in the house yet."
  defp ghost_text(n), do: "#{n} devices of Home Assistant are not in the house yet."

  defp devices_message("too_many"),
    do: "Home Assistant has more than 1,000 devices in its areas: too many for the ghosts."

  defp devices_message(_error), do: "The app cannot read the devices of Home Assistant now."

  defp away_text(1), do: "1 device is in an area of Home Assistant with no room here."
  defp away_text(n), do: "#{n} devices are in areas of Home Assistant with no room here."

  # The device of Home Assistant of an item. It is `{:known, name}` when the
  # page has the devices, and `:gone` when Home Assistant does not have it
  # now. It is `:linked` when the page does not have the devices, and `nil`
  # with no link.
  defp device(build, item, ha_devices) do
    case {build.devices[item.id], ha_devices} do
      {nil, _devices} ->
        nil

      {id, %{devices: devices}} ->
        case Enum.find(devices, &(&1.id == id)) do
          nil -> :gone
          device -> {:known, device.name}
        end

      {_id, _devices} ->
        :linked
    end
  end

  # The energy that Home Assistant measured for the device of an item, and
  # the estimate of the same months for the item.
  defp energy_text(%{partial: true} = energy, _estimate, _item),
    do:
      "Home Assistant measured #{Format.kwh(energy.kwh)} in #{Format.month(energy.from)}, a part of the month."

  defp energy_text(energy, estimate, item) do
    count = length(energy.months)

    measured =
      "Home Assistant measured #{Format.kwh(energy.kwh)} in #{Format.count(count, "month")}, " <>
        if(count == 1,
          do: "in #{Format.month(energy.from)}.",
          else: "from #{Format.month(energy.from)} to #{Format.month(energy.to)}."
        )

    # The estimate of each month of the year (January first). Before the
    # estimate is ready, and for a kind that uses no power, none.
    by_month =
      estimate.ready and item.type not in Estimate.no_use() and
        get_in(estimate.items, [item.id, :months])

    same = by_month && same_months(by_month, energy.months)
    measured <> ((same && " The estimate for the same months: #{Format.kwh(same)}.") || "")
  end

  defp same_months(by_month, months),
    do:
      months
      |> Enum.map(&Enum.at(by_month, String.to_integer(String.slice(&1, 5, 2)) - 1))
      |> Enum.sum()

  @doc """
  The stations of the accounts of the makers that an item can link to: only
  for a power station with no link (`DIYWeb.MakerLink.choices/1`). An item
  of a device of Home Assistant has none: the app uses Home Assistant when
  it gives the station.
  """
  def unit_choices(%{makers: makers} = assigns, item_id) when makers != %{} do
    case item_id && Build.item(assigns.build, item_id) do
      {:ok, %{type: "power_station", id: id}} ->
        if Map.has_key?(assigns.build.units, id) or Map.has_key?(assigns.build.devices, id),
          do: [],
          else: MakerLink.choices(assigns)

      _other ->
        []
    end
  end

  def unit_choices(_assigns, _item_id), do: []

  attr :station, :map,
    required: true,
    doc: "the parts of a station (`DIYWeb.HomeAssistant.station/2`)"

  attr :prefix, :string, required: true, doc: "the start of the ids: `ha` or a maker"
  attr :item, :string, required: true
  attr :event, :string, required: true, doc: "the event of a switch"
  attr :maker, :string, default: nil
  attr :text, :any, required: true, doc: "the words of the state of a switch"

  attr :link_text, :any,
    default: nil,
    doc: "the words of the link of the station, or `nil` (`DIYWeb.HomeAssistant.link_text/1`)"

  # The numbers and the switches of a power station, from Home Assistant
  # or from the cloud of its maker.
  defp station_parts(assigns) do
    ~H"""
    <%!-- The numbers change each 5 seconds to 20 minutes: they are not
      a live region. Their texts are in one element that stays: an element
      that comes or goes above the switches makes a switch lose the
      focus. --%>
    <div id={"#{@prefix}-station-info"} class="flex flex-col gap-2">
      <dl :if={@station.known} id={"#{@prefix}-station"} class="stage-facts">
        <dt>Battery level</dt>
        <dd id={"#{@prefix}-battery"}>{percent(@station.battery)}</dd>
        <dt>Power in</dt>
        <dd id={"#{@prefix}-input"}>{watts(@station.input)}</dd>
        <dt>Power out</dt>
        <dd id={"#{@prefix}-output"}>{watts(@station.output)}</dd>
      </dl>
      <p
        :if={@station.known && @link_text && @link_text.(@station)}
        id={"#{@prefix}-station-link"}
        class="text-sm"
      >
        {@link_text.(@station)}
      </p>
      <p
        :if={not @station.known and @station.online}
        id={"#{@prefix}-station-wait"}
        class="text-sm"
      >
        The app waits for the numbers of the station.
      </p>
    </div>
    <%!-- A part that the station does not have has no switch: only its
      name and its status. The rows are in one element that stays: a row
      that comes moves no key below it. --%>
    <div id={"#{@prefix}-switches"} class="contents">
      <div :for={switch <- @station.switches} class="flex flex-col gap-1">
        <div id={"#{@prefix}-#{switch.part}"} class="stage-switch-row stage-row-plain">
          <span :if={switch.state == "none"} id={"#{@prefix}-#{switch.part}-label"}>
            {switch.name}
          </span>
          <label
            :if={switch.state != "none"}
            for={"#{@prefix}-switch-#{switch.part}"}
            id={"#{@prefix}-#{switch.part}-label"}
          >
            {switch.name}
          </label>
          <button
            :if={switch.state != "none"}
            type="button"
            id={"#{@prefix}-switch-#{switch.part}"}
            role="switch"
            class="stage-switch"
            aria-labelledby={"#{@prefix}-#{switch.part}-label"}
            aria-describedby={"#{@prefix}-#{switch.part}-state"}
            aria-checked={to_string(switch.state == "on")}
            aria-disabled={
              to_string(
                switch.state not in ~w(on off) or switch.pending != nil or switch.link == false
              )
            }
            phx-click={@event}
            phx-value-item={@item}
            phx-value-maker={@maker}
            phx-value-part={switch.part}
            phx-value-on={to_string(switch.state != "on")}
          ></button>
        </div>
        <p id={"#{@prefix}-#{switch.part}-state"} role="status" class="text-sm">
          {@text.(switch)}
        </p>
      </div>
    </div>
    """
  end

  # A number of a power station, or "Not known".
  defp percent(nil), do: "Not known"
  defp percent(value), do: "#{round(value)}%"

  defp watts(nil), do: "Not known"
  defp watts(value), do: "#{Format.int(value)} W"

  defp device_text({:known, name}), do: "This is #{name} in Home Assistant."
  defp device_text(:gone), do: "Its device is not in Home Assistant now."
  defp device_text(:linked), do: "It has a link to a device of Home Assistant."

  # An item of the house with no device, of the same kind as the item of a
  # device. Only for an appliance, not for the lights or the fans of a
  # house. It can be the same thing two times.
  defp twin(build, item) do
    with id when is_binary(id) <- build.devices[item.id],
         true <- item.type not in ~w(lights ceiling_fan always_on other),
         %{} = other <-
           Enum.find(
             build.items,
             &(&1.type == item.type and &1.id != item.id and
                 not Map.has_key?(build.devices, &1.id))
           ),
         {:ok, room} <- Build.room(build, other.room) do
      %{name: Catalog.name(other), room: room.name, kind: Catalog.text_name(item)}
    else
      _ -> nil
    end
  end

  # The usage, the cost and the flags of an item, as a text. The cost is at
  # the price of the hours when the item runs (DIY.Power.item_cost/4). The
  # cost of a gas item has its gas.
  defp item_note(item, build, estimate, price, gas) do
    usage =
      if estimate.ready and item.type not in Estimate.no_use() do
        %{year: kwh, therms: therms} = estimate.items[item.id]
        gas_text = if therms / 12 >= 0.5, do: " and #{Format.therms(therms / 12)}", else: ""

        cost =
          Power.item_cost(item, estimate, build.power, price.cents) / 12 +
            therms / 12 * gas.dollars

        ": #{Format.kwh(kwh / 12)}#{gas_text}, #{Format.money(cost)} a month"
      else
        ""
      end

    flags =
      [item.typical && "typical", item.planned && "a plan", item.backup && "on the station"]
      |> Enum.filter(& &1)
      |> Enum.map_join("", &", #{&1}")

    usage <> flags
  end

  # The state of the device of an item, in the list of the rooms.
  defp state_note("on"), do: ", on now"
  defp state_note("off"), do: ", off now"
  defp state_note("unavailable"), do: ", Home Assistant cannot reach it now"
  defp state_note(nil), do: ""

  # The rooms of the house next to a room, on its layer: it can be open to
  # them (`DIY.Build.set_open/3`).
  defp next_rooms(build, room) do
    for other <- build.rooms,
        other.id != room.id,
        other.plan,
        not Build.van_level?(other.level),
        Layout.layer(other) == Layout.layer(room),
        Layout.touch?(room.plan, other.plan),
        do: other
  end

  attr :room, :map, required: true
  attr :next, :list, default: [], doc: "the rooms next to the room, on its layer"
  attr :open, :list, default: [], doc: "the ids of the rooms that it is open to"

  # The sheet of a room: its name, its size, the rooms that it is open to,
  # and its removal.
  defp room_sheet(assigns) do
    ~H"""
    <.sheet id="room-sheet" title={@room.name} close={~p"/inside?#{[room: @room.id]}"}>
      <form id={"rename-#{@room.id}"} phx-submit="rename_room" class="flex items-end gap-2">
        <input type="hidden" name="room_id" value={@room.id} />
        <label class="grow">
          <span class="text-sm font-semibold">Name</span>
          <input
            id={"name-#{@room.id}"}
            name="name"
            value={@room.name}
            class="input input-sm w-full"
            maxlength="40"
          />
        </label>
        <button class="btn btn-sm">Rename</button>
      </form>

      <form id={"size-#{@room.id}"} phx-submit="room_size" class="space-y-2">
        <input type="hidden" name="room_id" value={@room.id} />
        <p class="text-sm font-semibold">Size, in feet</p>
        <div class="flex items-end gap-2">
          <label>
            <span class="text-xs">Width</span>
            <input
              name="w"
              type="number"
              step="any"
              min={Layout.min_room() / 12}
              max={Layout.max_room() / 12}
              inputmode="decimal"
              value={Format.value(Float.round(@room.plan.w / 12, 2))}
              class="input input-sm w-24"
            />
          </label>
          <label>
            <span class="text-xs">Depth</span>
            <input
              name="d"
              type="number"
              step="any"
              min={Layout.min_room() / 12}
              max={Layout.max_room() / 12}
              inputmode="decimal"
              value={Format.value(Float.round(@room.plan.d / 12, 2))}
              class="input input-sm w-24"
            />
          </label>
          <button class="btn btn-sm">Set the size</button>
        </div>
        <p class="text-xs opacity-70">
          The walls at the front move. On the plan, the handles on the walls move them too.
        </p>
      </form>

      <form :if={@next != []} id={"open-#{@room.id}"} phx-change="room_open">
        <input type="hidden" name="room_id" value={@room.id} />
        <input type="hidden" name="open[]" value="" />
        <fieldset class="space-y-1">
          <legend class="text-sm font-semibold">No wall to</legend>
          <label :for={other <- @next} class="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              id={"open-#{@room.id}-#{other.id}"}
              name="open[]"
              value={other.id}
              checked={other.id in @open}
              class="checkbox checkbox-sm"
            />
            {other.name}
          </label>
        </fieldset>
        <p class="text-xs opacity-70">
          An open plan: the rooms join, with no wall between them.
        </p>
      </form>

      <button
        type="button"
        id={"delete-#{@room.id}"}
        phx-click="delete_room"
        phx-value-id={@room.id}
        data-confirm={"Remove #{@room.name} and its items?"}
        class="btn btn-sm btn-error btn-outline"
      >
        Remove the room
      </button>
    </.sheet>
    """
  end

  attr :levels, :list, required: true

  # The sheet of a new room: the app puts it in a free place.
  defp new_room_sheet(assigns) do
    assigns = assign(assigns, :place_names, @place_names)

    ~H"""
    <.sheet id="new-room-sheet" title="Add a room">
      <form id="new-room" phx-submit="add_room" class="space-y-2">
        <label class="block">
          <span class="text-sm">Name</span>
          <input
            name="room[name]"
            class="input input-sm w-full"
            maxlength="40"
            placeholder="Office"
            required
          />
        </label>
        <label class="block">
          <span class="text-sm">Floor</span>
          <select name="room[level]" class="select select-sm w-full">
            <option :for={level <- @levels} value={level} selected={level == "f1"}>
              {Build.level_name(level)}
            </option>
          </select>
        </label>
        <label class="block">
          <span class="text-sm">Place</span>
          <select name="room[place]" class="select select-sm w-full">
            <option :for={{place, name} <- @place_names} value={place}>{name}</option>
          </select>
        </label>
        <p class="text-xs opacity-70">The room goes to a free place. Then drag it where it is.</p>
        <button class="btn btn-sm btn-primary">Add the room</button>
      </form>
    </.sheet>
    """
  end

  attr :build, :map, required: true
  attr :item, :map, required: true
  attr :estimate, :map, required: true
  attr :price, :map, required: true

  attr :error, :any,
    default: nil,
    doc: "the key of a number that is not valid, or `{:wire, id, key}`"

  attr :said, :string, default: nil, doc: "the new value after − or +, for a screen reader"
  attr :outage, :string, default: nil
  attr :close, :string, default: "/inside", doc: "the page of the close link"
  attr :ha, :map, required: true
  attr :frames, :map, required: true, doc: "the frames of its kind (`DIYWeb.Stage.frames/2`)"

  attr :ha_devices, :map,
    default: nil,
    doc: "the devices of Home Assistant (`DIYWeb.HomeAssistant`), for an item with a device"

  attr :van, :map,
    default: nil,
    doc: "on the page Van: the van of the item, or the van itself (`DIYWeb.VanPage`)"

  attr :power, :map,
    default: nil,
    doc: "the switch of the item of a device (`DIYWeb.HomeAssistant.power/2`), or `nil`"

  attr :station, :map,
    default: nil,
    doc: "the parts of a power station (`DIYWeb.HomeAssistant.station/2`), or `nil`"

  attr :unit, :map,
    default: nil,
    doc:
      "the unit of the cloud of a maker of the station (`DIYWeb.MakerLink.station/2`), or `nil`"

  attr :unit_choices, :list,
    default: [],
    doc: "the stations of the account of a maker that the item can link to"

  attr :energy, :map,
    default: nil,
    doc: "the energy of the device of the item (`DIYWeb.HomeAssistant.item_energy/2`), or `nil`"

  attr :ha_meter, :map,
    default: nil,
    doc: "the meter of Home Assistant, when the build does not use it (`DIYWeb.HomeAssistant`)"

  attr :numbers, :list,
    default: [],
    doc: "for an item in a van: its weight and its energy in a day, in words"

  @doc """
  An item in front of the person (`DIYWeb.Stage`). Its panel is the same
  for each item, on the page Rooms and on the page Van. Its parts are in
  this order: what it costs, the link of a hub to Home Assistant, its use,
  its place, and more. For an item in a van, the first part has its
  weight and its energy. Each part has a heading, and the panel scrolls: no part is out of
  sight.
  """
  def item_stage(assigns) do
    kind = Catalog.kind(assigns.item.type)
    {:ok, room} = Build.room(assigns.build, assigns.item.room)
    in_van = Build.van_level?(room.level)

    # The rooms (or the zones of its van) where the item can go. An item
    # does not go from the house to a van (`DIY.Build.move_item/3`).
    rooms =
      if in_van,
        do: Enum.filter(Build.zones(assigns.build, assigns.van.id), &Catalog.fits?(kind, &1)),
        else:
          Enum.filter(
            assigns.build.rooms,
            &(Catalog.fits?(kind, &1) and not Build.van_level?(&1.level))
          )

    van = Enum.any?(assigns.build.items, &(&1.type == "camper_van"))

    features =
      cond do
        in_van -> Enum.filter(kind.features, &(&1 in [:wires | @van_features]))
        # A bank in the house gives power through the stations.
        kind.type == "van_battery" -> [:backup, :power_view, :wires]
        van -> kind.features
        true -> kind.features -- @van_features
      end

    features = if gas_item?(assigns.item), do: features ++ [:gas], else: features

    solar =
      if assigns.item.type == "solar_panels",
        do: Solar.notes(assigns.build, assigns.item),
        else: []

    assigns =
      assign(assigns,
        no_use: Estimate.no_use(),
        kind: kind,
        room: room,
        rooms: rooms,
        in_van: in_van,
        on_van_page: assigns.van != nil,
        features: features,
        fields: Enum.filter(kind.params, &shown?(&1, assigns.item, van or in_van)),
        spots: MapSet.new(assigns.frames.spots, & &1.key),
        gas: Prices.gas(assigns.build),
        solar: solar,
        name: Catalog.name(assigns.item),
        device: device(assigns.build, assigns.item, assigns.ha_devices),
        twin: twin(assigns.build, assigns.item)
      )

    ~H"""
    <Stage.stage
      type={@item.type}
      frames={@frames}
      item={@item.id}
      title={@name}
      note={
        if @in_van,
          do: "In #{@room.name}, in the van",
          else: "In #{@room.name}#{level_note(@room.level)}"
      }
      close={@close}
      state={@power && @power.state}
    >
      <:screen :if={@item.type == "home_assistant"}>
        <HomeAssistant.screen ha={@ha} />
      </:screen>

      <section
        :if={@in_van and @numbers != []}
        id="part-cost"
        class="stage-cost"
        aria-labelledby="part-cost-title"
      >
        <h3 id="part-cost-title" class="sr-only">Its weight and its energy</h3>
        <p class="stage-month">{hd(@numbers)}</p>
        <p :for={line <- tl(@numbers)} class="stage-year">{line}</p>
      </section>

      <section
        :if={@estimate.ready and not @in_van}
        id="part-cost"
        class="stage-cost"
        aria-labelledby="part-cost-title"
      >
        <h3 id="part-cost-title" class="sr-only">
          {if @item.type in @no_use, do: "Its energy", else: "What it costs"}
        </h3>
        <p :if={@item.type in @no_use} id="item-math" class="stage-help">
          {if @on_van_page and @item.type == "camper_van",
            do:
              "A camper van has its own build, with its own batteries and power: this page. Its charge at home is not in this estimate.",
            else: hd(Estimate.explain(@item, 7, @estimate))}
        </p>
        <%= if @item.type not in @no_use do %>
          <p class="stage-month">
            {Format.dollars(Power.item_cost(@item, @estimate, @build.power, @price.cents) / 12)} a month
          </p>
          <p id="item-year" class="stage-year">
            {Format.kwh(@estimate.items[@item.id].year)} and {Format.money(
              Power.item_cost(@item, @estimate, @build.power, @price.cents)
            )} in one year
          </p>
          <p :if={@estimate.items[@item.id].therms > 0} id="item-gas" class="stage-year">
            Gas: {Format.therms(@estimate.items[@item.id].therms)} and {Format.money(
              @estimate.items[@item.id].therms * @gas.dollars
            )} in one year
          </p>
        <% end %>
      </section>

      <div :if={@item.typical} id="part-guess" class="stage-guess">
        <p>
          {cond do
            @item.type == "camper_van" ->
              "These numbers are typical of the model. Check them on the label in the door frame."

            @in_van ->
              "These numbers are a guess. Check them on the label."

            true ->
              "These numbers are a guess for a house like yours. Check them on the item."
          end}
        </p>
        <button type="button" phx-click="check_item" phx-value-id={@item.id} class="stage-btn">
          They are right
        </button>
      </div>

      <p :if={@item.type == "cpap"} id="item-medical" class="stage-help">
        A power station can run it for some hours: the page Power gives them. Ask the maker which
        batteries it can use. On a battery, turn off the humidifier: then it uses near 10 W. Also tell
        the company that sells your power. Many keep a list of homes with a medical need, but the list
        does not keep the power on.
      </p>

      <ul :if={@solar != []} id="item-solar" class="stage-list">
        <li :for={note <- @solar}>{note}</li>
      </ul>

      <p
        :if={@item.type in ~w(power_station solar_panels) or (@outage && @item.backup)}
        id="item-power"
        class="stage-help"
      >
        <span :if={@outage && (@item.type == "power_station" or @item.backup)} class="font-semibold">
          {@outage}
        </span>
        <.link patch={~p"/power"} class="link">Open the page Power</.link>
      </p>

      <details
        :if={@estimate.ready and @item.type not in @no_use and not @in_van}
        id="part-how"
        class="stage-how"
      >
        <summary>How the app gets this number</summary>
        <p>For one month: {month_name(math_month(@item))}{season(math_month(@item))}.</p>
        <ul class="stage-list">
          <li :for={line <- Estimate.explain(@item, math_month(@item), @estimate)}>{line}</li>
        </ul>
      </details>

      <section
        :if={@item.type == "home_assistant"}
        id="part-link"
        class="stage-sec"
        aria-labelledby="part-link-title"
      >
        <h3 id="part-link-title" class="stage-sec-title">Home Assistant</h3>
        <HomeAssistant.card ha={@ha} title={false} form={false} />
      </section>

      <section
        :if={@device && @item.type != "home_assistant"}
        id="part-link"
        class="stage-sec"
        aria-labelledby="part-link-title"
      >
        <h3 id="part-link-title" class="stage-sec-title">Home Assistant</h3>
        <p id="ha-device" class="text-sm wrap-anywhere">{device_text(@device)}</p>
        <%!-- A station with a device that is not a station now: for
          example, the person disabled its battery in Home Assistant. --%>
        <p
          :if={@item.type == "power_station" and match?({:known, _}, @device) and is_nil(@station)}
          id="ha-not-station"
          class="text-sm"
        >
          Home Assistant does not give the battery and the power out of this station now. Look at its entities in Home Assistant.
        </p>
        <p :if={@energy} id="ha-energy" class="text-sm">
          {energy_text(@energy, @estimate, @item)}
        </p>
        <div :if={@power} id="ha-power" class="stage-switch-row stage-row-plain">
          <label for="ha-switch" id="ha-power-label">Power</label>
          <%!-- aria-disabled, not disabled: the switch keeps the focus while
            a control waits. --%>
          <button
            type="button"
            id="ha-switch"
            role="switch"
            class="stage-switch"
            aria-labelledby="ha-power-label"
            aria-describedby="ha-power-state"
            aria-checked={to_string(@power.state == "on")}
            aria-disabled={to_string(@power.state not in ~w(on off) or @power.pending != nil)}
            phx-click="ha_switch"
            phx-value-item={@item.id}
            phx-value-on={to_string(@power.state != "on")}
          ></button>
        </div>
        <p :if={@power} id="ha-power-state" role="status" class="text-sm">
          {HomeAssistant.power_text(@power)}
        </p>
        <.station_parts
          :if={@station}
          station={@station}
          prefix="ha"
          item={@item.id}
          event="ha_station_switch"
          text={&HomeAssistant.power_text/1}
          link_text={&HomeAssistant.link_text/1}
        />
        <p :if={@twin} id="ha-twin" class="text-sm">
          The house also has {@twin.name} in {@twin.room}, with no link to Home Assistant. If it is the same {@twin.kind}, remove one of them.
        </p>
      </section>

      <section
        :if={@unit || @unit_choices != []}
        id="part-maker"
        class="stage-sec"
        aria-labelledby="part-maker-title"
      >
        <%!-- The title takes the focus after a link or its end: the key
          with the focus goes away. --%>
        <h3 id="part-maker-title" class="stage-sec-title" tabindex="-1">
          {MakerLink.names((@unit && [@unit.maker]) || Enum.map(@unit_choices, & &1.maker))}
        </h3>
        <%!-- The notes of the link are in one element that stays: a note
          that comes or goes above the switches makes a switch lose the
          focus. --%>
        <div :if={@unit} id="maker-notes" class="flex flex-col gap-2 text-sm wrap-anywhere">
          <p :if={@unit.name} id="maker-name">
            This is {@unit.name} in your account of {MakerLink.name(@unit.maker)}.
          </p>
          <p :if={@unit.state in ~w(none refused)} id="maker-closed">
            The app has no link to {MakerLink.name(@unit.maker)} now.{if @unit.last_numbers,
              do: " These are its last numbers."}
            <.link patch={~p"/settings"} class="link">Connect it in Settings.</.link>
          </p>
          <p :if={@unit.state in ~w(loading connecting)} id="maker-connecting">
            The app connects to {MakerLink.name(@unit.maker)}.
          </p>
          <p :if={@unit.state == "offline"} id="maker-offline">
            <span :if={@unit.error != "crypto"}>
              The app cannot reach {MakerLink.name(@unit.maker)} now.{if @unit.last_numbers,
                do: " These are its last numbers."}
            </span>
            <span :if={@unit.error == "crypto"}>{MakerLink.message("crypto", @unit.maker)}</span>
          </p>
          <p :if={@unit.online && not @unit.found} id="maker-gone">
            Your account of {MakerLink.name(@unit.maker)} does not have this station now.
          </p>
          <%!-- The station of the last list: only while the link is
            connected, so that the part does not tell a state "now" with no
            link. --%>
          <p :if={@unit.online && @unit.known && not @unit.reachable} id="maker-unreachable">
            {MakerLink.name(@unit.maker)} cannot reach the station now.{if @unit.last_numbers,
              do: " These are its last numbers."}
          </p>
        </div>
        <%!-- The parts of the station are in one element that stays while
          the item has a unit: a part that comes or goes moves the key below
          it, and that key loses the focus. --%>
        <div :if={@unit} id="maker-station" class="contents">
          <.station_parts
            :if={@unit.found}
            station={@unit}
            prefix={@unit.maker}
            item={@item.id}
            event="maker_switch"
            maker={@unit.maker}
            text={&MakerLink.switch_text(&1, @unit.maker)}
          />
        </div>
        <button
          :if={@unit}
          type="button"
          id="maker-unlink"
          class="stage-link self-start"
          phx-click={JS.push("maker_unlink") |> JS.dispatch("diy:focus", to: "#part-maker-title")}
          phx-value-item={@item.id}
        >
          Remove the link to {MakerLink.name(@unit.maker)}
        </button>
        <div :if={is_nil(@unit)} id="maker-choices" class="flex flex-col gap-2">
          <p class="text-sm">Link it to a station of your account:</p>
          <button
            :for={{choice, index} <- Enum.with_index(@unit_choices)}
            type="button"
            id={"maker-choice-#{index}"}
            class="stage-btn stage-btn-wrap self-start"
            phx-click={JS.push("maker_link") |> JS.dispatch("diy:focus", to: "#part-maker-title")}
            phx-value-item={@item.id}
            phx-value-unit={choice.unit}
          >
            {choice.name}{if choice.model, do: " (#{choice.model})"}
          </button>
        </div>
      </section>

      <section
        :if={@fields != [] or :usage in @kind.features or :van in @kind.features}
        id="part-use"
        class="stage-sec"
        aria-labelledby="part-use-title"
      >
        <h3 id="part-use-title" class="stage-sec-title">How you use it</h3>
        <.link
          :if={:van in @kind.features and not @on_van_page}
          patch={~p"/van?#{[id: @item.id]}"}
          id="open-van"
          class="stage-btn stage-primary"
        >
          Open the build of the van
        </.link>
        <form
          :if={@fields != []}
          id="item-form"
          phx-change="item"
          phx-submit="item"
          class="stage-fields"
        >
          <input type="hidden" name="item_id" value={@item.id} />
          <.field
            :for={param <- @fields}
            item={@item}
            param={param}
            value={@item.params[param.key]}
            error={@error == param.key}
            spot={MapSet.member?(@spots, param.key)}
          />
        </form>
        <button
          :if={@item.type in ~w(camper_van power_station) and @item.params["model"] != "other"}
          type="button"
          id="use-model"
          phx-click="use_model"
          phx-value-id={@item.id}
          class="stage-btn"
        >
          Use the numbers of the model
        </button>
        <p :if={station_source(@item)} id="station-source" class="stage-help">
          The numbers of the model: {station_source(@item)}
        </p>
        <p :if={own_station_numbers?(@item)} id="station-own" class="stage-help">
          Your numbers are not the numbers of the model. The key gives them.
        </p>
        <.usage :if={:usage in @kind.features} usage={@build.usage} ha_meter={@ha_meter} />
      </section>

      <p id="item-said" class="sr-only" role="status">{@said}</p>

      <Wires.section :if={:wires in @kind.features} build={@build} item={@item} error={@error} />

      <section id="part-where" class="stage-sec" aria-labelledby="part-where-title">
        <h3 id="part-where-title" class="stage-sec-title">Where it is</h3>
        <form :if={length(@rooms) > 1} id="move-form" phx-change="move_item" class="stage-field">
          <input type="hidden" name="item_id" value={@item.id} />
          <label for="item-room" class="stage-label">{if @in_van, do: "Zone", else: "Room"}</label>
          <select id="item-room" name="room" class="stage-input">
            <option :for={room <- @rooms} value={room.id} selected={room.id == @item.room}>
              {room.name}
            </option>
          </select>
        </form>
        <.place
          :if={@item.at}
          item={@item}
          room={@room}
          items={@build.items}
          bad={bad_sides(@error)}
        />
      </section>

      <section id="part-more" class="stage-sec" aria-labelledby="part-more-title">
        <h3 id="part-more-title" class="stage-sec-title">More</h3>
        <form :if={not @in_van} id="flags-form" phx-change="flag" class="stage-fields">
          <input type="hidden" name="item_id" value={@item.id} />
          <.switch name="planned" checked={@item.planned}>I do not have it yet: it is a plan</.switch>
          <.switch :if={station?(@build) and loads_power?(@item)} name="backup" checked={@item.backup}>
            A power station runs it (in an outage too)
          </.switch>
        </form>
        <p :if={@features != []} class="stage-help">
          <span class="font-semibold">The app uses it for:</span> {features(@features)}.
        </p>
        <button
          :if={@in_van and @item.type == "power_station" and @item.home}
          type="button"
          id="bring-home"
          phx-click="bring_home"
          phx-value-item={@item.id}
          class="stage-btn"
        >
          Bring it home
        </button>
        <div :if={not (@on_van_page and @item.id == @van.id)} id="item-remove" class="stage-remove">
          <button
            type="button"
            id="ask-remove"
            phx-click={
              JS.hide()
              |> JS.show(to: "#remove-confirm", display: "flex")
              |> JS.focus(to: "#keep-item")
            }
            class="stage-btn stage-danger"
          >
            Remove the item
          </button>
          <div
            id="remove-confirm"
            class="stage-confirm hidden"
            role="group"
            aria-labelledby="remove-text"
          >
            <p id="remove-text">
              {cond do
                @item.type == "smart_meter" and @build.usage ->
                  "Remove this item? With no smart meter, the real usage goes too."

                @in_van ->
                  "Remove this item from the van?"

                true ->
                  "Remove this item from the house?"
              end}
            </p>
            <button
              type="button"
              id="delete-item"
              phx-click="delete_item"
              phx-value-id={@item.id}
              class="stage-btn stage-danger"
            >
              Remove
            </button>
            <button
              type="button"
              id="keep-item"
              phx-click={
                JS.hide(to: "#remove-confirm")
                |> JS.show(to: "#ask-remove")
                |> JS.focus(to: "#ask-remove")
              }
              class="stage-btn"
            >
              Keep it
            </button>
          </div>
        </div>
      </section>
    </Stage.stage>
    """
  end

  attr :item, :map, required: true
  attr :param, :map, required: true
  attr :value, :any, required: true
  attr :error, :boolean, default: false
  attr :spot, :boolean, default: false, doc: "true when a tag on the model shows the number"

  # A parameter of an item in its panel. Each kind of value has the same
  # control on each item. A number has − and +, a field and its unit. A
  # choice is a row of buttons. Yes or no is a switch. A name is a field.
  # The ids start with "param-". A screen reader reads the unit, the help
  # and the error of the field with it (aria-describedby). At an end of the
  # range, − or + is dimmed for a screen reader (aria-disabled). It is not
  # disabled: it keeps the focus, and a tap says the end again.
  defp field(%{param: %{type: :bool}} = assigns) do
    ~H"""
    <div id={"param-#{@param.key}-field"} class="stage-field">
      <.switch
        name={"item[#{@param.key}]"}
        checked={@value}
        describedby={@param.note && "param-#{@param.key}-help"}
      >
        {@param.label}
      </.switch>
      <p :if={@param.note} id={"param-#{@param.key}-help"} class="stage-help">{@param.note}</p>
    </div>
    """
  end

  defp field(%{param: %{type: {:choice, values}}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <fieldset
      id={"param-#{@param.key}-field"}
      class="stage-field"
      aria-describedby={@param.note && "param-#{@param.key}-help"}
    >
      <legend class="stage-label">{@param.label}</legend>
      <div class="stage-choices">
        <label :for={{key, label} <- @values} class="stage-choice">
          <input type="radio" name={"item[#{@param.key}]"} value={key} checked={key == @value} />
          <span>{label}</span>
        </label>
      </div>
      <p :if={@param.note} id={"param-#{@param.key}-help"} class="stage-help">{@param.note}</p>
    </fieldset>
    """
  end

  defp field(%{param: %{type: :text}} = assigns) do
    ~H"""
    <div id={"param-#{@param.key}-field"} class="stage-field">
      <label for={"param-#{@param.key}"} class="stage-label">{@param.label}</label>
      <input
        id={"param-#{@param.key}"}
        name={"item[#{@param.key}]"}
        value={Format.value(@value)}
        type="text"
        phx-debounce="400"
        aria-invalid={@error && "true"}
        aria-describedby={@error && "param-#{@param.key}-error"}
        class="stage-input"
      />
      <p :if={@error} id={"param-#{@param.key}-error"} class="stage-error">Give a name.</p>
    </div>
    """
  end

  defp field(assigns) do
    key = assigns.param.key

    described =
      Enum.filter(
        [
          assigns.param.unit && "param-#{key}-unit",
          assigns.param.note && "param-#{key}-help",
          assigns.error && "param-#{key}-error"
        ],
        & &1
      )

    value = assigns.value

    assigns =
      assign(assigns,
        described: described != [] && Enum.join(described, " "),
        least: is_number(value) and value <= assigns.param.min,
        most: is_number(value) and value >= assigns.param.max
      )

    ~H"""
    <div id={"param-#{@param.key}-field"} class="stage-field">
      <label for={"param-#{@param.key}"} class="stage-label">{@param.label}</label>
      <div class="stage-stepper">
        <button
          type="button"
          class="stage-step"
          phx-click="step_param"
          phx-value-id={@item.id}
          phx-value-key={@param.key}
          phx-value-by="-1"
          aria-label={"Less: #{@param.label}"}
          aria-disabled={@least && "true"}
        >
          −
        </button>
        <input
          id={"param-#{@param.key}"}
          name={"item[#{@param.key}]"}
          value={Format.value(@value)}
          type="number"
          step={if @param.type == :float, do: "any", else: "1"}
          min={@param.min}
          max={@param.max}
          inputmode="decimal"
          phx-debounce="400"
          aria-invalid={@error && "true"}
          aria-describedby={@described}
          class="stage-input"
        />
        <span id={@param.unit && "param-#{@param.key}-unit"} class="stage-unit">{@param.unit}</span>
        <button
          type="button"
          class="stage-step"
          phx-click="step_param"
          phx-value-id={@item.id}
          phx-value-key={@param.key}
          phx-value-by="1"
          aria-label={"More: #{@param.label}"}
          aria-disabled={@most && "true"}
        >
          +
        </button>
      </div>
      <p :if={@error} id={"param-#{@param.key}-error"} class="stage-error">
        Give a number from {Format.value(@param.min)} to {Format.value(@param.max)}.
      </p>
      <p :if={@param.note || @spot} class="stage-help">
        <span :if={@param.note} id={"param-#{@param.key}-help"}>{@param.note}</span>
        <button
          :if={@spot}
          type="button"
          class="stage-link"
          data-show={@param.key}
          aria-label={"Show me where: #{@param.label}"}
        >
          Show me where
        </button>
      </p>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :checked, :boolean, default: false
  attr :describedby, :string, default: nil, doc: "the id of a help for the switch"
  slot :inner_block, required: true

  # Yes or no, as a switch: a checkbox with the role switch. The hidden
  # field sends false when the switch is off.
  defp switch(assigns) do
    ~H"""
    <label class="stage-switch-row">
      <span>{render_slot(@inner_block)}</span>
      <input type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        role="switch"
        name={@name}
        value="true"
        checked={@checked}
        aria-describedby={@describedby}
        class="stage-switch"
      />
    </label>
    """
  end

  attr :item, :map, required: true
  attr :room, :map, required: true, doc: "the room or the zone of the item"
  attr :items, :list, default: [], doc: "the items of the build: the item under the item"

  attr :bad, :list,
    default: [],
    doc: "the sides of the size that are not valid (\"w\", \"d\", \"h\")"

  @doc """
  The place of an item on the plan: buttons that move it, its place in
  words, its size and its turn. It is in the panel of each item
  (`item_stage/1`). Each side of the size has the control of a number:
  − and +, a field and its unit (`DIY.Catalog.stepped/3`). A change of a
  field applies at once.
  """
  def place(assigns) do
    {pw, pd} =
      if assigns.item.type == "solar_panels",
        do: Layout.array(assigns.item).panel,
        else: Layout.panel()

    one = Map.get(assigns.item.params, "panel_watts", Layout.panel_watts())

    assigns =
      assign(assigns,
        panel: "#{pw} by #{pd} inches for each panel of #{one} W",
        sides: size_fields(assigns.item),
        max: Layout.max_size()
      )

    ~H"""
    <div id="item-place" class="stage-fields">
      <p class="stage-label">Its place, its size and its turn</p>
      <%!-- "Turn it" is next to the arrows and over the map. After a tap,
      the page scrolls the map onto the screen if necessary ("diy:show"):
      the person sees the turn, also on a phone. --%>
      <div class="flex flex-wrap items-center gap-2">
        <.moves
          id="move-item"
          event="nudge_item"
          target={@item.id}
          step={6}
          what="the item"
          van={Build.van_level?(@room.level)}
        />
        <button
          type="button"
          id="turn-item"
          phx-click={
            JS.push("turn_item", value: %{id: @item.id})
            |> JS.dispatch("diy:show", to: "#item-map")
          }
          class="btn btn-sm"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Turn it
        </button>
      </div>
      <p id="item-where" class="stage-help" aria-live="polite">{where(@item, @room, @items)}</p>
      <.room_map item={@item} room={@room} items={@items} />
      <p :if={@item.type == "solar_panels"} class="stage-help">
        The watts give the size of the panels: {@panel}.
      </p>
      <p :if={@item.type == "camper_van"} class="stage-help">
        The model of the van gives its size, with its mirrors.
      </p>
      <form
        :if={@item.type not in ["solar_panels", "camper_van"]}
        id="size-form"
        phx-change="item_size"
        phx-submit="item_size"
        class="stage-fields"
      >
        <input type="hidden" name="item_id" value={@item.id} />
        <div :for={{key, label, value} <- @sides} id={"size-#{key}-field"} class="stage-field">
          <label for={"size-#{key}"} class="stage-label">{label}</label>
          <div class="stage-stepper">
            <button
              type="button"
              class="stage-step"
              phx-click="step_size"
              phx-value-id={@item.id}
              phx-value-side={key}
              phx-value-by="-1"
              aria-label={"Less: #{label}"}
              aria-disabled={value <= 1 && "true"}
            >
              −
            </button>
            <input
              id={"size-#{key}"}
              name={key}
              type="number"
              min="1"
              max={@max}
              step="1"
              inputmode="numeric"
              value={value}
              phx-debounce="400"
              aria-invalid={key in @bad && "true"}
              aria-describedby={"size-#{key}-unit#{if key in @bad, do: " size-error"}"}
              class="stage-input"
            />
            <span id={"size-#{key}-unit"} class="stage-unit">in</span>
            <button
              type="button"
              class="stage-step"
              phx-click="step_size"
              phx-value-id={@item.id}
              phx-value-side={key}
              phx-value-by="1"
              aria-label={"More: #{label}"}
              aria-disabled={value >= @max && "true"}
            >
              +
            </button>
          </div>
        </div>
        <p :if={@bad != []} id="size-error" class="stage-error">
          Give each side in inches, from 1 to {@max}.
        </p>
      </form>
      <%!-- The key of the typical size puts the focus here, not on a side:
        LiveView does not change the value of a field with the focus. --%>
      <p
        :if={@item.type not in ["solar_panels", "camper_van"]}
        id="size-help"
        tabindex="-1"
        class="stage-help"
      >
        {cond do
          @item.size ->
            "You gave this size."

          station_source(@item) ->
            "These are the sizes of the model. Change them only when your station has a different size, for example on a cart."

          true ->
            "These are the typical sizes of this kind of item. Give the sizes of your item."
        end}
      </p>
      <div :if={@item.size} class="flex flex-wrap gap-2">
        <button
          type="button"
          id="typical-size"
          phx-click={
            JS.push("item_size", value: %{item_id: @item.id, typical: "true"})
            |> JS.focus(to: "#size-help")
          }
          class="stage-btn"
        >
          {if station_source(@item), do: "The size of the model", else: "The typical size"}
        </button>
      </div>
    </div>
    """
  end

  # The icon of each button. The names are whole, so that the CSS build
  # finds them in the code.
  @arrows %{
    "left" => "hero-arrow-left",
    "up" => "hero-arrow-up",
    "down" => "hero-arrow-down",
    "right" => "hero-arrow-right"
  }

  attr :id, :string, required: true
  attr :event, :string, required: true, doc: "nudge_item or nudge_room"
  attr :target, :string, required: true, doc: "the id of the item or of the room"
  attr :step, :integer, required: true, doc: "inches for each tap"
  attr :what, :string, required: true
  attr :van, :boolean, default: false, doc: "true in a van: the words of a van"
  attr :blocked, :list, default: [], doc: "the buttons (left, up, down, right) that cannot move"

  @doc """
  Four buttons that move an item or a room: for a person who does not
  drag (WCAG 2.2, 2.5.7). Each arrow points as the move goes on the
  screen (`DIYWeb.Camera.arrows/1`). In the house, the Up arrow moves it to
  the back. In a van, the Left arrow moves it to the front (the cab), and
  the Up arrow to the right side of the van. A button that cannot move
  looks disabled (`aria-disabled`), but it keeps the focus of the
  keyboard. The server refuses its move, and the page says why.
  """
  def moves(assigns) do
    camera = if assigns.van, do: Camera.van(), else: Camera.house()

    assigns =
      assign(assigns,
        buttons:
          for {key, dx, dy} <- steps(camera, assigns.step) do
            {key, dx, dy, Map.fetch!(@arrows, key), direction(dx, dy, assigns.van)}
          end
      )

    ~H"""
    <div id={@id} class="flex items-center gap-1" role="group" aria-label={"Move #{@what}"}>
      <span class="text-xs mr-1">Move {@what}:</span>
      <button
        :for={{key, dx, dy, icon, text} <- @buttons}
        type="button"
        id={"#{@id}-#{key}"}
        phx-click={@event}
        phx-value-id={@target}
        phx-value-dx={dx}
        phx-value-dy={dy}
        aria-disabled={key in @blocked && "true"}
        class={["btn btn-sm btn-square", key in @blocked && "opacity-40"]}
        aria-label={"Move #{@what} #{feet(@step)} #{text}"}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    <p :if={length(@blocked) == 4} id={"#{@id}-full"} class="text-xs opacity-70">
      No free place is next to it. Make it smaller first (Change).
    </p>
    """
  end

  attr :item, :map, required: true
  attr :room, :map, required: true, doc: "the room or the zone of the item, with its plan"
  attr :items, :list, default: [], doc: "the items of the build"

  @doc """
  A small map of the room from above, in the sheet of an item. The item
  has the color of the app, and a thick line on its front. The other items
  of the room are gray: an item on a wall or a ceiling has a dashed line.
  The map has the axes of the move buttons (`moves/1`): the Up arrow moves
  the item up on the map. So a turn, a move and a new size show
  immediately, also when the plan is behind the sheet. Under the map, a
  text gives the space of the item on the plan. Another text tells when
  the item is larger than its room, and if a turn can help. The text above the map gives its place in words, so the map
  has no text for a screen reader.
  """
  def room_map(assigns) do
    %{item: item, room: room} = assigns
    camera = if Build.van_level?(room.level), do: Camera.van(), else: Camera.house()
    {{rx, ry}, {dx, dy}} = Camera.arrows(camera)
    box = Layout.item_box(item)

    others =
      for o <- assigns.items, o.room == room.id, o.id != item.id, o.at != nil do
        {Layout.item_box(o), Catalog.lift(o.type) > 0}
      end

    # The box of the map on the screen: the room and the item (an item can
    # be larger than its room).
    points =
      for {x, y} <- [
            {0, 0},
            {room.plan.w, room.plan.d},
            {box.x, box.y},
            {box.x + box.w, box.y + box.d}
          ],
          do: {rx * x + ry * y, dx * x + dy * y}

    {xs, ys} = Enum.unzip(points)
    pad = 6
    {x0, y0} = {Enum.min(xs) - pad, Enum.min(ys) - pad}
    {w, d} = Layout.extent(item)

    assigns =
      assign(assigns,
        view: "#{x0} #{y0} #{Enum.max(xs) + pad - x0} #{Enum.max(ys) + pad - y0}",
        matrix: "matrix(#{rx} #{dx} #{ry} #{dy} 0 0)",
        box: box,
        others: others,
        front: front(box, item.turn),
        space: "#{feet(w)} by #{feet(d)}",
        room_space: "#{feet(room.plan.w)} by #{feet(room.plan.d)}",
        larger: w > room.plan.w or d > room.plan.d,
        turn_fits: d <= room.plan.w and w <= room.plan.d
      )

    ~H"""
    <svg id="item-map" class="stage-map" viewBox={@view} aria-hidden="true">
      <g transform={@matrix}>
        <rect class="stage-map-room" x="0" y="0" width={@room.plan.w} height={@room.plan.d} />
        <rect
          :for={{o, up} <- @others}
          class={["stage-map-other", up && "is-up"]}
          x={o.x}
          y={o.y}
          width={o.w}
          height={o.d}
        />
        <rect
          id="item-map-item"
          class="stage-map-item"
          x={@box.x}
          y={@box.y}
          width={@box.w}
          height={@box.d}
        />
        <line
          id="item-map-front"
          class="stage-map-front"
          x1={elem(@front, 0)}
          y1={elem(@front, 1)}
          x2={elem(@front, 2)}
          y2={elem(@front, 3)}
        />
      </g>
    </svg>
    <p id="item-space" class="stage-help">Its space on the plan: {@space}.</p>
    <%!-- The live region is always there: a screen reader reads a new
    text in it. --%>
    <div id="item-larger-live" aria-live="polite">
      <p :if={@larger} id="item-larger" class="stage-help">
        It is larger than {@room.name} ({@room_space}): it goes through a wall. {if @turn_fits,
          do: "Make it smaller, or turn it.",
          else: "Make it smaller."}
      </p>
    </div>
    """
  end

  # The front side of an item on the map: `{x1, y1, x2, y2}`. With no turn,
  # the front is at the large y. A quarter turn takes the front to the
  # large x (`DIYWeb.Icon.Shapes`), then to the small y, then to the small
  # x.
  defp front(%{x: x, y: y, w: w, d: d}, turn) do
    case rem(turn, 4) do
      0 -> {x, y + d, x + w, y + d}
      1 -> {x + w, y, x + w, y + d}
      2 -> {x, y, x + w, y}
      3 -> {x, y, x, y + d}
    end
  end

  # The move of each button on the plan (inches): left, up, down and right
  # on the screen of a camera.
  defp steps(camera, step) do
    {{rx, ry}, {dx, dy}} = Camera.arrows(camera)

    [
      {"left", -rx * step, -ry * step},
      {"up", -dx * step, -dy * step},
      {"down", dx * step, dy * step},
      {"right", rx * step, ry * step}
    ]
  end

  # The words of a move of a room in the house, or of a zone or an item in
  # a van. In a van, the right side is at x = 0.
  defp direction(dx, _dy, van) when dx != 0 do
    case {dx < 0, van} do
      {true, true} -> "to the right side"
      {false, true} -> "to the left side"
      {true, false} -> "to the left"
      {false, false} -> "to the right"
    end
  end

  defp direction(_dx, dy, _van) when dy < 0, do: "to the back"
  defp direction(_dx, _dy, _van), do: "to the front"

  @doc """
  The move buttons (`moves/1`) that cannot move a room or a zone by a step.
  A zone is in a van (`van`): its buttons follow the camera of a van.
  """
  def blocked(build, id, step, van \\ false) do
    camera = if van, do: Camera.van(), else: Camera.house()

    for {key, dx, dy} <- steps(camera, step),
        not Build.can_move?(build, id, dx, dy),
        do: key
  end

  # The fields of the size of an item: its width, its depth and its height.
  defp size_fields(item) do
    {w, d, h} = Layout.size(item)
    [{"w", "Width", w}, {"d", "Depth", d}, {"h", "Height", h}]
  end

  # The sides of the size that are not valid, from the error of the item
  # ("size:w,h").
  defp bad_sides("size:" <> sides), do: String.split(sides, ",", trim: true)
  defp bad_sides(_error), do: []

  # An item of the house (not of a van): its panel is on the page Rooms.
  defp house_item(build, id) do
    with {:ok, item} <- Build.item(build, id),
         {:ok, room} <- Build.room(build, item.room),
         false <- Build.van_level?(room.level),
         do: {:ok, item},
         else: (_other -> {:error, :item})
  end

  @doc """
  The status after a new model of a van or of a station, or after "Use
  the numbers of the model". It tells the new numbers, or that the
  numbers stay.
  """
  def model_said(%{type: "camper_van", params: %{"model" => "other"}}),
    do: "Another van. The numbers stay."

  def model_said(%{type: "camper_van", params: %{"model" => model}}) do
    {_key, name, _numbers, _source} = List.keyfind(Catalog.van_models(), model, 0)
    "#{name}: the numbers of the model are in the fields."
  end

  def model_said(%{type: "power_station", params: %{"model" => "other"}}),
    do: "Another station. The numbers stay."

  def model_said(%{type: "power_station", params: params} = station) do
    {_key, name, numbers, {w, d, h}, _source} =
      List.keyfind(Catalog.station_models(), params["model"], 0)

    if Map.take(params, Map.keys(numbers)) == numbers do
      size = if station.size, do: "", else: " Its size: #{w} by #{d} by #{h} in."

      "#{name}: #{Format.value(numbers["kwh"])} kWh, #{Format.int(numbers["output_w"])} W, " <>
        "a charge of #{Format.int(numbers["charge_w"])} W, " <>
        "#{Format.int(numbers["solar_w"])} W of solar input, #{numbers["weight"]} lb.#{size}"
    else
      "#{name}. Your numbers stay. The key Use the numbers of the model gives its numbers."
    end
  end

  # The source of the numbers of a model of power station, or nil for a
  # different item and for another station.
  defp station_source(%{type: "power_station", params: %{"model" => model}}) do
    with {_key, _name, _numbers, _size, source} <-
           List.keyfind(Catalog.station_models(), model, 0),
         do: source
  end

  defp station_source(_item), do: nil

  # True when a station of a model has numbers that are not the numbers of
  # the model.
  defp own_station_numbers?(%{type: "power_station", params: %{"model" => model} = params})
       when model != "other" do
    {_key, _name, numbers, _size, _source} = List.keyfind(Catalog.station_models(), model, 0)
    Map.take(params, Map.keys(numbers)) != numbers
  end

  defp own_station_numbers?(_item), do: false

  # True when the house has a power station (a planned one too).
  defp station?(build), do: Enum.any?(build.items, &(&1.type == "power_station"))

  # An item that burns natural gas.
  defp gas_item?(%{type: "furnace"}), do: true
  defp gas_item?(%{params: params}), do: params["fuel"] == "gas"

  # The items that a station can run: the items that use power.
  defp loads_power?(%{type: type}), do: type not in DIY.Estimate.no_use()

  # A month that shows the work of an item: January for heat, July else.
  defp math_month(%{type: type}) when type in ["furnace", "heat_strips", "space_heater"], do: 1
  defp math_month(_item), do: 7

  # The level of the room of an item, for a floor or the roof. A room
  # around the house (a garage, a yard) needs no level.
  defp level_note("outside"), do: ""
  defp level_note(level), do: " (#{Build.level_name(level)})"

  defp season(1), do: ", a cold month"
  defp season(7), do: ", a hot month"

  # A parameter shows when it is for the item: the weight only in a van,
  # and the heat efficiency only for a unit that heats.
  defp shown?(%{key: "weight"}, _item, van), do: van
  defp shown?(%{key: "hspf2"}, item, _van), do: item.params["heat_pump"] == true

  defp shown?(%{key: "watts"}, %{type: "pool_heater"} = item, _van),
    do: item.params["fuel"] != "gas"

  defp shown?(%{key: "kbtu"}, %{type: "pool_heater"} = item, _van),
    do: item.params["fuel"] == "gas"

  defp shown?(_param, _item, _van), do: true

  defp month_name(month), do: Enum.at(Estimate.month_names(), month - 1)

  @doc "Features of a kind of item, in words."
  def features(features), do: Enum.map_join(features, ", ", &feature/1)

  defp feature(:estimate), do: "the estimate of your power bill"
  defp feature(:gas), do: "the estimate of your gas bill"
  defp feature(:backup), do: "the hours of backup in an outage"
  defp feature(:shift), do: "the charge at night"
  defp feature(:power_view), do: "the view of what feeds what, and the permit notes"
  defp feature(:solar), do: "the power of the sun"
  defp feature(:ev), do: "the cost of the home charge next to gas"

  defp feature(:usage),
    do: "your real usage, from the file of the meter or from Home Assistant"

  defp feature(:van), do: "the build of the van: its zones, its weight and its power"
  defp feature(:weight), do: "the weight budget of the van"
  defp feature(:van_power), do: "the power budget of the van"
  defp feature(:safety), do: "the safety notes of the van"
  defp feature(:wires), do: "the checks of its wires (NEC)"

  attr :usage, :map, default: nil
  attr :ha_meter, :map, default: nil

  # The file of a meter. The browser reads it (the hook UsageFile), and
  # sends only the sum of each month. Home Assistant can also give the
  # months of the meter.
  defp usage(assigns) do
    ~H"""
    <div id="usage" class="space-y-2 rounded-box bg-base-200 p-3">
      <h3 id="usage-title" class="font-semibold" tabindex="-1">Your real usage</h3>
      <div :if={@ha_meter} id="ha-meter" class="space-y-2">
        <p class="text-sm">
          Home Assistant has {Format.count(length(@ha_meter.months), "month")} of usage from this meter, from {Format.month(
            hd(@ha_meter.months).month
          )} to {Format.month(List.last(@ha_meter.months).month)}.
        </p>
        <%!-- The button goes away after the tap: the focus goes to the
          title of the usage, and the flash tells the result. --%>
        <button
          type="button"
          id="use-ha-meter"
          phx-click={JS.push("ha_use_meter") |> JS.focus(to: "#usage-title")}
          class="stage-btn"
        >
          Use Home Assistant
        </button>
      </div>
      <p :if={@usage} id="usage-months" class="text-sm">
        {DIY.Usage.source_name(@usage.source)}: {Format.count(length(@usage.months), "month")}, from {Format.month(
          hd(@usage.months).month
        )} to {Format.month(List.last(@usage.months).month)}.
        <button type="button" phx-click="clear_usage" class="link">Remove the real usage</button>
      </p>
      <label class="block text-sm">
        <span class="font-semibold">Open the file of your meter</span>
        <input
          id="usage-file"
          type="file"
          accept=".csv,.xml,text/csv,application/xml,text/xml"
          phx-hook="UsageFile"
          class="file-input file-input-sm block w-full"
        />
      </label>
      <p class="text-xs opacity-80">
        The file stays on this device. The browser reads it. It sends only three numbers for each month: the kWh from the grid, the kWh to the grid, and the days with data.
      </p>
      <details class="text-xs">
        <summary class="cursor-pointer">How to get the file</summary>
        <ul class="list-disc pl-5 space-y-1 pt-1">
          <li>
            Texas: log in at smartmetertexas.com. Open "Energy Data 15 Min Interval". Choose the last 12 months. Export the CSV.
          </li>
          <li>
            Other states: on the site of your utility, find "Green Button" or "Download My Data". Save the file. A .zip file has the file in it: open the .zip file first.
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :room, :map, required: true
  attr :query, :string, default: ""

  # The kinds of items that can go in a room, with a search. With a text,
  # the kinds that match but go in a different place show too, with where
  # they go.
  defp add_sheet(assigns) do
    fits = Catalog.kinds_for_room(assigns.room)

    search? = String.trim(assigns.query) != ""
    others = if search?, do: Enum.reject(Catalog.search(assigns.query), &(&1 in fits)), else: []
    matched = Catalog.search(assigns.query, fits)

    # "Other" takes any name and power: it always shows.
    other = Enum.filter(fits, &(&1.type == "other" and &1 not in matched))

    assigns =
      assign(assigns,
        kinds: matched ++ other,
        others: others,
        none: search? and matched == [] and others == [],
        count: if(search?, do: count_text(length(matched), length(others)))
      )

    ~H"""
    <.sheet id="add-sheet" title={"Add to #{@room.name}"}>
      <form id="add-search" phx-change="add_search" phx-submit="add_search" role="search">
        <label class="input input-sm w-full">
          <.icon name="hero-magnifying-glass" class="size-4 opacity-70" />
          <input
            type="search"
            name="q"
            value={@query}
            placeholder="Search: Tesla, pool, fridge"
            aria-label="Search the items"
            autocomplete="off"
            phx-debounce="200"
          />
        </label>
      </form>
      <ul class="grid grid-cols-2 gap-2">
        <li :for={kind <- @kinds}>
          <button
            type="button"
            id={"add-#{kind.type}"}
            phx-click="add_item"
            phx-value-room={@room.id}
            phx-value-type={kind.type}
            class="btn btn-block justify-start h-auto py-2 text-left"
          >
            <Icon.item type={kind.type} class="size-8" /> {kind.name}
          </button>
        </li>
      </ul>
      <p :if={@none} id="add-none" class="text-sm opacity-70">
        No item has this name. Use "Other": it takes any name and power.
      </p>
      <p id="add-count" role="status" class="sr-only">{@count}</p>
      <div :if={@others != []} id="add-elsewhere" class="space-y-1">
        <h3 class="text-sm font-semibold">Not for this room</h3>
        <ul class="space-y-1 text-sm">
          <li :for={kind <- @others} id={"elsewhere-#{kind.type}"} class="flex items-center gap-2">
            <Icon.item type={kind.type} class="size-6" />
            <span>{kind.name}: in {Catalog.where(kind)}.</span>
          </li>
        </ul>
      </div>
    </.sheet>
    """
  end

  # The count of the search, for a screen reader.
  defp count_text(found, 1), do: "#{found} found. 1 goes in a different place."
  defp count_text(found, others), do: "#{found} found. #{others} go in a different place."

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :close, :string, default: "/inside", doc: "the page of the close link"
  slot :inner_block, required: true

  @doc """
  A sheet over the page. The close link goes back to the page under it.
  The hook Sheet closes it with the Escape key, and keeps the focus in it.
  """
  def sheet(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Sheet"
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40"
    >
      <.link patch={@close} class="absolute inset-0" aria-label="Close" tabindex="-1"></.link>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        class="relative card bg-base-100 w-full max-w-xl max-h-[85dvh] overflow-y-auto p-4 space-y-3"
        phx-mounted={JS.focus_first()}
      >
        <div class="flex items-center justify-between">
          <h2 id={"#{@id}-title"} class="text-lg font-bold">{@title}</h2>
          <.link patch={@close} class="btn btn-sm btn-ghost" aria-label="Close" data-close>
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
