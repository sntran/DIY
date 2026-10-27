defmodule DIYWeb.HomeLive do
  @moduledoc """
  The pages of a build. The build comes from the device (`DIYWeb.Device`).

  - `/` (`:front`): the two doors, the ZIP code and the preset of a new
    build. Then the front of the house, with the bill estimate.
  - `/inside` (`:inside`): the plan of the house at scale, cut open
    (`DIYWeb.Inside`). `?item=ID` opens an item, `?add=ROOM` the list of
    the items for a room, and `?room=ROOM` chooses a room. `?sheet=room`
    changes the chosen room, and `?sheet=new_room` adds a room.
  - `/estimate` (`:estimate`): the math of the estimate, month by month.
  - `/van` (`:van`): the build of a camper van (`?id=ID`), with its zones,
    an item (`?item=ID`) and the items for a zone (`?add=ZONE`).
  - `/settings` (`:settings`): the place, the price, the numbers of the
    house, and the file of the build.

  The numbers of the house come from the house only (`DIY.Build.house_view/1`):
  a van has its own budgets (`DIY.Van`).

  The weather of the ZIP code (`DIY.Weather`) and the utility area of a
  Texas ZIP code (`DIY.Market`) come in the background.
  """
  use DIYWeb, :live_view

  @power_types ~w(power_station solar_panels transfer_switch ev)

  # The time to ask for the sky at the house again: 30 minutes, or sooner
  # at the next change of the time of day. After an error: 5 minutes.
  @sky_again 30 * 60 * 1000
  @sky_retry 5 * 60 * 1000

  # The sides of the size of an item, for − and +.
  @sides %{"w" => {:w, "Width"}, "d" => {:d, "Depth"}, "h" => {:h, "Height"}}

  # The time in ms that the status of − and + stays empty after a tap at an
  # end of the range. Some screen readers do not hear two changes that come
  # one immediately after the other.
  @said_again 100

  # The most short links of one page (DIY.Links).
  @max_short 20

  alias DIY.{
    Bill,
    Build,
    Catalog,
    EFL,
    Estimate,
    House,
    Layout,
    Lesson,
    Market,
    Plan,
    PlanLink,
    Power,
    Prices,
    Links,
    Share,
    Usage,
    Van,
    Weather
  }

  alias DIYWeb.{
    Cutaway,
    Device,
    Format,
    HomeAssistant,
    Inside,
    Outside,
    Picture,
    PlanChart,
    Scene,
    Stage,
    VanCutaway
  }

  # The key of the address of the WebSocket (DIYWeb.Address). The first
  # render has no WebSocket and no events: it has no key.
  defp address(socket) do
    case connected?(socket) && get_connect_info(socket, :peer_data) do
      %{address: ip} -> DIYWeb.Address.key(ip)
      _none -> nil
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Small Steps Home")
     |> assign(:weather, %{zip: nil, status: :none, climate: nil})
     # The sky at the house now (DIY.Sky). Also the sky that the person
     # chose for the picture: "now", or a time of day and a weather.
     |> assign(:sky, %{zip: nil, status: :none, now: nil, timer: nil})
     |> assign(:sky_pick, %{"time" => "now", "weather" => "now"})
     |> assign(:market, %{zip: nil, status: :none})
     |> assign(:estimate, %{ready: false, missing: []})
     |> assign(:full, %{ready: false, missing: []})
     |> assign(:power, nil)
     |> assign(:bill_month, nil)
     |> assign(:bill, nil)
     |> assign(:whatif, nil)
     |> assign(:shares, %{})
     |> assign(:lesson_step, nil)
     |> assign(:plan_id, nil)
     |> assign(:efl, nil)
     |> assign(checks: nil, answers: %{})
     |> assign(:hint, false)
     |> assign(:price, nil)
     |> assign(:item, nil)
     |> assign(:add, nil)
     |> assign(:van_id, nil)
     |> assign(:scene, nil)
     |> assign(:van_scene, nil)
     |> assign(:van_view, nil)
     |> assign(:shown_van, nil)
     |> assign(:cutaway, nil)
     |> assign(ghosts: [], ha_count: 0, ha_away: 0, ghost_key: nil)
     |> assign(:outside, nil)
     |> assign(:room, nil)
     |> assign(:sheet, nil)
     |> assign(:status, nil)
     |> assign(shared: nil, meta: nil, adopt: nil, share: nil, share_zip: true, origin: "")
     |> assign(:plan_link, nil)
     # The short links that this page made: the id of each DATA (DIY.Links).
     # The key of the address counts the links of the person in a day.
     |> assign(share_links: %{}, share_short: nil, address: address(socket))
     |> allow_upload(:build_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 512 * 1024,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    sheets? = socket.assigns.live_action in [:inside, :van]
    item = if sheets?, do: params["item"]

    {:noreply,
     socket
     # The error of a field is for the item that the sheet showed.
     |> assign(:item_error, if(item == socket.assigns[:item], do: socket.assigns[:item_error]))
     |> assign(:item_said, if(item == socket.assigns[:item], do: socket.assigns[:item_said]))
     |> assign(:item, item)
     # The error of a ZIP code is for the page that showed it.
     |> assign(zip_error: nil, zip_text: nil)
     |> item_frames()
     |> assign(:add, if(sheets?, do: params["add"]))
     # A new sheet Add starts with no search.
     |> assign(
       :add_query,
       if(params["add"] == socket.assigns[:add], do: socket.assigns[:add_query] || "", else: "")
     )
     |> assign(:room, params["room"])
     |> assign(:sheet, params["sheet"])
     |> ha_rooms(socket.assigns.live_action, params["sheet"])
     |> assign(:van_id, params["id"])
     |> pictures()
     |> assign(:lesson_step, parse_int(params["step"]))
     |> assign(checks: nil, answers: %{})
     |> assign(:hint, false)
     |> assign(:origin, origin(uri))
     |> shared(params)
     |> plan_link(params)
     |> share()}
  end

  # The scheme, the host and the port of the page, for the full links of
  # a shared house.
  defp origin(uri), do: URI.to_string(%{URI.parse(uri) | path: nil, query: nil, fragment: nil})

  # The page of the link of a shared house (DIY.Share): the house, its
  # title, and the tags of the preview. The title and the preview are in
  # the language of the link.
  defp shared(%{assigns: %{live_action: :shared}} = socket, %{"data" => data}) do
    case Share.resolve(data) do
      {:ok, build, summary} ->
        {title, description} =
          Gettext.with_locale(DIY.Gettext, summary.locale, fn ->
            {Picture.title(build, summary), share_description(summary)}
          end)

        origin = socket.assigns.origin

        socket
        |> assign(:page_title, title)
        |> assign(:adopt, nil)
        |> assign(
          :shared,
          {:ok, %{build: build, summary: summary, title: title, view: Outside.view(build)}}
        )
        |> assign(:meta, %{
          title: title,
          description: description,
          image: origin <> ~p"/s/#{data}/picture.png",
          url: origin <> ~p"/s/#{data}"
        })

      {:error, reason} ->
        socket
        |> assign(:page_title, "Small Steps Home")
        |> assign(:shared, {:error, reason})
        |> assign(:meta, nil)
    end
  end

  defp shared(%{assigns: %{shared: nil}} = socket, _params), do: socket

  defp shared(socket, _params),
    do: assign(socket, shared: nil, meta: nil, adopt: nil, page_title: "Small Steps Home")

  # The page of a link of plans (DIY.PlanLink): the plans, the title, and
  # the tags of the preview. They are in English, as the plan lesson.
  defp plan_link(%{assigns: %{live_action: :plan_link}} = socket, %{"data" => data}) do
    case PlanLink.decode(data) do
      {:ok, plans} ->
        title = PlanChart.title(plans)
        origin = socket.assigns.origin

        socket
        |> assign(page_title: title, plan_link: {:ok, plans})
        |> assign(:meta, %{
          title: title,
          description:
            Enum.map_join(plans, ", ", & &1.name) <>
              ". The price for each kWh changes with the use of a month. Small Steps Home shows the bill of each month for your own house.",
          image: origin <> ~p"/p/#{data}/picture.png",
          url: origin <> ~p"/p/#{data}"
        })

      {:error, reason} ->
        assign(socket, page_title: "Small Steps Home", plan_link: {:error, reason}, meta: nil)
    end
  end

  defp plan_link(%{assigns: %{plan_link: nil}} = socket, _params), do: socket

  defp plan_link(socket, _params),
    do: assign(socket, plan_link: nil, meta: nil, page_title: "Small Steps Home")

  defp share_description(%{cost: nil}),
    do: gettext("Small Steps Home shows where the electricity of a house goes.")

  defp share_description(%{cost: cost}),
    do:
      gettext(
        "%{cost} for the electricity of a year. Small Steps Home shows where the electricity of a house goes.",
        cost: Format.money(cost)
      )

  # The frames of the model of the open item (DIYWeb.Stage), on the page
  # Rooms and on the page Van. The LiveView keeps them while the item is
  # open: a render does not send them again. The first frame of an item in
  # a van is from the camera of the van plan.
  defp item_frames(socket) do
    shown =
      with action when action in [:inside, :van] <- socket.assigns.live_action,
           id when is_binary(id) <- socket.assigns[:item],
           %Build{} = build <- socket.assigns[:build],
           {:ok, item} <- Build.item(build, id),
           {:ok, room} <- Build.room(build, item.room),
           do:
             {DIYWeb.Icon.Shapes.look(item),
              if(Build.van_level?(room.level), do: :van, else: :house)},
           else: (_none -> nil)

    case socket.assigns[:item_frames] do
      %{shown: ^shown} ->
        socket

      _other ->
        frames = with {type, plan} <- shown, do: Map.put(Stage.frames(type, plan), :shown, shown)
        assign(socket, :item_frames, frames)
    end
  end

  # The sheet of the match of the rooms reads the areas of Home Assistant
  # each time that it opens.
  defp ha_rooms(socket, :inside, "ha_rooms"),
    do: socket |> assign(:ha_sync, nil) |> HomeAssistant.fetch_rooms()

  defp ha_rooms(socket, _action, _sheet), do: socket

  @doc false
  # A build from the device (DIYWeb.Device): update the data of the pages.
  # Energy data that came before the first build changes it one time. A
  # build of a different tab does not: two tabs with different data must
  # not change the build again and again.
  def build_changed(%{assigns: %{ha_energy_late: true}} = socket),
    do: socket |> assign(:ha_energy_late, false) |> refresh() |> new_meter_months()

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

  # A ZIP code, on the start page or in Settings. After an error, the field
  # keeps the text that the person typed (`zip_text`), so the person can
  # correct it.
  def handle_event("zip", %{"zip" => zip}, socket) when is_binary(zip) do
    case Build.set_zip(socket.assigns.build, zip) do
      {:ok, build} ->
        {:noreply, socket |> assign(zip_error: nil, zip_text: nil) |> put(build)}

      {:error, :zip} ->
        {:noreply,
         assign(socket,
           zip_error:
             gettext("The app does not know this ZIP code. Give 5 digits, for example 75070."),
           zip_text: String.slice(zip, 0, 10)
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
           gettext("Give the lot in square feet, from 100 to 100,000,000, or leave it empty.")
         )}

      {:error, :house} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Choose one of each: the size, the age, the floors and the heat.")
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
        {:noreply, socket |> put(build) |> push_patch(to: item_path(socket, build, id))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # A tap on a ghost of a device of Home Assistant. Its item comes into the
  # house, with a link to the device, and its panel opens.
  def handle_event("ha_add_device", %{"id" => device}, socket) do
    with %{} = ghost <- Enum.find(socket.assigns.ghosts, &(&1.device == device)),
         {:ok, build, id} <-
           Build.add_device(
             socket.assigns.build,
             ghost.room,
             ghost.type,
             ghost.device,
             ghost.at,
             ghost.values
           ) do
      {:noreply, socket |> put(build) |> push_patch(to: item_path(socket, build, id))}
    else
      _ -> {:noreply, socket}
    end
  end

  # The switch of the item of a device: only when its state is known and
  # no control waits.
  def handle_event("ha_switch", %{"item" => item, "on" => on}, socket)
      when on in ~w(true false) do
    case DIYWeb.HomeAssistant.power(socket.assigns, item) do
      %{device: device, state: state, pending: nil} when state in ~w(on off) ->
        {:noreply, DIYWeb.HomeAssistant.control(socket, device, on == "true")}

      _power ->
        {:noreply, socket}
    end
  end

  # A switch of a part of a power station (its AC or DC outlets). It works
  # only when the state of the part is known and no control of the part
  # waits. Home Assistant must also have a link to the station.
  def handle_event("ha_station_switch", %{"item" => item, "part" => part, "on" => on}, socket)
      when on in ~w(true false) do
    with %{device: device, switches: switches} <-
           DIYWeb.HomeAssistant.station(socket.assigns, item),
         %{state: state, pending: nil, link: link} when state in ~w(on off) and link != false <-
           Enum.find(switches, &(&1.part == part)) do
      {:noreply, DIYWeb.HomeAssistant.control(socket, device, on == "true", part)}
    else
      _station -> {:noreply, socket}
    end
  end

  # A link of a power station to a station of the account of a maker
  # (DIYWeb.MakerLink): only to a station that the page offers. A station of
  # a known model gets the model, when the person did not choose one.
  def handle_event("maker_link", %{"item" => item, "unit" => unit}, socket) do
    with true <- unit in Enum.map(DIYWeb.MakerLink.choices(socket.assigns), & &1.unit),
         {:ok, build} <- Build.link_unit(socket.assigns.build, item, unit) do
      model = DIYWeb.MakerLink.model(socket.assigns, unit)
      {:ok, station} = Build.item(build, item)

      build =
        with true <- model != nil and station.params["model"] == "other",
             {:ok, build} <- Build.update_item(build, item, %{"model" => model}) do
          build
        else
          _ -> build
        end

      {:noreply, put(socket, build)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("maker_unlink", %{"item" => item}, socket) do
    case Build.unlink_unit(socket.assigns.build, item) do
      {:ok, build} ->
        socket = put(socket, build)

        # With no choice, the part of the maker goes with its title: the
        # title of the panel takes the focus.
        socket =
          if DIYWeb.Inside.unit_choices(socket.assigns, item) == [],
            do: push_event(socket, "diy:focus", %{to: "#item-stage-title"}),
            else: socket

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # A switch of the outlets of a station of a maker. It works only when the
  # link is connected, the state of the part is known, and no control of
  # the part waits.
  def handle_event("maker_switch", %{"item" => item, "part" => part, "on" => on}, socket)
      when on in ~w(true false) do
    with %{maker: maker, device: device, switches: switches} <-
           DIYWeb.MakerLink.station(socket.assigns, item),
         %{state: state, pending: nil, link: true} when state in ~w(on off) <-
           Enum.find(switches, &(&1.part == part)) do
      {:noreply, DIYWeb.MakerLink.control(socket, maker, device, part, on == "true")}
    else
      _station -> {:noreply, socket}
    end
  end

  # A new model of a van or of a station gets a status: what changed.
  def handle_event("item", %{"item_id" => id, "item" => values}, socket) when is_map(values) do
    with {:ok, before} <- Build.item(socket.assigns.build, id),
         {:ok, build} <- Build.update_item(socket.assigns.build, id, values) do
      {:ok, item} = Build.item(build, id)
      socket = assign(socket, item_error: nil, item_said: nil)

      if before.params["model"] != item.params["model"],
        do: {:noreply, socket |> say(Inside.model_said(item)) |> put(build)},
        else: {:noreply, put(socket, build)}
    else
      {:error, {:param, key}} -> {:noreply, assign(socket, :item_error, key)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  # A wire from the item of the panel to a different item (`DIYWeb.Wires`).
  # A status tells a screen reader that the wire is there.
  def handle_event("add_wire", %{"from" => from, "to" => to}, socket) do
    case Build.add_wire(socket.assigns.build, from, to) do
      {:ok, build, id} ->
        {:ok, wire} = Build.wire(build, id)
        {:ok, a} = Build.item(build, wire.from)
        {:ok, b} = Build.item(build, wire.to)
        pair = Enum.sort([a.id, b.id])
        n = Enum.count(build.wires, &(Enum.sort([&1.from, &1.to]) == pair))
        number = if n > 1, do: ": wire #{n}", else: ""
        said = "A wire from #{Catalog.name(a)} to #{Catalog.name(b)} is added#{number}."
        {:noreply, socket |> say(said) |> put(build)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # The numbers of a wire. The error of a number shows at its field.
  def handle_event("wire", %{"wire_id" => id, "wire" => values}, socket) when is_map(values) do
    case Build.update_wire(socket.assigns.build, id, values) do
      {:ok, build} -> {:noreply, socket |> assign(item_error: nil, item_said: nil) |> put(build)}
      {:error, :wire} -> {:noreply, socket}
      {:error, key} -> {:noreply, assign(socket, :item_error, {:wire, id, key})}
    end
  end

  def handle_event("delete_wire", %{"id" => id}, socket) do
    case Build.delete_wire(socket.assigns.build, id) do
      {:ok, build} ->
        {:noreply, socket |> say("The wire is removed.") |> put(build)}

      {:error, _reason} ->
        {:noreply, socket}
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
           ngettext(
             "The page has 1 month of your usage. The file stayed on this device.",
             "The page has %{count} months of your usage. The file stayed on this device.",
             length(usage.months)
           )
         )}

      :error ->
        {:noreply,
         put_flash(socket, :error, gettext("The app cannot read the usage of this file."))}
    end
  end

  def handle_event("usage_error", %{"error" => error}, socket) when is_binary(error) do
    # The text comes from the script of the page, in English.
    {:noreply, put_flash(socket, :error, {"en", String.slice(error, 0, 200)})}
  end

  def handle_event("clear_usage", _params, socket) do
    {:noreply, put(socket, Build.set_usage(socket.assigns.build, nil))}
  end

  # The meter of Home Assistant in place of the usage of the build. A house
  # with no smart meter gets one: outside, else inside.
  def handle_event("ha_use_meter", _params, socket) do
    with %{} = usage <- DIYWeb.HomeAssistant.meter_offer(socket.assigns),
         {:ok, build} <- with_meter(socket.assigns.build) do
      {:noreply,
       socket
       |> put(Build.set_usage(build, usage))
       |> put_flash(
         :info,
         ngettext(
           "The page has 1 month of your usage from Home Assistant.",
           "The page has %{count} months of your usage from Home Assistant.",
           length(usage.months)
         )
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  # A tap on − or + of a number of an item (DIYWeb.Inside): the next round
  # value, in the range of the number (`DIY.Catalog.stepped/3`). The panel
  # tells the new value to a screen reader (`say_step/6`).
  def handle_event("step_param", %{"id" => id, "key" => key, "by" => by}, socket) do
    with true <- by in ["-1", "1"],
         {:ok, item} <- Build.item(socket.assigns.build, id),
         %{} = param <-
           Enum.find(
             Catalog.kind(item.type).params,
             &(&1.key == key and &1.type in [:int, :float])
           ) do
      before = item.params[key]
      value = Catalog.stepped(param, before, String.to_integer(by))

      {:noreply, socket} =
        handle_event("item", %{"item_id" => id, "item" => %{key => value}}, socket)

      {:noreply, say_step(socket, id, {:param, key}, param, before, value)}
    else
      _other -> {:noreply, socket}
    end
  end

  # A tap on − or + of a side of the size of an item (`DIYWeb.Inside.place/1`).
  # The side gets the next round number of inches, from 1 to the largest
  # size. The status
  # tells it, as for a number of the item.
  def handle_event("step_size", %{"id" => id, "side" => side, "by" => by}, socket)
      when is_map_key(@sides, side) and by in ["-1", "1"] do
    with {:ok, item} <- Build.item(socket.assigns.build, id) do
      {w, d, h} = Layout.size(item)
      size = %{w: w, d: d, h: h}
      {key, label} = @sides[side]
      param = %{label: label, unit: "in", type: :int, min: 1, max: Layout.max_size()}
      value = Catalog.stepped(param, size[key], String.to_integer(by))

      case Build.size_item(socket.assigns.build, id, %{size | key => value}) do
        {:ok, build} ->
          socket = socket |> assign(:item_error, nil) |> put(build)
          {:noreply, say_step(socket, id, {:size, key}, param, size[key], value)}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("check_item", %{"id" => id}, socket) do
    with_build(socket, Build.check_item(socket.assigns.build, id))
  end

  def handle_event("move_item", %{"item_id" => id, "room" => room}, socket) do
    with_build(socket, Build.move_item(socket.assigns.build, id, room))
  end

  def handle_event("delete_item", %{"id" => id}, socket) do
    build = socket.assigns.build

    with {:ok, item} <- Build.item(build, id),
         {:ok, build} <- Build.delete_item(build, id) do
      {:noreply, socket |> put(build) |> push_patch(to: page_of(socket, item))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("take_to_van", %{"item" => id, "van" => van}, socket),
    do: with_build(socket, Build.take_to_van(socket.assigns.build, id, van))

  # A station of the house goes home from the van. When its panel is open on
  # the page of its van, the panel closes: the station is not in the van now.
  def handle_event("bring_home", %{"item" => id}, socket) do
    open? =
      socket.assigns.item == id and is_binary(socket.assigns[:shown_van]) and
        Enum.any?(
          Van.items(socket.assigns.build, socket.assigns.shown_van),
          &(elem(&1, 1).id == id)
        )

    case Build.bring_home(socket.assigns.build, id) do
      {:ok, build} when open? ->
        {:noreply,
         socket
         |> put(build)
         |> put_flash(:info, gettext("The power station is at home now."))
         |> push_patch(to: plan_path(socket, []))}

      result ->
        with_build(socket, result)
    end
  end

  def handle_event("use_model", %{"id" => id}, socket) do
    case Build.use_model(socket.assigns.build, id) do
      {:ok, build} ->
        {:ok, item} = Build.item(build, id)
        {:noreply, socket |> say(Inside.model_said(item)) |> put(build)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "add_room",
        %{"room" => %{"name" => name, "level" => level, "place" => place}},
        socket
      ) do
    place = Enum.find(Catalog.places(), &(Atom.to_string(&1) == place))

    case Build.add_room(socket.assigns.build, name, level, place) do
      {:ok, build, id} ->
        {:noreply, socket |> put(build) |> push_patch(to: ~p"/inside?#{[room: id]}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, room_error(reason))}
    end
  end

  # The plan at scale (DIYWeb.Inside and DIYWeb.VanPage, and the hook
  # Plan).
  def handle_event("select_room", %{"id" => ""}, socket),
    do: {:noreply, push_patch(socket, to: plan_path(socket, []))}

  def handle_event("select_room", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, push_patch(socket, to: plan_path(socket, room: id))}

  # A tap on an item opens it. In the house, the chosen room stays: the
  # sheet of the item closes back to it.
  def handle_event("open_item", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, push_patch(socket, to: plan_path(socket, keep_room(socket, item: id)))}

  # An item that the person drops on the plan. x and y are its center on
  # the plan, in inches. The room is the room of that center (the hook).
  def handle_event("place_item", %{"id" => id, "room" => room, "x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    build = socket.assigns.build

    with {:ok, item} <- Build.item(build, id),
         {:ok, %{plan: %{} = plan}} <- Build.room(build, room) do
      {w, d} = Layout.extent(item)
      at = %{x: round(x - w / 2) - plan.x, y: round(y - d / 2) - plan.y}
      # A drop snaps (`DIY.Stack`).
      plan_result(socket, Build.place_item(build, id, room, at, true), nil)
    else
      _none -> {:noreply, socket}
    end
  end

  # A room that moves (dx, dy in inches): its walls stay on a grid of 6
  # inches.
  def handle_event("move_room", %{"id" => id, "dx" => dx, "dy" => dy}, socket)
      when is_number(dx) and is_number(dy) do
    with {:ok, %{plan: %{} = plan}} <- Build.room(socket.assigns.build, id) do
      result = Build.move_room(socket.assigns.build, id, plan.x + step(dx), plan.y + step(dy))
      plan_result(socket, result, nil)
    else
      _none -> {:noreply, socket}
    end
  end

  # A wall of a room that moves: x0 and y0 at the back, x1 and y1 at the
  # front.
  def handle_event("size_room", %{"id" => id, "edge" => edge, "dx" => dx, "dy" => dy}, socket)
      when is_number(dx) and is_number(dy) do
    with {:ok, %{plan: %{} = plan}} <- Build.room(socket.assigns.build, id),
         {:ok, new} <- wall(plan, edge, step(dx), step(dy)) do
      plan_result(socket, Build.size_room(socket.assigns.build, id, new), nil)
    else
      _none -> {:noreply, socket}
    end
  end

  # The move buttons (in the sheet of an item, and in the bar of a room)
  # send the steps as text.
  def handle_event(event, %{"id" => id, "dx" => dx, "dy" => dy}, socket)
      when event in ["nudge_item", "nudge_room"] and is_binary(dx) and is_binary(dy) do
    case {parse_int(dx), parse_int(dy)} do
      {dx, dy} when is_integer(dx) and is_integer(dy) ->
        {:noreply, socket} = handle_event(event, %{"id" => id, "dx" => dx, "dy" => dy}, socket)
        # The sheet of the item shows its new place (`DIYWeb.Inside.where/3`):
        # the status does not tell it a second time.
        {:noreply, if(event == "nudge_item", do: assign(socket, :status, nil), else: socket)}

      _none ->
        {:noreply, socket}
    end
  end

  # The arrow keys in the list of the rooms, and the move buttons.
  def handle_event("nudge_item", %{"id" => id, "dx" => dx, "dy" => dy}, socket)
      when is_integer(dx) and is_integer(dy) do
    build = socket.assigns.build

    with {:ok, %{at: %{} = at} = item} <- Build.item(build, id) do
      result = Build.place_item(build, id, item.room, %{x: at.x + dx, y: at.y + dy})
      plan_result(socket, result, &item_status(&1, id))
    else
      _none -> {:noreply, socket}
    end
  end

  def handle_event("nudge_room", %{"id" => id, "dx" => dx, "dy" => dy}, socket)
      when is_integer(dx) and is_integer(dy) do
    with {:ok, %{plan: %{} = plan}} <- Build.room(socket.assigns.build, id) do
      result = Build.move_room(socket.assigns.build, id, plan.x + dx, plan.y + dy)
      plan_result(socket, result, &room_status(&1, id))
    else
      _none -> {:noreply, socket}
    end
  end

  def handle_event("turn_item", %{"id" => id}, socket),
    do: plan_result(socket, Build.turn_item(socket.assigns.build, id), &turn_status(&1, id))

  def handle_event("item_size", %{"item_id" => id, "typical" => "true"}, socket),
    do:
      with_build(assign(socket, :item_error, nil), Build.size_item(socket.assigns.build, id, nil))

  def handle_event("item_size", %{"item_id" => id} = params, socket) do
    size = Map.new(~w(w d h)a, &{&1, parse_int(params[Atom.to_string(&1)])})

    # The sides that are not valid: the panel tells it under the size, and
    # marks them (the item_error "size:w,h").
    case Build.size_item(socket.assigns.build, id, size) do
      {:ok, build} ->
        {:noreply, socket |> assign(item_error: nil, item_said: nil) |> put(build)}

      {:error, _reason} ->
        bad = for {side, {key, _label}} <- @sides, not Layout.valid_side?(size[key]), do: side
        {:noreply, assign(socket, :item_error, "size:" <> Enum.join(Enum.sort(bad), ","))}
    end
  end

  # The size of a room from the sheet, in feet: the walls at the front move.
  def handle_event("room_size", %{"room_id" => id, "w" => w, "d" => d}, socket)
      when is_binary(w) and is_binary(d) do
    with {:ok, %{plan: %{} = plan}} <- Build.room(socket.assigns.build, id),
         {:ok, w} <- inches(w),
         {:ok, d} <- inches(d) do
      new = %{plan | w: w, d: d}
      plan_result(socket, Build.size_room(socket.assigns.build, id, new), nil)
    else
      _none -> {:noreply, put_flash(socket, :error, move_error(:plan))}
    end
  end

  def handle_event("rename_room", %{"room_id" => id, "name" => name}, socket) do
    with_build(socket, Build.rename_room(socket.assigns.build, id, name))
  end

  # The search of the sheet Add (DIYWeb.Inside).
  def handle_event("add_search", %{"q" => q}, socket) when is_binary(q),
    do: {:noreply, assign(socket, :add_query, String.slice(q, 0, 40))}

  def handle_event("add_search", _params, socket), do: {:noreply, socket}

  # The match of the rooms with Home Assistant (DIYWeb.HomeAssistant): the
  # app changes the build, and the hook adds the areas to Home Assistant.
  def handle_event(
        "ha_sync",
        params,
        %{assigns: %{ha_rooms: %{areas: _} = ha_rooms, build: %{house: %{}}}} = socket
      )
      when is_map(params) do
    {build, out, status} = HomeAssistant.sync(socket.assigns.build, ha_rooms, params)
    socket = socket |> put(build) |> assign(:ha_sync, status)

    if out == [],
      do: {:noreply, HomeAssistant.fetch_rooms(socket)},
      else: {:noreply, push_event(socket, "ha:add_areas", %{areas: out})}
  end

  def handle_event("ha_sync", _params, socket), do: {:noreply, socket}

  def handle_event("ha:areas_added", params, %{assigns: %{build: %{house: %{}}}} = socket) do
    {build, status} =
      HomeAssistant.areas_added(socket.assigns.build, socket.assigns.ha_sync, params)

    {:noreply, socket |> put(build) |> assign(:ha_sync, status) |> HomeAssistant.fetch_rooms()}
  end

  def handle_event("ha:areas_added", _params, socket), do: {:noreply, socket}

  def handle_event("delete_room", %{"id" => id}, socket) do
    case Build.delete_room(socket.assigns.build, id) do
      {:ok, build} -> {:noreply, socket |> put(build) |> push_patch(to: ~p"/inside")}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("price", %{"price" => price}, socket) when is_binary(price) do
    result =
      case Float.parse(String.trim(price)) do
        # With no price of a bill, the app also forgets the kWh of the bill.
        _ when price == "" ->
          {:ok, build} = Build.set_bill(socket.assigns.build, nil)
          Build.set_price(build, nil)

        {cents, ""} ->
          Build.set_price(socket.assigns.build, cents)

        _ ->
          {:error, :price}
      end

    case result do
      {:ok, build} ->
        {:noreply, put(socket, build)}

      {:error, :price} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Give the price in cents for one kWh, for example 14.5.")
         )}
    end
  end

  # A month of the chart of the bill (a tap or the keyboard): the line
  # over the chart gives that month.
  def handle_event("bill_month", %{"month" => month}, socket) do
    case parse_int(month) do
      month when month in 1..12 -> {:noreply, assign(socket, :bill_month, month)}
      _other -> {:noreply, socket}
    end
  end

  # The price of the last bill of the person: its total divided by its kWh.
  # A price out of 3¢ to 100¢ is not a price of a bill: the page asks the
  # person to check the two numbers. With the month of the bill, the
  # estimate also fits the kWh of the bill (`DIY.Estimate.fit/2`), and the
  # page tells the fit under the bill.
  def handle_event("my_bill", %{"dollars" => dollars, "kwh" => kwh} = values, socket)
      when is_binary(dollars) and is_binary(kwh) do
    with {total, ""} when total > 0 and total <= 100_000 <- Float.parse(typed(dollars)),
         {kwh, ""} when kwh >= 1 and kwh <= 1_000_000 <- Float.parse(typed(kwh)) do
      cents = total / kwh * 100
      month = parse_int(values["month"])

      if cents >= 3 and cents <= 100 do
        {:ok, build} = Build.set_price(socket.assigns.build, cents)

        # The bill of a house that the person plans is of another home: it
        # gives only the price. With no month, the app forgets the old bill.
        bill = if build.door != "planning", do: %{month: month, kwh: kwh}

        {:ok, build} =
          with {:error, :bill} <- Build.set_bill(build, bill), do: Build.set_bill(build, nil)

        {:noreply,
         socket
         |> put(build)
         |> put_flash(
           :info,
           gettext("The app now uses the price of your bill: %{price} for each kWh.",
             price: Format.cents(cents)
           )
         )}
      else
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "These numbers give %{price} for each kWh. Check the total and the kWh of the bill.",
             price: Format.cents(cents)
           )
         )}
      end
    else
      _error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Give the total of the bill in dollars and its kWh, for example 150 and 1,100."
           )
         )}
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
        {:noreply, put_flash(socket, :error, gettext("Remove the rooms of the top floor first."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Give numbers in the limits of each field."))}
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
     socket
     |> put(build)
     |> put_flash(:info, gettext("The planned items are part of your house now."))}
  end

  def handle_event("power", params, socket) do
    case Power.update(socket.assigns.build.power, params) do
      {:ok, power} ->
        {:noreply, put(socket, Build.set_power(socket.assigns.build, power))}

      {:error, field} ->
        {:noreply, put_flash(socket, :error, power_error(field))}
    end
  end

  ## The plan lesson

  def handle_event("lesson", %{"step" => step}, socket) do
    step = parse_int(step)

    if step in 1..4 do
      build = socket.assigns.build
      build = if step > build.lesson, do: Build.set_lesson(build, step), else: build
      {:noreply, socket |> put(build) |> push_patch(to: ~p"/plans?#{[step: step]}")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("lesson_plan", %{"plan" => id}, socket),
    do: {:noreply, assign(socket, plan_id: id, checks: nil, answers: %{})}

  def handle_event("hint", _params, socket), do: {:noreply, assign(socket, :hint, true)}

  def handle_event("exercise", %{"plan" => id} = params, socket) when is_binary(id) do
    build = socket.assigns.build
    plan = Enum.find(build.plans, &(&1.id == id)) || Lesson.example_plan()
    {months, _source} = Lesson.months(build, socket.assigns.bill)
    month = Lesson.exercise_month(months)
    bill = Lesson.bill(plan, month, socket.assigns.shares[{plan.id, month.month}])
    step2 = params["parts"] != "total"
    parts = if step2, do: Lesson.parts(plan), else: [:total]
    checks = Lesson.check(bill, answers(params["answer"]), parts)

    # Step 3 uses a plan that is not the plan of step 2.
    socket =
      if step2 and Lesson.done?(checks),
        do: put(socket, Build.set_lesson_plan(build, plan.id || "example")),
        else: socket

    # The page shows the answers again (the text answers only).
    shown =
      for {part, text} <- answers(params["answer"]), is_binary(text), into: %{}, do: {part, text}

    {:noreply, assign(socket, checks: checks, answers: shown)}
  end

  def handle_event("efl", %{"name" => name, "lines" => lines}, socket) when is_binary(name) do
    case EFL.read(lines) do
      {:ok, result} ->
        name = name |> Path.rootname() |> String.slice(0, 60)
        {:noreply, assign(socket, :efl, Map.put(result, :name, name))}

      {:error, :averages} ->
        {:noreply,
         socket
         |> assign(:efl, nil)
         |> put_flash(:error, gettext("The app cannot read this EFL: it has no average prices."))}

      {:error, :lines} ->
        {:noreply,
         socket
         |> assign(:efl, nil)
         |> put_flash(:error, gettext("The app cannot read the text of this file."))}
    end
  end

  def handle_event("efl_error", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:efl, nil)
       |> put_flash(:error, gettext("The app cannot read this file. Open the PDF of an EFL."))}

  def handle_event("add_efl_plan", %{"name" => name}, socket) when is_binary(name) do
    case socket.assigns.efl do
      %{plan: plan, check: %{ok: true}} ->
        add_plan(assign(socket, :efl, nil), %{plan | name: plan_name(name, "The plan of the EFL")})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("add_plan", %{"plan" => form}, socket) do
    case Lesson.plan_from_form(form, tdu(socket.assigns.build) == nil) do
      {:ok, plan} ->
        add_plan(socket, plan)

      {:error, field} ->
        {:noreply, put_flash(socket, :error, plan_error(field))}
    end
  end

  def handle_event("delete_plan", %{"id" => id}, socket),
    do: with_build(socket, Build.delete_plan(socket.assigns.build, id))

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
    {:noreply,
     socket
     |> put(Build.restart(socket.assigns.build))
     |> assign(:bill_month, nil)
     |> push_patch(to: ~p"/")}
  end

  def handle_event("upload", _params, socket), do: {:noreply, socket}

  # The time of day and the weather of the picture (DIYWeb.Outside.sky_form):
  # on the page House and in the sheet of the share. A value that is not
  # known is "now".
  def handle_event("sky_pick", params, socket) do
    pick = %{
      "time" => if(params["time"] in DIY.Sky.times(), do: params["time"], else: "now"),
      "weather" => if(params["weather"] in DIY.Sky.weathers(), do: params["weather"], else: "now")
    }

    {:noreply, socket |> assign(:sky_pick, pick) |> share()}
  end

  # The box of the ZIP code in the sheet of the share.
  def handle_event("share_zip", %{"zip" => zip}, socket),
    do: {:noreply, socket |> assign(:share_zip, zip == "true") |> share()}

  # A short link of the link of the sheet (DIY.Links). A page makes 20 at
  # most: each one keeps a house on the server for one year. The address
  # of the person also has a limit for each day (DIY.Links.allow/2).
  def handle_event("share_short", _params, %{assigns: %{share: %{data: data}}} = socket)
      when is_binary(data) do
    links = socket.assigns.share_links

    result =
      cond do
        Map.has_key?(links, data) -> {:ok, links[data]}
        map_size(links) >= @max_short -> {:error, :many}
        true -> Links.create(data, Date.utc_today(), address: socket.assigns.address)
      end

    case result do
      {:ok, id} ->
        {:noreply,
         socket |> assign(share_links: Map.put(links, data, id), share_short: nil) |> share()}

      {:error, reason} ->
        {:noreply, assign(socket, :share_short, reason)}
    end
  end

  def handle_event("share_short", _params, socket), do: {:noreply, socket}

  # Start from a shared house: it takes the place of the build of the
  # device, as the import of a file does. When the device has a house, the
  # page asks first.
  def handle_event(
        "adopt",
        params,
        %{assigns: %{shared: {:ok, shared}, build: %Build{} = build}} = socket
      ) do
    if build.house != nil and params["sure"] != "true" do
      {:noreply, assign(socket, :adopt, :confirm)}
    else
      {:ok, build} = Build.import(build, Build.to_json(shared.build))

      {:noreply,
       socket
       |> put(build)
       |> assign(:bill_month, nil)
       |> put_flash(:info, gettext("This house is your house now. Change it to your own house."))
       |> push_patch(to: ~p"/")}
    end
  end

  def handle_event("adopt_cancel", _params, socket), do: {:noreply, assign(socket, :adopt, nil)}

  # The plans of a link go into the worksheet of the device. Then the page
  # Plans shows them with the months of the house. A device with no house
  # shows the first screens first. A plan that the worksheet has already
  # does not go in again.
  def handle_event(
        "plan_link_add",
        _params,
        %{assigns: %{plan_link: {:ok, plans}, build: %Build{} = build}} = socket
      ) do
    if build.market != nil and not plans?(build) do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext(
           "These plans are for Texas, in an area with retail choice. The house on this device is not in such an area."
         )
       )}
    else
      {build, added, left} =
        Enum.reduce(plans, {build, 0, 0}, fn plan, {build, added, left} ->
          if Enum.any?(build.plans, &same_plan?(&1, plan)) do
            {build, added, left}
          else
            case Build.add_plan(build, plan) do
              {:ok, build, _id} -> {build, added + 1, left}
              {:error, _full} -> {build, added, left + 1}
            end
          end
        end)

      {:noreply,
       socket
       |> put(Build.set_lesson(build, 4))
       |> put_flash(link_flash(added, left), link_text(added, left))
       |> push_patch(to: ~p"/plans?#{[step: 4]}")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp add_plan(socket, plan) do
    case Build.add_plan(socket.assigns.build, plan) do
      {:ok, build, _id} ->
        {:noreply,
         socket
         |> put(build)
         |> put_flash(:info, gettext("The worksheet has %{plan} now.", plan: plan.name))}

      {:error, :plans} ->
        {:noreply,
         put_flash(socket, :error, gettext("The worksheet has 10 plans. Remove a plan first."))}

      {:error, :plan} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "The app cannot keep this plan. A number of the plan is not in the range that the app accepts."
           )
         )}
    end
  end

  # Two plans are the same when all their numbers and their names are the
  # same. The averages of an EFL are not in a link.
  defp same_plan?(a, b), do: Map.drop(a, [:id, :averages]) == Map.drop(b, [:id, :averages])

  defp link_flash(_added, 0), do: :info
  defp link_flash(_added, _left), do: :error

  defp link_text(0, 0), do: gettext("The worksheet has these plans already.")
  defp link_text(_added, 0), do: gettext("The worksheet has the plans of the link now.")

  defp link_text(_added, _left),
    do:
      gettext(
        "The worksheet has 10 plans. Some plans of the link are not in it. Remove a plan first."
      )

  defp plan_name(name, default) do
    case name |> String.trim() |> String.slice(0, 60) do
      "" -> default
      name -> name
    end
  end

  defp plan_error(:name), do: gettext("Give the plan a name.")

  defp plan_error(field) when field in [:tdu_base, :tdu_cents],
    do: gettext("Give the delivery charges of your utility: its EFL gives them.")

  defp plan_error(:fee_kwh),
    do: gettext("Give the kWh of the minimum usage fee: the fee is for a month under that kWh.")

  defp plan_error(_field),
    do: gettext("Give each number of the plan in the limits: dollars, cents or kWh.")

  defp flag(build, id, flag, value) when value in ["true", "false"],
    do: Build.flag_item(build, id, flag, value == "true")

  defp flag(build, _id, _flag, _value), do: {:ok, build}

  # The page of a new item: the van of a zone, else the rooms.
  defp item_path(socket, build, id) do
    {:ok, item} = Build.item(build, id)

    case van_of(build, item) do
      nil -> ~p"/inside?#{keep_room(socket, item: id)}"
      van -> ~p"/van?#{[id: van, item: id]}"
    end
  end

  # The params of a page of the house, with the chosen room: it stays.
  defp keep_room(%{assigns: %{live_action: :inside, room: room}}, params) when is_binary(room),
    do: params ++ [room: room]

  defp keep_room(_socket, params), do: params

  # The page of an item that goes: its van, else the rooms.
  defp page_of(socket, item) do
    case {van_of(socket.assigns.build, item), keep_room(socket, [])} do
      {nil, []} -> ~p"/inside"
      {nil, params} -> ~p"/inside?#{params}"
      {van, _params} -> ~p"/van?#{[id: van]}"
    end
  end

  # The id of the van of an item in a zone, or nil.
  defp van_of(build, item) do
    {:ok, room} = Build.room(build, item.room)
    if Build.van_level?(room.level), do: String.replace_prefix(room.level, "van:", "")
  end

  # The page of a plan: the van on the page Van, else the rooms.
  defp plan_path(%{assigns: %{live_action: :van, shown_van: van}}, params) when is_binary(van),
    do: ~p"/van?#{[{:id, van} | params]}"

  defp plan_path(_socket, params), do: ~p"/inside?#{params}"

  # The result of a change of the plan: the new build (and a text for a
  # screen reader), or a message. A message that stays from an older change
  # goes.
  defp plan_result(socket, {:ok, build}, status) do
    socket = socket |> clear_flash(:error) |> put(build)
    {:noreply, assign(socket, :status, status && status.(build))}
  end

  defp plan_result(socket, {:error, reason}, _status),
    do: {:noreply, put_flash(socket, :error, move_error(reason))}

  defp move_error(:plan),
    do: gettext("A wall of a room is from 2 to 200 feet long, and a room stays near the house.")

  defp move_error(:overlap), do: gettext("A room or a zone cannot go over a different one.")
  defp move_error(:place), do: gettext("This item cannot go in that room.")
  defp move_error(:van), do: gettext("A zone stays in the van.")
  defp move_error(:fixed), do: gettext("The cab and the roof of the van stay where they are.")

  # An item or a room that is not on the plan now (it went to a van, or a
  # different tab removed it).
  defp move_error(_reason), do: gettext("This item or this room is not on the plan now.")

  # A length in feet from the sheet, in inches: from more than 0 to the
  # largest side of a room.
  defp inches(feet) do
    with {feet, ""} <- Float.parse(String.trim(feet)),
         true <- feet > 0 and feet <= Layout.max_room() / 12 do
      {:ok, round(feet * 12)}
    else
      _other -> :error
    end
  end

  # A move in inches on a grid of 6 inches.
  defp step(inches), do: round(inches / 6) * 6

  # The plan of a room after a move of one of its walls.
  defp wall(plan, "x0", dx, _dy), do: {:ok, %{plan | x: plan.x + dx, w: plan.w - dx}}
  defp wall(plan, "x1", dx, _dy), do: {:ok, %{plan | w: plan.w + dx}}
  defp wall(plan, "y0", _dx, dy), do: {:ok, %{plan | y: plan.y + dy, d: plan.d - dy}}
  defp wall(plan, "y1", _dx, dy), do: {:ok, %{plan | d: plan.d + dy}}
  defp wall(_plan, _edge, _dx, _dy), do: :error

  # The texts for a screen reader after an arrow key or a turn
  # (`DIYWeb.Inside.where/3`).
  defp item_status(build, id) do
    {:ok, item} = Build.item(build, id)
    {:ok, room} = Build.room(build, item.room)

    "#{Catalog.name(item)}: #{Inside.where(item, room, build.items)}"
  end

  defp turn_status(build, id) do
    {:ok, item} = Build.item(build, id)
    {w, d} = Layout.extent(item)
    "#{Catalog.name(item)} turned. Its space is #{Inside.feet(w)} by #{Inside.feet(d)}."
  end

  # A zone of a van tells its new place: from the back of the van and from
  # its right side (as the item sheet).
  defp room_status(build, id) do
    case Build.room(build, id) do
      {:ok, %{level: "van:" <> _, plan: plan} = zone} ->
        "#{zone.name} moved: #{Inside.feet(plan.y)} from the back of the van, #{Inside.feet(plan.x)} from its right side."

      {:ok, room} ->
        "#{room.name} moved."
    end
  end

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
           socket
           |> put(build)
           |> assign(:bill_month, nil)
           |> put_flash(:info, gettext("The page shows the build of the file now."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("The file is not a build of this app."))}
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
    do: gettext("Give the price at night in cents, from 0 to 200, or leave it empty.")

  defp power_error(field) when field in [:night_from, :night_to],
    do: gettext("Give an hour from 0 to 23.")

  defp power_error(:night), do: gettext("The night must start and end at different hours.")
  defp power_error(:buyback_cents), do: gettext("Give the price in cents, from 0 to 200.")
  defp power_error(:reserve), do: gettext("Give a part from 0 to 100%.")
  defp power_error(:mode), do: gettext("Choose how you use the batteries.")

  defp room_error(:name), do: gettext("Give the room a name.")
  defp room_error(:level), do: gettext("Choose a floor of the house.")
  defp room_error(:place), do: gettext("Choose a place: inside, outside or the roof.")
  defp room_error(:house), do: gettext("Choose a house first.")

  defp lookup(options, key) do
    Enum.find_value(options, fn {k, _label, value} -> if k == key, do: value end)
  end

  ## The build and its data

  # The meter of Home Assistant, also when the build uses it already.
  defp own_meter(%{ha_energy: %{meter: %{} = meter}}), do: meter
  defp own_meter(_assigns), do: nil

  # A build that uses the meter of Home Assistant gets its new months. A
  # different build keeps its usage (a file, or none): the page offers the
  # meter of Home Assistant.
  defp new_meter_months(socket) do
    build = socket.assigns.build
    usage = own_meter(socket.assigns)

    if usage && build.usage != usage && match?(%{source: "home_assistant"}, build.usage),
      do: put(socket, Build.set_usage(build, usage)),
      else: socket
  end

  # The build with a smart meter: the one it has, else a new one outside,
  # else inside.
  defp with_meter(build) do
    room =
      Enum.find(build.rooms, &(&1.place == :outdoor)) ||
        Enum.find(build.rooms, &(&1.place == :indoor))

    cond do
      Enum.any?(build.items, &(&1.type == "smart_meter")) ->
        {:ok, build}

      room ->
        with {:ok, build, _id} <- Build.add_item(build, room.id, "smart_meter"), do: {:ok, build}

      true ->
        :error
    end
  end

  # Changes the build, and updates the data of the pages. The same build
  # makes no change.
  defp put(%{assigns: %{build: build}} = socket, build), do: socket
  defp put(socket, build), do: socket |> Device.put_build(build) |> refresh()

  defp refresh(socket) do
    socket
    |> item_frames()
    |> load_weather()
    |> load_sky()
    |> load_market()
    |> estimate()
    |> pictures()
  end

  # The parts of the pictures (DIYWeb.Scene, DIYWeb.Outside and the plans).
  # An assign keeps a value that does not change, so the page sends a
  # picture again only when its parts change.
  defp pictures(%{assigns: %{build: %Build{house: house} = build}} = socket)
       when is_map(house) do
    vans = Van.vans(build)
    van = Enum.find(vans, &(&1.id == socket.assigns.van_id)) || List.first(vans)

    van_page? = socket.assigns.live_action == :van and van != nil

    socket
    |> assign(:scene, Scene.parts(build))
    |> assign(:van_scene, van && Scene.van_parts(build, van))
    |> assign(:shown_van, van && van.id)
    |> assign(:van_view, if(van_page?, do: VanCutaway.view(build, van)))
    |> ghosts()
    |> then(
      &assign(
        &1,
        :cutaway,
        if(&1.assigns.live_action == :inside,
          do: Cutaway.view(Build.house_view(build), &1.assigns.ghosts)
        )
      )
    )
    |> assign(:outside, if(socket.assigns.live_action == :front, do: Outside.view(build)))
  end

  defp pictures(socket), do: socket

  # The ghosts of the devices of Home Assistant on the page Rooms, and the
  # count of the devices in an area with no room (DIY.HomeAssistant).
  # The page computes them again only when the rooms, the items, the links
  # or the devices change: not for a patch of the page.
  defp ghosts(
         %{assigns: %{live_action: :inside, ha_devices: %{devices: devices, areas: areas} = ha}} =
           socket
       ) do
    build = socket.assigns.build
    key = :erlang.phash2({build.rooms, build.items, build.areas, build.devices, ha})

    if socket.assigns.ghost_key == key do
      socket
    else
      # A ghost keeps its place while it is free.
      kept = Map.new(socket.assigns.ghosts, &{&1.device, Map.take(&1, [:room, :at])})
      {ghosts, count} = DIY.HomeAssistant.ghosts(build, devices, areas, kept)

      assign(socket,
        ghosts: ghosts,
        ha_count: count,
        ha_away: DIY.HomeAssistant.away(build, devices, areas),
        ghost_key: key
      )
    end
  end

  defp ghosts(socket), do: assign(socket, ghosts: [], ha_count: 0, ha_away: 0, ghost_key: nil)

  defp load_weather(%{assigns: %{build: %{zip: nil}}} = socket), do: socket

  defp load_weather(%{assigns: %{build: %{zip: zip}, weather: %{zip: zip}}} = socket), do: socket

  defp load_weather(%{assigns: %{build: %{zip: zip}}} = socket) do
    {:ok, place} = DIY.Zip.lookup(zip)

    socket
    |> assign(:weather, %{zip: zip, status: :loading, climate: nil})
    |> start_async({:weather, zip}, fn -> Weather.climate(place.lat, place.lon) end)
  end

  # The sky of the ZIP code, for the picture of the house
  # (specs/Sky.tla). A new ZIP code has no sky until its answer comes. The
  # page asks again after an answer, with one timer: a new timer cancels
  # the one before. While the page asks again, the picture keeps the sky
  # of before.
  defp load_sky(%{assigns: %{build: %{zip: nil}}} = socket) do
    cancel_sky_timer(socket)
    assign(socket, :sky, %{zip: nil, status: :none, now: nil, timer: nil})
  end

  defp load_sky(%{assigns: %{build: %{zip: zip}, sky: %{zip: zip}}} = socket), do: socket

  defp load_sky(%{assigns: %{build: %{zip: zip}}} = socket) do
    cancel_sky_timer(socket)
    ask_sky(assign(socket, :sky, %{zip: zip, status: :loading, now: nil, timer: nil}))
  end

  defp ask_sky(%{assigns: %{sky: %{zip: zip}}} = socket) do
    {:ok, place} = DIY.Zip.lookup(zip)
    start_async(socket, {:sky, zip}, fn -> DIY.Sky.now(place.lat, place.lon) end)
  end

  defp cancel_sky_timer(%{assigns: %{sky: %{timer: timer}}}) when is_reference(timer),
    do: Process.cancel_timer(timer)

  defp cancel_sky_timer(_socket), do: :ok

  # The page asks for the market of a Texas ZIP code when the build has
  # none. It does not ask again while it waits for an answer. It also does
  # not ask again after an error for the same ZIP code: the key Try again
  # asks again. A market that came for this ZIP code before can be gone:
  # the build left the ZIP code and came back. Then the page asks again.
  defp load_market(
         %{assigns: %{build: %{zip: zip, market: nil}, market: %{zip: loaded, status: status}}} =
           socket
       )
       when is_binary(zip) and (zip != loaded or status == :ok) do
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
    build = Build.house_view(socket.assigns.build)
    climate = socket.assigns.weather.climate
    today = Build.today(build)
    estimate = Estimate.run(today, climate)
    full = if today == build, do: estimate, else: Estimate.run(build, climate)
    price = if build.zip, do: Prices.price(build)

    {power, bill, whatif, shares} =
      if estimate.ready do
        power = Power.run(today, estimate, climate, price.cents)

        {power, Bill.run(estimate, power),
         Power.whatif(build, power, estimate, full, climate, price.cents),
         night_shares(today, estimate, climate, price.cents)}
      else
        {nil, nil, nil, %{}}
      end

    socket
    |> assign(:estimate, estimate)
    |> assign(:full, full)
    |> assign(:price, price)
    |> assign(:power, power)
    |> assign(:bill, bill)
    |> assign(:whatif, whatif)
    |> assign(:shares, shares)
    |> share()
  end

  # The part of the power of each month at night, for each plan with a
  # price of the night: the day of DIY.Power with the hours of the plan.
  defp night_shares(build, estimate, climate, cents) do
    for %{night: %{} = night} = plan <- build.plans,
        power = %{build.power | night_from: night.from, night_to: night.to},
        m <- Power.run(%{build | power: power}, estimate, climate, cents).months,
        into: %{} do
      {{plan.id, m.month}, if(m.grid > 0, do: m.night / m.grid, else: night.share)}
    end
  end

  # The status of − and + again, after a tap at an end of the range. It is
  # only for the item that is open now, when no newer status came, and when
  # the number did not change.
  @impl true
  def handle_info(
        {:item_said, id, what, value, said},
        %{assigns: %{item: id, item_said: nil}} = socket
      ) do
    case Build.item(socket.assigns.build, id) do
      {:ok, item} ->
        if stepped_value(item, what) === value,
          do: {:noreply, assign(socket, :item_said, said)},
          else: {:noreply, socket}

      _other ->
        {:noreply, socket}
    end
  end

  # A status again (`say/2`), when no newer status came.
  def handle_info({:said, id, said}, %{assigns: %{item: id, item_said: nil}} = socket),
    do: {:noreply, assign(socket, :item_said, said)}

  # The devices of Home Assistant changed (DIYWeb.HomeAssistant): the page
  # draws the ghosts again.
  def handle_info(:ha_devices, socket), do: {:noreply, pictures(socket)}

  # The sky again, 30 minutes after an answer, when the ZIP code is the
  # same. The cache of DIY.Sky has a new key then. The picture keeps the
  # sky of before until the answer comes.
  def handle_info({:sky_again, zip}, %{assigns: %{sky: %{zip: zip} = sky}} = socket) do
    cancel_sky_timer(socket)
    {:noreply, socket |> assign(:sky, %{sky | status: :loading, timer: nil}) |> ask_sky()}
  end

  def handle_info({:sky_again, _zip}, socket), do: {:noreply, socket}

  # New energy data of Home Assistant (`new_meter_months/1`). The data can
  # come before the build of the device, for example after a reconnect.
  # Then the build gets the new months when it comes (`build_changed/1`).
  def handle_info(:ha_energy, %{assigns: %{build: nil}} = socket),
    do: {:noreply, assign(socket, :ha_energy_late, true)}

  def handle_info(:ha_energy, socket), do: {:noreply, new_meter_months(socket)}

  # A message that the page does not know (or a status of a different
  # item): nothing changes.
  def handle_info(_message, socket), do: {:noreply, socket}

  # The status after a tap on − or + (the assign `item_said`): the new
  # value and its unit, and an end of the range. A tap at an end does not
  # change the value. So the status is empty for @said_again ms, and then a
  # screen reader reads it again (`handle_info/2`).
  defp say_step(socket, id, what, param, before, value) do
    unit = if param.unit, do: " #{param.unit}", else: ""

    done =
      cond do
        value == param.max -> ", the most"
        value == param.min -> ", the least"
        true -> ""
      end

    said = "#{param.label}: #{Format.value(value)}#{unit}#{done}"

    if value == before do
      Process.send_after(self(), {:item_said, id, what, value, said}, @said_again)
      assign(socket, :item_said, nil)
    else
      assign(socket, :item_said, said)
    end
  end

  # The status after a wire is added or removed, or after a new model. The
  # same text a second time is empty for @said_again ms first, so a screen
  # reader reads it again.
  defp say(socket, said) do
    if socket.assigns[:item_said] == said do
      Process.send_after(self(), {:said, socket.assigns.item, said}, @said_again)
      assign(socket, :item_said, nil)
    else
      assign(socket, :item_said, said)
    end
  end

  # The value that a status tells: a number of the item, or a side of its
  # size.
  defp stepped_value(item, {:param, key}), do: item.params[key]

  defp stepped_value(item, {:size, side}) do
    {w, d, h} = Layout.size(item)
    Map.fetch!(%{w: w, d: d, h: h}, side)
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

  # The answer of the sky of a ZIP code that the build does not have now
  # goes away. The page asks again in 30 minutes, or at the next change of
  # the time of day. An error keeps the sky of before (with no sky, the
  # picture is a day with sun), and the page asks again in 5 minutes.
  def handle_async({:sky, zip}, result, %{assigns: %{sky: %{zip: zip} = sky}} = socket) do
    cancel_sky_timer(socket)

    {status, now, wait} =
      case result do
        {:ok, {:ok, %{next: next} = now}} when is_integer(next) ->
          {:ok, now, min(@sky_again, (next + 1) * 1000)}

        {:ok, {:ok, now}} ->
          {:ok, now, @sky_again}

        # The sky of before, with the clock of now.
        _error ->
          {:error, sky.now && DIY.Sky.at(sky.now.answer, DateTime.utc_now()), @sky_retry}
      end

    timer = Process.send_after(self(), {:sky_again, zip}, wait)
    sky = %{zip: zip, status: status, now: now, timer: timer}
    {:noreply, socket |> assign(:sky, sky) |> share()}
  end

  def handle_async({:sky, _zip}, _result, socket), do: {:noreply, socket}

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
    # The frame, the first screens and Settings are in the language of the
    # page (DIYWeb.Locale). The pages that are not translated yet are in
    # English (lang="en").
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={nav?(@build) and @live_action not in [:shared, :plan_link]}
      power={power?(@build)}
      plans={plans?(@build)}
      action={@live_action}
      saved={Device.saved?(assigns)}
    >
      <div id="device" phx-hook="Device" class="hidden"></div>
      <div id="home-assistant" phx-hook="HomeAssistant" class="hidden"></div>
      <div id="maker-link" phx-hook="MakerLink" class="hidden"></div>
      <div id="top" phx-hook="Top" data-page={page_key(assigns)} class="hidden"></div>
      <noscript>
        <p class="alert alert-warning">
          {gettext("This app needs JavaScript. Turn on JavaScript in the browser.")}
        </p>
      </noscript>

      <DIYWeb.Share.page :if={@live_action == :shared} shared={@shared} build={@build} adopt={@adopt} />
      <DIYWeb.PlanLinkPage.page
        :if={@live_action == :plan_link}
        compared={@plan_link}
        build={@build}
      />

      <p
        :if={is_nil(@build) and @live_action not in [:shared, :plan_link]}
        class="py-16 text-center opacity-70"
      >
        {gettext("The page reads your build from this device.")}
      </p>

      <%= if @build && @live_action not in [:shared, :plan_link] do %>
        <%= cond do %>
          <% is_nil(@build.door) -> %>
            <DIYWeb.Start.doors locale={@locale} />
          <% is_nil(@build.zip) -> %>
            <DIYWeb.Start.zip build={@build} error={@zip_error} typed={@zip_text} />
          <% is_nil(@build.house) -> %>
            <DIYWeb.Start.preset build={@build} />
          <% @live_action == :inside -> %>
            <div lang="en" class="contents">
              <DIYWeb.Inside.inside
                build={Build.house_view(@build)}
                away={Van.stations(@build).away}
                estimate={@full}
                bill={@bill}
                price={@price}
                view={@cutaway}
                item={@item}
                add={@add}
                add_query={@add_query}
                room={@room}
                sheet={@sheet}
                status={@status}
                item_error={assigns[:item_error]}
                item_said={assigns[:item_said]}
                outage={DIYWeb.PowerPage.outage_text(@power, @whatif)}
                ha={@ha}
                item_frames={@item_frames}
                ha_rooms={@ha_rooms}
                ha_sync={@ha_sync}
                ha_devices={@ha_devices}
                ha_states={@ha_states}
                ha_control={@ha_control}
                ha_stations={@ha_stations}
                makers={@makers}
                maker_control={@maker_control}
                ha_energy={@ha_energy}
                ghosts={@ghosts}
                ha_count={@ha_count}
                ha_away={@ha_away}
              />
            </div>
          <% @live_action == :estimate -> %>
            <div lang="en" class="contents">
              <DIYWeb.Math.estimate
                build={Build.today(Build.house_view(@build))}
                planned={Enum.count(Build.house_view(@build).items, & &1.planned)}
                estimate={@estimate}
                power={@power}
                bill={@bill}
                price={@price}
                weather={@weather}
              />
            </div>
          <% @live_action == :power -> %>
            <div lang="en" class="contents">
              <DIYWeb.PowerPage.page
                build={Build.house_view(@build)}
                power={@power}
                whatif={@whatif}
                price={@price}
                away={Van.stations(@build).away}
                scene={@scene}
              />
            </div>
          <% @live_action == :plans and plans?(@build) and @bill != nil -> %>
            <div lang="en" class="contents">
              <DIYWeb.LessonPage.page
                build={@build}
                bill={@bill}
                step={lesson_step(@lesson_step, @build)}
                plan_id={@plan_id}
                tdu={tdu(@build)}
                efl={@efl}
                checks={@checks}
                answers={@answers}
                hint={@hint}
                shares={@shares}
                origin={@origin}
              />
            </div>
          <% @live_action == :plans and plans_loading?(@weather, @market) -> %>
            <div lang="en" class="contents">
              <p id="plans-loading" class="py-8 opacity-80">
                The page gets the plans of your area and the months of your house.
              </p>
            </div>
          <% @live_action == :plans and plans_failed?(@weather, @market) != [] -> %>
            <div lang="en" id="plans-failed" class="py-8 space-y-3">
              <p :for={message <- plans_failed?(@weather, @market)} class="text-error">
                {message}
              </p>
              <p>The page needs the weather and the plans of your ZIP code to show the plans.</p>
              <button type="button" phx-click="retry" class="btn btn-sm">Try again</button>
            </div>
          <% @live_action == :plans -> %>
            <div lang="en" class="contents">
              <p id="no-lesson" class="py-8 opacity-80">
                The plan lesson is for a house in Texas, in an area with retail choice, with its estimate.
              </p>
            </div>
          <% @live_action == :van -> %>
            <div lang="en" class="contents">
              <DIYWeb.VanPage.page
                build={@build}
                van_id={@van_id}
                item={@item}
                add={@add}
                climate={@weather.climate}
                item_error={assigns[:item_error]}
                item_said={assigns[:item_said]}
                item_frames={@item_frames}
                estimate={@full}
                price={@price}
                ha={@ha}
                makers={@makers}
                maker_control={@maker_control}
                scene={@van_scene}
                view={@van_view}
                room={@room}
                sheet={@sheet}
                status={@status}
              />
            </div>
          <% @live_action == :settings -> %>
            <DIYWeb.Settings.settings
              locale={@locale}
              build={@build}
              price={@price}
              market={@market}
              uploads={@uploads}
              ha={@ha}
              makers={@makers}
              zip_error={@zip_error}
              zip_text={@zip_text}
            />
          <% true -> %>
            <div lang="en" class="contents">
              <DIYWeb.Front.front
                sky={DIY.Sky.pick(@sky_pick, @sky.now)}
                sky_pick={@sky_pick}
                sky_now={@sky.now}
                build={@build}
                estimate={@estimate}
                bill={@bill}
                whatif={@whatif}
                price={@price}
                weather={@weather}
                market={@market}
                outside={@outside}
                bill_month={@bill_month}
                ha_meter={DIYWeb.HomeAssistant.meter_offer(%{ha_energy: @ha_energy, build: @build})}
              />
              <DIYWeb.Share.sheet
                :if={@share}
                share={@share}
                short_error={@share_short}
                sky_pick={@sky_pick}
                sky_now={if @share_zip, do: @sky.now}
              />
            </div>
        <% end %>
      <% end %>
    </Layouts.app>
    """
  end

  # The sheet of the share (DIYWeb.Share): the link of the house of today,
  # with the numbers of the page. The picture and the title are in the
  # language of the page. The link changes only when the sheet opens, when
  # the box of the ZIP code changes, and when the numbers change. It also
  # changes with the choice of the sky, and with a new sky of now.
  defp share(
         %{
           assigns: %{
             live_action: :front,
             sheet: "share",
             bill: %{} = bill,
             build: %Build{} = build
           }
         } =
           socket
       ) do
    assigns = socket.assigns
    # A link with no ZIP code carries no sky of now: "now" is a day with
    # sun. The sky of now with the time of the post can tell the place.
    sky = DIY.Sky.pick(assigns.sky_pick, if(assigns.share_zip, do: assigns.sky.now))
    months = Enum.map(bill.months, & &1.kwh)
    summary = Share.summary(months, bill.cost, assigns.locale, sky, share_items(assigns))
    zip? = assigns.share_zip
    shared = if zip?, do: build, else: %{build | zip: nil}
    share = %{build: build, summary: summary, zip: zip?, title: Picture.title(shared, summary)}

    # A short link that this page made for the same DATA takes the place
    # of the long link (DIY.Links).
    share =
      case Share.encode(Build.today(build), summary, zip: zip?) do
        {:ok, data} ->
          path = assigns.share_links[data] || data

          Map.merge(share, %{
            data: data,
            short: Map.has_key?(assigns.share_links, data),
            url: assigns.origin <> ~p"/s/#{path}",
            picture: ~p"/s/#{data}/picture.png"
          })

        {:error, :too_large} ->
          Map.merge(share, %{data: nil, short: false, url: nil, picture: nil})
      end

    assign(socket, :share, share)
  end

  defp share(socket), do: assign(socket, :share, nil)

  # The items of the house of today, with their kWh and their cost of a
  # year. The cost is at the price of the hours when an item runs
  # (DIY.Power.item_cost/4). These are the numbers of the year of the link, with no planned item.
  # The picture of a link shows them on labels.
  defp share_items(%{build: build, estimate: estimate, price: price}) do
    for item <- Build.today(build).items, data = estimate.items[item.id] do
      {item.id, data.year, price && Power.item_cost(item, estimate, build.power, price.cents)}
    end
  end

  defp nav?(%Build{house: house}) when is_map(house), do: true
  defp nav?(_build), do: false

  # The page Power is for a house with power equipment, a car, or a plan,
  # or with a station that is in a van now (the page tells it). An item in
  # a van does not count.
  defp power?(%Build{} = build),
    do:
      Enum.any?(Build.house_view(build).items, &(&1.planned or &1.type in @power_types)) or
        Van.stations(build).away != []

  defp power?(_build), do: false

  # The plan lesson is for an area of Texas with retail choice.
  defp plans?(%Build{market: %{choice: true}}), do: true
  defp plans?(_build), do: false

  # The page Plans waits for the weather and the market of the ZIP code.
  # When one of them failed, it tells the error: the bill needs them.
  defp plans_loading?(weather, market), do: :loading in [weather.status, market.status]

  defp plans_failed?(weather, market),
    do: for(%{status: {:error, message}} <- [weather, market], do: message)

  # The delivery charges of the utility of the house, when the app knows
  # them (DIY.Plan.tdu/1).
  defp tdu(%Build{market: %{utility: utility}}) when is_binary(utility), do: Plan.tdu(utility)
  defp tdu(_build), do: nil

  # The page that the person sees: its name, the step of the lesson, and
  # the van. When it changes, the page goes to its top (the hook Top).
  defp page_key(%{live_action: :shared}), do: "shared"
  defp page_key(%{live_action: :plan_link}), do: "plan_link"
  defp page_key(%{build: nil}), do: "load"

  defp page_key(%{build: build} = assigns) do
    page =
      cond do
        is_nil(build.door) -> "door"
        is_nil(build.zip) -> "zip"
        is_nil(build.house) -> "house"
        true -> assigns.live_action
      end

    step = if page == :plans, do: lesson_step(assigns.lesson_step, build)
    van = if page == :van, do: assigns.shown_van
    "#{page}:#{step}:#{van}"
  end

  # A number that a person types, with no "$", no commas and no spaces.
  defp typed(text), do: String.replace(text, ~r/[\s$,]/, "")

  defp answers(%{} = answers), do: answers
  defp answers(_answers), do: %{}

  # The step of the lesson: the step of the page, at most the step that the
  # user reached.
  defp lesson_step(step, build) when is_integer(step) and step in 1..4,
    do: min(step, build.lesson)

  defp lesson_step(_step, build), do: build.lesson
end
