defmodule DIYWeb.Inside do
  @moduledoc """
  The inside of the house: one room at a time. The rooms of a floor are in
  a row: a swipe to the left or to the right goes to the next room. The
  floors are in a column: a swipe up or down goes to a different floor.
  The browser does the swipe (CSS scroll snap), with no script. Links do
  the same for a keyboard.

  Each room shows its name, its floor and dots for its place in the row.
  Outside (the backyard, the garage, the driveway) and the roof are rooms
  too.
  """
  use DIYWeb, :html

  alias DIY.{Build, Catalog, Estimate}
  alias DIYWeb.Format

  @place_names %{indoor: "Inside", outdoor: "Outside", roof: "On the roof"}

  attr :build, :map, required: true
  attr :estimate, :map, required: true, doc: "the estimate with the planned items"
  attr :bill, :map, default: nil, doc: "the bill of today (DIY.Bill)"
  attr :price, :map, required: true
  attr :item, :string, default: nil
  attr :add, :string, default: nil
  attr :item_error, :string, default: nil

  def inside(assigns) do
    assigns = assign(assigns, :levels, Build.levels(assigns.build.house.floors))

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

      <%!-- The hint is in a fixed element: #levels must not move (assets/js/scroll.js). --%>
      <div id="hints">
        <div :if={"swipe" not in @build.hints} id="swipe-hint" class="alert alert-info">
          <span aria-hidden="true">👆</span>
          <span>Swipe left or right for the next room. Swipe up or down for a different floor.</span>
          <button type="button" phx-click="hint" phx-value-hint="swipe" class="btn btn-sm">OK</button>
        </div>
      </div>

      <div
        id="levels"
        phx-hook="ScrollStart"
        data-start="level-f1"
        class="relative h-[calc(100dvh-13rem)] overflow-y-auto snap-y snap-mandatory overscroll-contain rounded-box"
      >
        <section
          :for={{level, l} <- Enum.with_index(@levels)}
          id={"level-#{level}"}
          class="min-h-full snap-start py-2"
          aria-label={Build.level_name(level)}
        >
          <div class="flex items-center justify-between px-1">
            <h2 class="font-semibold">{Build.level_name(level)}</h2>
            <span class="flex gap-1 text-sm">
              <a
                :if={l > 0}
                href={"#level-#{Enum.at(@levels, l - 1)}"}
                class="btn btn-sm btn-square btn-ghost"
                aria-label="The level above"
              >▲</a>
              <a
                :if={l < length(@levels) - 1}
                href={"#level-#{Enum.at(@levels, l + 1)}"}
                class="btn btn-sm btn-square btn-ghost"
                aria-label="The level below"
              >▼</a>
            </span>
          </div>
          <.row build={@build} level={level} estimate={@estimate} price={@price} />
        </section>
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
    </section>
    """
  end

  attr :build, :map, required: true
  attr :level, :string, required: true
  attr :estimate, :map, required: true
  attr :price, :map, required: true

  # The rooms of a level, in a row, and a card to add a room.
  defp row(assigns) do
    rooms = Build.rooms_on(assigns.build, assigns.level)
    assigns = assign(assigns, rooms: rooms, place_names: @place_names)

    ~H"""
    <div class="flex snap-x snap-mandatory overflow-x-auto gap-3 pb-2">
      <article
        :for={{room, i} <- Enum.with_index(@rooms)}
        id={"room-#{room.id}"}
        class="card card-border bg-base-100 snap-center shrink-0 w-[85%] p-4 space-y-3"
        aria-label={room.name}
      >
        <header class="flex items-start justify-between gap-2">
          <div>
            <h3 class="text-lg font-bold">{room.name}</h3>
            <p class="text-xs opacity-70">
              {Build.level_name(room.level)} · {@place_names[room.place]}
            </p>
          </div>
          <p class="flex gap-1 pt-2">
            <span class="sr-only">Room {i + 1} of {length(@rooms)}</span>
            <span
              :for={j <- 0..(length(@rooms) - 1)}
              aria-hidden="true"
              class={["size-2 rounded-full", if(i == j, do: "bg-primary", else: "bg-base-300")]}
            />
          </p>
        </header>

        <ul class="grid grid-cols-2 gap-2">
          <li :for={item <- Build.items_in(@build, room.id)}>
            <.link
              patch={~p"/inside?#{[item: item.id]}"}
              id={"item-#{item.id}"}
              class={[
                "card p-2 h-full hover:bg-base-200",
                cond do
                  item.planned -> "border-2 border-dashed border-primary"
                  item.typical -> "border border-dashed border-base-300"
                  true -> "card-border"
                end
              ]}
            >
              <span class="text-2xl" aria-hidden="true">{Catalog.kind(item.type).emoji}</span>
              <span class="text-sm font-semibold leading-tight">{Catalog.name(item)}</span>
              <span :if={@estimate.ready} class="text-xs opacity-80">
                {Format.kwh(@estimate.items[item.id].year / 12)} · {Format.money(
                  Format.cost(@estimate.items[item.id].year / 12, @price.cents)
                )} a month
              </span>
              <span :if={item.typical} class="text-xs opacity-60">Typical</span>
              <span :if={item.planned} class="text-xs font-semibold">Plan</span>
              <span :if={item.backup and station?(@build)} class="text-xs">🔋 On the station</span>
            </.link>
          </li>
          <li>
            <.link
              patch={~p"/inside?#{[add: room.id]}"}
              id={"add-#{room.id}"}
              class="card card-border border-dashed p-2 h-full items-center justify-center hover:bg-base-200"
              aria-label={"Add an item to #{room.name}"}
            >
              <span class="text-2xl" aria-hidden="true">＋</span>
              <span class="text-sm">Add</span>
            </.link>
          </li>
        </ul>

        <footer class="flex items-center justify-between text-sm">
          <span>
            <a
              :if={i > 0}
              href={"#room-#{Enum.at(@rooms, i - 1).id}"}
              class="btn btn-sm btn-square btn-ghost"
              aria-label="The room before"
            >◀</a>
            <a
              :if={i < length(@rooms) - 1}
              href={"#room-#{Enum.at(@rooms, i + 1).id}"}
              class="btn btn-sm btn-square btn-ghost"
              aria-label="The next room"
            >▶</a>
          </span>
          <details class="dropdown dropdown-end">
            <summary class="btn btn-sm btn-ghost">Change the room</summary>
            <div class="dropdown-content z-10 card card-border bg-base-100 p-3 w-64 space-y-2">
              <form id={"rename-#{room.id}"} phx-submit="rename_room" class="flex gap-2">
                <input type="hidden" name="room_id" value={room.id} />
                <label for={"name-#{room.id}"} class="sr-only">The name of the room</label>
                <input
                  id={"name-#{room.id}"}
                  name="name"
                  value={room.name}
                  class="input input-sm"
                  maxlength="40"
                />
                <button class="btn btn-sm">Rename</button>
              </form>
              <button
                type="button"
                id={"delete-#{room.id}"}
                phx-click="delete_room"
                phx-value-id={room.id}
                data-confirm={"Remove #{room.name} and its items?"}
                class="btn btn-sm btn-error btn-outline w-full"
              >
                Remove the room
              </button>
            </div>
          </details>
        </footer>
      </article>

      <article class="card card-border border-dashed snap-center shrink-0 w-[85%] p-4">
        <form id={"new-room-#{@level}"} phx-submit="add_room" class="space-y-2">
          <h3 class="font-semibold">Add a room on this level</h3>
          <input type="hidden" name="room[level]" value={@level} />
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
            <span class="text-sm">Place</span>
            <select name="room[place]" class="select select-sm w-full">
              <option
                :for={{place, name} <- @place_names}
                value={place}
                selected={default_place(@level) == place}
              >
                {name}
              </option>
            </select>
          </label>
          <button class="btn btn-sm">Add the room</button>
        </form>
      </article>
    </div>
    """
  end

  defp default_place("outside"), do: :outdoor
  defp default_place("roof"), do: :roof
  defp default_place(_level), do: :indoor

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
    assigns = assign(assigns, kind: kind, room: room, rooms: rooms)

    ~H"""
    <.sheet id="item-sheet" title={"#{@kind.emoji} #{Catalog.name(@item)}"}>
      <p class="text-sm opacity-80">In {@room.name} ({Build.level_name(@room.level)})</p>

      <div :if={@item.typical} class="alert alert-warning text-sm">
        <span>These numbers are a guess for a house like yours. Check them on the label of the item.</span>
        <button type="button" phx-click="check_item" phx-value-id={@item.id} class="btn btn-xs">Correct</button>
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
        <p class="opacity-80">How the app gets this number, for {month_name(math_month(@item))}:</p>
        <ul class="list-disc pl-5 opacity-80">
          <li :for={line <- Estimate.explain(@item, math_month(@item), @estimate)}>{line}</li>
        </ul>
      </div>

      <p class="text-sm">
        <span class="font-semibold">It turns on:</span> {features(@kind)}.
      </p>

      <.usage :if={:usage in @kind.features} usage={@build.usage} />

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

  # True when the house has a power station (a planned one too).
  defp station?(build), do: Enum.any?(build.items, &(&1.type == "power_station"))

  # The items that a station can run: the items that use power.
  defp loads_power?(%{type: type}),
    do: type not in ~w(power_station solar_panels transfer_switch smart_meter)

  # A month that shows the work of an item: January for heat, July else.
  defp math_month(%{type: type}) when type in ["furnace", "heat_strips", "space_heater"], do: 1
  defp math_month(_item), do: 7

  defp month_name(month), do: Enum.at(Estimate.month_names(), month - 1)

  defp features(kind), do: Enum.map_join(kind.features, ", ", &feature/1)

  defp feature(:estimate), do: "the usage estimate"
  defp feature(:backup), do: "the hours of backup in an outage"
  defp feature(:shift), do: "the charge at night"
  defp feature(:power_view), do: "the view of what feeds what, and the permit notes"
  defp feature(:solar), do: "the power of the sun"
  defp feature(:ev), do: "the cost of the home charge next to gas"
  defp feature(:usage), do: "your real usage, from the file of the meter"

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

  defp param(%{param: %{type: :bool}} = assigns) do
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

  defp param(%{param: %{type: {:choice, values}}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <label class="block">
      <span class="text-sm font-semibold">{@param.label}</span>
      <select name={"item[#{@param.key}]"} class="select select-sm w-full">
        <option :for={{key, label} <- @values} value={key} selected={key == @value}>{label}</option>
      </select>
    </label>
    """
  end

  defp param(assigns) do
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
            class="btn btn-block justify-start h-auto py-2"
          >
            <span aria-hidden="true">{kind.emoji}</span> {kind.name}
          </button>
        </li>
      </ul>
    </.sheet>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  # A sheet over the page. The close link goes back to the rooms. The hook
  # Sheet closes it with the Escape key, and keeps the focus in it.
  defp sheet(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Sheet"
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40"
    >
      <.link patch={~p"/inside"} class="absolute inset-0" aria-label="Close" tabindex="-1"></.link>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        class="relative card bg-base-100 w-full max-w-xl max-h-[85dvh] overflow-y-auto p-4 space-y-3"
        phx-mounted={JS.focus_first()}
      >
        <div class="flex items-center justify-between">
          <h2 id={"#{@id}-title"} class="text-lg font-bold">{@title}</h2>
          <.link patch={~p"/inside"} class="btn btn-sm btn-ghost" aria-label="Close" data-close>
            ✕
          </.link>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
