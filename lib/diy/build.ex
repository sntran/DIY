defmodule DIY.Build do
  @moduledoc """
  The build of a user: the place, the house, its rooms and its items. The
  build stays on the device (see `DIYWeb.Device`). The server reads it from
  JSON, and writes it to JSON after each change.

  `revision` counts the changes. Each change adds 1. `stamp` is a random
  name for each change. The device writes a build only on the build that
  it comes from: the stored stamp must be the stamp of that build (see
  `DIYWeb.Device` and `specs/Device.tla`).

  `from_json/1` never raises. The part of the house must be valid: a
  stored text from an old version, or a text that a person changed, gives
  an error, and the page starts a new build (the device keeps a copy). The
  van part must not stop the build from loading: the reader makes it whole
  (`repair_vans/1`), and a part of a van that it cannot read goes away. An
  item in a room that is not there goes home, or goes away: also an item
  of the house.

  ## The parts

  - `door`: `"my_house"` or `"planning"` (the two doors of the first
    screen).
  - `zip`: the ZIP code of the house.
  - `market`: the utility area of a Texas ZIP code, from Power to Choose
    (`DIY.Market`), or `nil`.
  - `price`: the price of one kWh that the user gives, in cents, or `nil`.
  - `house`: the numbers of the house: `size` (square feet), `year`
    (built), `floors` (1 to 3), `heat` (`"gas"`, `"heat_pump"` or
    `"electric"`), and `lot` (square feet, or `nil`).
  - `rooms`: each room has an `id`, a `name`, a `level` (see `levels/1`)
    and a `place` (`:indoor`, `:outdoor` or `:roof`). A camper van (an
    item) has its own rooms: its zones (`DIY.Catalog.zones/0`), on the level
    `"van:ID"` (the id of the van). They are fixed: the user cannot add,
    rename or remove a zone. The house and its numbers have only the rooms
    of the house (`house_view/1`). A room of the house and a zone of a van
    have a `plan`: their place and their size at scale, in inches
    (`DIY.Layout`). The shell of a van has no plan.
  - `items`: each item has these fields:
    - `id`, `type` (`DIY.Catalog`), `room` and `params`;
    - `typical`: true for an item of a preset that the user did not check;
    - `planned`: true for an item that the user does not have yet (the
      what-if of `DIY.Power`);
    - `backup`: true for an item that a power station runs;
    - `home`: for a power station in a van, the room of the house where it
      goes back, or `nil`;
    - `at` (its place in its room), `turn` and `size` (`DIY.Layout`). An
      item in the shell of a van has no `at`.
  - `usage`: the real usage of the meter file (`DIY.Usage`), or `nil`.
  - `power`: how the house uses its power stations, and the prices of the
    night and of the power to the grid (`DIY.Power.settings/0`).
  - `plans`: the plans of the worksheet of the plan lesson (`DIY.Plan`), at
    most 10.
  - `lesson`: the step of the plan lesson that the user reached (1 to 4).
  - `lesson_plan`: the plan that the user did in step 2 of the lesson (the
    id of a plan, or `"example"`), or `nil`. Step 3 uses a different plan.
  - `seq`: the number of the last id.
  - `hints`: the hints that the user closed.

  After each change, the plan is whole again (`DIY.Layout.fill/1`). Each
  room of the house has a plan, and each item is in its room.
  """

  alias DIY.{Catalog, Layout}

  @version 1
  @doors ~w(my_house planning)
  @heats ~w(gas heat_pump electric)
  # The hints that a person can close. The page Rooms showed the hint
  # "swipe" before it had the plan: a stored build can have it, so it
  # stays valid.
  @hints ~w(swipe plan)
  @places Catalog.places()

  @enforce_keys [:revision]
  defstruct version: @version,
            revision: 0,
            stamp: "",
            door: nil,
            zip: nil,
            market: nil,
            price: nil,
            house: nil,
            rooms: [],
            items: [],
            usage: nil,
            power: DIY.Power.settings(),
            plans: [],
            lesson: 1,
            lesson_plan: nil,
            seq: 0,
            hints: []

  @type plan :: %{x: integer(), y: integer(), w: pos_integer(), d: pos_integer()}
  @type room :: %{
          id: String.t(),
          name: String.t(),
          level: String.t(),
          place: atom(),
          plan: plan() | nil
        }
  @type item :: %{
          id: String.t(),
          type: String.t(),
          room: String.t(),
          typical: boolean(),
          planned: boolean(),
          backup: boolean(),
          home: String.t() | nil,
          params: map(),
          at: %{x: integer(), y: integer()} | nil,
          turn: 0..3,
          size: %{w: pos_integer(), d: pos_integer(), h: pos_integer()} | nil
        }
  @type house :: %{
          size: pos_integer(),
          year: pos_integer(),
          floors: 1..3,
          heat: String.t(),
          lot: pos_integer() | nil
        }
  @type t :: %__MODULE__{
          version: pos_integer(),
          revision: non_neg_integer(),
          stamp: String.t(),
          door: String.t() | nil,
          zip: String.t() | nil,
          market: map() | nil,
          price: float() | nil,
          house: house() | nil,
          rooms: [room()],
          items: [item()],
          usage: DIY.Usage.t() | nil,
          power: DIY.Power.settings(),
          plans: [DIY.Plan.t()],
          lesson: 1..4,
          lesson_plan: String.t() | nil,
          seq: non_neg_integer(),
          hints: [String.t()]
        }

  @doc "The version of the format of the build."
  def version, do: @version

  @doc "The doors of the first screen: my house, or a house I'm planning."
  def doors, do: @doors

  @doc "The kinds of heat of a house."
  def heats, do: @heats

  @doc """
  The levels of a house with a number of floors, from the top to the
  bottom: the roof (and the attic), each floor, and the ground outside.
  """
  def levels(floors) when floors in 1..3,
    do: ["roof"] ++ Enum.map(floors..1//-1, &"f#{&1}") ++ ["outside"]

  @doc "The name of a level."
  def level_name("roof"), do: "Roof and attic"
  def level_name("outside"), do: "Outside"
  def level_name("f" <> floor), do: "Floor #{floor}"

  @doc "A new, empty build."
  @spec new() :: t()
  def new, do: %__MODULE__{revision: 0}

  @doc """
  Applies a change to the build, adds 1 to its revision, and gives it a new
  stamp. The plan of the house is then whole (`DIY.Layout.fill/1`).
  """
  @spec change(t(), (t() -> t())) :: t()
  def change(%__MODULE__{revision: revision} = build, fun) do
    %__MODULE__{} = changed = fun.(build)
    %__MODULE__{} = changed = Layout.fill(changed)
    %__MODULE__{changed | revision: revision + 1, stamp: new_stamp()}
  end

  # 96 random bits: two changes never get the same stamp.
  defp new_stamp, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @doc """
  Starts the build again from nothing. The revision goes on, so that the
  new build replaces the stored build on the device.
  """
  @spec restart(t()) :: t()
  def restart(%__MODULE__{} = build), do: change(build, fn _ -> new() end)

  @doc """
  Puts a build from a file (an export of the app) in the place of the
  build. The revision goes on from the build, so that the device takes it.
  """
  @spec import(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def import(%__MODULE__{} = build, text) do
    with {:ok, imported} <- from_json(text) do
      {:ok, change(build, fn _ -> imported end)}
    end
  end

  @doc "The build as a file to keep: the JSON text, with no stamp."
  @spec export(t()) :: String.t()
  def export(%__MODULE__{} = build), do: to_json(%{build | stamp: ""})

  @doc "Sets the door of the first screen."
  @spec choose_door(t(), String.t()) :: {:ok, t()} | {:error, :door}
  def choose_door(build, door) when door in @doors,
    do: {:ok, change(build, &%{&1 | door: door})}

  def choose_door(_build, _door), do: {:error, :door}

  @doc """
  Sets the ZIP code. A ZIP code that is not in the data is an error. A new
  ZIP code clears the utility area. The same ZIP code makes no change.
  """
  @spec set_zip(t(), String.t()) :: {:ok, t()} | {:error, :zip}
  def set_zip(build, zip) when is_binary(zip) do
    zip = String.trim(zip)

    case DIY.Zip.lookup(zip) do
      {:ok, _place} when zip == build.zip -> {:ok, build}
      {:ok, _place} -> {:ok, change(build, &%{&1 | zip: zip, market: nil})}
      :error -> {:error, :zip}
    end
  end

  @doc "Sets the utility area of the ZIP code (`DIY.Market`)."
  @spec set_market(t(), map()) :: t()
  def set_market(build, market), do: change(build, &%{&1 | market: market})

  @doc "Sets the price of one kWh in cents, or clears it with `nil`."
  @spec set_price(t(), number() | nil) :: {:ok, t()} | {:error, :price}
  def set_price(build, nil), do: {:ok, change(build, &%{&1 | price: nil})}

  def set_price(build, price) when is_number(price) and price > 0 and price <= 200,
    do: {:ok, change(build, &%{&1 | price: price / 1})}

  def set_price(_build, _price), do: {:error, :price}

  @doc """
  Puts a house with its rooms and items: a preset of `DIY.House`. Each room
  of the preset has a `key`, and each item names the key of its room. The
  ids of the rooms and the items are new.
  """
  @spec put_house(t(), house(), [map()], [map()]) :: t()
  def put_house(build, house, rooms, items) do
    change(build, fn build ->
      build = %{build | house: house, rooms: [], items: []}

      {build, ids} =
        Enum.reduce(rooms, {build, %{}}, fn room, {build, ids} ->
          {id, build} = next_id(build, "r")
          new = %{id: id, name: room.name, level: room.level, place: room.place, plan: nil}
          {%{build | rooms: build.rooms ++ [new]}, Map.put(ids, room.key, id)}
        end)

      items
      |> Enum.reduce(build, fn item, build ->
        {id, build} = next_id(build, "i")
        room = Map.fetch!(ids, item.room)
        item = new_item(id, item.type, room, item.params) |> Map.put(:typical, true)
        %{build | items: build.items ++ [item]}
      end)
      |> no_meter_no_usage()
    end)
  end

  defp next_id(build, prefix) do
    seq = build.seq + 1
    {"#{prefix}#{seq}", %{build | seq: seq}}
  end

  @doc "Changes the numbers of the house. The rooms must fit the floors."
  @spec update_house(t(), map()) :: {:ok, t()} | {:error, atom()}
  def update_house(%__MODULE__{house: house} = build, changes) when is_map(house) do
    with {:ok, new} <- house(Map.merge(house, changes)),
         :ok <- fit(build.rooms, new.floors) do
      {:ok, change(build, &%{&1 | house: new})}
    end
  end

  def update_house(_build, _changes), do: {:error, :house}

  defp fit(rooms, floors) do
    levels = levels(floors)

    if Enum.all?(rooms, &(van_level?(&1.level) or &1.level in levels)),
      do: :ok,
      else: {:error, :floors}
  end

  @doc """
  Adds a room on a level. It goes to a free place (`DIY.Layout.fill/1`):
  the user then moves it.
  """
  @spec add_room(t(), String.t(), String.t(), atom()) ::
          {:ok, t(), String.t()} | {:error, atom()}
  def add_room(%__MODULE__{house: %{floors: floors}} = build, name, level, place) do
    with {:ok, name} <- name(name),
         true <- level in levels(floors) || {:error, :level},
         true <- place in @places || {:error, :place} do
      {id, build} = next_id(build, "r")
      room = %{id: id, name: name, level: level, place: place, plan: nil}
      {:ok, change(build, &%{&1 | rooms: &1.rooms ++ [room]}), id}
    end
  end

  def add_room(_build, _name, _level, _place), do: {:error, :house}

  @doc "Gives a room a new name."
  @spec rename_room(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def rename_room(build, id, name) do
    with {:ok, name} <- name(name),
         {:ok, _room} <- house_room(build, id) do
      rooms = Enum.map(build.rooms, &if(&1.id == id, do: %{&1 | name: name}, else: &1))
      {:ok, change(build, &%{&1 | rooms: rooms})}
    end
  end

  @doc """
  Removes a room of the house and its items. A camper van in the room goes
  too, with its zones. A station in a van that had its home in the room
  gets a new home: a room of the house where it can go, first on the same
  level. A station with no home goes away with its van.
  """
  @spec delete_room(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def delete_room(build, id) do
    with {:ok, removed} <- house_room(build, id) do
      {:ok,
       change(build, fn build ->
         rooms = Enum.reject(build.rooms, &(&1.id == id))
         house = Enum.reject(rooms, &van_level?(&1.level))
         house = Enum.sort_by(house, &(&1.level != removed.level))

         items =
           for item <- build.items,
               item.room != id,
               do: if(item.home == id, do: %{item | home: new_home(item, house)}, else: item)

         %{build | rooms: rooms, items: items}
         |> drop_vans()
         |> no_meter_no_usage()
       end)}
    end
  end

  defp new_home(item, house) do
    places = Catalog.kind(item.type).places
    Enum.find_value(house, &(&1.place in places && &1.id))
  end

  defp house_room(build, id) do
    case room(build, id) do
      {:ok, %{level: level} = room} ->
        if van_level?(level), do: {:error, :room}, else: {:ok, room}

      error ->
        error
    end
  end

  @doc "The level of the zones of a camper van."
  def van_level(van_id), do: "van:" <> van_id

  @doc "True for the level of the zones of a camper van."
  def van_level?(level), do: String.starts_with?(level, "van:")

  @doc """
  The house: the build with only the rooms of the house and their items
  (no zone of a van, and no item in a van).
  """
  @spec house_view(t()) :: t()
  def house_view(build) do
    rooms = Enum.reject(build.rooms, &van_level?(&1.level))
    ids = MapSet.new(rooms, & &1.id)
    %{build | rooms: rooms, items: Enum.filter(build.items, &(&1.room in ids))}
  end

  @zone_order Catalog.zones() |> Keyword.keys() |> Enum.with_index() |> Map.new()

  @doc "The zones of a camper van, in order (`DIY.Catalog.zones/0`)."
  def zones(build, van_id),
    do: build |> rooms_on(van_level(van_id)) |> Enum.sort_by(&Map.fetch!(@zone_order, &1.place))

  @doc "The zone of a camper van with a place, or `nil`."
  def zone(build, van_id, place), do: Enum.find(zones(build, van_id), &(&1.place == place))

  # The zones of a van that is not in the build go, with their items. A
  # station with a home in the house goes back to its home.
  defp drop_vans(build) do
    vans = for i <- build.items, i.type == "camper_van", do: van_level(i.id)
    {gone, rooms} = Enum.split_with(build.rooms, &(van_level?(&1.level) and &1.level not in vans))
    gone = MapSet.new(gone, & &1.id)
    homes = MapSet.new(rooms, & &1.id)

    items =
      for item <- build.items,
          not MapSet.member?(gone, item.room) or MapSet.member?(homes, item.home || ""),
          do:
            if(MapSet.member?(gone, item.room),
              do: %{item | room: item.home, home: nil, at: nil},
              else: item
            )

    %{build | rooms: rooms, items: items}
  end

  @doc """
  Takes a power station of the house to the electrical bay of a van. The
  station keeps its room of the house as its home: the house loses its
  capacity while the van has it.
  """
  @spec take_to_van(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def take_to_van(build, id, van_id) do
    with {:ok, item} <- item(build, id),
         {:ok, _room} <- house_room(build, item.room),
         true <- item.type == "power_station" || {:error, :item},
         %{} = bay <- zone(build, van_id, :bay) || {:error, :van} do
      {:ok, replace_item(build, %{item | room: bay.id, home: item.room, at: nil})}
    end
  end

  @doc """
  Brings a power station of the house from a van to its home. A station of
  the van (with no home) stays in the van.
  """
  @spec bring_home(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def bring_home(build, id) do
    with {:ok, item} <- item(build, id),
         {:ok, room} <- room(build, item.room),
         true <-
           (item.type == "power_station" and van_level?(room.level) and item.home != nil) ||
             {:error, :item} do
      {:ok, replace_item(build, %{item | room: item.home, home: nil, at: nil})}
    end
  end

  @doc "The room with an id."
  def room(build, id) do
    case Enum.find(build.rooms, &(&1.id == id)) do
      nil -> {:error, :room}
      room -> {:ok, room}
    end
  end

  @doc "The item with an id."
  def item(build, id) do
    case Enum.find(build.items, &(&1.id == id)) do
      nil -> {:error, :item}
      item -> {:ok, item}
    end
  end

  @doc "Adds an item of a type to a room, with the default numbers."
  @spec add_item(t(), String.t(), String.t()) :: {:ok, t(), String.t()} | {:error, atom()}
  def add_item(build, room_id, type) do
    with {:ok, room} <- room(build, room_id),
         %{} = kind <- Catalog.kind(type) || {:error, :type},
         true <- room.place in kind.places || {:error, :place} do
      {id, build} = next_id(build, "i")
      item = new_item(id, type, room_id, Catalog.defaults(type))
      {:ok, change(build, &(%{&1 | items: &1.items ++ [item]} |> van_zones(item))), id}
    end
  end

  # A camper van gets its zones. Its numbers are the numbers of its model:
  # typical, until the user checks them on the label of the van.
  defp van_zones(build, %{type: "camper_van"} = van) do
    Enum.reduce(Catalog.zones(), replace(build, %{van | typical: true}), fn {place, name},
                                                                            build ->
      {id, build} = next_id(build, "r")

      %{
        build
        | rooms:
            build.rooms ++
              [%{id: id, name: name, level: van_level(van.id), place: place, plan: nil}]
      }
    end)
  end

  defp van_zones(build, _item), do: build

  defp replace(build, item),
    do: %{build | items: Enum.map(build.items, &if(&1.id == item.id, do: item, else: &1))}

  @doc "Gives a camper van the numbers of its model (`DIY.Catalog.van_models/0`)."
  @spec van_model(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def van_model(build, id) do
    with {:ok, %{type: "camper_van"} = van} <- item(build, id) do
      {:ok, replace_item(build, model_numbers(van))}
    else
      _ -> {:error, :item}
    end
  end

  defp model_numbers(van) do
    {_key, _name, numbers, _source} = List.keyfind(Catalog.van_models(), van.params["model"], 0)
    %{van | params: Map.merge(van.params, numbers), typical: true}
  end

  # The numbers of a van that come from its label (or from a scale).
  @label ~w(gvwr front_gawr rear_gawr front_empty rear_empty)

  @doc """
  Changes the numbers of an item. The item is not typical after this: the
  user checked it. A camper van with a new model gets the numbers of the
  model (typical). A camper van is not typical only after a change of a
  number of its label.
  """
  @spec update_item(t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def update_item(build, id, values) when is_map(values) do
    with {:ok, item} <- item(build, id),
         {:ok, params} <- Catalog.params(item.type, Map.merge(item.params, values)) do
      {:ok, replace_item(build, checked(item, params))}
    end
  end

  defp checked(%{type: "camper_van", params: old} = van, params) do
    cond do
      params["model"] != old["model"] -> model_numbers(%{van | params: params})
      Enum.any?(@label, &(params[&1] != old[&1])) -> %{van | params: params, typical: false}
      true -> %{van | params: params}
    end
  end

  defp checked(item, params), do: %{item | params: params, typical: false}

  defp new_item(id, type, room, params),
    do: %{
      id: id,
      type: type,
      room: room,
      typical: false,
      planned: false,
      backup: false,
      home: nil,
      params: params,
      at: nil,
      turn: 0,
      size: nil
    }

  @doc """
  Sets a flag of an item: `:planned` (the user does not have it yet) or
  `:backup` (a power station runs it).
  """
  @spec flag_item(t(), String.t(), :planned | :backup, boolean()) :: {:ok, t()} | {:error, :item}
  def flag_item(build, id, flag, value) when flag in [:planned, :backup] and is_boolean(value) do
    with {:ok, item} <- item(build, id),
         do: {:ok, replace_item(build, Map.put(item, flag, value))}
  end

  @doc "Sets how the house uses its power (`DIY.Power.settings/0`)."
  @spec set_power(t(), DIY.Power.settings()) :: t()
  def set_power(build, power), do: change(build, &%{&1 | power: power})

  @max_plans 10

  @doc """
  Adds a plan to the worksheet (at most 10), with a new id. The build keeps
  only a plan that `DIY.Plan.read/1` accepts, so that the build can always
  load again.
  """
  @spec add_plan(t(), DIY.Plan.t()) :: {:ok, t(), String.t()} | {:error, :plans | :plan}
  def add_plan(%{plans: plans}, _plan) when length(plans) >= @max_plans, do: {:error, :plans}

  def add_plan(build, plan) do
    {id, next} = next_id(build, "p")

    case DIY.Plan.read(DIY.Plan.to_map(%{plan | id: id})) do
      {:ok, plan} -> {:ok, change(next, &%{&1 | plans: &1.plans ++ [plan]}), id}
      :error -> {:error, :plan}
    end
  end

  @doc "Removes a plan of the worksheet."
  @spec delete_plan(t(), String.t()) :: {:ok, t()} | {:error, :plan}
  def delete_plan(build, id) do
    if Enum.any?(build.plans, &(&1.id == id)),
      do: {:ok, change(build, &%{&1 | plans: Enum.reject(&1.plans, fn p -> p.id == id end)})},
      else: {:error, :plan}
  end

  @doc "Sets the step of the plan lesson that the user reached."
  @spec set_lesson(t(), 1..4) :: t()
  def set_lesson(build, step) when step in 1..4, do: change(build, &%{&1 | lesson: step})

  @doc "Keeps the plan that the user did in step 2 of the lesson."
  @spec set_lesson_plan(t(), String.t()) :: t()
  def set_lesson_plan(build, id) when is_binary(id) and byte_size(id) <= 20,
    do: change(build, &%{&1 | lesson_plan: id})

  @doc """
  The build of today: the build with no planned item (the what-if of
  `DIY.Power`).
  """
  @spec today(t()) :: t()
  def today(build), do: %{build | items: Enum.reject(build.items, & &1.planned)}

  @doc "Marks an item as checked by the user, with no change of its numbers."
  @spec check_item(t(), String.t()) :: {:ok, t()} | {:error, :item}
  def check_item(build, id) do
    with {:ok, item} <- item(build, id), do: {:ok, replace_item(build, %{item | typical: false})}
  end

  @doc """
  Moves an item to a different room, where its kind can go. An item does
  not go between the house and a van: a station goes with
  `take_to_van/3` and `bring_home/2`. The item goes to a free place in
  the room (`DIY.Layout.fill/1`).
  """
  @spec move_item(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def move_item(build, id, room_id) do
    with {:ok, item} <- item(build, id),
         {:ok, from} <- room(build, item.room),
         {:ok, room} <- room(build, room_id),
         true <- room.place in Catalog.kind(item.type).places || {:error, :place},
         true <- van_level?(from.level) == van_level?(room.level) || {:error, :place} do
      {:ok, replace_item(build, %{item | room: room_id, at: nil})}
    end
  end

  @doc """
  Moves a room of the house or a zone of a van: `x` and `y` are its new
  back corner, in inches. Its items go with it. The room must not overlap
  a room of its layer (`DIY.Layout.layer/1`), and a zone stays in its van.
  """
  @spec move_room(t(), String.t(), integer(), integer()) :: {:ok, t()} | {:error, atom()}
  def move_room(build, id, x, y) when is_integer(x) and is_integer(y) do
    with {:ok, room} <- plan_room(build, id),
         do: put_room_plan(build, room, %{room.plan | x: x, y: y}, {0, 0})
  end

  @doc """
  Gives a room of the house or a zone of a van a new plan: the user moves a
  wall. The items keep their place, and stay in the room. The room must
  not overlap a room of its layer, and a zone stays in its van.
  """
  @spec size_room(t(), String.t(), plan()) :: {:ok, t()} | {:error, atom()}
  def size_room(build, id, %{x: x, y: y} = plan) do
    with {:ok, room} <- plan_room(build, id),
         do: put_room_plan(build, room, plan, {x - room.plan.x, y - room.plan.y})
  end

  # A room or a zone with a plan (not the shell of a van).
  defp plan_room(build, id) do
    case room(build, id) do
      {:ok, %{plan: %{}} = room} -> {:ok, room}
      _other -> {:error, :room}
    end
  end

  # The box of a zone of a van, or nil for a room of the house.
  defp van_box(build, %{level: "van:" <> van_id}) do
    {:ok, van} = item(build, van_id)
    Layout.van_box(van)
  end

  defp van_box(_build, _room), do: nil

  defp put_room_plan(build, room, plan, {dx, dy}) do
    box = van_box(build, room)

    cond do
      not Layout.valid_plan?(plan) or (box != nil and not Layout.inside?(plan, box)) ->
        {:error, :plan}

      not Layout.free?(build, room, plan) ->
        {:error, :overlap}

      true ->
        {:ok,
         change(build, fn build ->
           %{
             build
             | rooms:
                 Enum.map(build.rooms, &if(&1.id == room.id, do: %{&1 | plan: plan}, else: &1)),
               items:
                 Enum.map(build.items, fn
                   %{room: id, at: %{x: x, y: y}} = item when id == room.id ->
                     %{item | at: %{x: x - dx, y: y - dy}}

                   item ->
                     item
                 end)
           }
         end)}
    end
  end

  @doc """
  Puts an item at a place in a room: its room, or a different room where
  its kind can go. `at` is the back corner of the item in the room, in
  inches. The item stays in the room. An item does not go between the
  house and a van (as `move_item/3`).
  """
  @spec place_item(t(), String.t(), String.t(), %{x: integer(), y: integer()}) ::
          {:ok, t()} | {:error, atom()}
  def place_item(build, id, room_id, %{x: x, y: y}) when is_integer(x) and is_integer(y) do
    with {:ok, item} <- item(build, id),
         {:ok, from} <- plan_room(build, item.room),
         {:ok, room} <- plan_room(build, room_id),
         true <- room.place in Catalog.kind(item.type).places || {:error, :place},
         true <- van_level?(from.level) == van_level?(room.level) || {:error, :place} do
      at = Layout.clamp(%{x: x, y: y}, item, room.plan)
      {:ok, replace_item(build, %{item | room: room.id, at: at})}
    end
  end

  @doc "Turns an item a quarter turn, around its center."
  @spec turn_item(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def turn_item(build, id) do
    with {:ok, item} <- item(build, id),
         {:ok, _room} <- plan_room(build, item.room) do
      {w, d} = Layout.extent(item)
      turned = %{item | turn: rem(item.turn + 1, 4)}
      {tw, td} = Layout.extent(turned)
      at = %{x: item.at.x + div(w - tw, 2), y: item.at.y + div(d - td, 2)}
      {:ok, replace_item(build, %{turned | at: at})}
    end
  end

  @doc """
  Gives an item a size in inches (`%{w, d, h}`), or its typical size again
  with `nil`. The item stays in its room.
  """
  @spec size_item(t(), String.t(), map() | nil) :: {:ok, t()} | {:error, atom()}
  def size_item(build, id, size) do
    with {:ok, item} <- item(build, id),
         true <- (size == nil or Layout.valid_size?(size)) || {:error, :size},
         # The watts of solar panels give their size: a size goes, and no
         # size comes.
         true <- (size == nil or item.type != "solar_panels") || {:error, :size},
         do: {:ok, replace_item(build, %{item | size: size})}
  end

  defp replace_item(build, item) do
    change(build, fn build ->
      %{build | items: Enum.map(build.items, &if(&1.id == item.id, do: item, else: &1))}
    end)
  end

  @doc "Removes an item."
  @spec delete_item(t(), String.t()) :: {:ok, t()} | {:error, :item}
  def delete_item(build, id) do
    with {:ok, _item} <- item(build, id) do
      {:ok,
       change(
         build,
         &(%{&1 | items: Enum.reject(&1.items, fn i -> i.id == id end)}
           |> drop_vans()
           |> no_meter_no_usage())
       )}
    end
  end

  # With no smart meter, the build keeps no real usage: a person removes the
  # meter to remove the data of the meter.
  defp no_meter_no_usage(build) do
    if Enum.any?(build.items, &(&1.type == "smart_meter")), do: build, else: %{build | usage: nil}
  end

  @doc "Puts the real usage of a meter file, or removes it with `nil`."
  @spec set_usage(t(), DIY.Usage.t() | nil) :: t()
  def set_usage(build, usage), do: change(build, &%{&1 | usage: usage})

  @doc "Closes a hint, so that it does not show again."
  @spec close_hint(t(), String.t()) :: {:ok, t()} | {:error, :hint}
  def close_hint(build, hint) when hint in @hints,
    do: {:ok, change(build, &%{&1 | hints: Enum.uniq(&1.hints ++ [hint])})}

  def close_hint(_build, _hint), do: {:error, :hint}

  @doc "The rooms of a level, in their order."
  def rooms_on(build, level), do: Enum.filter(build.rooms, &(&1.level == level))

  @doc "The items of a room, in their order."
  def items_in(build, room_id), do: Enum.filter(build.items, &(&1.room == room_id))

  ## JSON

  @doc "The build as a JSON text."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = build) do
    Jason.encode!(%{
      "version" => build.version,
      "revision" => build.revision,
      "stamp" => build.stamp,
      "door" => build.door,
      "zip" => build.zip,
      "market" => build.market,
      "price" => build.price,
      "house" => build.house,
      "rooms" => Enum.map(build.rooms, &%{&1 | place: Atom.to_string(&1.place)}),
      "items" => build.items,
      "usage" => build.usage && DIY.Usage.to_map(build.usage),
      "power" => DIY.Power.to_map(build.power),
      "plans" => Enum.map(build.plans, &DIY.Plan.to_map/1),
      "lesson" => build.lesson,
      "lesson_plan" => build.lesson_plan,
      "seq" => build.seq,
      "hints" => build.hints
    })
  end

  @doc """
  Reads a build from a JSON text. The error tells why the text is not a
  build of this version.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> from_map(map)
      {:ok, _other} -> {:error, :not_a_build}
      {:error, _reason} -> {:error, :not_json}
    end
  end

  def from_json(_text), do: {:error, :not_json}

  defp from_map(%{"version" => @version} = map) do
    with {:ok, revision} <- count(map["revision"], :revision),
         {:ok, stamp} <- string(map["stamp"], :stamp),
         {:ok, door} <- door(map["door"]),
         {:ok, zip} <- zip(map["zip"]),
         {:ok, market} <- market(map["market"]),
         {:ok, price} <- price(map["price"]),
         {:ok, house} <- house(map["house"]),
         {:ok, rooms} <- rooms(map["rooms"], house),
         {:ok, items} <- items(map["items"], rooms),
         {:ok, usage} <- usage(map["usage"]),
         {:ok, power} <- power(map["power"]),
         {:ok, plans} <- plans(map["plans"]),
         {:ok, lesson} <- lesson(map["lesson"]),
         {:ok, lesson_plan} <- lesson_plan(map["lesson_plan"]),
         {:ok, seq} <- count(map["seq"], :seq),
         seq = last_id(seq, rooms ++ items ++ plans),
         {:ok, hints} <- hints(map["hints"]) do
      {:ok,
       %__MODULE__{
         revision: revision,
         stamp: stamp,
         door: door,
         zip: zip,
         market: market,
         price: price,
         house: house,
         rooms: rooms,
         items: items,
         usage: usage,
         power: power,
         plans: plans,
         lesson: lesson,
         lesson_plan: lesson_plan,
         seq: seq,
         hints: hints
       }
       |> repair_vans()
       |> Layout.fill()}
    end
  end

  defp from_map(%{"version" => version}) when is_integer(version),
    do: {:error, {:version, version}}

  defp from_map(_map), do: {:error, :not_a_build}

  # The number of the last id: at least the number of each id of the build,
  # so that a new id is new (a text that a person changed can have a small
  # `seq`).
  defp last_id(seq, list) do
    Enum.reduce(list, seq, fn %{id: id}, seq ->
      case Integer.parse(String.slice(id, 1..-1//1)) do
        {number, ""} -> max(seq, number)
        _ -> seq
      end
    end)
  end

  defp count(value, _error) when is_integer(value) and value >= 0, do: {:ok, value}
  defp count(_value, error), do: {:error, error}

  defp string(value, _error) when is_binary(value), do: {:ok, value}
  defp string(_value, error), do: {:error, error}

  defp door(nil), do: {:ok, nil}
  defp door(door) when door in @doors, do: {:ok, door}
  defp door(_door), do: {:error, :door}

  defp zip(nil), do: {:ok, nil}

  defp zip(zip) do
    case DIY.Zip.lookup(zip) do
      {:ok, _place} -> {:ok, zip}
      :error -> {:error, :zip}
    end
  end

  defp market(nil), do: {:ok, nil}

  defp market(market) do
    case DIY.Market.from_map(market) do
      {:ok, market} -> {:ok, market}
      :error -> {:error, :market}
    end
  end

  # A build of an older version has no plans, and is at the start of the
  # lesson.
  defp plans(nil), do: {:ok, []}

  defp plans(plans) when is_list(plans) and length(plans) <= @max_plans do
    plans
    |> all(&DIY.Plan.read/1)
    |> unique(:plans)
  end

  defp plans(_plans), do: {:error, :plans}

  defp lesson(nil), do: {:ok, 1}
  defp lesson(step) when step in 1..4, do: {:ok, step}
  defp lesson(_step), do: {:error, :lesson}

  defp lesson_plan(nil), do: {:ok, nil}
  defp lesson_plan(id) when is_binary(id) and byte_size(id) <= 20, do: {:ok, id}
  defp lesson_plan(_id), do: {:error, :lesson_plan}

  # A build of an older version has no power: the default settings.
  defp power(nil), do: {:ok, DIY.Power.settings()}

  defp power(power) do
    case DIY.Power.read(power) do
      {:ok, power} -> {:ok, power}
      :error -> {:error, :power}
    end
  end

  defp usage(nil), do: {:ok, nil}

  defp usage(usage) do
    case DIY.Usage.read(usage) do
      {:ok, usage} -> {:ok, usage}
      :error -> {:error, :usage}
    end
  end

  defp price(nil), do: {:ok, nil}
  defp price(price) when is_number(price) and price > 0 and price <= 200, do: {:ok, price / 1}
  defp price(_price), do: {:error, :price}

  defp house(nil), do: {:ok, nil}

  defp house(house) when is_map(house) do
    with {:ok, size} <- between(get(house, :size), 200, 20_000),
         {:ok, year} <- between(get(house, :year), 1800, 2100),
         {:ok, floors} <- between(get(house, :floors), 1, 3),
         heat when heat in @heats <- get(house, :heat),
         {:ok, lot} <- lot(get(house, :lot)) do
      {:ok, %{size: size, year: year, floors: floors, heat: heat, lot: lot}}
    else
      _ -> {:error, :house}
    end
  end

  defp house(_house), do: {:error, :house}

  # A map from JSON has text keys, and a map of the code has atom keys.
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp between(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp between(_value, _min, _max), do: :error

  defp lot(nil), do: {:ok, nil}
  defp lot(lot), do: between(lot, 100, 100_000_000)

  defp name(name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, 40) do
      "" -> {:error, :name}
      name -> {:ok, name}
    end
  end

  defp name(_name), do: {:error, :name}

  @place_names Map.new(@places, &{Atom.to_string(&1), &1})
  @zone_names Map.new(Catalog.zones(), fn {zone, _name} -> {Atom.to_string(zone), zone} end)

  # The van part of a stored build, made whole: the zones of a van that is
  # not there go (`drop_vans/1`), and each van has each of its zones one
  # time. The items of a second zone with the same place go to the first.
  # A van of an older version, or a text that a person changed, can need
  # this: the van part must not stop the build from loading.
  defp repair_vans(build) do
    build = drop_vans(build)

    Enum.reduce(for(i <- build.items, i.type == "camper_van", do: i), build, fn van, build ->
      level = van_level(van.id)
      zones = rooms_on(build, level)
      keep = Enum.uniq_by(zones, & &1.place)
      to = Map.new(zones -- keep, fn z -> {z.id, Enum.find(keep, &(&1.place == z.place)).id} end)

      build = %{
        build
        | rooms: Enum.reject(build.rooms, &Map.has_key?(to, &1.id)),
          items: Enum.map(build.items, &%{&1 | room: Map.get(to, &1.room, &1.room)})
      }

      for {place, name} <- Catalog.zones(),
          not Enum.any?(keep, &(&1.place == place)),
          reduce: build do
        build ->
          {id, build} = next_id(build, "r")
          room = %{id: id, name: name, level: level, place: place, plan: nil}
          %{build | rooms: build.rooms ++ [room]}
      end
    end)
  end

  # The rooms. A room of the house must be valid, with an id of its own. A
  # zone of a van that the app cannot read is lost, and so is a zone with
  # the id of a room before it.
  defp rooms(rooms, house) when is_list(rooms) do
    levels = if house, do: levels(house.floors), else: []
    read = Enum.map(rooms, &read_room(&1, levels))
    ids = for {:house, room} <- read, do: room.id

    if :error in read or Enum.uniq(ids) != ids,
      do: {:error, :rooms},
      else: {:ok, keep_first(read, ids)}
  end

  defp rooms(_rooms, _house), do: {:error, :rooms}

  # The rooms (or the items) of the house, and the parts of a van with an
  # id that is new, in their order.
  defp keep_first(read, ids) do
    {list, _seen} =
      Enum.reduce(read, {[], MapSet.new(ids)}, fn
        {:house, x}, {acc, seen} ->
          {[x | acc], seen}

        {:van, x}, {acc, seen} ->
          if MapSet.member?(seen, x.id),
            do: {acc, seen},
            else: {[x | acc], MapSet.put(seen, x.id)}

        _lost, acc ->
          acc
      end)

    Enum.reverse(list)
  end

  # A zone of a van with a place that the app does not know, or with no
  # id, is lost. A zone with no valid name gets the name of its place.
  defp read_room(%{"level" => "van:" <> _ = level} = room, _levels) do
    with id when is_binary(id) <- room["id"],
         {:ok, place} <- Map.fetch(@zone_names, room["place"]) do
      name =
        case name(room["name"]) do
          {:ok, name} -> name
          {:error, :name} -> Keyword.fetch!(Catalog.zones(), place)
        end

      {:van, %{id: id, name: name, level: level, place: place, plan: read_plan(room["plan"])}}
    else
      _ -> :lost
    end
  end

  defp read_room(%{"id" => id, "name" => name, "level" => level, "place" => place} = room, levels)
       when is_binary(id) and is_binary(level) do
    with {:ok, name} <- name(name),
         true <- level in levels,
         {:ok, place} <- Map.fetch(@place_names, place) do
      {:house, %{id: id, name: name, level: level, place: place, plan: read_plan(room["plan"])}}
    else
      _ -> :error
    end
  end

  defp read_room(_room, _levels), do: :error

  # Reads each element of a list with fun, or gives :error.
  defp all(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp unique({:ok, list}, error) do
    list = Enum.reverse(list)
    ids = Enum.map(list, & &1.id)
    if Enum.uniq(ids) == ids, do: {:ok, list}, else: {:error, error}
  end

  defp unique(:error, error), do: {:error, error}

  # The items: an item of the house must be valid, with an id of its own.
  # An item of a van that the app cannot read, or an item in a room that is
  # not there (a zone that is lost), goes home or goes away (`van_item/4`).
  defp items(items, rooms) when is_list(items) do
    by_id = Map.new(rooms, &{&1.id, &1})
    house = Enum.reject(rooms, &van_level?(&1.level))
    read = Enum.map(items, &read_item(&1, by_id, house))
    ids = for {:house, item} <- read, do: item.id

    if :error in read or Enum.uniq(ids) != ids,
      do: {:error, :items},
      else: {:ok, keep_first(read, ids)}
  end

  defp items(_items, _rooms), do: {:error, :items}

  # An item of a kind that goes only in a van, in a room of the house, is
  # an item of a van.
  defp read_item(%{} = item, by_id, house) do
    case Map.get(by_id, item["room"]) do
      %{level: "van:" <> _} = zone ->
        van_item(item, zone, by_id, house)

      %{} = room ->
        if van_only?(item["type"]),
          do: van_item(item, nil, by_id, house),
          else: house_item(item, room, house)

      nil ->
        van_item(item, nil, by_id, house)
    end
  end

  defp read_item(_item, _by_id, _house), do: :error

  defp van_only?(type) do
    case Catalog.kind(type) do
      %{places: places} -> not Enum.any?(places, &(&1 in @places))
      nil -> false
    end
  end

  # A camper van: a van must not stop the build from loading. A number that
  # is not valid gets the default number. A van in a room where it cannot
  # go goes to the first room where it can go, or goes away.
  defp house_item(%{"type" => "camper_van", "id" => id} = item, room, house)
       when is_binary(id) do
    places = Catalog.kind("camper_van").places
    room = if room.place in places, do: room, else: Enum.find(house, &(&1.place in places))

    if room,
      do:
        {:house,
         %{
           id: id,
           type: "camper_van",
           room: room.id,
           typical: Map.get(item, "typical") == true,
           planned: Map.get(item, "planned") == true,
           backup: false,
           home: nil,
           params: Catalog.loose_params("camper_van", Map.get(item, "params"))
         }
         |> Map.merge(read_spot(item))},
      else: :skip
  end

  defp house_item(%{"type" => "camper_van"}, _room, _house), do: :skip

  # An item of the house. An item of a build of an older version has no
  # `planned` and no `backup`: false. Only an item in a van has a home.
  defp house_item(
         %{"id" => id, "type" => type, "typical" => typical, "params" => params} = item,
         room,
         _house
       )
       when is_binary(id) and is_boolean(typical) do
    with %{} = kind <- Catalog.kind(type),
         true <- room.place in kind.places,
         planned when is_boolean(planned) <- Map.get(item, "planned", false),
         backup when is_boolean(backup) <- Map.get(item, "backup", false),
         {:ok, params} <- Catalog.params(type, params) do
      {:house,
       Map.merge(
         %{
           id: id,
           type: type,
           room: room.id,
           typical: typical,
           planned: planned,
           backup: backup,
           home: nil,
           params: params
         },
         read_spot(item)
       )}
    else
      _ -> :error
    end
  end

  defp house_item(_item, _room, _house), do: :error

  # An item in a zone of a van, or in a room that is not there. A number
  # that is not valid gets the default number. An item that cannot go in
  # its zone goes to the electrical bay of the van. A station with no zone
  # goes home. A home must be a room of the house where the kind can go:
  # else the first such room. An item that the app cannot read goes away.
  defp van_item(%{"id" => id, "type" => type} = item, zone, by_id, house) when is_binary(id) do
    case Catalog.kind(type) do
      %{} = kind ->
        home = item_home(kind, Map.get(item, "home"), house)
        bay = zone && Enum.find(Map.values(by_id), &(&1.level == zone.level and &1.place == :bay))

        room =
          cond do
            zone && zone.place in kind.places -> zone.id
            bay && :bay in kind.places -> bay.id
            true -> nil
          end

        item =
          Map.merge(
            %{
              id: id,
              type: type,
              room: room || home,
              typical: Map.get(item, "typical") == true,
              planned: Map.get(item, "planned") == true,
              backup: false,
              home: if(room, do: home),
              params: Catalog.loose_params(type, Map.get(item, "params"))
            },
            read_spot(item)
          )

        if item.room, do: {:van, item}, else: :skip

      nil ->
        :skip
    end
  end

  defp van_item(_item, _zone, _by_id, _house), do: :skip

  defp item_home(_kind, nil, _house), do: nil

  defp item_home(kind, home, house) do
    rooms = Enum.filter(house, &(&1.place in kind.places))
    Enum.find_value(rooms, &(&1.id == home && home)) || Enum.find_value(rooms, & &1.id)
  end

  # The place of an item in its room, its turn and its size. A part that
  # is not valid goes away: the item goes to a free place
  # (`DIY.Layout.fill/1`), with no turn, or with its typical size.
  defp read_spot(item) do
    %{at: read_at(item["at"]), turn: item_turn(item), size: read_size(item["size"])}
  end

  defp read_at(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y),
    do: if(abs(x) <= Layout.max_at() and abs(y) <= Layout.max_at(), do: %{x: x, y: y})

  defp read_at(_at), do: nil

  defp item_turn(%{"turn" => turn}) when turn in 0..3, do: turn
  defp item_turn(_item), do: 0

  defp read_size(%{"w" => w, "d" => d, "h" => h}) do
    size = %{w: w, d: d, h: h}
    if Layout.valid_size?(size), do: size
  end

  defp read_size(_size), do: nil

  defp read_plan(%{"x" => x, "y" => y, "w" => w, "d" => d}) do
    plan = %{x: x, y: y, w: w, d: d}
    if Layout.valid_plan?(plan), do: plan
  end

  defp read_plan(_plan), do: nil

  defp hints(hints) when is_list(hints) do
    if Enum.all?(hints, &(&1 in @hints)), do: {:ok, Enum.uniq(hints)}, else: {:error, :hints}
  end

  defp hints(_hints), do: {:error, :hints}
end
