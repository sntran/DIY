defmodule DIYWeb.VanCutawayTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, Catalog, House}
  alias DIYWeb.{Cutaway, VanCutaway}
  alias DIYWeb.Icon.Shapes

  # A house with a camper van of a model.
  defp van(model) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 1, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    build = Build.put_house(build, house, rooms, items)
    drive = Enum.find(build.rooms, &(&1.name == "Driveway")).id
    {:ok, build, van} = Build.add_item(build, drive, "camper_van")
    {:ok, build} = Build.update_item(build, van, %{"model" => model})
    {build, van}
  end

  defp view(build, van), do: VanCutaway.view(build, elem(Build.item(build, van), 1))

  test "the two layers of each model: the floor and the roof" do
    for {model, _name, _numbers, _source} <- Catalog.van_models() do
      {build, van} = van(model)
      view = view(build, van)
      assert Enum.map(view.levels, & &1.id) == ["floor", "roof"]
      # The page of a van starts on all the van, and it keeps its look.
      html = render_component(&Cutaway.cutaway/1, view: view)
      refute html =~ "data-start"
      refute html =~ "cutaway-house"
      # The van has no pill under the names of its zones.
      refute html =~ "data-pill"
      assert html =~ ~s(class="cutaway block w-full h-full touch-none select-none")
      [floor, roof] = view.levels
      assert roof.z > floor.z

      # The zones with a plan: five on the floor, and the roof of the van.
      assert length(floor.rooms) == 5
      assert length(roof.rooms) == 1

      ids = Enum.map(floor.objects, & &1.id)

      for part <- ~w(left back right-back right-front),
          do: assert("van-wall-#{part}" in ids)

      for part <- ~w(well-left well-right seat-driver seat-passenger dash wheel hood bumper),
          do: assert("van-#{part}" in ids)
    end
  end

  test "the driver sits on the left side of the van, and the sliding door is on its right side" do
    m = 0.0254

    for {model, _name, _numbers, _source} <- Catalog.van_models() do
      {build, van} = van(model)
      [floor, _roof] = view(build, van).levels
      objects = Map.new(floor.objects, &{&1.id, &1})
      # The left side of the van is at the large x, near the eye of the
      # camera of a van (DIYWeb.Geometry).
      half = Catalog.van_size(model).cargo_width * m / 2
      assert elem(objects["van-wheel"].box, 0) > half
      assert elem(objects["van-seat-driver"].box, 0) > half
      assert elem(objects["van-seat-passenger"].box, 3) < half

      # The opening of the sliding door is in the wall at x = 0.
      door =
        elem(objects["van-wall-right-front"].box, 1) - elem(objects["van-wall-right-back"].box, 4)

      assert_in_delta door, 48 * m, 1.0e-9

      # The model of the van has its sliding door on the same side. The rail
      # of the door is the only long dark strip along a side.
      [_arm, _mirror, {:group, body}, _other_arm, _other_mirror] = Shapes.van(model)

      rails =
        for {:face, corners, {nx, _ny, _nz}, "i-dark-~"} <- body,
            {low, high} = corners |> Enum.map(&elem(&1, 1)) |> Enum.min_max(),
            high - low > 1.0,
            do: nx < 0

      assert rails == [true]
    end
  end

  ## The property

  # The kinds of items of a van, by zone.
  defp kinds do
    for {place, _name} <- Catalog.zones(),
        place != :shell,
        kind <- Catalog.kinds_for(place),
        do: {place, kind.type}
  end

  # A random van: its model, and random items in random zones, at random
  # places, with random turns.
  defp builds do
    gen all(
          model <- member_of(Enum.map(Catalog.van_models(), &elem(&1, 0))),
          steps <-
            list_of(
              tuple({member_of(kinds()), integer(-20..200), integer(-20..200), integer(0..3)}),
              max_length: 12
            )
        ) do
      {build, van} = van(model)

      build =
        Enum.reduce(steps, build, fn {{place, type}, x, y, turn}, build ->
          zone = Build.zone(build, van, place)

          with {:ok, build, id} <- Build.add_item(build, zone.id, type),
               {:ok, build} <- Build.place_item(build, id, zone.id, %{x: x, y: y}) do
            Enum.reduce(1..turn//1, build, fn _, build ->
              elem(Build.turn_item(build, id), 1)
            end)
          else
            _error -> build
          end
        end)

      {build, van}
    end
  end

  property "each point is in the box of the SVG, each id is one of a kind, and the back paints first" do
    check all({build, van} <- builds(), max_runs: 40) do
      view = view(build, van)
      html = render_component(&Cutaway.cutaway/1, view: view, selected: nil)
      [x, y, w, h] = box(html)

      for [px, py] <- points(html),
          do: assert(px >= x - 0.1 and px <= x + w + 0.1 and py >= y - 0.1 and py <= y + h + 0.1)

      ids = for [_, id] <- Regex.scan(~r/ id="([^"]+)"/, html), do: id
      assert Enum.uniq(ids) == ids

      # The items that fit in their zones (a larger item goes through the
      # walls of its zone: then no order is right).
      zones = Map.new(build.rooms, &{&1.id, &1})

      big =
        MapSet.new(
          for item <- build.items,
              zones[item.room] && zones[item.room].plan,
              not fits?(item, zones[item.room]),
              do: item.id
        )

      for level <- view.levels do
        indexed = level.objects |> Enum.reject(&MapSet.member?(big, &1.id)) |> Enum.with_index()

        for {a, i} <- indexed, {b, j} <- indexed, i < j, cover?(a, b) do
          refute behind?(b.box, a.box) and not behind?(a.box, b.box),
                 "#{b.id} is behind #{a.id}, but it paints after it"
        end
      end
    end
  end

  defp fits?(item, zone) do
    {ew, ed} = DIY.Layout.extent(item)
    ew <= zone.plan.w and ed <= zone.plan.d
  end

  defp behind?({_, _, _, ax1, ay1, az1}, {bx0, by0, bz0, _, _, _}),
    do: ax1 <= bx0 + 1.0e-6 or ay1 <= by0 + 1.0e-6 or az1 <= bz0 + 1.0e-6

  defp cover?(a, b) do
    {ax0, ay0, ax1, ay1} = screen(a)
    {bx0, by0, bx1, by1} = screen(b)
    ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01
  end

  defp screen(object) do
    {xs, ys} =
      object.polys
      |> Enum.flat_map(fn {points, _class} -> String.split(points) end)
      |> Enum.map(fn pair ->
        pair |> String.split(",") |> Enum.map(&number/1) |> List.to_tuple()
      end)
      |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp box(html) do
    [_, box] = Regex.run(~r/viewBox="([^"]+)"/, html)
    box |> String.split() |> Enum.map(&number/1)
  end

  defp points(html) do
    for [_, list] <- Regex.scan(~r/points="([^"]+)"/, html),
        pair <- String.split(list),
        do: pair |> String.split(",") |> Enum.map(&number/1)
  end

  defp number(text), do: text |> Float.parse() |> elem(0)
end
