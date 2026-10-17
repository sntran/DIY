defmodule DIYWeb.MakerLink do
  @moduledoc """
  The LiveView part of the direct link to the cloud of the maker of a
  power station, for a person with no Home Assistant. The hook `MakerLink`
  of the page (`assets/js/maker_link.js`) keeps the token on the device. It
  reads the stations through the relay of the app
  (`DIYWeb.RelayController`). The LiveView never sees the token. The TLA+
  model `specs/MakerLink.tla` checks the rules of the hook.

  A LiveView with `on_mount DIYWeb.MakerLink` gets two assigns:

  - `:makers`: for each maker (`"pecron"`), the state of the link and the
    error of the last step (`message/2`). The states are `loading`,
    `none`, `connecting`, `connected`, `offline` and `refused`. It also has
    the stations of the account (`nil` before the hook tells them). It
    also keeps the switches of each station of the last list
    (`switches`), also when a new token makes the stations `nil`. So a
    switch does not come and go while the page waits for a new list.
  - `:maker_control`: for each part of a station (`{maker, device,
    part}`), a control that waits for its end (`{:pending, on}`). Or it
    has the error of the last control (`{:error, error}`).

  The key Connect of the card (`card/1`) sends the DOM event
  `maker:connect` to the hook with the form (`JS.dispatch/1`). So the token
  does not go to the LiveView. The events of the page are
  `maker_disconnect` and the switches of a station (`control/5`).
  """
  use DIYWeb, :html

  alias DIY.{Build, HomeAssistant, Pecron}
  alias DIYWeb.Format
  alias Phoenix.LiveView

  @makers ~w(pecron)
  @names %{"pecron" => "Pecron"}
  @states ~w(none connecting connected offline refused)
  @errors ~w(format storage token denied unreachable offline timeout failed)
  @numbers ~w(battery input output)
  @switches [{"ac", "AC outlets"}, {"dc", "DC outlets"}]
  @switch_parts Enum.map(@switches, &elem(&1, 0))

  # The most stations of one account, and the longest name or model, that
  # the page takes from the hook.
  @max_stations 100
  @max_text 200

  @doc false
  def on_mount(:default, _params, _session, socket) do
    makers =
      Map.new(@makers, &{&1, %{state: "loading", error: nil, stations: nil, switches: %{}}})

    socket =
      socket
      |> assign(makers: makers, maker_control: %{})
      |> LiveView.attach_hook(:maker_link, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  @doc "The name of a maker."
  def name(maker), do: Map.fetch!(@names, maker)

  @doc """
  Asks the hook to turn the AC or DC outlets of a station on or off
  (`maker:control`). The control waits for its end (`maker:control_done`).
  """
  def control(socket, maker, device, part, on) when is_boolean(on) do
    socket
    |> assign(
      :maker_control,
      Map.put(socket.assigns.maker_control, {maker, device, part}, {:pending, on})
    )
    |> LiveView.push_event("maker:control", %{maker: maker, device: device, part: part, on: on})
  end

  @doc """
  The unit of an item and its station, for the panel, or `nil`: the item
  has a link to a unit (`DIY.Build.link_unit/3`). It has the maker, the
  device, and the parts as in `DIYWeb.HomeAssistant.station/2`: the
  numbers, `known`, `online` (the link is connected) and the switches. It
  also has the state of the link, `found` (the account has the station)
  and `reachable` (the maker can reach the station now). It has the name
  of the station in the account (`name`), or `nil`. Each switch has
  `link`: with the link not connected, a switch does not work. With no
  stations, the switches of the last list stay (`"none"` for a part that
  the station does not have). Before the first list, the station has no
  switches: the page does not know them.
  """
  def station(%{build: build, makers: makers, maker_control: controls}, item_id) do
    with "pecron:" <> device = unit <- build.units[item_id] do
      maker = "pecron"
      link = makers[maker]
      online = link.state == "connected"
      parts = Enum.find(link.stations || [], &(&1["id"] == device))
      known = link.switches[device]

      switches =
        for {part, name} <- @switches, known != nil do
          {pending, error} = pending(controls[{maker, device, part}])

          state =
            cond do
              parts -> switch_state(parts, part)
              part in known -> nil
              true -> "none"
            end

          %{
            part: part,
            name: name,
            online: online,
            link: online,
            state: state,
            pending: pending,
            error: error
          }
        end

      numbers = Map.new(@numbers, &{String.to_atom(&1), parts && parts[&1]})

      Map.merge(numbers, %{
        unit: unit,
        maker: maker,
        device: device,
        state: link.state,
        online: online,
        known: parts != nil,
        found: link.stations == nil or parts != nil,
        name: parts && parts["name"],
        reachable: parts == nil or parts["online"] == true,
        switches: switches
      })
    else
      _ -> nil
    end
  end

  # A switch that the station does not have, or with no state: "none" and
  # "unavailable", as in DIYWeb.HomeAssistant.station/2.
  defp switch_state(parts, part) do
    cond do
      not Map.has_key?(parts, part) or parts[part] == nil -> "none"
      parts["online"] != true -> "unavailable"
      true -> parts[part]
    end
  end

  defp pending({:pending, on}), do: {on, nil}
  defp pending({:error, error}), do: {nil, error}
  defp pending(nil), do: {nil, nil}

  @doc """
  The stations of the account that an item can link to: the stations of a
  connected link that no item has. Each has its unit, its name and its
  model.
  """
  def choices(%{build: build, makers: makers}) do
    for maker <- @makers,
        makers[maker].state == "connected",
        station <- makers[maker].stations || [],
        unit = "#{maker}:#{station["id"]}",
        Build.unit_item(build, unit) == nil do
      %{unit: unit, name: station["name"] || name(maker), model: station["model"], maker: maker}
    end
  end

  @doc """
  The model of the catalog for the station of a unit
  (`DIY.HomeAssistant.station_model/2`), or `nil`.
  """
  def model(%{makers: makers}, "pecron:" <> device) do
    station = Enum.find(makers["pecron"].stations || [], &(&1["id"] == device))
    station && HomeAssistant.station_model("pecron", station["model"])
  end

  @doc false
  def handle_event("maker:status", %{"maker" => maker, "state" => state} = params, socket)
      when maker in @makers and state in @states do
    error = if params["error"] in @errors, do: params["error"]
    link = %{socket.assigns.makers[maker] | state: state, error: error}

    # The controls are only for a generation of the link: a new token or
    # a disconnect ends them. In a different state, a control that waits
    # gets its end from the hook, with its error.
    controls =
      if state in ~w(none connecting),
        do: Map.reject(socket.assigns.maker_control, fn {{m, _d, _p}, _v} -> m == maker end),
        else: socket.assigns.maker_control

    {:halt,
     assign(socket, makers: Map.put(socket.assigns.makers, maker, link), maker_control: controls)}
  end

  def handle_event("maker:status", _params, socket), do: {:halt, socket}

  # The stations of the account. A payload that the page cannot read
  # changes nothing. A new state of a switch ends the error of its last
  # control.
  def handle_event("maker:stations", %{"maker" => maker, "stations" => stations}, socket)
      when maker in @makers do
    case read_stations(stations) do
      :error ->
        {:halt, socket}

      stations ->
        old = socket.assigns.makers[maker].stations || []

        state = fn list, device, part ->
          Enum.find_value(list, &(&1["id"] == device && &1[part]))
        end

        controls =
          Map.reject(socket.assigns.maker_control, fn
            {{^maker, device, part}, {:error, _}} ->
              state.(stations || [], device, part) != state.(old, device, part)

            _control ->
              false
          end)

        # The switches of each station of a new list. With no list, the
        # switches of the last list stay.
        old_link = socket.assigns.makers[maker]

        switches =
          if stations,
            do:
              Map.new(stations, &{&1["id"], Enum.filter(@switch_parts, fn part -> &1[part] end)}),
            else: old_link.switches

        link = %{old_link | stations: stations, switches: switches}

        {:halt,
         assign(socket,
           makers: Map.put(socket.assigns.makers, maker, link),
           maker_control: controls
         )}
    end
  end

  def handle_event("maker:stations", _params, socket), do: {:halt, socket}

  # The end of a control: only for a control that waits.
  def handle_event("maker:control_done", %{"maker" => maker} = params, socket)
      when maker in @makers do
    key = {maker, params["device"], params["part"]}
    error = params["error"]

    case socket.assigns.maker_control do
      %{^key => {:pending, _on}} = controls when error in [nil | @errors] ->
        controls =
          if error, do: Map.put(controls, key, {:error, error}), else: Map.delete(controls, key)

        {:halt, assign(socket, :maker_control, controls)}

      _controls ->
        {:halt, socket}
    end
  end

  def handle_event("maker:control_done", _params, socket), do: {:halt, socket}

  def handle_event("maker_disconnect", %{"maker" => maker}, socket) when maker in @makers,
    do: {:halt, LiveView.push_event(socket, "maker:disconnect", %{maker: maker})}

  def handle_event("maker_disconnect", _params, socket), do: {:halt, socket}
  def handle_event(_event, _params, socket), do: {:cont, socket}

  @doc """
  The stations from the hook: `nil`, a list of stations, or `:error`. A
  station with an id that the page cannot read makes the payload an
  error. Else the page tells that the account does not have the station.
  A number that the page cannot read is `nil`, so one number does not
  stop the other stations. A battery is from 0 to 100 %, and a power from
  0 to 1,000,000 W. A name or a model that is too long is `nil`, and so is
  a switch with a state that the page does not know.
  """
  def read_stations(nil), do: nil

  def read_stations(stations) when is_list(stations) and length(stations) <= @max_stations do
    read = Enum.map(stations, &read_station/1)
    if Enum.any?(read, &is_nil/1), do: :error, else: read
  end

  def read_stations(_stations), do: :error

  defp read_station(%{"id" => id} = station) do
    numbers = Map.new(@numbers, &{&1, number(&1, station[&1])})
    switches = Map.new(@switch_parts, &{&1, if(station[&1] in ~w(on off), do: station[&1])})

    if Pecron.id?(id) do
      numbers
      |> Map.merge(switches)
      |> Map.merge(%{
        "id" => id,
        "name" => text(station["name"]),
        "model" => text(station["model"]),
        "online" => station["online"] == true
      })
    end
  end

  defp read_station(_station), do: nil

  defp number("battery", value) when is_number(value) and value >= 0 and value <= 100, do: value
  defp number("battery", _value), do: nil
  defp number(_part, value) when is_number(value) and value >= 0 and value <= 1_000_000, do: value
  defp number(_part, _value), do: nil

  defp text(value) when is_binary(value) and byte_size(value) <= @max_text, do: value
  defp text(_value), do: nil

  @doc "The state of the link to a maker, in words."
  def status(%{state: "loading"}, _maker), do: nil
  def status(%{state: "none"}, _maker), do: "Not connected."
  def status(%{state: "connecting"}, maker), do: "The app connects to #{name(maker)}."

  def status(%{state: "connected", stations: stations}, maker),
    do: "Connected to #{name(maker)}: #{Format.count(length(stations || []), "station")}."

  def status(%{state: "offline"}, maker),
    do: "The app cannot reach #{name(maker)} now. It tries again in 30 seconds."

  def status(%{state: "refused"}, maker),
    do: "#{name(maker)} does not accept the token. Make a new token and connect again."

  @doc "Why the last step did not work, in words."
  def message("format", "pecron"), do: "A token of Pecron starts with phk_. Copy all of it."

  def message("storage", _maker),
    do: "This browser cannot keep the token. Look at the settings of the site."

  def message("token", maker), do: "#{name(maker)} does not accept the token."

  def message("denied", maker),
    do:
      "#{name(maker)} did not let the app turn the outlets on or off. On app.pecron.com, look at the option \"Allow HA to send control commands\"."

  def message("unreachable", maker), do: "#{name(maker)} does not answer now."
  def message("offline", _maker), do: "The app cannot reach its server. Look at the network."

  def message("timeout", _maker),
    do: "The app got no answer in 20 seconds. Look at the network, and try again later."

  def message("failed", maker), do: "#{name(maker)} did not do it. Try again."

  @doc """
  The state of a switch of a station of a maker (`station/2`), in words. A
  part that the station does not have gets the same words, also with no
  link.
  """
  def switch_text(%{state: "none"}, maker), do: "#{name(maker)} has no switch for it."

  def switch_text(%{online: false}, maker),
    do: "The app has no link to #{name(maker)} now."

  def switch_text(%{pending: true}, maker), do: "#{name(maker)} turns it on."
  def switch_text(%{pending: false}, maker), do: "#{name(maker)} turns it off."

  def switch_text(switch, maker) do
    error = switch.error && message(switch.error, maker)

    state =
      case switch.state do
        "on" -> "It is on."
        "off" -> "It is off."
        "unavailable" -> "#{name(maker)} cannot reach the station now."
        nil -> "The app waits for its state."
      end

    Enum.join(List.wrap(error) ++ [state], " ")
  end

  attr :makers, :map, required: true
  attr :maker, :string, required: true

  @doc """
  The card of the direct link to a maker, in Settings. It has the state of
  the link, and the field of the token with the key Connect, or the key
  Disconnect.
  """
  def card(assigns) do
    assigns = assign(assigns, link: assigns.makers[assigns.maker], name: name(assigns.maker))

    ~H"""
    <div id={"#{@maker}-card"} lang="en" class="space-y-2">
      <h2 class="text-lg font-bold">{@name}</h2>
      <p class="text-sm">
        See your {@name} stations from anywhere, with no Home Assistant, and turn their outlets on and off.
        The token stays on this device. Each request goes through the server of the app, which keeps no token.
      </p>
      <p class="text-sm">
        The token has the same access as your account: it reads your stations and turns their outlets on and off.
        On the portal, the options "Exposed devices" and "Allow HA to send control commands" choose the stations that the app sees, and the controls that it can send.
      </p>
      <%!-- The status takes the focus after Connect and Disconnect: the
        form or the key goes. --%>
      <p id={"#{@maker}-status"} role="status" class="text-sm font-medium" tabindex="-1">
        {status(@link, @maker)}
      </p>
      <p
        :if={@link.error && @link.error != "token"}
        id={"#{@maker}-error"}
        role="alert"
        class="text-sm text-error"
      >
        {message(@link.error, @maker)}
      </p>
      <form
        :if={@link.state in ~w(none refused)}
        id={"#{@maker}-form"}
        data-maker={@maker}
        phx-submit={JS.dispatch("maker:connect") |> JS.dispatch("diy:focus", to: "##{@maker}-status")}
        class="flex flex-wrap gap-2 items-end"
      >
        <label>
          <span class="text-sm">Your token of {@name}</span>
          <input
            name="token"
            type="password"
            autocomplete="off"
            spellcheck="false"
            placeholder="phk_…"
            class="input input-sm w-72 max-w-full block"
          />
        </label>
        <button class="btn btn-sm">Connect</button>
      </form>
      <p :if={@link.state in ~w(none refused)} class="text-xs opacity-70">
        Make the token on app.pecron.com: sign in with the account of the Pecron app, then make a long-lived token. You can stop the token there at any time.
      </p>
      <button
        :if={@link.state in ~w(connecting connected offline refused)}
        type="button"
        id={"#{@maker}-disconnect"}
        phx-click={JS.push("maker_disconnect") |> JS.dispatch("diy:focus", to: "##{@maker}-status")}
        phx-value-maker={@maker}
        class="btn btn-sm"
      >
        Disconnect
      </button>
    </div>
    """
  end
end
