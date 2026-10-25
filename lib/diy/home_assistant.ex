defmodule DIY.HomeAssistant do
  @moduledoc """
  The rooms of the app and the areas of Home Assistant.

  Home Assistant has floors and areas. A floor has a level: 0 is the
  ground floor, 1 the floor over it. An area is a room, on a floor or on
  none. The app matches each room of the house with an area: first by the
  link that the build keeps (`DIY.Build.link_area/3`), then by the name.
  Home Assistant compares names with no case and no spaces, and so does
  the app. The match gives three lists: the rooms in both, the rooms only
  in the app, and the areas only in Home Assistant.

  The roof is a surface, not a room: it has no area. The zones of a van
  have none either.

  The devices of Home Assistant come into the house as ghosts
  (`ghosts/4`). A ghost is a device in an area of a room, with a kind of
  the catalog (`kind_of/1`). It has no item. A tap on a ghost adds its item
  (`DIY.Build.add_device/6`).

  A power station of Pecron or EcoFlow (`station?/1`) is a ghost of the
  kind `power_station`. When the app knows its model (`station_model/2`),
  its item gets the model, and so the numbers of the model.
  """

  alias DIY.{Build, Catalog, Layout}

  @type floor :: %{id: String.t(), name: String.t(), level: integer() | nil}
  @type area :: %{id: String.t(), name: String.t(), floor: String.t() | nil}
  @type device :: %{
          id: String.t(),
          name: String.t(),
          area: String.t() | nil,
          domains: [String.t()],
          station: String.t() | nil,
          model: String.t() | nil
        }

  # The words of a name of a device, and the kind of each. When two words
  # end at the same place, the longer one wins: a "water heater" is not a
  # space heater.
  @phrases [
    {~w(microwave oven), "microwave"},
    {~w(dish washer), "dishwasher"},
    {~w(washer dryer), "washer_dryer"},
    {~w(fridge freezer), "fridge"},
    {~w(backlight), "lights"},
    {~w(water heater), "water_heater"},
    {~w(space heater), "space_heater"},
    {~w(heater), "space_heater"},
    {~w(pool pump), "pool_pump"},
    {~w(heat pump), "mini_split"},
    {~w(mini split), "mini_split"},
    {~w(air conditioner), "mini_split"},
    {~w(aircon), "mini_split"},
    {~w(ac), "mini_split"},
    {~w(ev charger), "ev"},
    {~w(car charger), "ev"},
    {~w(wall connector), "ev"},
    {~w(wallbox), "ev"},
    {~w(fridge), "fridge"},
    {~w(refrigerator), "fridge"},
    {~w(freezer), "freezer"},
    {~w(dishwasher), "dishwasher"},
    {~w(washer), "washer"},
    {~w(washing machine), "washer"},
    {~w(dryer), "dryer"},
    {~w(microwave), "microwave"},
    {~w(oven), "range"},
    {~w(stove), "range"},
    {~w(cooktop), "range"},
    {~w(tv), "tv"},
    {~w(television), "tv"},
    {~w(computer), "computer"},
    {~w(pc), "computer"},
    {~w(cpap), "cpap"},
    {~w(fan), "ceiling_fan"},
    {~w(light), "lights"},
    {~w(lamp), "lights"},
    {~w(bulb), "lights"}
  ]

  # The phrases by their last word, from the end: [{phrase, size, type}],
  # in the order of @phrases. And the phrases of two words or more as one
  # word ("heatpump"). The stem of a word is as in stem/1.
  stem = fn word -> if byte_size(word) > 2, do: String.trim_trailing(word, "s"), else: word end

  @by_last Enum.reduce(Enum.reverse(@phrases), %{}, fn {phrase, type}, index ->
             stems = Enum.map(phrase, stem)
             entry = {Enum.reverse(stems), length(stems), type}
             Map.update(index, List.last(stems), [entry], &[entry | &1])
           end)

  @joined for {phrase, type} <- Enum.reverse(@phrases),
              length(phrase) > 1,
              into: %{},
              do: {phrase |> Enum.map(stem) |> Enum.join(), {length(phrase), type}}

  # The domains of the entities of a device with no word of a kind. A
  # thermostat, a speaker or a plug can be many things: no kind.
  @domains [{"light", "lights"}, {"fan", "ceiling_fan"}, {"water_heater", "water_heater"}]

  # The makers of the power stations that the hook finds
  # (STATION_SOURCES in assets/js/home_assistant.js). Each is the start of
  # the keys of its models in the catalog.
  @makers ~w(pecron ecoflow)

  # The most ghosts on the plan in one room, and in the house. A large
  # Home Assistant can have hundreds of devices: the plan shows the first
  # ones, and the next ones come when the person adds them.
  @per_room 8
  @in_house 60

  # The words of a name of an area outside: in a yard, and in a garage or a
  # shed. An attic is under the roof.
  @yard ~w(yard garden patio porch deck lawn pool driveway terrace balcony)
  @garage ~w(garage shed carport)
  @attic ~w(attic loft)

  @doc """
  The name of a room or of an area for a match: no case and no spaces.
  Home Assistant does the same (`normalize_name`). It uses a case fold, so
  "ß" is "ss".
  """
  def key(name), do: name |> :string.casefold() |> String.replace(" ", "")

  @doc "The rooms of the house that can have an area (`DIY.Build.area_room?/1`)."
  def rooms(build), do: Enum.filter(build.rooms, &Build.area_room?/1)

  @doc """
  The match of the rooms and the areas: `%{both: [{room, area}], app:
  [room], ha: [area]}`. A link to an area that is not there now does not
  count. The build has one room for each area at most.
  """
  def match(build, areas) do
    rooms = rooms(build)
    by_id = Map.new(areas, &{&1.id, &1})

    {linked, rooms} =
      Enum.reduce(rooms, {[], []}, fn room, {pairs, rest} ->
        case by_id[build.areas[room.id]] do
          nil -> {pairs, [room | rest]}
          area -> {[{room, area} | pairs], rest}
        end
      end)

    used = MapSet.new(linked, fn {_room, area} -> area.id end)
    areas = Enum.reject(areas, &MapSet.member?(used, &1.id))

    {named, app, ha} =
      Enum.reduce(Enum.reverse(rooms), {[], [], areas}, fn room, {pairs, app, ha} ->
        case Enum.find(ha, &(key(&1.name) == key(room.name))) do
          nil -> {pairs, [room | app], ha}
          area -> {[{room, area} | pairs], app, List.delete(ha, area)}
        end
      end)

    %{
      both: Enum.reverse(linked) ++ Enum.reverse(named),
      app: Enum.reverse(app),
      ha: ha
    }
  end

  @doc """
  The rooms only in the app that cannot get a new area (their ids). Home
  Assistant refuses a second area with one name. So a room cannot get an
  area when Home Assistant has an area with its name. It also cannot when
  a room before it in the list has its name.
  """
  def blocked(match, areas) do
    used = MapSet.new(areas, &key(&1.name))

    {blocked, _used} =
      Enum.reduce(match.app, {MapSet.new(), used}, fn room, {blocked, used} ->
        if MapSet.member?(used, key(room.name)),
          do: {MapSet.put(blocked, room.id), used},
          else: {blocked, MapSet.put(used, key(room.name))}
      end)

    blocked
  end

  @doc """
  The level and the place of a new room for an area: the floor of the
  area, else a guess from its name. A level that the house
  does not have gives floor 1.
  """
  def place_of(area, floors, house_floors) do
    level = Enum.find_value(floors, fn floor -> floor.id == area.floor && floor.level end)
    words = area.name |> String.downcase() |> String.split(~r/[^a-z]+/, trim: true)

    cond do
      is_integer(level) and level in 0..(house_floors - 1)//1 -> {"f#{level + 1}", :indoor}
      Enum.any?(words, &(&1 in @yard)) -> {"outside", :outdoor}
      Enum.any?(words, &(&1 in @garage)) -> {"outside", :indoor}
      Enum.any?(words, &(&1 in @attic)) -> {"roof", :indoor}
      true -> {"f1", :indoor}
    end
  end

  @doc """
  The level of the floor in Home Assistant for a room: floor 1 is level 0.
  A room around the house or in the attic has no floor (`nil`).
  """
  def floor_level(%{level: "f" <> n}), do: String.to_integer(n) - 1
  def floor_level(_room), do: nil

  @doc """
  The changes of the build for a match:

  - `links`: each room and its area, for the rooms in both;
  - `adds`: the areas to add as rooms, each with its level and its place.

  The app links each new room to its area. It gives the build, and the
  names of the areas that it could not add. For example, the house does
  not have the level.
  """
  def apply(build, links, adds) do
    build =
      Enum.reduce(links, build, fn {room, area}, build ->
        case Build.link_area(build, room, area) do
          {:ok, build} -> build
          {:error, _reason} -> build
        end
      end)

    Enum.reduce(adds, {build, []}, fn {area, level, place}, {build, missed} ->
      with {:ok, build, id} <- Build.add_room(build, area.name, level, place),
           {:ok, build} <- Build.link_area(build, id, area.id) do
        {build, missed}
      else
        _error -> {build, missed ++ [area.name]}
      end
    end)
  end

  @doc """
  The kind of the catalog for a device of Home Assistant, or `nil`. The
  words of its name come first, then the words of its model: "Kitchen
  fridge" is a fridge. Of two words, the last in the name wins: "TV room
  lights" are lights. A word can have an "s" at its end, and two words can
  be one ("heatpump"). With no word, the domains of its entities give the
  kind: a light, a fan or a water heater.
  """
  def kind_of(%{name: name, domains: domains} = device) do
    if station?(device),
      do: "power_station",
      else:
        by_words(name) || by_words(device[:model]) ||
          Enum.find_value(@domains, fn {domain, type} -> domain in domains && type end)
  end

  @doc "The makers of the power stations that the hook finds: `pecron` and `ecoflow`."
  def makers, do: @makers

  @doc """
  True for a power station: the hook found its battery and its power out
  (`station` is its maker). Its kind is `power_station`, whatever its
  name.
  """
  def station?(device), do: Map.get(device, :station) in @makers

  @doc """
  The key of the model of a power station of a maker
  (`DIY.Catalog.station_models/0`), from the model of its device, or
  `nil`. The match has no case, no spaces and no signs. The name of the
  maker can come first. For example "E3800LFP" and "PECRON E3800LFP" are
  the E3800LFP. "DELTA_PRO_3" and "EcoFlow DELTA Pro 3" are the DELTA Pro
  3.
  """
  def station_model(maker, model) when maker in @makers and is_binary(model) do
    code = model |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
    prefix = maker <> "_"

    Enum.find_value(Catalog.station_models(), fn {key, _name, _numbers, _size, _source} ->
      own = key |> String.replace_prefix(prefix, "") |> String.replace("_", "")
      String.starts_with?(key, prefix) and code in [own, maker <> own] and key
    end)
  end

  def station_model(_maker, _model), do: nil

  @doc """
  The numbers of the item of a ghost, for `DIY.Build.add_device/6`: the
  model of a power station, when the app knows it. Else none.
  """
  def device_values(device, "power_station") do
    case station_model(device[:station], device[:model]) do
      key when is_binary(key) -> %{"model" => key}
      nil -> %{}
    end
  end

  def device_values(_device, _type), do: %{}

  defp by_words(nil), do: nil

  defp by_words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.map(&stem/1)
    |> Enum.reverse()
    |> last_phrase()
  end

  # A word with no "s" at its end ("lights" is "light").
  defp stem(word) when byte_size(word) > 2, do: String.trim_trailing(word, "s")
  defp stem(word), do: word

  # The kind of the last phrase in the words (from the end). Of two phrases
  # that end at one word, the longer one wins. One look for each word, so
  # a long name costs little.
  defp last_phrase([]), do: nil

  defp last_phrase([word | before] = words) do
    in_row =
      for {phrase, size, type} <- Map.get(@by_last, word, []),
          Enum.take(words, size) == phrase,
          do: {size, type}

    case in_row ++ List.wrap(@joined[word]) do
      [] -> last_phrase(before)
      matches -> matches |> Enum.max_by(&elem(&1, 0)) |> elem(1)
    end
  end

  @doc """
  The ghosts of the devices of Home Assistant on the plan, and the count
  of all the ghosts: `{ghosts, count}`. A ghost is a device with no item,
  in the area of a room of the house (`match/2`). It has a kind that can go
  in the room. A ghost has its device, the name of the device, its room,
  its kind. It also has the numbers of its item (`device_values/2`), and a
  free place in its room (`at`). A device with no name
  gives the name of its kind. The plan shows 8 ghosts in a room and 60 in
  the house at most.

  A device can have its kind already (`kind`): then the app does not read
  its name again.

  `kept` has the places of the ghosts before: `%{device => %{room: room,
  at: at}}`. A ghost keeps its place while that place is free. So when
  the person adds one ghost, the others do not move.
  """
  def ghosts(build, devices, areas, kept \\ %{}) do
    rooms = for {room, area} <- match(build, areas).both, into: %{}, do: {area.id, room}
    linked = MapSet.new(Map.values(build.devices))

    all =
      for device <- devices,
          not MapSet.member?(linked, device.id),
          room = rooms[device.area],
          room != nil and room.plan != nil,
          type = Map.get_lazy(device, :kind, fn -> kind_of(device) end),
          type != nil and Catalog.fits?(Catalog.kind(type), room),
          do: %{
            device: device.id,
            name: name(device.name, type),
            room: room.id,
            type: type,
            values: device_values(device, type)
          }

    shown =
      all
      |> Enum.group_by(& &1.room)
      |> Enum.flat_map(fn {_room, ghosts} -> Enum.take(ghosts, @per_room) end)
      |> MapSet.new(& &1.device)

    ghosts = all |> Enum.filter(&MapSet.member?(shown, &1.device)) |> Enum.take(@in_house)
    {place(build, ghosts, kept), length(all)}
  end

  # A device with no name has the name of its kind.
  defp name(name, type) do
    if String.trim(name) == "", do: Catalog.kind(type).name, else: name
  end

  # A free place for each ghost in its room, where no item and no ghost
  # before it is. It is its place before (`kept`) when that place is still
  # free. Else it is the place that is the farthest from them (`spread/3`).
  # So the ghosts and their names do not cover each other.
  defp place(build, ghosts, kept) do
    plans = Map.new(build.rooms, &{&1.id, &1.plan})

    {placed, _boxes} =
      Enum.map_reduce(ghosts, %{}, fn ghost, boxes ->
        item = %{type: ghost.type, size: nil, turn: 0, params: Catalog.defaults(ghost.type)}
        room = plans[ghost.room]

        others =
          Map.get_lazy(boxes, ghost.room, fn ->
            for i <- build.items, i.room == ghost.room, i.at != nil, do: Layout.item_box(i)
          end)

        at =
          case kept[ghost.device] do
            %{room: room_id, at: at} when room_id == ghost.room ->
              if free?(Layout.item_box(Map.put(item, :at, at)), room, others),
                do: at,
                else: spread(item, room, others)

            _ ->
              spread(item, room, others)
          end

        box = Layout.item_box(Map.put(item, :at, at))
        {Map.put(ghost, :at, at), Map.put(boxes, ghost.room, [box | others])}
      end)

    placed
  end

  # A box in its room, on no other box.
  defp free?(box, room, others) do
    box.x >= 0 and box.y >= 0 and box.x + box.w <= room.w and box.y + box.d <= room.d and
      not Enum.any?(others, &Layout.overlap?(&1, box))
  end

  @doc """
  A free place for an item in a room, where it does not overlap the boxes
  of the others. At this place, the nearest center of a box is the
  farthest. The places are on a grid of about 30 steps on each side, 12
  inches at least. An item that hangs on a wall (a mini split) is
  on the back wall. A ceiling fan is on the ceiling: it can be anywhere.
  With no free place (or for an item larger than the room), it is the
  back corner.
  """
  def spread(item, room, others) do
    {w, d} = Layout.extent(item)
    step = max(12, round(max(room.w, room.d) / 30))
    centers = Enum.map(others, &{&1.x + &1.w / 2, &1.y + &1.d / 2})
    wall? = Catalog.lift(item.type) > 0 and item.type != "ceiling_fan"
    back = if wall?, do: 0, else: max(room.d - d, 0)

    # An item that is larger than its room has no free place in it.
    free =
      if w > room.w or d > room.d,
        do: [],
        else:
          for(
            y <- 0..back//step,
            x <- 0..(room.w - w)//step,
            box = %{x: x, y: y, w: w, d: d},
            not Enum.any?(others, &Layout.overlap?(&1, box)),
            do: {x, y}
          )

    case free do
      [] ->
        %{x: 0, y: 0}

      free ->
        {x, y} =
          Enum.max_by(free, fn {x, y} ->
            {cx, cy} = {x + w / 2, y + d / 2}

            Enum.reduce(
              centers,
              :infinity,
              &min(&2, (elem(&1, 0) - cx) ** 2 + (elem(&1, 1) - cy) ** 2)
            )
          end)

        %{x: x, y: y}
    end
  end

  @doc """
  The count of the devices of Home Assistant with a kind, in an area that
  is not a room of the house. The match of the rooms
  (`DIYWeb.HomeAssistant.rooms_sheet/1`) can add their areas as rooms. A
  device in no area does not count: no match can help it.
  """
  def away(build, devices, areas) do
    rooms = MapSet.new(match(build, areas).both, fn {_room, area} -> area.id end)
    linked = MapSet.new(Map.values(build.devices))

    Enum.count(
      devices,
      &(&1.area != nil and not MapSet.member?(linked, &1.id) and
          not MapSet.member?(rooms, &1.area) and
          Map.get_lazy(&1, :kind, fn -> kind_of(&1) end) != nil)
    )
  end
end
