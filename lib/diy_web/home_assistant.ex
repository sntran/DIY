defmodule DIYWeb.HomeAssistant do
  @moduledoc """
  The LiveView part of the link to Home Assistant. The hook `HomeAssistant`
  of the page (`assets/js/home_assistant.js`) does the sign-in and keeps
  the tokens on the device: the server never sees them. The TLA+ model
  `specs/HomeAssistant.tla` checks the rules of the hook.

  A LiveView with `on_mount DIYWeb.HomeAssistant` gets the assign `:ha`:

  - `state`: `loading` (the hook did not tell yet), `none`, `signing_in`,
    `connecting`, `connected`, `offline` or `signed_out`;
  - `url`: the address of Home Assistant;
  - `name` and `version`: the name of the home and the version of Home
    Assistant, when it is connected;
  - `error`: why the last step did not work (`message/1`), or `nil`.

  The events of the page: `ha_connect` (with the address and the way back)
  and `ha_disconnect`. The card of the link (`card/1`) is in Settings and
  in the sheet of a Home Assistant hub (an item of a room).

  The match of the rooms (`rooms_sheet/1`, `DIY.HomeAssistant`) uses two
  more assigns:

  - `:ha_rooms`: the floors and the areas of Home Assistant, and `admin`
    (only an admin can add floors and areas). It is `nil` while the hook
    reads them (`fetch_rooms/1`). It is `%{error: error}` when the hook
    cannot read them (`rooms_message/1`).
  - `:ha_sync`: what the last match did, or `nil`.
  """
  use DIYWeb, :html

  alias DIY.{Build, HomeAssistant}
  alias DIYWeb.Inside
  alias Phoenix.LiveView

  @states ~w(none signing_in connecting connected offline signed_out)
  @errors ~w(url blocked state denied token unreachable storage signed_out)

  # The longest address, and the longest name or version, that the page
  # takes from the hook.
  @max_url 2048
  @max_text 200

  # The longest id, and the longest name, of a floor or an area.
  @max_id 255
  @max_name 255

  # The pages where Home Assistant sends the browser back after the
  # sign-in: Settings, or the sheet of a hub. The hook has the same rule
  # (`wayBack` in `assets/js/home_assistant.js`).
  @back ~r"\A/(settings|inside\?item=[A-Za-z0-9_-]{1,40})\z"

  # The most floors and areas that the page takes from the hook, and the
  # most areas that one match adds as rooms.
  @max_floors 100
  @max_areas 500
  @max_adds 50

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:ha, %{state: "loading", url: nil, name: nil, version: nil, error: nil})
      |> assign(ha_rooms: nil, ha_sync: nil)

    {:cont, LiveView.attach_hook(socket, :home_assistant, :handle_event, &handle_event/3)}
  end

  @doc """
  Asks the hook for the floors and the areas of Home Assistant. The answer
  is the event `ha:rooms`.
  """
  def fetch_rooms(socket) do
    socket
    |> assign(:ha_rooms, nil)
    |> LiveView.push_event("ha:rooms_fetch", %{})
  end

  @doc false
  def handle_event("ha:status", %{"state" => state} = params, socket) when state in @states do
    ha = %{
      state: state,
      url: text(params["url"], @max_url),
      name: text(params["name"], @max_text),
      version: text(params["version"], @max_text),
      error: if(params["error"] in @errors, do: params["error"])
    }

    before = socket.assigns.ha.state
    socket = assign(socket, :ha, ha)

    # The link comes back while the sheet of the match is open: the sheet
    # reads the areas again. They can be different now.
    if state == "connected" and socket.assigns[:live_action] == :inside and
         socket.assigns[:sheet] == "ha_rooms" and
         (before != "connected" or not match?(%{areas: _}, socket.assigns.ha_rooms)),
       do: {:halt, fetch_rooms(socket)},
       else: {:halt, socket}
  end

  def handle_event("ha:status", _params, socket), do: {:halt, socket}

  def handle_event("ha:rooms", %{"error" => error}, socket) when error in ~w(offline failed),
    do: {:halt, assign(socket, :ha_rooms, %{error: error})}

  def handle_event("ha:rooms", %{"floors" => floors, "areas" => areas, "admin" => admin}, socket)
      when is_list(floors) and is_list(areas) and is_boolean(admin) do
    # A floor or an area that the page cannot read does not count.
    ha_rooms =
      if length(floors) <= @max_floors and length(areas) <= @max_areas,
        do: %{
          floors: floors |> Enum.map(&read_floor/1) |> Enum.reject(&is_nil/1),
          areas: areas |> Enum.map(&read_area/1) |> Enum.reject(&is_nil/1),
          admin: admin
        },
        else: %{error: "too_many"}

    {:halt, assign(socket, :ha_rooms, ha_rooms)}
  end

  def handle_event("ha:rooms", _params, socket), do: {:halt, socket}

  def handle_event("ha_connect", %{"url" => text} = params, socket) do
    back =
      if is_binary(params["back"]) and params["back"] =~ @back,
        do: params["back"],
        else: "/settings"

    case address(text) do
      {:ok, url} ->
        {:halt, LiveView.push_event(socket, "ha:connect", %{url: url, back: back})}

      :error ->
        {:halt, assign(socket, :ha, %{socket.assigns.ha | error: "url"})}
    end
  end

  def handle_event("ha_disconnect", _params, socket),
    do: {:halt, LiveView.push_event(socket, "ha:disconnect", %{})}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp text(value, max) when is_binary(value) and byte_size(value) <= max, do: value
  defp text(_value, _max), do: nil

  # A floor or an area from the hook, or nil. An id has at most 255 bytes,
  # as in the build (`DIY.Build.link_area/3`).
  defp read_floor(%{"id" => id, "name" => name, "level" => level})
       when is_integer(level) or is_nil(level) do
    if text(id, @max_id) && text(name, @max_name), do: %{id: id, name: name, level: level}
  end

  defp read_floor(_floor), do: nil

  defp read_area(%{"id" => id, "name" => name, "floor" => floor}) do
    if text(id, @max_id) && text(name, @max_name) && (is_nil(floor) or text(floor, @max_id)),
      do: %{id: id, name: name, floor: floor}
  end

  defp read_area(_area), do: nil

  @doc """
  The address of Home Assistant in a text of the person. It has the
  scheme (`http` or `https`), the host, the port and the path, with no
  `/` at the end. The hook makes the same address (`address` in
  `assets/js/home_assistant.js`).
  """
  def address(text) when is_binary(text) and byte_size(text) <= @max_url do
    case URI.new(String.trim(text)) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        host = String.downcase(host)
        host = if String.contains?(host, ":"), do: "[#{host}]", else: host
        port = if uri.port == URI.default_port(scheme), do: "", else: ":#{uri.port}"
        path = String.trim_trailing(uri.path || "", "/")
        {:ok, "#{scheme}://#{host}#{port}#{path}"}

      _ ->
        :error
    end
  end

  def address(_text), do: :error

  @doc "The state of the link, in words, or `nil` while the page waits for the hook."
  def status(%{state: "loading"}), do: nil
  def status(%{state: "none"}), do: "Not connected."
  def status(%{state: "signing_in"}), do: "The app gets the sign-in from Home Assistant."

  def status(%{state: "connecting", url: url}),
    do: "The app connects to Home Assistant at #{url}."

  def status(%{state: "connected", name: name, version: version, url: url}),
    do: "Connected to #{name || "Home Assistant"} (Home Assistant #{version}) at #{url}."

  def status(%{state: "offline", url: url}),
    do: "Home Assistant at #{url} does not answer now. The app tries again."

  def status(%{state: "signed_out"}), do: "Not connected."

  @doc "Why the last step did not work, in words."
  def message("url"),
    do: "Give the address of your Home Assistant, for example https://home.example.com."

  def message("blocked"),
    do:
      "This page uses HTTPS, so the browser blocks an http address. Use the HTTPS address of your Home Assistant."

  def message("state"), do: "The sign-in did not finish. Try again."
  def message("denied"), do: "Home Assistant did not give access."
  def message("token"), do: "Home Assistant did not accept the sign-in. Try again."

  def message("unreachable"),
    do:
      "The app cannot reach Home Assistant at this address. Make sure that this device can open it."

  def message("storage"),
    do: "This browser cannot keep the sign-in. Make sure that the storage of the site is on."

  def message("signed_out"), do: "Home Assistant ended the sign-in. Connect again."

  attr :ha, :map, required: true, doc: "the link (the assign `:ha`)"
  attr :back, :string, required: true, doc: "the page where the sign-in comes back"
  attr :hub, :map, default: nil, doc: "the hub of the house and its room, for Settings"
  attr :title, :boolean, default: true, doc: "false in the sheet of a hub: it has its title"

  @doc """
  The card of the link: the address and the sign-in, or the state of the
  link and a disconnect.
  """
  def card(assigns) do
    assigns =
      assign(assigns,
        status: status(assigns.ha),
        linked: assigns.ha.state in ~w(signing_in connecting connected offline)
      )

    ~H"""
    <div id="home-assistant-card" class="space-y-2">
      <h2 :if={@title} class="text-lg font-bold">Home Assistant</h2>
      <p class="text-sm">
        Connect your Home Assistant to bring its rooms and devices into the app.
        The sign-in stays on this device: the server of the app does not see it.
      </p>
      <p id="ha-status" role="status" class="text-sm font-medium">{@status}</p>
      <p :if={@ha.error} id="ha-error" role="alert" class="text-sm text-error">
        {message(@ha.error)}
      </p>
      <form
        :if={not @linked}
        id="ha-form"
        phx-submit="ha_connect"
        class="flex flex-wrap gap-2 items-end"
      >
        <input type="hidden" name="back" value={@back} />
        <label>
          <span class="text-sm">The address of your Home Assistant</span>
          <input
            name="url"
            value={@ha.url}
            type="url"
            inputmode="url"
            autocomplete="url"
            placeholder="https://home.example.com"
            class="input input-sm w-72 max-w-full block"
          />
        </label>
        <button class="btn btn-sm">Connect</button>
      </form>
      <p :if={not @linked} class="text-xs opacity-70">
        The browser goes to the sign-in page of your Home Assistant, and then comes back here.
        Use the HTTPS address (for example, from Home Assistant Cloud): this page blocks an http address.
      </p>
      <button
        :if={@linked}
        type="button"
        id="ha-disconnect"
        phx-click="ha_disconnect"
        class="btn btn-sm"
      >
        Disconnect
      </button>
      <.link
        :if={@ha.state == "connected"}
        patch={~p"/inside?#{[sheet: "ha_rooms"]}"}
        id="ha-match"
        class="btn btn-sm"
      >
        Match the rooms with Home Assistant
      </.link>
      <p :if={@hub} id="ha-hub" class="text-sm">
        Your hub is in {@hub.room.name}: <.link
          patch={~p"/inside?#{[item: @hub.item.id]}"}
          class="link"
        >open it</.link>.
      </p>
      <p :if={@title and is_nil(@hub)} id="ha-hub" class="text-sm">
        You can also add a Home Assistant hub to a room on the page Rooms: its sheet has this card.
      </p>
    </div>
    """
  end

  ## The match of the rooms

  @doc """
  The changes of a match that the person chose (the form of
  `rooms_sheet/1`). The app links the rooms in both, and adds the areas of
  Home Assistant that the person chose as rooms: 50 at most. It gives the new build,
  the rooms for Home Assistant to add, and the status. The hook gets the
  rooms with `ha:add_areas`, with the level and the name of the floor of
  each room. Only an admin of Home Assistant can add areas.
  """
  def sync(build, %{areas: areas, admin: admin}, params) do
    match = HomeAssistant.match(build, areas)

    links =
      for {room, area} <- match.both, build.areas[room.id] != area.id, do: {room.id, area.id}

    choices = if is_map(params["ha"]), do: params["ha"], else: %{}

    {adds, over} =
      Enum.split(
        for(
          area <- match.ha,
          {level, place} <- choice(choices[area.id], build),
          do: {area, level, place}
        ),
        @max_adds
      )

    {build, missed} = HomeAssistant.apply(build, links, adds)
    missed = missed ++ for({area, _level, _place} <- over, do: area.name)
    chosen = if is_list(params["app"]), do: MapSet.new(params["app"]), else: MapSet.new()
    blocked = HomeAssistant.blocked(match, areas)

    out =
      for room <- match.app,
          admin,
          MapSet.member?(chosen, room.id),
          not MapSet.member?(blocked, room.id),
          do: %{
            room: room.id,
            name: room.name,
            level: HomeAssistant.floor_level(room),
            floor: Build.level_name(room.level)
          }

    status = %{
      linked: length(links),
      added: length(adds) + length(over) - length(missed),
      missed: missed,
      sent: length(out),
      done: nil,
      errors: []
    }

    {build, out, status}
  end

  # The level and the place that the person chose for an area, as a list
  # of one: "f1 indoor". "skip", or a level or a place that the house does
  # not have, gives no room (an empty list).
  defp choice(text, build) when is_binary(text) do
    places = Map.new(DIY.Catalog.places(), &{Atom.to_string(&1), &1})

    with [level, place] <- String.split(text, " "),
         true <- level in Build.levels(build.house.floors),
         {:ok, place} <- Map.fetch(places, place) do
      [{level, place}]
    else
      _skip -> []
    end
  end

  defp choice(_text, _build), do: []

  @doc """
  The answer of Home Assistant to `ha:add_areas`: the new areas, each with
  its room, and the rooms that it did not add. The app links each room to
  its area, when no different room has the area. It gives the new build
  and the status.
  """
  def areas_added(build, status, %{"links" => links, "errors" => errors})
      when is_list(links) and length(links) <= @max_areas and is_list(errors) and
             length(errors) <= @max_areas do
    pairs =
      for %{"room" => room, "area" => area} <- links,
          text(room, 40) && text(area, @max_id),
          do: {room, area}

    {build, done, taken} =
      Enum.reduce(pairs, {build, 0, []}, fn {room, area}, {build, done, taken} ->
        case Build.link_area(build, room, area) do
          {:ok, build} -> {build, done + 1, taken}
          {:error, :taken} -> {build, done, taken ++ [room]}
          {:error, _reason} -> {build, done, taken}
        end
      end)

    names = Map.new(build.rooms, &{&1.id, &1.name})

    failed =
      for(
        %{"room" => room, "message" => message} <- errors,
        is_binary(names[room]),
        do: "#{names[room]} (#{text(message, @max_text) || "no reason"})"
      ) ++ for(room <- taken, do: "#{names[room]} (a different room has the area)")

    status =
      status || %{linked: 0, added: 0, missed: [], sent: length(pairs), done: nil, errors: []}

    {build, %{status | done: done, errors: failed}}
  end

  def areas_added(build, status, _params), do: {build, status}

  @doc "Why the sheet of the match has no floors and no areas, in words."
  def rooms_message("offline"), do: "Home Assistant does not answer now. Try again later."

  def rooms_message("failed"),
    do:
      "Home Assistant did not give its floors and areas. The match needs Home Assistant 2024.4 or later."

  def rooms_message("too_many"),
    do: "Home Assistant has more than 500 areas or more than 100 floors: too many for the match."

  @doc "What the last match did, in words."
  def sync_text(status) do
    [
      "The app linked #{count(status.linked, "room")} and added #{count(status.added, "room")}.",
      status.missed != [] && "It did not add: #{Enum.join(status.missed, ", ")}.",
      status.sent > 0 && is_nil(status.done) &&
        "Home Assistant adds #{count(status.sent, "area")}.",
      is_integer(status.done) && "Home Assistant added #{count(status.done, "area")}.",
      status.errors != [] && "Home Assistant did not add: #{Enum.join(status.errors, ", ")}."
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp count(n, word), do: DIYWeb.Format.count(n, word)

  attr :build, :map, required: true
  attr :ha, :map, required: true
  attr :ha_rooms, :map, default: nil
  attr :ha_sync, :map, default: nil

  @doc """
  The sheet of the match of the rooms. It has three lists: the rooms in
  both, the rooms only in the app, and the areas only in Home Assistant.
  The person chooses the rooms to add to Home Assistant, and the place of
  each area to add to the app.
  """
  def rooms_sheet(assigns) do
    assigns =
      case assigns.ha_rooms do
        %{areas: areas, floors: floors} ->
          floors_count = assigns.build.house.floors

          match = HomeAssistant.match(assigns.build, areas)

          assign(assigns,
            match: match,
            blocked: HomeAssistant.blocked(match, areas),
            suggest: &HomeAssistant.place_of(&1, floors, floors_count),
            options: options(assigns.build)
          )

        _other ->
          assign(assigns, match: nil)
      end

    ~H"""
    <Inside.sheet id="ha-rooms-sheet" title="Match the rooms with Home Assistant">
      <p :if={@ha.state in ~w(none signed_out)} id="ha-rooms-wait" class="text-sm">
        Connect Home Assistant first: open the sheet of the hub, or Settings.
      </p>
      <p
        :if={@ha.state in ~w(signing_in connecting offline)}
        id="ha-rooms-wait"
        role="status"
        class="text-sm"
      >
        The app waits for the link to Home Assistant.
      </p>
      <p
        :if={@ha.state == "loading" or (@ha.state == "connected" and is_nil(@ha_rooms))}
        id="ha-rooms-wait"
        role="status"
        class="text-sm"
      >
        The app reads the areas of Home Assistant.
      </p>
      <p
        :if={@ha.state == "connected" and match?(%{error: _}, @ha_rooms)}
        id="ha-rooms-wait"
        role="alert"
        class="text-sm"
      >
        {rooms_message(@ha_rooms.error)}
      </p>
      <form
        :if={@ha.state == "connected" and @match}
        id="ha-rooms"
        phx-submit="ha_sync"
        class="space-y-4"
      >
        <section id="ha-both">
          <h3 class="font-bold">In both ({length(@match.both)})</h3>
          <p :if={@match.both == []} class="text-sm opacity-80">
            No room has an area of the same name.
          </p>
          <ul class="text-sm list-disc pl-5">
            <li :for={{room, area} <- @match.both}>
              {room.name}
              <span :if={HomeAssistant.key(room.name) != HomeAssistant.key(area.name)}>
                (in Home Assistant: {area.name})
              </span>
            </li>
          </ul>
        </section>

        <section id="ha-app">
          <h3 class="font-bold">Only in the app ({length(@match.app)})</h3>
          <p :if={not @ha_rooms.admin and @match.app != []} class="text-sm">
            Only an admin of Home Assistant can add areas. Your user of Home Assistant is not an admin.
          </p>
          <%= for room <- @match.app do %>
            <p :if={MapSet.member?(@blocked, room.id)} class="py-1 text-sm">
              {room.name} ({Build.level_name(room.level)}): a different room or area has this name.
              Give the room a different name to add it.
            </p>
            <label
              :if={not MapSet.member?(@blocked, room.id)}
              class="flex items-center gap-2 py-1 text-sm"
            >
              <input
                type="checkbox"
                name="app[]"
                value={room.id}
                checked={@ha_rooms.admin}
                disabled={not @ha_rooms.admin}
                class="checkbox"
              /> Add {room.name} to Home Assistant ({Build.level_name(room.level)})
            </label>
          <% end %>
        </section>

        <section id="ha-ha">
          <h3 class="font-bold">Only in Home Assistant ({length(@match.ha)})</h3>
          <label :for={area <- @match.ha} class="block text-sm">
            <span>{area.name}</span>
            <select name={"ha[#{area.id}]"} class="select select-sm w-full">
              <option
                :for={{value, label} <- @options}
                value={value}
                selected={value == choice_value(@suggest.(area))}
              >
                {label}
              </option>
            </select>
          </label>
        </section>

        <button class="btn btn-sm btn-primary">Match the rooms</button>
      </form>
      <p :if={@ha_sync} id="ha-sync" role="status" class="text-sm">{sync_text(@ha_sync)}</p>
    </Inside.sheet>
    """
  end

  defp choice_value({level, place}), do: "#{level} #{place}"

  # The choices for an area: a floor, around the house, the attic, or no
  # room.
  defp options(build) do
    floors = for level <- Build.levels(build.house.floors), match?("f" <> _, level), do: level

    for(
      level <- Enum.sort(floors),
      do: {"#{level} indoor", "Add as a room of #{Build.level_name(level)}"}
    ) ++
      [
        {"outside indoor", "Add as a room around the house, inside (a garage)"},
        {"outside outdoor", "Add as a room around the house, outside (a yard)"},
        {"roof indoor", "Add as a room in the attic"},
        {"skip", "Do not add it"}
      ]
  end
end
