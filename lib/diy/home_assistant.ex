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
  """

  alias DIY.Build

  @type floor :: %{id: String.t(), name: String.t(), level: integer() | nil}
  @type area :: %{id: String.t(), name: String.t(), floor: String.t() | nil}

  # The words of a name of an area outside: in a yard, and in a garage or a
  # shed. An attic is under the roof.
  @yard ~w(yard garden patio porch deck lawn pool driveway terrace balcony)
  @garage ~w(garage shed carport)
  @attic ~w(attic loft)

  @doc """
  The name of a room or of an area for a match: no case and no spaces, as
  Home Assistant does (`normalize_name`).
  """
  def key(name), do: name |> String.downcase() |> String.replace(" ", "")

  @doc "The rooms of the house that can have an area: not the roof."
  def rooms(build) do
    for room <- Build.house_view(build).rooms, room.place != :roof, do: room
  end

  @doc """
  The match of the rooms and the areas: `%{both: [{room, area}], app:
  [room], ha: [area]}`. A link to an area that is not there now does not
  count.
  """
  def match(build, areas) do
    rooms = rooms(build)
    by_id = Map.new(areas, &{&1.id, &1})

    {linked, rooms} =
      Enum.reduce(rooms, {[], []}, fn room, {pairs, rest} ->
        area = by_id[build.areas[room.id]]

        if area && not Enum.any?(pairs, fn {_room, other} -> other.id == area.id end),
          do: {[{room, area} | pairs], rest},
          else: {pairs, [room | rest]}
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
end
