defmodule DIY.Build do
  @moduledoc """
  The build of a user: the place, the house, its rooms and its items. The
  build stays on the device (see `DIYWeb.Device`). The server reads it from
  JSON, and writes it to JSON after each change.

  `revision` counts the changes. Each change adds 1. `stamp` is a random
  name for each change. The device writes a build only on the build that
  it comes from: the stored stamp must be the stamp of that build (see
  `DIYWeb.Device` and `specs/Device.tla`).

  `from_json/1` accepts only a build that it can read in full. It never
  raises: a stored text from an old version, or a text that a person
  changed, gives an error, and the page starts a new build.

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
    and a `place` (`:indoor`, `:outdoor` or `:roof`).
  - `items`: each item has an `id`, a `type` (`DIY.Catalog`), a `room`,
    `typical` (true for an item of a preset that the user did not check),
    `planned` (true for an item that the user does not have yet: the
    what-if of `DIY.Power`), `backup` (true for an item that a power
    station runs) and its `params`.
  - `usage`: the real usage of the meter file (`DIY.Usage`), or `nil`.
  - `power`: how the house uses its power stations, and the prices of the
    night and of the power to the grid (`DIY.Power.settings/0`).
  - `seq`: the number of the last id.
  - `hints`: the hints that the user closed.
  """

  alias DIY.Catalog

  @version 1
  @doors ~w(my_house planning)
  @heats ~w(gas heat_pump electric)
  @hints ~w(swipe)
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
            seq: 0,
            hints: []

  @type room :: %{id: String.t(), name: String.t(), level: String.t(), place: atom()}
  @type item :: %{
          id: String.t(),
          type: String.t(),
          room: String.t(),
          typical: boolean(),
          planned: boolean(),
          backup: boolean(),
          params: map()
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
  stamp.
  """
  @spec change(t(), (t() -> t())) :: t()
  def change(%__MODULE__{revision: revision} = build, fun) do
    %__MODULE__{} = changed = fun.(build)
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
          new = %{id: id, name: room.name, level: room.level, place: room.place}
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
    if Enum.all?(rooms, &(&1.level in levels)), do: :ok, else: {:error, :floors}
  end

  @doc "Adds a room on a level."
  @spec add_room(t(), String.t(), String.t(), atom()) ::
          {:ok, t(), String.t()} | {:error, atom()}
  def add_room(%__MODULE__{house: %{floors: floors}} = build, name, level, place) do
    with {:ok, name} <- name(name),
         true <- level in levels(floors) || {:error, :level},
         true <- place in @places || {:error, :place} do
      {id, build} = next_id(build, "r")
      room = %{id: id, name: name, level: level, place: place}
      {:ok, change(build, &%{&1 | rooms: &1.rooms ++ [room]}), id}
    end
  end

  def add_room(_build, _name, _level, _place), do: {:error, :house}

  @doc "Gives a room a new name."
  @spec rename_room(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def rename_room(build, id, name) do
    with {:ok, name} <- name(name),
         {:ok, _room} <- room(build, id) do
      rooms = Enum.map(build.rooms, &if(&1.id == id, do: %{&1 | name: name}, else: &1))
      {:ok, change(build, &%{&1 | rooms: rooms})}
    end
  end

  @doc "Removes a room and its items."
  @spec delete_room(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def delete_room(build, id) do
    with {:ok, _room} <- room(build, id) do
      {:ok,
       change(build, fn build ->
         no_meter_no_usage(%{
           build
           | rooms: Enum.reject(build.rooms, &(&1.id == id)),
             items: Enum.reject(build.items, &(&1.room == id))
         })
       end)}
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
      {:ok, change(build, &%{&1 | items: &1.items ++ [item]}), id}
    end
  end

  @doc """
  Changes the numbers of an item. The item is not typical after this: the
  user checked it.
  """
  @spec update_item(t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def update_item(build, id, values) when is_map(values) do
    with {:ok, item} <- item(build, id),
         {:ok, params} <- Catalog.params(item.type, Map.merge(item.params, values)) do
      {:ok, replace_item(build, %{item | params: params, typical: false})}
    end
  end

  defp new_item(id, type, room, params),
    do: %{
      id: id,
      type: type,
      room: room,
      typical: false,
      planned: false,
      backup: false,
      params: params
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

  @doc "Moves an item to a different room, where its kind can go."
  @spec move_item(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def move_item(build, id, room_id) do
    with {:ok, item} <- item(build, id),
         {:ok, room} <- room(build, room_id),
         true <- room.place in Catalog.kind(item.type).places || {:error, :place} do
      {:ok, replace_item(build, %{item | room: room_id})}
    end
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
         &no_meter_no_usage(%{&1 | items: Enum.reject(&1.items, fn i -> i.id == id end)})
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
         {:ok, seq} <- count(map["seq"], :seq),
         seq = last_id(seq, rooms ++ items),
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
         seq: seq,
         hints: hints
       }}
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

  defp rooms(rooms, house) when is_list(rooms) do
    levels = if house, do: levels(house.floors), else: []

    rooms
    |> all(&read_room(&1, levels))
    |> unique(:rooms)
  end

  defp rooms(_rooms, _house), do: {:error, :rooms}

  defp read_room(%{"id" => id, "name" => name, "level" => level, "place" => place}, levels)
       when is_binary(id) do
    with {:ok, name} <- name(name),
         true <- level in levels,
         {:ok, place} <- Map.fetch(@place_names, place) do
      {:ok, %{id: id, name: name, level: level, place: place}}
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

  defp items(items, rooms) when is_list(items) do
    places = Map.new(rooms, &{&1.id, &1.place})

    items
    |> all(&read_item(&1, places))
    |> unique(:items)
  end

  defp items(_items, _rooms), do: {:error, :items}

  # An item of a build of an older version has no `planned` and no
  # `backup`: they are false.
  defp read_item(
         %{"id" => id, "type" => type, "room" => room, "typical" => typical, "params" => params} =
           item,
         places
       )
       when is_binary(id) and is_boolean(typical) do
    with %{} = kind <- Catalog.kind(type),
         {:ok, place} <- Map.fetch(places, room),
         true <- place in kind.places,
         planned when is_boolean(planned) <- Map.get(item, "planned", false),
         backup when is_boolean(backup) <- Map.get(item, "backup", false),
         {:ok, params} <- Catalog.params(type, params) do
      {:ok,
       %{
         id: id,
         type: type,
         room: room,
         typical: typical,
         planned: planned,
         backup: backup,
         params: params
       }}
    else
      _ -> :error
    end
  end

  defp read_item(_item, _places), do: :error

  defp hints(hints) when is_list(hints) do
    if Enum.all?(hints, &(&1 in @hints)), do: {:ok, Enum.uniq(hints)}, else: {:error, :hints}
  end

  defp hints(_hints), do: {:error, :hints}
end
