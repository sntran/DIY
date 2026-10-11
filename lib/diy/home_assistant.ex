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
  (`ghosts/3`). A ghost is a device in an area of a room, with a kind of
  the catalog (`kind_of/1`). It has no item. A tap on a ghost adds its item
  (`DIY.Build.add_device/4`).
  """

  alias DIY.{Build, Catalog, Layout}

  @type floor :: %{id: String.t(), name: String.t(), level: integer() | nil}
  @type area :: %{id: String.t(), name: String.t(), floor: String.t() | nil}
  @type device :: %{
          id: String.t(),
          name: String.t(),
          area: String.t() | nil,
          domains: [String.t()],
          model: String.t() | nil
        }

  # The words of a name of a device, and the kind of each. When two words
  # end at the same place, the longer one wins: a "water heater" is not a
  # space heater.
  @phrases [
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

  # The domains of the entities of a device with no word of a kind. A
  # thermostat, a speaker or a plug can be many things: no kind.
  @domains [{"light", "lights"}, {"fan", "ceiling_fan"}, {"water_heater", "water_heater"}]

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
    by_words(name) || by_words(device[:model]) ||
      Enum.find_value(@domains, fn {domain, type} -> domain in domains && type end)
  end

  defp by_words(nil), do: nil

  defp by_words(text) do
    words = text |> String.downcase() |> String.split(~r/[^a-z0-9]+/u, trim: true)
    stems = Enum.map(words, &stem/1)

    matches =
      for {phrase, type} <- @phrases,
          {last, size} <- ends(stems, Enum.map(phrase, &stem/1)),
          do: {last, size, type}

    case Enum.max_by(matches, fn {last, size, _type} -> {last, size} end, fn -> nil end) do
      nil -> nil
      {_last, _size, type} -> type
    end
  end

  # A word with no "s" at its end ("lights" is "light").
  defp stem(word) when byte_size(word) > 2, do: String.trim_trailing(word, "s")
  defp stem(word), do: word

  # Where a phrase ends in the words, and its size: the words in a row, or
  # the phrase as one word ("heatpump").
  defp ends(words, phrase) do
    n = length(phrase)
    joined = Enum.join(phrase)

    for {_word, i} <- Enum.with_index(words),
        Enum.slice(words, i, n) == phrase or (n > 1 and Enum.at(words, i) == joined),
        do: {if(Enum.at(words, i) == joined, do: i, else: i + n - 1), n}
  end

  @doc """
  The ghosts of the devices of Home Assistant. A ghost is a device with
  no item, in the area of a room of the house (`match/2`). It has a kind
  that can go in the room. A ghost has its device, the name of the device,
  its room, its kind, and a free place in its room (`at`).
  """
  def ghosts(build, devices, areas) do
    rooms = for {room, area} <- match(build, areas).both, into: %{}, do: {area.id, room}
    linked = MapSet.new(Map.values(build.devices))

    ghosts =
      for device <- devices,
          not MapSet.member?(linked, device.id),
          room = rooms[device.area],
          room != nil and room.plan != nil,
          type = kind_of(device),
          type != nil and room.place in Catalog.kind(type).places,
          do: %{device: device.id, name: device.name, room: room.id, type: type}

    place(build, ghosts)
  end

  # A free place for each ghost in its room, where no item and no ghost
  # before it is. It is the place that is the farthest from them
  # (`spread/3`). So the ghosts and their names do not cover each other.
  defp place(build, ghosts) do
    plans = Map.new(build.rooms, &{&1.id, &1.plan})

    {placed, _boxes} =
      Enum.map_reduce(ghosts, %{}, fn ghost, boxes ->
        item = %{type: ghost.type, size: nil, turn: 0, params: Catalog.defaults(ghost.type)}

        others =
          Map.get_lazy(boxes, ghost.room, fn ->
            for i <- build.items, i.room == ghost.room, i.at != nil, do: Layout.item_box(i)
          end)

        at = spread(item, plans[ghost.room], others)
        box = Layout.item_box(Map.put(item, :at, at))
        {Map.put(ghost, :at, at), Map.put(boxes, ghost.room, [box | others])}
      end)

    placed
  end

  @doc """
  A free place for an item in a room, where it does not overlap the boxes
  of the others. At this place, the nearest center of a box is the
  farthest. The places are on a grid of about 60 steps on each side, as in
  `DIY.Layout.free_at/3`. An item that hangs on a wall (a mini split) is
  on the back wall. A ceiling fan is on the ceiling: it can be anywhere.
  With no free place, it is the back corner.
  """
  def spread(item, room, others) do
    {w, d} = Layout.extent(item)
    step = max(6, round(max(room.w, room.d) / 60))
    centers = Enum.map(others, &{&1.x + &1.w / 2, &1.y + &1.d / 2})
    wall? = Catalog.lift(item.type) > 0 and item.type != "ceiling_fan"
    back = if wall?, do: 0, else: max(room.d - d, 0)

    free =
      for y <- 0..back//step,
          x <- 0..max(room.w - w, 0)//step,
          box = %{x: x, y: y, w: w, d: d},
          not Enum.any?(others, &Layout.overlap?(&1, box)),
          do: {x, y}

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
          not MapSet.member?(rooms, &1.area) and kind_of(&1) != nil)
    )
  end
end
