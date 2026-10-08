defmodule DIYWeb.HomeLive do
  @moduledoc """
  The pages of a build. The build comes from the device (`DIYWeb.Device`).

  - `/` (`:front`): the two doors, the ZIP code and the preset of a new
    build. Then the front of the house, with the bill estimate.
  - `/inside` (`:inside`): the rooms, one at a time. A swipe goes to the
    next room of a floor, or to a different floor. `?item=ID` opens an
    item, and `?add=ROOM` the list of the items for a room.
  - `/estimate` (`:estimate`): the math of the estimate, month by month.
  - `/settings` (`:settings`): the place, the price, the numbers of the
    house, and the file of the build.

  The weather of the ZIP code (`DIY.Weather`) and the utility area of a
  Texas ZIP code (`DIY.Market`) come in the background.
  """
  use DIYWeb, :live_view

  @power_types ~w(power_station solar_panels transfer_switch ev)

  alias DIY.{Bill, Build, Catalog, Estimate, House, Market, Power, Prices, Usage, Weather}
  alias DIYWeb.{Device, Format}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Small Steps Home")
     |> assign(:weather, %{zip: nil, status: :none, climate: nil})
     |> assign(:market, %{zip: nil, status: :none})
     |> assign(:estimate, %{ready: false, missing: []})
     |> assign(:full, %{ready: false, missing: []})
     |> assign(:power, nil)
     |> assign(:bill, nil)
     |> assign(:whatif, nil)
     |> assign(:price, nil)
     |> assign(:item, nil)
     |> assign(:add, nil)
     |> allow_upload(:build_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 512 * 1024,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    item = if socket.assigns.live_action == :inside, do: params["item"]

    {:noreply,
     socket
     # The error of a field is for the item that the sheet showed.
     |> assign(:item_error, if(item == socket.assigns[:item], do: socket.assigns[:item_error]))
     |> assign(:item, item)
     |> assign(:add, if(socket.assigns.live_action == :inside, do: params["add"]))}
  end

  @doc false
  # A build from the device (DIYWeb.Device): update the data of the pages.
  def build_changed(socket), do: refresh(socket)

  ## The events

  @impl true
  # No change before the page has the build of the device.
  def handle_event(_event, _params, %{assigns: %{build: nil}} = socket), do: {:noreply, socket}

  def handle_event("door", %{"door" => door}, socket) do
    case Build.choose_door(socket.assigns.build, door) do
      {:ok, build} -> {:noreply, put(socket, build)}
      {:error, :door} -> {:noreply, socket}
    end
  end

  def handle_event("zip", %{"zip" => zip}, socket) when is_binary(zip) do
    case Build.set_zip(socket.assigns.build, zip) do
      {:ok, build} ->
        {:noreply, socket |> assign(:zip_error, nil) |> put(build)}

      {:error, :zip} ->
        {:noreply,
         assign(
           socket,
           :zip_error,
           "The app does not know this ZIP code. Give 5 digits, for example 75070."
         )}
    end
  end

  def handle_event("preset", %{"preset" => preset}, socket) when is_map(preset) do
    case preset(preset, socket.assigns.build.door) do
      {:ok, {house, rooms, items}} ->
        build = Build.put_house(socket.assigns.build, house, rooms, items)
        {:noreply, put(socket, build)}

      {:error, :lot} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Give the lot in square feet, from 100 to 100,000,000, or leave it empty."
         )}

      {:error, :house} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Choose one of each: the size, the age, the floors and the heat."
         )}
    end
  end

  def handle_event("hint", %{"hint" => hint}, socket) do
    case Build.close_hint(socket.assigns.build, hint) do
      {:ok, build} -> {:noreply, put(socket, build)}
      {:error, :hint} -> {:noreply, socket}
    end
  end

  def handle_event("add_item", %{"room" => room, "type" => type}, socket) do
    case Build.add_item(socket.assigns.build, room, type) do
      {:ok, build, id} ->
        {:noreply, socket |> put(build) |> push_patch(to: ~p"/inside?#{[item: id]}")}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("item", %{"item_id" => id, "item" => values}, socket) when is_map(values) do
    case Build.update_item(socket.assigns.build, id, values) do
      {:ok, build} -> {:noreply, socket |> assign(:item_error, nil) |> put(build)}
      {:error, {:param, key}} -> {:noreply, assign(socket, :item_error, key)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  # The sums of a meter file, from the hook UsageFile: the file stays on
  # the device.
  def handle_event("usage", params, socket) do
    case Usage.read(params) do
      {:ok, usage} ->
        {:noreply,
         socket
         |> put(Build.set_usage(socket.assigns.build, usage))
         |> put_flash(
           :info,
           "The page has #{Format.count(length(usage.months), "month")} of your usage. The file stayed on this device."
         )}

      :error ->
        {:noreply, put_flash(socket, :error, "The app cannot read the usage of this file.")}
    end
  end

  def handle_event("usage_error", %{"error" => error}, socket) when is_binary(error) do
    {:noreply, put_flash(socket, :error, String.slice(error, 0, 200))}
  end

  def handle_event("clear_usage", _params, socket) do
    {:noreply, put(socket, Build.set_usage(socket.assigns.build, nil))}
  end

  def handle_event("check_item", %{"id" => id}, socket) do
    with_build(socket, Build.check_item(socket.assigns.build, id))
  end

  def handle_event("move_item", %{"item_id" => id, "room" => room}, socket) do
    with_build(socket, Build.move_item(socket.assigns.build, id, room))
  end

  def handle_event("delete_item", %{"id" => id}, socket) do
    case Build.delete_item(socket.assigns.build, id) do
      {:ok, build} -> {:noreply, socket |> put(build) |> push_patch(to: ~p"/inside")}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event(
        "add_room",
        %{"room" => %{"name" => name, "level" => level, "place" => place}},
        socket
      ) do
    place = Enum.find(Catalog.places(), &(Atom.to_string(&1) == place))

    case Build.add_room(socket.assigns.build, name, level, place) do
      {:ok, build, _id} -> {:noreply, put(socket, build)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, room_error(reason))}
    end
  end

  def handle_event("rename_room", %{"room_id" => id, "name" => name}, socket) do
    with_build(socket, Build.rename_room(socket.assigns.build, id, name))
  end

  def handle_event("delete_room", %{"id" => id}, socket) do
    with_build(socket, Build.delete_room(socket.assigns.build, id))
  end

  def handle_event("price", %{"price" => price}, socket) when is_binary(price) do
    result =
      case Float.parse(String.trim(price)) do
        _ when price == "" -> Build.set_price(socket.assigns.build, nil)
        {cents, ""} -> Build.set_price(socket.assigns.build, cents)
        _ -> {:error, :price}
      end

    case result do
      {:ok, build} ->
        {:noreply, put(socket, build)}

      {:error, :price} ->
        {:noreply,
         put_flash(socket, :error, "Give the price in cents for one kWh, for example 14.5.")}
    end
  end

  def handle_event("house", %{"house" => values}, socket) when is_map(values) do
    changes =
      for {key, value} <- values, key in ~w(size year floors), into: %{} do
        {String.to_existing_atom(key), parse_int(value)}
      end

    changes = if values["heat"], do: Map.put(changes, :heat, values["heat"]), else: changes

    case Build.update_house(socket.assigns.build, changes) do
      {:ok, build} ->
        {:noreply, put(socket, build)}

      {:error, :floors} ->
        {:noreply, put_flash(socket, :error, "Remove the rooms of the top floor first.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Give numbers in the limits of each field.")}
    end
  end

  # The flags of an item: "planned" and "backup", "true" or "false".
  def handle_event("flag", %{"item_id" => id} = params, socket) do
    with_build(
      socket,
      with {:ok, build} <- flag(socket.assigns.build, id, :planned, params["planned"]) do
        flag(build, id, :backup, params["backup"])
      end
    )
  end

  def handle_event("plan_done", _params, socket) do
    build =
      Enum.reduce(socket.assigns.build.items, socket.assigns.build, fn item, build ->
        if item.planned,
          do: elem(Build.flag_item(build, item.id, :planned, false), 1),
          else: build
      end)

    {:noreply,
     socket |> put(build) |> put_flash(:info, "The planned items are part of your house now.")}
  end

  def handle_event("power", params, socket) do
    case Power.update(socket.assigns.build.power, params) do
      {:ok, power} ->
        {:noreply, put(socket, Build.set_power(socket.assigns.build, power))}

      {:error, field} ->
        {:noreply, put_flash(socket, :error, power_error(field))}
    end
  end

  def handle_event("utility", %{"choice" => choice}, socket) do
    market = Market.by_user(socket.assigns.build.market, choice == "true")
    {:noreply, put(socket, Build.set_market(socket.assigns.build, market))}
  end

  def handle_event("retry", _params, socket) do
    {:noreply,
     socket
     |> assign(:weather, %{zip: nil, status: :none, climate: nil})
     |> assign(:market, %{zip: nil, status: :none})
     |> refresh()}
  end

  def handle_event("restart", _params, socket) do
    {:noreply, socket |> put(Build.restart(socket.assigns.build)) |> push_patch(to: ~p"/")}
  end

  def handle_event("upload", _params, socket), do: {:noreply, socket}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp flag(build, id, flag, value) when value in ["true", "false"],
    do: Build.flag_item(build, id, flag, value == "true")

  defp flag(build, _id, _flag, _value), do: {:ok, build}

  defp with_build(socket, {:ok, build}), do: {:noreply, put(socket, build)}
  defp with_build(socket, {:error, _reason}), do: {:noreply, socket}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  # A build from a file (an export of the app).
  defp handle_progress(:build_file, entry, socket) do
    if entry.done? do
      [text] =
        consume_uploaded_entries(socket, :build_file, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)

      case Build.import(socket.assigns.build, text) do
        {:ok, build} ->
          {:noreply,
           socket |> put(build) |> put_flash(:info, "The page shows the build of the file now.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "The file is not a build of this app.")}
      end
    else
      {:noreply, socket}
    end
  end

  # The house of a preset form.
  defp preset(preset, door) do
    size = lookup(House.sizes(), preset["size"]) || parse_int(preset["size_sqft"])

    year =
      if door == "planning", do: Date.utc_today().year, else: lookup(House.ages(), preset["age"])

    floors = parse_int(preset["floors"])
    heat = preset["heat"]
    house = %{size: size, year: year, floors: floors, heat: heat, lot: nil}

    with true <- (is_integer(size) and size in 200..20_000) || {:error, :house},
         true <- is_integer(year) || {:error, :house},
         true <- floors in 1..3 || {:error, :house},
         true <- heat in Build.heats() || {:error, :house},
         {:ok, lot} <- lot(preset["lot"]) do
      house = %{house | lot: lot}
      {:ok, if(preset["start"] == "scratch", do: House.scratch(house), else: House.preset(house))}
    end
  end

  # The lot of a preset form: empty, or a number of square feet.
  defp lot(text) when text in [nil, ""], do: {:ok, nil}

  defp lot(text) do
    case parse_int(text) do
      lot when is_integer(lot) and lot in 100..100_000_000 -> {:ok, lot}
      _ -> {:error, :lot}
    end
  end

  defp power_error(:night_cents),
    do: "Give the price at night in cents, from 0 to 200, or leave it empty."

  defp power_error(field) when field in [:night_from, :night_to], do: "Give an hour from 0 to 23."
  defp power_error(:night), do: "The night must start and end at different hours."
  defp power_error(:buyback_cents), do: "Give the price in cents, from 0 to 200."
  defp power_error(:reserve), do: "Give a part from 0 to 100%."
  defp power_error(:mode), do: "Choose how you use the batteries."

  defp room_error(:name), do: "Give the room a name."
  defp room_error(:level), do: "Choose a floor of the house."
  defp room_error(:place), do: "Choose a place: inside, outside or the roof."
  defp room_error(:house), do: "Choose a house first."

  defp lookup(options, key) do
    Enum.find_value(options, fn {k, _label, value} -> if k == key, do: value end)
  end

  ## The build and its data

  # Changes the build, and updates the data of the pages. The same build
  # makes no change.
  defp put(%{assigns: %{build: build}} = socket, build), do: socket
  defp put(socket, build), do: socket |> Device.put_build(build) |> refresh()

  defp refresh(socket) do
    socket
    |> load_weather()
    |> load_market()
    |> estimate()
  end

  defp load_weather(%{assigns: %{build: %{zip: nil}}} = socket), do: socket

  defp load_weather(%{assigns: %{build: %{zip: zip}, weather: %{zip: zip}}} = socket), do: socket

  defp load_weather(%{assigns: %{build: %{zip: zip}}} = socket) do
    {:ok, place} = DIY.Zip.lookup(zip)

    socket
    |> assign(:weather, %{zip: zip, status: :loading, climate: nil})
    |> start_async({:weather, zip}, fn -> Weather.climate(place.lat, place.lon) end)
  end

  defp load_market(
         %{assigns: %{build: %{zip: zip, market: nil}, market: %{zip: loaded}}} = socket
       )
       when is_binary(zip) and zip != loaded do
    case DIY.Zip.lookup(zip) do
      {:ok, %{state: "TX"}} ->
        socket
        |> assign(:market, %{zip: zip, status: :loading})
        |> start_async({:market, zip}, fn -> Market.fetch(zip) end)

      _other ->
        socket
    end
  end

  defp load_market(socket), do: socket

  # The estimate of the house of today (with no planned item), its power
  # and its bill, the estimate with the planned items (for the math of an
  # item), and the what-if (DIY.Power).
  defp estimate(socket) do
    build = socket.assigns.build
    climate = socket.assigns.weather.climate
    today = Build.today(build)
    estimate = Estimate.run(today, climate)
    full = if today == build, do: estimate, else: Estimate.run(build, climate)
    price = if build.zip, do: Prices.price(build)

    {power, bill, whatif} =
      if estimate.ready do
        power = Power.run(today, estimate, climate, price.cents)

        {power, Bill.run(estimate, power),
         Power.whatif(build, estimate, full, climate, price.cents)}
      else
        {nil, nil, nil}
      end

    socket
    |> assign(:estimate, estimate)
    |> assign(:full, full)
    |> assign(:price, price)
    |> assign(:power, power)
    |> assign(:bill, bill)
    |> assign(:whatif, whatif)
  end

  @impl true
  def handle_async({:weather, zip}, result, socket) do
    weather =
      case result do
        {:ok, {:ok, climate}} ->
          %{zip: zip, status: :ok, climate: climate}

        {:ok, {:error, message}} ->
          %{zip: zip, status: {:error, message}, climate: nil}

        {:exit, _reason} ->
          %{zip: zip, status: {:error, "The weather service did not answer."}, climate: nil}
      end

    if socket.assigns.weather.zip == zip,
      do: {:noreply, socket |> assign(:weather, weather) |> estimate()},
      else: {:noreply, socket}
  end

  def handle_async({:market, zip}, result, socket) do
    build = socket.assigns.build

    cond do
      build.zip == zip and build.market == nil ->
        {:noreply, market(socket, zip, result)}

      # The answer of a ZIP code that the build does not have now: the page
      # throws it away, and asks again if the build gets that ZIP code back.
      socket.assigns.market.zip == zip ->
        {:noreply, assign(socket, :market, %{zip: nil, status: :none})}

      true ->
        {:noreply, socket}
    end
  end

  defp market(socket, zip, {:ok, {:ok, market}}) do
    socket
    |> assign(:market, %{zip: zip, status: :ok})
    |> put(Build.set_market(socket.assigns.build, market))
  end

  defp market(socket, zip, {:ok, {:error, message}}),
    do: assign(socket, :market, %{zip: zip, status: {:error, message}})

  defp market(socket, zip, {:exit, _reason}),
    do: assign(socket, :market, %{zip: zip, status: {:error, "Power to Choose did not answer."}})

  ## The pages

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={nav?(@build)}
      power={power?(@build)}
      action={@live_action}
      saved={Device.saved?(assigns)}
    >
      <div id="device" phx-hook="Device" class="hidden"></div>
      <noscript>
        <p class="alert alert-warning">
          This app needs JavaScript. Turn on JavaScript in the browser.
        </p>
      </noscript>

      <p :if={is_nil(@build)} class="py-16 text-center opacity-70">
        The page reads your build from this device.
      </p>

      <%= if @build do %>
        <%= cond do %>
          <% is_nil(@build.door) -> %>
            <DIYWeb.Start.doors />
          <% is_nil(@build.zip) -> %>
            <DIYWeb.Start.zip build={@build} error={assigns[:zip_error]} />
          <% is_nil(@build.house) -> %>
            <DIYWeb.Start.preset build={@build} />
          <% @live_action == :inside -> %>
            <DIYWeb.Inside.inside
              build={@build}
              estimate={@full}
              bill={@bill}
              price={@price}
              item={@item}
              add={@add}
              item_error={assigns[:item_error]}
            />
          <% @live_action == :estimate -> %>
            <DIYWeb.Math.estimate
              build={Build.today(@build)}
              planned={Enum.count(@build.items, & &1.planned)}
              estimate={@estimate}
              power={@power}
              bill={@bill}
              price={@price}
              weather={@weather}
            />
          <% @live_action == :power -> %>
            <DIYWeb.PowerPage.page
              build={@build}
              power={@power}
              whatif={@whatif}
              price={@price}
            />
          <% @live_action == :settings -> %>
            <DIYWeb.Settings.settings
              build={@build}
              price={@price}
              market={@market}
              uploads={@uploads}
            />
          <% true -> %>
            <DIYWeb.Front.front
              build={@build}
              estimate={@estimate}
              bill={@bill}
              whatif={@whatif}
              price={@price}
              weather={@weather}
              market={@market}
            />
        <% end %>
      <% end %>
    </Layouts.app>
    """
  end

  defp nav?(%Build{house: house}) when is_map(house), do: true
  defp nav?(_build), do: false

  # The page Power is for a house with power equipment, a car, or a plan.
  defp power?(%Build{items: items}),
    do: Enum.any?(items, &(&1.planned or &1.type in @power_types))

  defp power?(_build), do: false
end
