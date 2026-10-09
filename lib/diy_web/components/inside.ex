defmodule DIYWeb.Inside do
  @moduledoc """
  The inside of the house: the plan at scale (`DIYWeb.Cutaway`). The house
  is cut open: each floor is a layer, from the ground up to the roof. Each
  item stands at its place in its room. The person drags an item to move
  it, also to a different room. A tap on an item opens it, and a tap on a
  room chooses it. A chosen room has handles on its walls, and a bar with
  its size and its buttons. The hook Plan (`assets/js/plan.js`) does the
  drag and the zoom. The sheets have buttons that move an item or a room
  with no drag.

  The plan is for the eyes. A list of the rooms and their items gives the
  same facts to a screen reader and to a keyboard. It shows when it has
  the focus. In the list, the arrow keys move an item or a room.
  """
  use DIYWeb, :html

  alias DIY.{Build, Catalog, Estimate, Layout}
  alias DIYWeb.{Camera, Cutaway, Format, Icon}

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
  attr :sheet, :string, default: nil, doc: "\"room\" (change the room) or \"new_room\""
  attr :item_error, :string, default: nil
  attr :status, :string, default: nil, doc: "a text for a screen reader after a move"
  attr :away, :list, default: [], doc: "the stations of the house in a van: {item, van}"

  def inside(assigns) do
    room =
      case assigns.room && Build.room(assigns.build, assigns.room) do
        {:ok, room} -> room
        _none -> nil
      end

    assigns = assign(assigns, chosen: room, levels: Build.levels(assigns.build.house.floors))

    ~H"""
    <section id="inside" class="space-y-2">
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
            class="btn btn-sm btn-ghost shrink-0 px-2"
          >
            {level.name}
          </button>
        </div>

        <%!-- With a chosen room, the plan is shorter: its bar shows under it. --%>
        <div class={[
          "relative overflow-hidden rounded-box border border-base-300",
          if(@chosen, do: "h-[calc(100dvh-22rem)]", else: "h-[calc(100dvh-14rem)]")
        ]}>
          <Cutaway.cutaway view={@view} selected={@chosen && @chosen.id} />
          <.zoom all="Show all the house" />
          <.link
            :if={!@chosen}
            patch={~p"/inside?#{[sheet: "new_room"]}"}
            id="add-room"
            class="btn btn-sm btn-primary absolute bottom-2 right-2"
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
        />
        <p id="plan-status" class="sr-only" aria-live="polite">{@status}</p>
      </div>

      <.item_sheet
        :if={@item && match?({:ok, _}, Build.item(@build, @item))}
        build={@build}
        item={elem(Build.item(@build, @item), 1)}
        estimate={@estimate}
        price={@price}
        error={@item_error}
      />
      <.add_sheet
        :if={@add && match?({:ok, _}, Build.room(@build, @add))}
        room={elem(Build.room(@build, @add), 1)}
      />
      <.room_sheet :if={@chosen && @sheet == "room"} room={@chosen} />
      <.new_room_sheet :if={@sheet == "new_room"} levels={@levels} />
    </section>
    """
  end

  attr :all, :string, required: true, doc: "the label of the button that shows all the plan"

  @doc "The buttons of the zoom of a plan, at its top right (the hook Plan)."
  def zoom(assigns) do
    ~H"""
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

  # The bar of the chosen room: its name, its size, and its buttons.
  defp room_bar(assigns) do
    ~H"""
    <div id="room-bar" class="card card-border bg-base-100 p-3 gap-2">
      <div class="flex items-center gap-2">
        <div class="grow min-w-0">
          <p class="font-semibold truncate">{@room.name}</p>
          <p class="text-xs opacity-70">
            {Build.level_name(@room.level)} · {feet(@room.plan.w)} by {feet(@room.plan.d)}
          </p>
        </div>
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
        <.link patch={~p"/inside"} class="btn btn-sm btn-ghost btn-square" aria-label="Close">
          <.icon name="hero-x-mark" class="size-4" />
        </.link>
      </div>
      <.moves
        id="move-room"
        event="nudge_room"
        target={@room.id}
        step={24}
        what="the room"
        blocked={blocked(@build, @room.id, 24)}
      />
    </div>
    """
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

  # The rooms and their items, as a list: for a screen reader, and for a
  # keyboard (it shows when it has the focus). The arrow keys move an item
  # or a room (the hook Plan).
  defp list(assigns) do
    assigns = assign(assigns, :place_names, @place_names)

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
                  patch={~p"/inside?#{[item: item.id]}"}
                  id={"item-#{item.id}"}
                  data-nudge={item.id}
                  class="link"
                >
                  {Catalog.name(item)}{item_note(item, @estimate, @price)}
                </.link>
              </li>
              <li :for={{item, van} <- @away} :if={item.home == room.id}>
                <.link patch={~p"/van?#{[id: van.id]}"} id={"away-#{item.id}"} class="link">
                  {Catalog.name(item)}: in the van now
                </.link>
              </li>
              <li>
                <.link
                  patch={~p"/inside?#{[add: room.id]}"}
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

  # The usage, the cost and the flags of an item, as a text.
  defp item_note(item, estimate, price) do
    usage =
      if estimate.ready,
        do:
          ": #{Format.kwh(estimate.items[item.id].year / 12)}, #{Format.money(Format.cost(estimate.items[item.id].year / 12, price.cents))} a month",
        else: ""

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

  # The numbers of an item, the math of its kWh, and the features that it
  # turns on.
  defp item_sheet(assigns) do
    kind = Catalog.kind(assigns.item.type)
    {:ok, room} = Build.room(assigns.build, assigns.item.room)
    rooms = Enum.filter(assigns.build.rooms, &(&1.place in kind.places))
    van = Enum.any?(assigns.build.items, &(&1.type == "camper_van"))
    features = if van, do: kind.features, else: kind.features -- @van_features

    assigns =
      assign(assigns, kind: kind, room: room, rooms: rooms, van: van, features: features)

    ~H"""
    <.sheet id="item-sheet" title={Catalog.name(@item)} icon={@item.type}>
      <p class="text-sm opacity-80">In {@room.name}{level_note(@room.level)}</p>

      <div :if={@item.typical} class="alert alert-warning text-sm">
        <span>
          {if @item.type == "camper_van",
            do: "These numbers are typical of the model. Check them on the label in the door frame.",
            else:
              "These numbers are a guess for a house like yours. Check them on the label of the item."}
        </span>
        <button
          type="button"
          phx-click="check_item"
          phx-value-id={@item.id}
          class="btn btn-xs shrink-0 whitespace-nowrap"
        >They are right</button>
      </div>

      <form id="flags-form" phx-change="flag" class="space-y-1">
        <input type="hidden" name="item_id" value={@item.id} />
        <label class="flex items-center gap-2 text-sm">
          <input type="hidden" name="planned" value="false" />
          <input
            type="checkbox"
            name="planned"
            value="true"
            checked={@item.planned}
            class="checkbox checkbox-sm"
          /> I do not have it yet: it is a plan
        </label>
        <label :if={station?(@build) and loads_power?(@item)} class="flex items-center gap-2 text-sm">
          <input type="hidden" name="backup" value="false" />
          <input
            type="checkbox"
            name="backup"
            value="true"
            checked={@item.backup}
            class="checkbox checkbox-sm"
          /> A power station runs it (in an outage too)
        </label>
      </form>

      <form id="item-form" phx-change="item" phx-submit="item" class="space-y-3">
        <input type="hidden" name="item_id" value={@item.id} />
        <.param
          :for={param <- @kind.params}
          :if={shown?(param, @item, @van)}
          param={param}
          value={@item.params[param.key]}
          error={@error == param.key}
        />
      </form>

      <div :if={@estimate.ready} id="item-math" class="space-y-1 text-sm">
        <p class="font-semibold">
          In one year: {Format.kwh(@estimate.items[@item.id].year)} · {Format.money(
            Format.cost(@estimate.items[@item.id].year, @price.cents)
          )}
        </p>
        <p class="opacity-80">
          How the app gets this number, for one month: {month_name(math_month(@item))}{season(
            math_month(@item)
          )}.
        </p>
        <ul class="list-disc pl-5 opacity-80">
          <li :for={line <- Estimate.explain(@item, math_month(@item), @estimate)}>{line}</li>
        </ul>
      </div>

      <p class="text-sm">
        <span class="font-semibold">The app uses it for:</span> {features(@features)}.
      </p>

      <.usage :if={:usage in @kind.features} usage={@build.usage} />

      <.link
        :if={:van in @kind.features}
        patch={~p"/van?#{[id: @item.id]}"}
        id="open-van"
        class="btn btn-sm btn-primary"
      >
        Open the build of the van
      </.link>

      <form :if={length(@rooms) > 1} id="move-form" phx-change="move_item">
        <input type="hidden" name="item_id" value={@item.id} />
        <label class="text-sm">
          Move it to
          <select name="room" class="select select-sm">
            <option :for={room <- @rooms} value={room.id} selected={room.id == @item.room}>
              {room.name}
            </option>
          </select>
        </label>
      </form>

      <.place :if={@item.at} item={@item} room={@room} />

      <button
        type="button"
        id="delete-item"
        phx-click="delete_item"
        phx-value-id={@item.id}
        data-confirm={
          if @item.type == "smart_meter" and @build.usage,
            do: "Remove this item? With no smart meter, the real usage goes too.",
            else: "Remove this item?"
        }
        class="btn btn-sm btn-error btn-outline"
      >
        Remove the item
      </button>
    </.sheet>
    """
  end

  attr :item, :map, required: true
  attr :room, :map, required: true, doc: "the room or the zone of the item"

  @doc """
  The place of an item on the plan: buttons that move it, its place in
  words, its size and its turn. It is in the sheet of an item of the house
  or of a van.
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
