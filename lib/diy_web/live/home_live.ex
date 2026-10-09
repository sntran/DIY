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
    Power,
    Prices,
    Usage,
    Van,
    Weather
  }

  alias DIYWeb.{Cutaway, Device, Format, Inside, Scene, VanCutaway}

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
     |> assign(:shares, %{})
     |> assign(:lesson_step, nil)
     |> assign(:plan_id, nil)
     |> assign(:efl, nil)
     |> assign(:checks, nil)
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
     |> assign(:room, nil)
     |> assign(:sheet, nil)
     |> assign(:status, nil)
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
    sheets? = socket.assigns.live_action in [:inside, :van]
    item = if sheets?, do: params["item"]

    {:noreply,
     socket
     # The error of a field is for the item that the sheet showed.
     |> assign(:item_error, if(item == socket.assigns[:item], do: socket.assigns[:item_error]))
     |> assign(:item, item)
     |> assign(:add, if(sheets?, do: params["add"]))
     |> assign(:room, params["room"])
     |> assign(:sheet, params["sheet"])
     |> assign(:van_id, params["id"])
     |> pictures()
     |> assign(:lesson_step, parse_int(params["step"]))
     |> assign(:checks, nil)
     |> assign(:hint, false)}
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
        {:noreply, socket |> put(build) |> push_patch(to: item_path(build, id))}

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
    build = socket.assigns.build

    with {:ok, item} <- Build.item(build, id),
         {:ok, build} <- Build.delete_item(build, id) do
      {:noreply, socket |> put(build) |> push_patch(to: page_of(socket.assigns.build, item))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("take_to_van", %{"item" => id, "van" => van}, socket),
    do: with_build(socket, Build.take_to_van(socket.assigns.build, id, van))

  def handle_event("bring_home", %{"item" => id}, socket),
    do: with_build(socket, Build.bring_home(socket.assigns.build, id))

  def handle_event("van_model", %{"id" => id}, socket),
    do: with_build(socket, Build.van_model(socket.assigns.build, id))

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

  def handle_event("open_item", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, push_patch(socket, to: plan_path(socket, item: id))}

  # An item that the person drops on the plan. x and y are its center on
  # the plan, in inches. The room is the room of that center (the hook).
  def handle_event("place_item", %{"id" => id, "room" => room, "x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    build = socket.assigns.build

    with {:ok, item} <- Build.item(build, id),
         {:ok, %{plan: %{} = plan}} <- Build.room(build, room) do
      {w, d} = Layout.extent(item)
      at = %{x: round(x - w / 2) - plan.x, y: round(y - d / 2) - plan.y}
      plan_result(socket, Build.place_item(build, id, room, at), nil)
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
        # The sheet of the item shows its new place (`DIYWeb.Inside.where/2`):
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
    do: with_build(socket, Build.size_item(socket.assigns.build, id, nil))

  def handle_event("item_size", %{"item_id" => id} = params, socket) do
    size = Map.new(~w(w d h)a, &{&1, parse_int(params[Atom.to_string(&1)])})

    case Build.size_item(socket.assigns.build, id, size) do
      {:ok, build} ->
        {:noreply, put(socket, build)}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Give each side in inches, from 1 to #{Layout.max_size()}.")}
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

  def handle_event("delete_room", %{"id" => id}, socket) do
    case Build.delete_room(socket.assigns.build, id) do
      {:ok, build} -> {:noreply, socket |> put(build) |> push_patch(to: ~p"/inside")}
      {:error, _reason} -> {:noreply, socket}
    end
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
    do: {:noreply, assign(socket, plan_id: id, checks: nil)}

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

    {:noreply, assign(socket, :checks, checks)}
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
         |> put_flash(:error, "The app cannot read this EFL: it has no average prices.")}

      {:error, :lines} ->
        {:noreply,
         socket
         |> assign(:efl, nil)
         |> put_flash(:error, "The app cannot read the text of this file.")}
    end
  end

  def handle_event("efl_error", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:efl, nil)
       |> put_flash(:error, "The app cannot read this file. Open the PDF of an EFL.")}

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
    {:noreply, socket |> put(Build.restart(socket.assigns.build)) |> push_patch(to: ~p"/")}
  end

  def handle_event("upload", _params, socket), do: {:noreply, socket}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp add_plan(socket, plan) do
    case Build.add_plan(socket.assigns.build, plan) do
      {:ok, build, _id} ->
        {:noreply,
         socket |> put(build) |> put_flash(:info, "The worksheet has #{plan.name} now.")}

      {:error, :plans} ->
        {:noreply, put_flash(socket, :error, "The worksheet has 10 plans. Remove a plan first.")}

      {:error, :plan} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The app cannot keep this plan. A number of the plan is not in the range that the app accepts."
         )}
    end
  end

  defp plan_name(name, default) do
    case name |> String.trim() |> String.slice(0, 60) do
      "" -> default
      name -> name
    end
  end

  defp plan_error(:name), do: "Give the plan a name."

  defp plan_error(field) when field in [:tdu_base, :tdu_cents],
    do: "Give the delivery charges of your utility: its EFL gives them."

  defp plan_error(:fee_kwh),
    do: "Give the kWh of the minimum usage fee: the fee is for a month under that kWh."

  defp plan_error(_field),
    do: "Give each number of the plan in the limits: dollars, cents or kWh."

  defp flag(build, id, flag, value) when value in ["true", "false"],
    do: Build.flag_item(build, id, flag, value == "true")

  defp flag(build, _id, _flag, _value), do: {:ok, build}

  # The page of a new item: the van of a zone, else the rooms.
  defp item_path(build, id) do
    {:ok, item} = Build.item(build, id)

    case van_of(build, item) do
      nil -> ~p"/inside?#{[item: id]}"
      van -> ~p"/van?#{[id: van, item: id]}"
    end
  end

  # The page of an item that goes: its van, else the rooms.
  defp page_of(build, item) do
    case van_of(build, item) do
      nil -> ~p"/inside"
      van -> ~p"/van?#{[id: van]}"
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
    do: "A wall of a room is from 2 to 200 feet long, and a room stays near the house."

  defp move_error(:overlap), do: "A room or a zone cannot go over a different one."
  defp move_error(:place), do: "This item cannot go in that room."
  defp move_error(:van), do: "A zone stays in the van."
  defp move_error(:fixed), do: "The cab and the roof of the van stay where they are."

  # An item or a room that is not on the plan now (it went to a van, or a
  # different tab removed it).
  defp move_error(_reason), do: "This item or this room is not on the plan now."

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
  # (`DIYWeb.Inside.where/2`).
  defp item_status(build, id) do
    {:ok, item} = Build.item(build, id)
    {:ok, room} = Build.room(build, item.room)

    "#{Catalog.name(item)}: #{Inside.where(item, room)}"
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
    |> pictures()
  end

  # The parts of the pictures (DIYWeb.Scene): an assign keeps a value that
  # does not change, so the page sends a picture again only when its parts
  # change.
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
    |> assign(
      :cutaway,
      if(socket.assigns.live_action == :inside, do: Cutaway.view(Build.house_view(build)))
    )
  end

  defp pictures(socket), do: socket

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
      plans={plans?(@build)}
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
              build={Build.house_view(@build)}
              away={Van.stations(@build).away}
              estimate={@full}
              bill={@bill}
              price={@price}
              view={@cutaway}
              item={@item}
              add={@add}
              room={@room}
              sheet={@sheet}
              status={@status}
              item_error={assigns[:item_error]}
              outage={DIYWeb.PowerPage.outage_text(@power, @whatif)}
            />
          <% @live_action == :estimate -> %>
            <DIYWeb.Math.estimate
              build={Build.today(Build.house_view(@build))}
              planned={Enum.count(Build.house_view(@build).items, & &1.planned)}
              estimate={@estimate}
              power={@power}
              bill={@bill}
              price={@price}
              weather={@weather}
            />
          <% @live_action == :power -> %>
            <DIYWeb.PowerPage.page
              build={Build.house_view(@build)}
              power={@power}
              whatif={@whatif}
              price={@price}
              away={Van.stations(@build).away}
              scene={@scene}
            />
          <% @live_action == :plans and plans?(@build) and @bill != nil -> %>
            <DIYWeb.LessonPage.page
              build={@build}
              bill={@bill}
              step={lesson_step(@lesson_step, @build)}
              plan_id={@plan_id}
              tdu={tdu(@build)}
              efl={@efl}
              checks={@checks}
              hint={@hint}
              shares={@shares}
            />
          <% @live_action == :plans -> %>
            <p id="no-lesson" class="py-8 opacity-80">
              The plan lesson is for a house in Texas, in an area with retail choice, with its estimate.
            </p>
          <% @live_action == :van -> %>
            <DIYWeb.VanPage.page
              build={@build}
              van_id={@van_id}
              item={@item}
              add={@add}
              climate={@weather.climate}
              item_error={assigns[:item_error]}
              scene={@van_scene}
              view={@van_view}
              room={@room}
              sheet={@sheet}
              status={@status}
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
              scene={@scene}
            />
        <% end %>
      <% end %>
    </Layouts.app>
    """
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

  # The delivery charges of the utility of the house, when the app knows
  # them (DIY.Plan.tdu/1).
  defp tdu(%Build{market: %{utility: utility}}) when is_binary(utility), do: Plan.tdu(utility)
  defp tdu(_build), do: nil

  defp answers(%{} = answers), do: answers
  defp answers(_answers), do: %{}

  # The step of the lesson: the step of the page, at most the step that the
  # user reached.
  defp lesson_step(step, build) when is_integer(step) and step in 1..4,
    do: min(step, build.lesson)

  defp lesson_step(_step, build), do: build.lesson
end
