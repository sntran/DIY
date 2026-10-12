defmodule DIYWeb.HomeAssistant do
  @moduledoc """
  The LiveView part of the link to Home Assistant. The hook `HomeAssistant`
  of the page (`assets/js/home_assistant.js`) does the sign-in and keeps
  the tokens on the device: the server never sees them. The TLA+ model
  `specs/HomeAssistant.tla` checks the rules of the hook.

  A LiveView with `on_mount DIYWeb.HomeAssistant` gets the assign `:ha`:

  - `state`: `loading` (the hook did not tell yet), `none`, `signing_in`,
    `connecting`, `connected`, `offline` or `signed_out`. The sign-in page
    (`DIYWeb.SignInLive`) also has `done`;
  - `url`: the address of Home Assistant;
  - `name` and `version`: the name of the home and the version of Home
    Assistant, when it is connected;
  - `error`: why the last step did not work (`message/1`), or `nil`.

  The key Connect sends the DOM event `ha:connect` to the hook
  (`JS.dispatch/1`). The hook opens the sign-in page in a new tab. A
  browser lets a page open a tab only in the tap, so the address goes to
  the hook, not to the server. The event of the page is `ha_disconnect`.
  The card of the link (`card/1`) is in Settings and in the panel of a
  Home Assistant hub (an item of a room).

  The match of the rooms (`rooms_sheet/1`, `DIY.HomeAssistant`) uses two
  more assigns:

  - `:ha_rooms`: the floors and the areas of Home Assistant, and `admin`
    (only an admin can add floors and areas). It is `nil` while the hook
    reads them (`fetch_rooms/1`). It is `%{error: error}` when the hook
    cannot read them (`rooms_message/1`).
  - `:ha_sync`: what the last match did, or `nil`.

  The ghosts of the devices (`DIY.HomeAssistant.ghosts/4`) use the assign
  `:ha_devices`: the devices and the areas of Home Assistant. It is `nil`
  before the hook reads them, and `%{error: error}` when the hook cannot
  read them. The page asks for them when the link becomes connected
  (`ha:devices_fetch`), and forgets them after a disconnect. Each change
  sends the message `:ha_devices` to the LiveView, so that it draws the
  ghosts again.

  The states of the lights, the switches and the fans use two more
  assigns (`power/2`):

  - `:ha_states`: the state of each device that the app turns on and off,
    from the hook (`ha:states`): `on`, `off` or `unavailable`. The hook
    watches the states while the link is connected. The page forgets them
    when the link is not connected.
  - `:ha_control`: for each device, a control that waits for its end
    (`{:pending, on}`), or the error of the last control
    (`{:error, error}`). The switch of an item sends the control to the
    hook (`control/3`, `ha:control`), and the hook tells its end
    (`ha:control_done`).

  The energy data of Home Assistant uses the assign `:ha_energy`
  (`read_energy/1`). It has the meter of the house (`DIY.Usage`, with the
  source `home_assistant`) and the energy of each device. It is `nil` before the
  hook reads it, and `%{error: error}` when the hook cannot read it. The
  page asks for it when the link becomes connected (`ha:energy_fetch`),
  and forgets it after a disconnect. Each change sends the message
  `:ha_energy` to the LiveView.

  The sign-in page uses `on_mount {DIYWeb.HomeAssistant, :sign_in}`: it
  takes only the states of the sign-in (`none`, `signing_in` and `done`),
  and no other event.
  """
  use DIYWeb, :html

  alias DIY.{Build, HomeAssistant, Usage}
  alias DIYWeb.Inside
  alias Phoenix.LiveView

  # The states of the link on a page of the app, and on the sign-in page
  # (`DIYWeb.SignInLive`). The ghosts of the devices show while the link
  # is open.
  @states ~w(none signing_in connecting connected offline signed_out)
  @tab_states ~w(none signing_in done)
  @errors ~w(url blocked tab closed cancelled unasked state denied token unreachable storage signed_out)

  # The longest address, and the longest name or version, that the page
  # takes from the hook.
  @max_url 2048
  @max_text 200

  # The longest id, and the longest name, of a floor or an area.
  @max_id 255
  @max_name 255

  # The most floors and areas that the page takes from the hook, and the
  # most areas that one match adds as rooms.
  @max_floors 100
  @max_areas 500
  @max_adds 50

  # The most devices that the page takes from the hook, and the most
  # domains of the entities of one device.
  @max_devices 1000
  @max_domains 30

  # The most devices with energy, and the most months of one device, that
  # the page takes from the hook.
  @max_energy_devices 200
  @max_energy_months 13

  # The domains of the entities that the app turns on and off, and the
  # states of a device.
  @controls ~w(fan light switch)
  @power_states ~w(on off unavailable)

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:ha, %{state: "loading", url: nil, name: nil, version: nil, error: nil})
      |> assign(ha_rooms: nil, ha_sync: nil, ha_devices: nil, ha_states: %{}, ha_control: %{})
      |> assign(ha_energy: nil)

    {:cont, LiveView.attach_hook(socket, :home_assistant, :handle_event, &handle_event/3)}
  end

  def on_mount(:sign_in, _params, _session, socket) do
    socket =
      assign(socket, :ha, %{state: "loading", url: nil, name: nil, version: nil, error: nil})

    {:cont, LiveView.attach_hook(socket, :home_assistant, :handle_event, &sign_in_event/3)}
  end

  @doc false
  def sign_in_event("ha:status", %{"state" => state} = params, socket) when state in @tab_states,
    do: {:halt, assign(socket, :ha, read_status(state, params))}

  def sign_in_event(_event, _params, socket), do: {:halt, socket}

  @doc """
  Asks the hook for the devices and the areas of Home Assistant. The
  answer is the event `ha:devices`.
  """
  def fetch_devices(socket), do: LiveView.push_event(socket, "ha:devices_fetch", %{})

  @doc """
  Asks the hook for the energy data of Home Assistant. The answer is the
  event `ha:energy`.
  """
  def fetch_energy(socket), do: LiveView.push_event(socket, "ha:energy_fetch", %{})

  @doc """
  Asks the hook to turn a device on or off (`ha:control`). The control
  waits for its end (`ha:control_done`).
  """
  def control(socket, device, on) when is_boolean(on) do
    socket
    |> assign(:ha_control, Map.put(socket.assigns.ha_control, device, {:pending, on}))
    |> LiveView.push_event("ha:control", %{device: device, on: on})
  end

  @doc "True for a device that the app turns on and off: a light, a switch or a fan."
  def controls?(device), do: Enum.any?(device.domains, &(&1 in @controls))

  @doc """
  The switch of an item, or `nil`. It is for the item of a device that
  the app turns on and off, while the page has the devices. It has the
  device and its state (`nil` before the hook tells it). It also has the
  control that waits (`pending`: `true` for on, `false` for off), and the
  error of the last control. When the link is not connected (`online`:
  false), the switch stays, so that it keeps the focus, but it has no
  state.
  """
  def power(%{ha: ha, build: build, ha_devices: ha_devices} = assigns, item_id) do
    with id when is_binary(id) <- build.devices[item_id],
         %{devices: devices} <- ha_devices,
         %{} = device <- Enum.find(devices, &(&1.id == id)),
         true <- controls?(device) do
      {pending, error} =
        case assigns.ha_control[id] do
          {:pending, on} -> {on, nil}
          {:error, error} -> {nil, error}
          nil -> {nil, nil}
        end

      %{
        device: id,
        online: ha.state == "connected",
        state: assigns.ha_states[id],
        pending: pending,
        error: error
      }
    else
      _ -> nil
    end
  end

  @doc """
  The state of each item of a device, for the plan: `%{item => state}`.
  Only while the link is connected.
  """
  def item_states(%{ha: %{state: "connected"}, build: build, ha_states: states}) do
    for {item, device} <- build.devices, Map.has_key?(states, device), into: %{} do
      {item, states[device]}
    end
  end

  def item_states(_assigns), do: %{}

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
  def handle_event("ha:status", %{"state" => state} = params, socket) when state in @states,
    do: status(socket, state, params)

  def handle_event("ha:status", _params, socket), do: {:halt, socket}

  # The devices count only while the link is connected: an answer that
  # comes after a disconnect changes nothing.
  def handle_event("ha:devices", params, %{assigns: %{ha: %{state: "connected"}}} = socket) do
    case read_devices(params) do
      nil -> {:halt, socket}
      devices -> {:halt, devices_changed(socket, devices)}
    end
  end

  def handle_event("ha:devices", _params, socket), do: {:halt, socket}

  # The energy data counts only while the link is connected.
  def handle_event("ha:energy", params, %{assigns: %{ha: %{state: "connected"}}} = socket) do
    case read_energy(params) do
      nil -> {:halt, socket}
      energy -> {:halt, energy_changed(socket, energy)}
    end
  end

  def handle_event("ha:energy", _params, socket), do: {:halt, socket}

  # The states count only while the link is connected. A payload that the
  # page cannot read changes nothing.
  def handle_event(
        "ha:states",
        %{"states" => states},
        %{assigns: %{ha: %{state: "connected"}}} = socket
      )
      when is_map(states) and map_size(states) <= @max_devices do
    if Enum.all?(states, fn {id, state} -> text(id, @max_id) && state in @power_states end) do
      # A new state of a device ends the error of its last control.
      old = socket.assigns.ha_states

      control =
        Map.reject(socket.assigns.ha_control, fn {device, value} ->
          match?({:error, _}, value) and states[device] != old[device]
        end)

      {:halt, assign(socket, ha_states: states, ha_control: control)}
    else
      {:halt, socket}
    end
  end

  def handle_event("ha:states", _params, socket), do: {:halt, socket}

  # The end of a control: only for a control that waits.
  def handle_event("ha:control_done", %{"device" => device, "error" => error}, socket)
      when error in [nil, "offline", "failed", "timeout"] do
    case socket.assigns.ha_control do
      %{^device => {:pending, _on}} = control ->
        control =
          if error,
            do: Map.put(control, device, {:error, error}),
            else: Map.delete(control, device)

        {:halt, assign(socket, :ha_control, control)}

      _control ->
        {:halt, socket}
    end
  end

  def handle_event("ha:control_done", _params, socket), do: {:halt, socket}

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

  def handle_event("ha_disconnect", _params, socket),
    do: {:halt, LiveView.push_event(socket, "ha:disconnect", %{})}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp read_status(state, params) do
    %{
      state: state,
      url: text(params["url"], @max_url),
      name: text(params["name"], @max_text),
      version: text(params["version"], @max_text),
      error: if(params["error"] in @errors, do: params["error"])
    }
  end

  defp status(socket, state, params) do
    before = socket.assigns.ha.state
    socket = assign(socket, :ha, read_status(state, params))

    # The states and the controls are only for a connected link.
    socket =
      if state == "connected",
        do: socket,
        else: assign(socket, ha_states: %{}, ha_control: %{})

    # The link becomes connected: the page reads the devices. After a
    # disconnect, it forgets them.
    socket =
      cond do
        state == "connected" and before != "connected" ->
          socket |> fetch_devices() |> fetch_energy()

        state in ~w(none signed_out) and
            (socket.assigns.ha_devices != nil or socket.assigns.ha_energy != nil) ->
          socket |> devices_changed(nil) |> energy_changed(nil)

        true ->
          socket
      end

    # The link comes back while the sheet of the match is open: the sheet
    # reads the areas again. They can be different now.
    if state == "connected" and socket.assigns[:live_action] == :inside and
         socket.assigns[:sheet] == "ha_rooms" and
         (before != "connected" or not match?(%{areas: _}, socket.assigns.ha_rooms)),
       do: {:halt, fetch_rooms(socket)},
       else: {:halt, socket}
  end

  defp devices_changed(socket, devices) do
    send(self(), :ha_devices)
    assign(socket, :ha_devices, devices)
  end

  defp energy_changed(socket, energy) do
    send(self(), :ha_energy)
    assign(socket, :ha_energy, energy)
  end

  @doc """
  The energy data of Home Assistant from the hook (`ha:energy`), or
  `%{error: error}`:

  - `meter`: the months of the meter of the house (`DIY.Usage`, with the
    source `home_assistant`), or `nil`;
  - `devices`: for each device, its name in the energy settings (or
    `nil`) and the kWh of its months (`%{month: "YYYY-MM", kwh: kwh}`).
    Two sensors of one device give the sum of their kWh;
  - `month`: the month of now ("YYYY-MM"), in the time zone of Home
    Assistant.

  A device that the page cannot read does not count. A meter that the page
  cannot read is `nil`: the devices stay. A payload that the page cannot
  read gives `nil`.
  """
  def read_energy(%{"error" => error}) when error in ~w(offline failed), do: %{error: error}

  def read_energy(%{"meter" => meter, "devices" => devices, "month" => month})
      when is_list(devices) and length(devices) <= @max_energy_devices and is_binary(month) do
    if month?(month) do
      devices =
        devices
        |> Enum.map(&read_energy_device/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.group_by(& &1.device)
        |> Map.new(fn {device, [first | _] = all} ->
          months =
            all
            |> Enum.flat_map(& &1.months)
            |> Enum.group_by(& &1.month, & &1.kwh)
            |> Enum.map(fn {month, kwh} -> %{month: month, kwh: Enum.sum(kwh)} end)
            |> Enum.sort_by(& &1.month)

          {device, %{name: first.name, months: months}}
        end)

      %{meter: read_meter(meter), devices: devices, month: month}
    end
  end

  def read_energy(_params), do: nil

  defp read_meter(%{"source" => "home_assistant"} = meter) do
    case Usage.read(meter) do
      {:ok, usage} -> usage
      :error -> nil
    end
  end

  defp read_meter(_meter), do: nil

  defp month?(month), do: month =~ ~r/\A20\d\d-(0[1-9]|1[0-2])\z/

  defp read_energy_device(%{"device" => device, "name" => name, "months" => months})
       when is_list(months) and length(months) in 1..@max_energy_months do
    with device when is_binary(device) <- text(device, @max_id),
         true <- is_nil(name) or is_binary(text(name, @max_name)),
         months when is_list(months) <- read_energy_months(months) do
      %{device: device, name: name, months: months}
    else
      _ -> nil
    end
  end

  defp read_energy_device(_device), do: nil

  defp read_energy_months(months) do
    months = Enum.map(months, &read_energy_month/1)
    names = Enum.map(months, &(&1 && &1.month))
    if Enum.all?(months) and names == Enum.uniq(names), do: months
  end

  defp read_energy_month(%{"month" => month, "kwh" => kwh})
       when is_binary(month) and is_number(kwh) and kwh >= 0 and kwh < 1_000_000 do
    if month?(month), do: %{month: month, kwh: kwh / 1}
  end

  defp read_energy_month(_month), do: nil

  @doc """
  The meter of Home Assistant, when the build does not use it yet: the
  page offers it (`ha_use_meter`). `nil` when the build uses it already,
  or when Home Assistant has no meter.
  """
  def meter_offer(%{ha_energy: %{meter: %{} = meter}, build: build}) do
    if match?(%{source: "home_assistant"}, build.usage), do: nil, else: meter
  end

  def meter_offer(_assigns), do: nil

  @doc """
  The energy of the device of an item, from Home Assistant, or `nil`. It
  is the energy of the last 12 months that are over (`months` has their
  names). So the page can put the estimate of the same months next to it.
  With no month that is over, it is the energy of this month so far
  (`partial`). It also has the first and the last month. The month of now
  is in the time zone of Home Assistant. A month after it does not count.
  """
  def item_energy(%{ha_energy: %{devices: devices, month: current}, build: build}, item_id) do
    with id when is_binary(id) <- build.devices[item_id],
         %{months: months} <- devices[id],
         over = Enum.filter(months, &(&1.month < current)),
         now = Enum.filter(months, &(&1.month == current)),
         [_ | _] = shown <- if(over == [], do: now, else: Enum.take(over, -12)) do
      partial = over == []

      %{
        kwh: shown |> Enum.map(& &1.kwh) |> Enum.sum(),
        months: Enum.map(shown, & &1.month),
        from: hd(shown).month,
        to: List.last(shown).month,
        partial: partial
      }
    else
      _ -> nil
    end
  end

  def item_energy(_assigns, _item_id), do: nil

  @doc """
  The devices and the areas of Home Assistant from the hook (`ha:devices`),
  or `%{error: error}`. A device or an area that the page cannot read does
  not count, and a second device with the same id neither. Too many
  devices or areas give `%{error: "too_many"}`. A payload that the page
  cannot read gives `nil`.
  """
  def read_devices(%{"error" => error}) when error in ~w(offline failed), do: %{error: error}

  def read_devices(%{"devices" => devices, "areas" => areas})
      when is_list(devices) and is_list(areas) do
    if length(devices) <= @max_devices and length(areas) <= @max_areas do
      %{
        devices:
          devices
          |> Enum.map(&read_device/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1.id),
        areas: areas |> Enum.map(&read_area/1) |> Enum.reject(&is_nil/1)
      }
    else
      %{error: "too_many"}
    end
  end

  def read_devices(_params), do: nil

  defp read_device(%{"id" => id, "name" => name, "area" => area, "domains" => domains} = device)
       when is_list(domains) and length(domains) <= @max_domains do
    with id when is_binary(id) <- text(id, @max_id),
         name when is_binary(name) <- text(name, @max_name),
         true <- is_nil(area) or is_binary(text(area, @max_id)),
         true <- Enum.all?(domains, &is_binary(text(&1, 40))) do
      device = %{
        id: id,
        name: name,
        area: area,
        domains: domains,
        model: text(device["model"], @max_name)
      }

      # The page reads the kind of a device one time.
      Map.put(device, :kind, HomeAssistant.kind_of(device))
    else
      _ -> nil
    end
  end

  defp read_device(_device), do: nil

  defp text(value, max) when is_binary(value) and byte_size(value) <= max, do: value
  defp text(_value, _max), do: nil

  # A floor or an area from the hook, or nil. An id has at most 255 bytes,
  # as in the build (`DIY.Build.link_area/3`). An area on a floor with a
  # longer id has no floor.
  defp read_floor(%{"id" => id, "name" => name, "level" => level})
       when is_integer(level) or is_nil(level) do
    if text(id, @max_id) && text(name, @max_name), do: %{id: id, name: name, level: level}
  end

  defp read_floor(_floor), do: nil

  defp read_area(%{"id" => id, "name" => name, "floor" => floor})
       when is_binary(floor) or is_nil(floor) do
    if text(id, @max_id) && text(name, @max_name),
      do: %{id: id, name: name, floor: text(floor, @max_id)}
  end

  defp read_area(_area), do: nil

  @doc "The state of the link, in words, or `nil` while the page waits for the hook."
  def status(%{state: "loading"}), do: nil
  def status(%{state: "none"}), do: "Not connected."
  def status(%{state: "signing_in"}), do: "Sign in to Home Assistant on the new tab."

  def status(%{state: "connecting", url: url}),
    do: "The app connects to Home Assistant at #{url}."

  def status(%{state: "connected", name: name, version: version, url: url}),
    do: "Connected to #{name || "Home Assistant"} (Home Assistant #{version}) at #{url}."

  def status(%{state: "offline", url: url}),
    do: "Home Assistant at #{url} does not answer now. The app tries again."

  def status(%{state: "signed_out"}), do: "Not connected."

  @doc "The state of the sign-in page (`DIYWeb.SignInLive`), in words."
  def tab_status(%{state: "loading"}), do: "The app gets ready for the sign-in."

  def tab_status(%{state: "signing_in", url: url}),
    do: "The app signs in to Home Assistant at #{url}."

  def tab_status(%{state: "done"}), do: "The sign-in is done."
  def tab_status(_ha), do: "The sign-in did not finish."

  @doc """
  Why the sign-in did not work, in words, for the sign-in page. The page
  has no field of the address.
  """
  def tab_message("url"),
    do: "The address of Home Assistant is not correct. Connect again on the page of the app."

  def tab_message(error), do: message(error)

  @doc "The state of the switch of an item (`power/2`), in words."
  def power_text(%{online: false}), do: "The app has no link to Home Assistant now."
  def power_text(%{pending: true}), do: "Home Assistant turns it on."
  def power_text(%{pending: false}), do: "Home Assistant turns it off."

  def power_text(power) do
    error =
      case power.error do
        "failed" -> "Home Assistant did not do it. Try again."
        "offline" -> "The link to Home Assistant closed before the end. Try again."
        "timeout" -> "Home Assistant does not answer now. Try again later."
        nil -> nil
      end

    state =
      case power.state do
        "on" -> "It is on."
        "off" -> "It is off."
        "unavailable" -> "Home Assistant cannot reach it now."
        nil -> "The app waits for its state."
      end

    Enum.join(List.wrap(error) ++ [state], " ")
  end

  @doc "Why the last step did not work, in words."
  def message("url"),
    do: "Give the address of your Home Assistant, for example https://home.example.com."

  def message("blocked"),
    do:
      "This page uses HTTPS, so the browser blocks an http address. Use the HTTPS address of your Home Assistant."

  def message("tab"),
    do:
      "The browser did not open a new tab for the sign-in. Let this site open pop-ups. Then connect again."

  def message("closed"), do: "The tab of the sign-in closed before the end. Connect again."
  def message("cancelled"), do: "A disconnect stopped this sign-in. Connect again."

  def message("unasked"),
    do:
      "Only the key Connect of the app can start a sign-in. Connect again on the page of the app."

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
  attr :hub, :map, default: nil, doc: "the hub of the house and its room, for Settings"
  attr :title, :boolean, default: true, doc: "false in the panel of a hub: it has its title"

  attr :form, :boolean,
    default: true,
    doc: "false in the panel of a hub: the address is on the screen of the hub (`screen/1`)"

  @doc """
  The card of the link: the address and the sign-in, or the state of the
  link and a disconnect.
  """
  def card(assigns) do
    assigns = assign(assigns, status: status(assigns.ha), linked: linked?(assigns.ha))

    ~H"""
    <div id="home-assistant-card" lang="en" class="space-y-2">
      <h2 :if={@title} class="text-lg font-bold">Home Assistant</h2>
      <p class="text-sm">
        Connect your Home Assistant to bring its rooms and devices into the app.
        The sign-in stays on this device: the server of the app does not see it.
      </p>
      <p id="ha-status" role="status" class="text-sm font-medium">{@status}</p>
      <p :if={@ha.error} id="ha-error" role="alert" class="text-sm text-error">
        {message(@ha.error)}
      </p>
      <button
        :if={not @form and not @linked}
        type="button"
        id="ha-show-screen"
        class="stage-link"
        data-show="screen"
      >
        Type the address on the screen of the hub
      </button>
      <form
        :if={@form and not @linked}
        id="ha-form"
        phx-submit={JS.dispatch("ha:connect")}
        class="flex flex-wrap gap-2 items-end"
      >
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
        The sign-in page of your Home Assistant opens in a new tab. After the sign-in, the tab closes.
        Use the HTTPS address (for example, from Home Assistant Cloud): this page blocks an http address.
      </p>
      <button
        :if={@linked}
        type="button"
        id="ha-disconnect"
        phx-click="ha_disconnect"
        class="btn btn-sm"
      >
        {if @ha.state == "signing_in", do: "Stop the sign-in", else: "Disconnect"}
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
        You can also add a Home Assistant hub to a room on the page Rooms: its panel has this card.
      </p>
    </div>
    """
  end

  # The link is open, or it opens: the address does not change.
  defp linked?(ha), do: ha.state in ~w(signing_in connecting connected offline)

  attr :ha, :map, required: true, doc: "the link (the assign `:ha`)"

  @doc """
  The LED screen of a hub (`DIYWeb.Stage`): the address of Home Assistant
  and the key Connect. When the link is open, the screen shows its state.
  Connect opens the sign-in page in a new tab. The rest of the link (its
  state, the errors, Disconnect and the match of the rooms) is in the panel
  of the hub (`card/1`). When the address is not
  correct, the screen also tells it next to the field. A screen reader
  reads the error of the panel with the field.
  """
  def screen(assigns) do
    assigns =
      assign(assigns,
        status: status(assigns.ha),
        linked: linked?(assigns.ha),
        bad: assigns.ha.error in ~w(url blocked)
      )

    ~H"""
    <form
      :if={not @linked}
      id="ha-form"
      phx-submit={JS.dispatch("ha:connect")}
      class="stage-led-form"
    >
      <label for="ha-url" class="stage-led-label">Address of your Home Assistant</label>
      <input
        id="ha-url"
        name="url"
        value={@ha.url}
        type="url"
        inputmode="url"
        autocomplete="url"
        placeholder="https://home.example.com"
        aria-invalid={@bad && "true"}
        aria-describedby={@bad && "ha-screen-error ha-error"}
        class="stage-led-input"
      />
      <p :if={@bad} id="ha-screen-error" class="stage-led-error">Check the address.</p>
      <button class="stage-led-key">Connect</button>
    </form>
    <p :if={@linked} id="ha-screen-state" class="stage-led-state">{@status}</p>
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
