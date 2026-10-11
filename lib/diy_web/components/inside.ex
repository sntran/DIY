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

  alias DIY.{Build, Catalog, Estimate, Layout, Prices, Solar}
  alias DIYWeb.{Camera, Cutaway, Format, HomeAssistant, Icon, Stage}

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
  attr :room, :string, default: nil, doc: "the room that the person chose"

  attr :sheet, :string,
    default: nil,
    doc: "\"room\" (change the room), \"new_room\" or \"ha_rooms\" (`DIYWeb.HomeAssistant`)"

  attr :item_error, :string, default: nil
  attr :item_said, :string, default: nil, doc: "the new value after − or +, for a screen reader"

  attr :item_frames, :map,
    default: nil,
    doc: "the frames of the open item (`DIYWeb.Stage.frames/1`)"

  attr :status, :string, default: nil, doc: "a text for a screen reader after a move"
  attr :away, :list, default: [], doc: "the stations of the house in a van: {item, van}"
  attr :ha, :map, required: true, doc: "the link to Home Assistant (`DIYWeb.HomeAssistant`)"
  attr :ha_rooms, :map, default: nil, doc: "the floors and the areas of Home Assistant"
  attr :ha_sync, :map, default: nil, doc: "what the last match of the rooms did"

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
          assigns.ha.error in ~w(state denied token unreachable signed_out) and not hub_open
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
        />
        <p id="plan-status" class="sr-only" aria-live="polite">{@status}</p>
      </div>

      <.item_stage
        :if={@item && @item_frames && match?({:ok, _}, Build.item(@build, @item))}
        frames={@item_frames}
        close={if @chosen, do: ~p"/inside?#{[room: @chosen.id]}", else: ~p"/inside"}
        build={@build}
        item={elem(Build.item(@build, @item), 1)}
        estimate={@estimate}
        price={@price}
        error={@item_error}
        said={@item_said}
        outage={@outage}
        ha={@ha}
      />
      <.add_sheet
        :if={@add && match?({:ok, _}, Build.room(@build, @add))}
        room={elem(Build.room(@build, @add), 1)}
      />
      <.room_sheet :if={@chosen && @sheet == "room"} room={@chosen} />
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
  key goes to its right side, and the Right key to its back.
  """
  def where(item, %{level: "van:" <> _} = zone),
    do:
      "#{feet(item.at.x)} from the right side of #{zone.name}, #{feet(item.at.y)} from its back."

  def where(item, room),
    do:
      "#{feet(item.at.x)} from the left wall of #{room.name}, #{feet(item.at.y)} from the back wall."

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
                  {Catalog.name(item)}{item_note(item, @estimate, @price, @gas)}
                </.link>
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

  # The usage, the cost and the flags of an item, as a text. The cost of a
  # gas item has its gas.
  defp item_note(item, estimate, price, gas) do
    usage =
      if estimate.ready and item.type not in Estimate.no_use() do
        %{year: kwh, therms: therms} = estimate.items[item.id]
        gas_text = if therms / 12 >= 0.5, do: " and #{Format.therms(therms / 12)}", else: ""
        cost = Format.cost(kwh / 12, price.cents) + therms / 12 * gas.dollars
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

  attr :room, :map, required: true

  # The sheet of a room: its name, its size, and its removal.
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
  attr :error, :string, default: nil
  attr :said, :string, default: nil, doc: "the new value after − or +, for a screen reader"
  attr :outage, :string, default: nil
  attr :close, :string, default: "/inside", doc: "the page of the close link"
  attr :ha, :map, required: true
  attr :frames, :map, required: true, doc: "the frames of its kind (`DIYWeb.Stage.frames/1`)"

  # An item in front of the person (DIYWeb.Stage). Its panel is the same
  # for each item. Its parts are in this order: what it costs, the link of
  # a hub to Home Assistant, its use, its place, and more.
  # Each part has a heading, and the panel scrolls: no part is out of sight.
  defp item_stage(assigns) do
    kind = Catalog.kind(assigns.item.type)
    {:ok, room} = Build.room(assigns.build, assigns.item.room)
    rooms = Enum.filter(assigns.build.rooms, &(&1.place in kind.places))
    van = Enum.any?(assigns.build.items, &(&1.type == "camper_van"))
    features = if van, do: kind.features, else: kind.features -- @van_features
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
        van: van,
        features: features,
        fields: Enum.filter(kind.params, &shown?(&1, assigns.item, van)),
        spots: MapSet.new(assigns.frames.spots, & &1.key),
        gas: Prices.gas(assigns.build),
        solar: solar,
        name: Catalog.name(assigns.item)
      )

    ~H"""
    <Stage.stage
      type={@item.type}
      frames={@frames}
      item={@item.id}
      title={@name}
      note={"In #{@room.name}#{level_note(@room.level)}"}
      close={@close}
    >
      <:screen :if={@item.type == "home_assistant"}>
        <HomeAssistant.screen ha={@ha} back={~p"/inside?#{[item: @item.id]}"} />
      </:screen>

      <section
        :if={@estimate.ready}
        id="part-cost"
        class="stage-cost"
        aria-labelledby="part-cost-title"
      >
        <h3 id="part-cost-title" class="sr-only">
          {if @item.type in @no_use, do: "Its energy", else: "What it costs"}
        </h3>
        <p :if={@item.type in @no_use} id="item-math" class="stage-help">
          {hd(Estimate.explain(@item, 7, @estimate))}
        </p>
        <%= if @item.type not in @no_use do %>
          <p class="stage-month">
            {Format.dollars(Format.cost(@estimate.items[@item.id].year / 12, @price.cents))} a month
          </p>
          <p id="item-year" class="stage-year">
            {Format.kwh(@estimate.items[@item.id].year)} and {Format.money(
              Format.cost(@estimate.items[@item.id].year, @price.cents)
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
          {if @item.type == "camper_van",
            do: "These numbers are typical of the model. Check them on the label in the door frame.",
            else: "These numbers are a guess for a house like yours. Check them on the item."}
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

      <details :if={@estimate.ready and @item.type not in @no_use} id="part-how" class="stage-how">
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
        <HomeAssistant.card
          ha={@ha}
          back={~p"/inside?#{[item: @item.id]}"}
          title={false}
          form={false}
        />
      </section>

      <section
        :if={@fields != [] or :usage in @kind.features or :van in @kind.features}
        id="part-use"
        class="stage-sec"
        aria-labelledby="part-use-title"
      >
        <h3 id="part-use-title" class="stage-sec-title">How you use it</h3>
        <.link
          :if={:van in @kind.features}
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
        <p :if={@fields != []} id="item-said" class="sr-only" role="status">{@said}</p>
        <.usage :if={:usage in @kind.features} usage={@build.usage} />
      </section>

      <section id="part-where" class="stage-sec" aria-labelledby="part-where-title">
        <h3 id="part-where-title" class="stage-sec-title">Where it is</h3>
        <form :if={length(@rooms) > 1} id="move-form" phx-change="move_item" class="stage-field">
          <input type="hidden" name="item_id" value={@item.id} />
          <label for="item-room" class="stage-label">Room</label>
          <select id="item-room" name="room" class="stage-input">
            <option :for={room <- @rooms} value={room.id} selected={room.id == @item.room}>
              {room.name}
            </option>
          </select>
        </form>
        <.place :if={@item.at} item={@item} room={@room} />
      </section>

      <section id="part-more" class="stage-sec" aria-labelledby="part-more-title">
        <h3 id="part-more-title" class="stage-sec-title">More</h3>
        <form id="flags-form" phx-change="flag" class="stage-fields">
          <input type="hidden" name="item_id" value={@item.id} />
          <.switch name="planned" checked={@item.planned}>I do not have it yet: it is a plan</.switch>
          <.switch :if={station?(@build) and loads_power?(@item)} name="backup" checked={@item.backup}>
            A power station runs it (in an outage too)
          </.switch>
        </form>
        <p class="stage-help">
          <span class="font-semibold">The app uses it for:</span> {features(@features)}.
        </p>
        <div id="item-remove" class="stage-remove">
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
              {if @item.type == "smart_meter" and @build.usage,
                do: "Remove this item? With no smart meter, the real usage goes too.",
                else: "Remove this item from the house?"}
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

  @doc """
  The place of an item on the plan: buttons that move it, its place in
  words, its size and its turn. It is on the panel of an item of the house
  (`DIYWeb.Stage`), and in the sheet of an item of a van.
  """
  def place(assigns) do
    {pw, pd} = Layout.panel()
    assigns = assign(assigns, :panel, "#{pw} by #{pd}")

    ~H"""
    <div id="item-place" class="space-y-2 rounded-box bg-base-200 p-3">
      <p class="text-sm font-semibold">Its place, its size and its turn</p>
      <.moves
        id="move-item"
        event="nudge_item"
        target={@item.id}
        step={6}
        what="the item"
        van={Build.van_level?(@room.level)}
      />
      <p id="item-where" class="text-sm" aria-live="polite">{where(@item, @room)}</p>
      <p :if={@item.type == "solar_panels"} class="text-xs opacity-70">
        The watts give the size of the panels on the roof: {@panel} inches for each panel of 400 W.
      </p>
      <p :if={@item.type == "camper_van"} class="text-xs opacity-70">
        The model of the van gives its size, with its mirrors.
      </p>
      <form
        :if={@item.type not in ["solar_panels", "camper_van"]}
        id="size-form"
        phx-submit="item_size"
        class="flex flex-wrap items-end gap-2"
      >
        <input type="hidden" name="item_id" value={@item.id} />
        <label :for={{key, label, value} <- size_fields(@item)}>
          <span class="block text-xs">{label}</span>
          <input
            name={key}
            type="number"
            min="1"
            max={Layout.max_size()}
            step="1"
            inputmode="numeric"
            value={value}
            class="input input-sm w-20"
          />
        </label>
        <button class="btn btn-sm">Set the size</button>
      </form>
      <p :if={@item.type not in ["solar_panels", "camper_van"]} class="text-xs opacity-70">
        In inches.{if @item.size,
          do: " You gave this size.",
          else: " These are the typical sizes of this kind of item. Give the sizes of your item."}
      </p>
      <div class="flex gap-2">
        <button
          type="button"
          id="turn-item"
          phx-click="turn_item"
          phx-value-id={@item.id}
          class="btn btn-sm"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Turn it
        </button>
        <button
          :if={@item.size}
          type="button"
          id="typical-size"
          phx-click="item_size"
          phx-value-item_id={@item.id}
          phx-value-typical="true"
          class="btn btn-sm btn-ghost"
        >
          The typical size
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

  # True when the house has a power station (a planned one too).
  defp station?(build), do: Enum.any?(build.items, &(&1.type == "power_station"))

  # An item that burns natural gas.
  defp gas_item?(%{type: "furnace"}), do: true
  defp gas_item?(%{params: params}), do: params["fuel"] == "gas"

  # The items that a station can run: the items that use power.
  defp loads_power?(%{type: type}),
    do: type not in ~w(power_station solar_panels transfer_switch smart_meter camper_van)

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
  defp feature(:usage), do: "your real usage, from the file of the meter"
  defp feature(:van), do: "the build of the van: its zones, its weight and its power"
  defp feature(:weight), do: "the weight budget of the van"
  defp feature(:van_power), do: "the power budget of the van"
  defp feature(:safety), do: "the safety notes of the van"

  attr :usage, :map, default: nil

  # The file of a meter. The browser reads it (the hook UsageFile), and
  # sends only the sum of each month.
  defp usage(assigns) do
    ~H"""
    <div id="usage" class="space-y-2 rounded-box bg-base-200 p-3">
      <h3 class="font-semibold">Your real usage</h3>
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

  attr :param, :map, required: true
  attr :value, :any, required: true
  attr :error, :boolean, default: false

  @doc "The input of a parameter of an item (`DIY.Catalog`)."
  def param(%{param: %{type: :bool}} = assigns) do
    ~H"""
    <label class="flex items-center gap-2">
      <input type="hidden" name={"item[#{@param.key}]"} value="false" />
      <input
        type="checkbox"
        name={"item[#{@param.key}]"}
        value="true"
        checked={@value}
        class="checkbox checkbox-sm"
      />
      <span>{@param.label}</span>
    </label>
    """
  end

  def param(%{param: %{type: {:choice, values}}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <label class="block">
      <span class="text-sm font-semibold">{@param.label}</span>
      <select name={"item[#{@param.key}]"} class="select select-sm w-full">
        <option :for={{key, label} <- @values} value={key} selected={key == @value}>{label}</option>
      </select>
      <span :if={@param.note} class="block text-xs opacity-70">{@param.note}</span>
    </label>
    """
  end

  def param(assigns) do
    ~H"""
    <label class="block">
      <span class="text-sm font-semibold">{@param.label}{if @param.unit, do: " (#{@param.unit})"}</span>
      <input
        name={"item[#{@param.key}]"}
        value={Format.value(@value)}
        type={if @param.type == :text, do: "text", else: "number"}
        step={if @param.type == :float, do: "any", else: "1"}
        min={@param[:min]}
        max={@param[:max]}
        inputmode={if @param.type == :text, do: "text", else: "decimal"}
        phx-debounce="400"
        class={["input input-sm w-full", @error && "input-error"]}
      />
      <span :if={@error} class="text-xs text-error">
        {if @param.type == :text,
          do: "Give a name.",
          else: "Give a number from #{Format.value(@param.min)} to #{Format.value(@param.max)}."}
      </span>
      <span :if={@param.note} class="block text-xs opacity-70">{@param.note}</span>
    </label>
    """
  end

  attr :room, :map, required: true

  # The kinds of items that can go in a room.
  defp add_sheet(assigns) do
    assigns = assign(assigns, :kinds, Catalog.kinds_for(assigns.room.place))

    ~H"""
    <.sheet id="add-sheet" title={"Add to #{@room.name}"}>
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
    </.sheet>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: nil, doc: "the kind of an item, for its icon"
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
          <h2 id={"#{@id}-title"} class="flex items-center gap-2 text-lg font-bold">
            <Icon.item :if={@icon} type={@icon} class="size-8" />{@title}
          </h2>
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
