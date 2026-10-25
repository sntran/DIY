defmodule DIYWeb.CutawayTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, Catalog, House, Layout}
  alias DIYWeb.{Camera, Cutaway, Decor}
  alias DIYWeb.Icon.{Shapes, StationShapes}

  defp house(floors \\ 2) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: floors, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id
  defp kitchen_room(build), do: Enum.find(build.rooms, &(&1.name == "Kitchen"))

  defp add(build, room, type, params \\ %{}) do
    {:ok, build, id} = Build.add_item(build, room, type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  defp html(build, selected \\ nil),
    do: render_component(&Cutaway.cutaway/1, view: Cutaway.view(build), selected: selected)

  # The mean x of the points of polygons on the screen.
  defp mean_x(polys) do
    xs =
      for {points, _class} <- polys,
          pair <- String.split(points),
          [x, _y] = String.split(pair, ","),
          do: String.to_float(x <> if(String.contains?(x, "."), do: "", else: ".0"))

    Enum.sum(xs) / length(xs)
  end

  test "a tracker has its panels at each position of the sun, and a rack has none" do
    build = house()
    yard = room(build, "Backyard")
    tracker = %{"watts" => "1650", "panel_watts" => "550", "mount" => "tracker"}
    {build, _id} = add(build, yard, "solar_panels", tracker)
    html = html(Layout.fill(build))

    # 3 panels of 550 W at each of the 8 positions: 7:00, 9:00, 11:00, the
    # day (13:00), 15:00, 17:00, the sunset (18:00) and the night.
    for class <-
          ~w(p-track-7 p-track-9 p-track-11 p-track-day p-track-15 p-track-17 p-track-sunset p-track-night) do
      assert length(Regex.scan(~r/class="i-pv #{class}"/, html)) == 3, class
    end

    # The footing of the pole is at the middle of the item. In this view,
    # the x of the screen does not change with the height.
    [ground | _] = Cutaway.view(Layout.fill(build)).levels
    object = Enum.find(ground.objects, &Enum.any?(&1.polys, fn {_p, c} -> c =~ "p-track" end))
    mid_x = fn class -> object.polys |> Enum.filter(&(elem(&1, 1) =~ class)) |> mean_x() end
    assert_in_delta mid_x.("p-pad"), mid_x.("p-shadow"), 1.0

    # The pole goes up to the middle of the frame, behind the panels. When
    # the camera sees the front of the panels, the pole paints first, so
    # the panels hide its top. When the camera sees their back, the pole
    # paints after them.
    classes = Enum.map(object.polys, &elem(&1, 1))
    pole = Enum.find_index(classes, &(&1 =~ "i-steel"))

    for {hour, class} <-
          [{7, "p-track-7"}, {13, "p-track-day"}, {18, "p-track-sunset"}] ++
            [{nil, "p-track-night"}] do
      frames = for {c, i} <- Enum.with_index(classes), c =~ class, do: i
      front? = DIYWeb.Camera.shows?(DIYWeb.Camera.house(), DIY.Solar.track_sun(hour))

      if front?,
        do: assert(Enum.all?(frames, &(&1 > pole)), class),
        else: assert(Enum.all?(frames, &(&1 < pole)), class)
    end

    # By day, the camera sees the front of the panels.
    assert DIYWeb.Camera.shows?(DIYWeb.Camera.house(), DIY.Solar.track_sun(13))

    # A turn of the item does not turn the frame: it faces the sun.
    [{_, item}] = for i <- build.items, i.type == "solar_panels", do: {i.id, i}

    turned = %{
      build
      | items: Enum.map(build.items, &if(&1.id == item.id, do: %{&1 | turn: 1}, else: &1))
    }

    frames = fn html ->
      Regex.scan(~r/<polygon points="[^"]*" class="i-pv p-track-[^"]*"/, html)
    end

    assert length(frames.(html(Layout.fill(turned)))) == 24

    # Panels on a rack have no positions.
    {rack, _id} = add(house(), yard, "solar_panels", %{"watts" => "1650"})
    refute html(Layout.fill(rack)) =~ "p-track"
  end

  test "the layers of houses of 1, 2 and 3 floors" do
    ids = fn build -> Enum.map(Cutaway.view(build).levels, & &1.id) end
    assert ids.(house(1)) == ["ground", "attic", "roof"]
    assert ids.(house(2)) == ["ground", "f2", "attic", "roof"]
    assert ids.(house(3)) == ["ground", "f2", "f3", "attic", "roof"]

    # A house with no attic and no roof: no layer for them. A floor with no
    # room still has its slab.
    build = house(2)

    build =
      Enum.reduce(build.rooms, build, fn room, build ->
        if room.level in ["roof", "f2"],
          do: elem(Build.delete_room(build, room.id), 1),
          else: build
      end)

    assert ids.(build) == ["ground", "f2"]
  end

  test "the surfaces of the rooms, with the data for the hook" do
    build = house()
    html = html(build, room(build, "Kitchen"))
    # The axes of the camera of the house: test/js/plan.test.js has the same
    # numbers.
    assert html =~ ~s(data-axes="0.269464 0.086996 -0.155575 0.150682 0.0 -0.257955")
    assert html =~ ~s(data-arrows="1 0 0 1")
    # The page starts on floor 1. The house has its look (the class
    # cutaway-house in assets/css/app.css).
    assert html =~ ~s(data-start="ground")
    assert html =~ "cutaway-house"
    assert html =~ ~s(class="p-floor p-tile p-chosen")
    assert html =~ ~s(data-plan="0 0 144 294")
    # The roof has its rise: 147 inches times 5/12.
    assert html =~ ~s(data-rise="61")
    assert html =~ "p-roof-f"
    assert html =~ "p-gable"
    assert length(Regex.scan(~r/data-handle="/, html)) == 4
    assert html =~ ~s(data-outline=)
    refute html(build) =~ "data-outline"

    # The item with an open sheet: its layer shows (the hook).
    refute html =~ "data-open"
    view = Cutaway.view(build)
    assert render_component(&Cutaway.cutaway/1, view: view, open: "i16") =~ ~s(data-open="i16")
  end

  test "the slab under each room of the house has the id of its room" do
    build = house()
    view = Cutaway.view(build)

    for level <- view.levels, {_points, "p-slab" <> _, room} <- level.slabs do
      assert Enum.any?(level.rooms, &(&1.id == room))
    end

    # Each room on a slab has its slab: the yards are on the ground.
    on_slab = for level <- view.levels, {_points, _class, room} <- level.slabs, do: room
    rooms = for level <- view.levels, level.id != "roof", room <- level.rooms, do: room.id
    assert Enum.sort(Enum.uniq(on_slab)) == Enum.sort(rooms)
    assert html(build) =~ ~s(class="p-slab-t" data-of="#{room(build, "Kitchen")}")

    # A floor with no room: the slab of the house, with no room.
    build =
      Enum.reduce(build.rooms, build, fn room, build ->
        if room.level == "f2", do: elem(Build.delete_room(build, room.id), 1), else: build
      end)

    f2 = Enum.find(Cutaway.view(build).levels, &(&1.id == "f2"))
    assert [_ | _] = f2.slabs
    assert Enum.all?(f2.slabs, &match?({_points, _class, nil}, &1))
  end

  test "the cut of the walls: full at the back, on a slope at the far end, 75 cm between rooms, else low" do
    cut = fn camera -> for side <- ~w(x0 y0 x1 y1), do: Cutaway.cut(side, camera) end
    assert cut.(Camera.house()) == [:far, :back, :near, :front]
    assert cut.(Camera.van()) == [:back, :far, :front, :near]

    # A slope: the full height at the back of the span, low at its front,
    # and the same out of the span.
    assert Cutaway.slope(0, {0, 100}, {2.4, 0.25}) == 2.4
    assert Cutaway.slope(100, {0, 100}, {2.4, 0.25}) == 0.25
    assert_in_delta Cutaway.slope(50, {0, 100}, {2.4, 0.25}), 1.325, 1.0e-9
    assert Cutaway.slope(-10, {0, 100}, {2.4, 0.25}) == 2.4
    assert Cutaway.slope(130, {0, 100}, {2.4, 0.25}) == 0.25

    # In the house, the wall at the back of the kitchen is full. Its wall at
    # the left side is full at the back and lower at the front: its top
    # slopes. The wall at its front is low.
    build = house()
    kitchen = room(build, "Kitchen")
    view = Cutaway.view(build)
    [ground | _] = view.levels
    walls = Map.new(for %{kind: :wall, room: ^kitchen} = w <- ground.objects, do: {w.id, w})
    height = fn %{box: {_, _, z0, _, _, z1}} -> z1 - z0 end
    assert_in_delta height.(walls["ground-#{kitchen}-y0-0"]), 2.4, 1.0e-9
    assert_in_delta height.(walls["ground-#{kitchen}-y1-0"]), 0.25, 1.0e-9

    # The face of the wall at the left that looks to the side (x). On the
    # screen, its back end (from p1 up to p4) is higher than its front end
    # (from p2 up to p3).
    {side, "p-wall-r"} = hd(walls["ground-#{kitchen}-x0-0"].polys)

    [p1, p2, p3, p4] =
      for pair <- String.split(side), do: pair |> String.split(",") |> Enum.map(&number/1)

    assert Enum.at(p1, 1) - Enum.at(p4, 1) > Enum.at(p2, 1) - Enum.at(p3, 1)
    assert Enum.at(p2, 1) - Enum.at(p3, 1) > 0

    # The wall between the kitchen and the living room is cut at 75 cm. A
    # high wall there hides a part of the kitchen: the camera is to the
    # right.
    living = room(build, "Living room")

    assert [0.75] ==
             for(
               %{kind: :wall, room: ^living, id: id} = w <- ground.objects,
               id =~ "-x0-",
               do: Float.round(height.(w), 6)
             )
             |> Enum.uniq()

    # The kitchen 200 inches to the back: the living room is in front of it
    # on a slant. The wall at the back of the living room is low next to the
    # kitchen, so it does not hide the items of the kitchen. Far from the
    # kitchen, it is high.
    back = %{kitchen_room(build) | plan: %{kitchen_room(build).plan | y: -200}}
    moved = Enum.map(build.rooms, &if(&1.id == kitchen, do: back, else: &1))
    [ground | _] = Cutaway.view(%{build | rooms: moved}).levels

    parts =
      for %{kind: :wall, room: ^living, id: id, box: {x0, _, _, x1, _, _}} = w <- ground.objects,
          id =~ "-y0-",
          do: {x0, x1, height.(w)}

    {_x0, _x1, near} = Enum.min_by(parts, &elem(&1, 0))
    {_x0, _x1, far} = Enum.max_by(parts, &elem(&1, 0))
    assert {Float.round(near, 6), Float.round(far, 6)} == {0.25, 2.4}

    # A yard behind the kitchen. The wall at the back of the kitchen is then
    # low, so it does not hide the items of the yard.
    yard = Enum.find(build.rooms, &(&1.name == "Backyard"))
    behind = %{yard | plan: %{yard.plan | x: 0, y: -400, w: 144, d: 300}}
    rooms = Enum.map(build.rooms, &if(&1.id == yard.id, do: behind, else: &1))
    [ground | _] = Cutaway.view(%{build | rooms: rooms}).levels

    assert [0.25] ==
             for(
               %{kind: :wall, room: ^kitchen, id: id} = w <- ground.objects,
               id =~ "-y0-",
               do: Float.round(height.(w), 6)
             )
  end

  test "a wall between two rooms is low where it can hide an item of the room behind it" do
    build = house()

    [kitchen, living, bed, bath] =
      Enum.map(["Kitchen", "Living room", "Bedroom 1", "Bathroom"], &room(build, &1))

    height = fn %{box: {_, _, z0, _, _, z1}} -> Float.round(z1 - z0, 6) end

    # The parts of the wall on a side of a room: {from, to, height}, with
    # from and to along the side (inches).
    parts = fn build, room, side ->
      view = Cutaway.view(build)

      for level <- view.levels,
          %{kind: :wall, room: ^room, id: id, box: {x0, y0, _, x1, y1, _}} = w <- level.objects,
          id =~ "-#{side}-" do
        {a, b} = if side == "x0", do: {y0, y1}, else: {x0, x1}
        {round(a / 0.0254), round(b / 0.0254), height.(w)}
      end
      |> Enum.sort()
    end

    # With no item near them, the walls between the rooms are at 75 cm.
    assert [{0, 294, 0.75}] == parts.(build, living, "x0")
    assert [{0, 144, 0.75}] == parts.(build, bath, "y0")

    # The dishwasher of the kitchen against the wall of the living room:
    # the wall is low in front of it. The eye looks at a slant, so the low
    # part goes on to the front.
    move = fn build, type, room, at ->
      items =
        for item <- build.items,
            do: if(item.type == type and item.room == room, do: %{item | at: at}, else: item)

      %{build | items: items}
    end

    assert [{0, 100, 0.75}, {100, low, 0.25}, {low, 294, 0.75}] =
             parts.(move.(build, "dishwasher", kitchen, %{x: 120, y: 100}), living, "x0")

    assert low > 124

    # The dishwasher at the back: the low part starts at the back corner. It
    # stays on the line between the two rooms: it does not go past the
    # corner, as a wall on the outside does.
    corner = move.(build, "dishwasher", kitchen, %{x: 120, y: 0})
    assert [{0, low, 0.25}, {low, 294, 0.75}] = parts.(corner, living, "x0")
    assert low > 24

    # The face of the low part and the face of the part of 75 cm are on the
    # same plane. So on the screen, the two parts have a corner in common.
    [low_part, high_part] =
      for(
        level <- Cutaway.view(corner).levels,
        %{kind: :wall, room: ^living, id: id} = w <- level.objects,
        id =~ "-x0-",
        do: w
      )
      |> Enum.sort_by(fn %{box: {_, y0, _, _, _, _}} -> y0 end)

    corners = fn w -> MapSet.new(for {points, _} <- w.polys, p <- String.split(points), do: p) end
    refute MapSet.disjoint?(corners.(low_part), corners.(high_part))

    # The computer of the bedroom against the wall of the bathroom.
    assert [{0, 50, 0.75}, {50, low, 0.25}, {low, 144, 0.75}] =
             parts.(move.(build, "computer", bed, %{x: 50, y: 150}), bath, "y0")

    assert low > 74

    # An item far from the wall, or an item over it (a fan), does not count.
    assert [{0, 294, 0.75}] ==
             parts.(move.(build, "dishwasher", kitchen, %{x: 60, y: 100}), living, "x0")

    fan =
      Enum.map(build.items, fn item ->
        if item.type == "ceiling_fan",
          do: %{item | room: kitchen, at: %{x: 100, y: 100}},
          else: item
      end)

    assert [{0, 294, 0.75}] == parts.(%{build | items: fan}, living, "x0")
  end

  test "the lines of the floors: a pattern of each material, on the plane of the floor" do
    build = house()
    html = html(build)

    # The pattern of a floor goes along the axes of the camera: one unit of
    # the pattern is one inch on the floor.
    transform = ~s{patternTransform="matrix(0.269464 0.086996 -0.155575 0.150682 0 0)"}
    css = File.read!("assets/css/app.css")

    for {name, w, h, _lines} <- Cutaway.textures() do
      assert html =~
               ~s(id="tex-#{name}" patternUnits="userSpaceOnUse" width="#{w}" height="#{h}" #{transform})

      assert css =~ ".p-tex-#{name} { fill: url(#tex-#{name}) }"
    end

    # The lines of a floor are a second polygon with the same points, after
    # the floor. A floor of carpet has no lines. Then the light of a lamp
    # at night: a room inside has it, and a yard does not.
    polys = fn name ->
      id = room(build, name)

      Cutaway.view(build).levels
      |> Enum.flat_map(&(&1.low ++ &1.rooms))
      |> Enum.find(&(&1.id == id))
      |> Map.fetch!(:polys)
    end

    assert [{floor, "p-floor p-tile"}, {floor, "p-tex p-tex-tile"}, {floor, "p-tex p-glow"}] =
             polys.("Kitchen")

    assert [{floor, "p-floor p-carpet"}, {floor, "p-tex p-glow"}] = polys.("Bedroom 1")
    refute Enum.any?(polys.("Backyard"), &(elem(&1, 1) == "p-tex p-glow"))
    assert css =~ ".p-glow { fill: url(#p-glow-fill);"

    # The two slopes of the roof have their shingles.
    assert length(Regex.scan(~r/class="p-tex p-tex-roof"/, html)) == 2

    # The lines are for the eyes: they have no data of their room, so a tap
    # goes through them to the floor.
    assert html =~ ~r/<polygon points="[^"]+" class="p-tex p-tex-tile"><\/polygon>/
    refute html =~ ~r/class="p-tex [^"]*" data-/
  end

  test "the items that run have small loops: only in the house, and they stop" do
    css = File.read!("assets/css/app.css")

    # The loops are in the house, for an item that is not planned, and only
    # when the person does not ask for less motion. Each loop stops after 5
    # seconds at most, at its first state (an even count of runs).
    [loops] =
      for [_, block] <-
            Regex.scan(~r/@media \(prefers-reduced-motion: no-preference\) \{(.*?)\n\}/s, css),
          block =~ "cutaway-house",
          do: block

    for part <- ~w(i-fire i-coil) do
      [_, time, count] =
        Regex.run(
          ~r/\.cutaway-house \.#{part} \{ animation: var\(--p-[a-z]+, none\) ([\d.]+)s [\w-]+ (\d+) alternate \}/,
          loops
        )

      assert String.to_float(time) * String.to_integer(count) <= 5
      assert rem(String.to_integer(count), 2) == 0
      refute String.replace(css, loops, "") =~ ".#{part} { animation:"
    end

    # A loop runs only in the layer that shows: the name of its animation is
    # there. So a loop starts when the person opens the tab of its layer.
    for id <- ~w(ground f2 f3 attic roof) do
      assert loops =~
               ".cutaway-house[data-dim=#{id}] > #plan-#{id} .p-item:not(.p-planned)"
    end

    assert loops =~ ".cutaway-house:not([data-dim]) .p-item:not(.p-planned)"
    assert loops =~ "{ --p-fire: p-flicker; --p-coil: p-warm }"

    # Only the flame of a furnace and the hot coils have a loop: not a tail
    # light of a car or of a van.
    m = 0.0254
    frame = %{at: {0, 0, 0}, turn: 0, camera: Camera.house()}

    looped =
      for type <- Catalog.types(),
          {w, d, h} = Catalog.size(type),
          {:poly, _corners, class} <-
            Shapes.placed(type, Map.put(frame, :size, {w * m, d * m, h * m})),
          class =~ ~r/i-fire|i-coil/,
          uniq: true,
          do: type

    assert Enum.sort(looped) == ~w(furnace heat_strips space_heater)

    for {model, _name, _numbers, _source} <- Catalog.van_models(),
        {:poly, _corners, class} <- Shapes.placed_model(Shapes.van(model), frame),
        do: refute(class =~ ~r/i-fire|i-coil/)

    # On the plan, the flame of the furnace is a part of its item (a group
    # with the class p-item).
    build = house()
    furnace = Enum.find(build.items, &(&1.type == "furnace")).id

    assert [{_points, "i-flame i-fire"}] =
             for(
               level <- Cutaway.view(build).levels,
               %{kind: :item, id: ^furnace} = object <- level.objects,
               {_p, class} = poly <- object.polys,
               class =~ "i-fire",
               do: poly
             )
  end

  test "a pool larger than its room paints before the items over it" do
    build = house()
    yard = room(build, "Backyard")
    {build, pool} = add(build, yard, "pool")
    {build, pump} = add(build, yard, "pool_pump")

    # After a turn, the pool (228 by 408) is larger than the yard (300
    # deep). The pump goes on its coping, and on its water. The pool still
    # paints first: the pump stays on the top of the plan, and a tap on it
    # opens the pump.
    {:ok, build} = Build.turn_item(build, pool)
    {:ok, %{at: at}} = Build.item(build, pool)
    {:ok, build} = Build.place_item(build, pump, yard, %{x: at.x + 100, y: at.y + 8}, true)
    {:ok, %{on: ^pool}} = Build.item(build, pump)
    assert_paints_first(build, pool, pump)
    {:ok, build} = Build.place_item(build, pump, yard, %{x: at.x + 100, y: at.y + 150}, true)
    {:ok, on_water} = Build.item(build, pump)
    refute Map.has_key?(on_water, :on)
    assert_paints_first(build, pool, pump)
  end

  test "a pool through a wall paints before a pump on it, and the walls keep their order" do
    # A pool (223 inches) in the laundry (78 wide) goes through its wall
    # into the garage. The wall of the garage stays behind the water heater.
    build = house()
    laundry = room(build, "Laundry")
    {build, pool} = add(build, laundry, "pool")
    {:ok, build} = Build.size_item(build, pool, %{w: 223, d: 223, h: 223})
    {:ok, build} = Build.place_item(build, pool, laundry, %{x: 0, y: 22})
    heater = Enum.find(build.items, &(&1.type == "water_heater")).id
    garage = room(build, "Garage")

    # A pump on its coping, and a low item in the garage. The pool is on the
    # two sides of the wall: near the wall, the low item makes a cycle with
    # the pool (docs/design.md). In a cycle, the pool comes first, so it
    # does not cover the pump.
    {build, pump} = add(build, laundry, "pool_pump")
    {:ok, build} = Build.place_item(build, pump, laundry, %{x: 20, y: 30}, true)
    {build, low} = add(build, garage, "other")
    {:ok, build} = Build.size_item(build, low, %{w: 12, d: 12, h: 4})

    for at <- [%{x: 60, y: 270}, %{x: 0, y: 250}, %{x: 100, y: 200}, %{x: 0, y: 150}] do
      {:ok, build} = Build.place_item(build, low, garage, at)
      [ground | _] = Cutaway.view(build).levels
      ids = Enum.map(ground.objects, & &1.id)
      index = fn id -> Enum.find_index(ids, &(&1 == id)) end
      assert index.("ground-#{garage}-x0-0") < index.(heater)
      assert index.(pool) < index.(pump), inspect(at)
    end
  end

  defp assert_paints_first(build, first, last) do
    [ground | _] = Cutaway.view(build).levels
    ids = Enum.map(ground.objects, & &1.id)
    assert Enum.find_index(ids, &(&1 == first)) < Enum.find_index(ids, &(&1 == last))
    assert Enum.find(ground.objects, &(&1.id == first)).flat
  end

  test "a soft shadow under an item on a floor, and none under an item on a wall" do
    build = house()
    kitchen = room(build, "Kitchen")
    {build, fridge} = add(build, kitchen, "fridge")
    {build, meter} = add(build, kitchen, "smart_meter")
    {:ok, build} = Build.place_item(build, fridge, kitchen, %{x: 20, y: 60})
    [ground | _] = Cutaway.view(build).levels
    objects = Map.new(ground.objects, &{&1.id, &1})

    # The shadow paints first. It is on the floor, 3 inches out from each
    # side of the fridge. On the screen, it goes past the corners of the
    # bottom of the fridge.
    [{shadow, "p-shadow"} | _rest] = objects[fridge].polys
    {x0, y0, z, x1, y1, _z1} = objects[fridge].box

    xs = fn points ->
      for pair <- String.split(points), do: pair |> String.split(",") |> hd() |> number()
    end

    bottom =
      Camera.points(Camera.house(), {0, 0}, [{x0, y0, z}, {x1, y0, z}, {x1, y1, z}, {x0, y1, z}])

    assert Enum.min(xs.(shadow)) < Enum.min(xs.(bottom))
    assert Enum.max(xs.(shadow)) > Enum.max(xs.(bottom))

    refute Enum.any?(objects[meter].polys, &match?({_points, "p-shadow"}, &1))
    assert html(build) =~ ~s(<radialGradient id="p-shadow-fill">)
  end

  test "a high wall has a baseboard, and a window when it is long enough" do
    build = house()
    kitchen = room(build, "Kitchen")
    [ground | _] = Cutaway.view(build).levels
    walls = Map.new(for %{kind: :wall, room: ^kitchen} = w <- ground.objects, do: {w.id, w})
    classes = fn id -> for {_points, class} <- walls[id].polys, do: class end

    # The wall at the back of the kitchen: its three faces, its baseboard,
    # and a window (a frame, two panes and a sill).
    assert classes.("ground-#{kitchen}-y0-0") ==
             ~w(p-wall-r p-wall-l p-wall-t p-baseboard p-frame p-pane p-pane p-frame)

    # A low wall has no trim. A wall on a slope has its baseboard, but no
    # window.
    assert classes.("ground-#{kitchen}-y1-0") == ~w(p-wall-r p-wall-l p-wall-t)
    assert classes.("ground-#{kitchen}-x0-0") == ~w(p-wall-r p-wall-l p-wall-t p-baseboard)

    # A long wall also has a picture at the left of its window, as at the
    # back of Bedroom 1. In the living room, the lamp stands in front of
    # that place: no picture. A garage has no picture.
    living = room(build, "Living room")

    art = fn build, index, room ->
      level = Enum.at(Cutaway.view(build).levels, index)
      for %{kind: :wall, room: ^room} = w <- level.objects, {_p, "p-art"} <- w.polys, do: w.id
    end

    bed = room(build, "Bedroom 1")
    assert art.(build, 1, bed) == ["f2-#{bed}-y0-0"]
    assert art.(build, 0, living) == []
    assert art.(build, 0, room(build, "Garage")) == []

    # The lamp and the TV at the front of the room: the picture comes.
    items =
      for i <- build.items,
          do: if(i.type in ~w(lights tv), do: %{i | at: %{i.at | y: 200}}, else: i)

    assert art.(%{build | items: items}, 0, living) == ["ground-#{living}-y0-0"]

    # A short high wall has its baseboard, but no window.
    small = %{kitchen_room(build) | plan: %{kitchen_room(build).plan | w: 40}}
    rooms = Enum.map(build.rooms, &if(&1.id == kitchen, do: small, else: &1))
    [ground | _] = Cutaway.view(%{build | rooms: rooms}).levels

    assert ["p-wall-r", "p-wall-l", "p-wall-t", "p-baseboard"] ==
             for(
               %{kind: :wall, id: "ground-" <> _ = id} = w <- ground.objects,
               id == "ground-#{kitchen}-y0-0",
               {_points, class} <- w.polys,
               do: class
             )
  end

  test "the materials of the floors" do
    material = &Cutaway.material/1
    assert material.(%{place: :outdoor, name: "Driveway"}) == "asphalt"
    assert material.(%{place: :outdoor, name: "Back patio"}) == "deck"
    assert material.(%{place: :outdoor, name: "Yard"}) == "grass"
    assert material.(%{place: :roof, name: "Porch roof"}) == "membrane"
    assert material.(%{place: :indoor, name: "Master bedroom"}) == "carpet"
    assert material.(%{place: :indoor, name: "Garage"}) == "concrete"
    assert material.(%{place: :indoor, name: "Attic"}) == "ply"
    assert material.(%{place: :indoor, name: "Office"}) == "wood"
  end

  test "panels on the roof go over the ridge, and an AC stands on a slope" do
    build = house()
    roof = room(build, "Roof")
    {build, panels} = add(build, roof, "solar_panels", %{"watts" => "8000"})
    {:ok, build} = Build.place_item(build, panels, roof, %{x: 0, y: 60})
    {build, ac} = add(build, roof, "ac")
    {:ok, build} = Build.place_item(build, ac, roof, %{x: 300, y: 130})
    view = Cutaway.view(build)
    [roof_layer] = Enum.filter(view.levels, &(&1.id == "roof"))
    objects = Map.new(roof_layer.objects, &{&1.id, &1})

    # 20 panels in 7 columns and 3 rows: the panels of the middle row are
    # over the ridge, so they have two parts.
    pv = for {_points, "i-pv"} <- objects[panels].polys, do: 1
    assert length(pv) == 20 + 7

    # The AC is on the roof: its bottom is over the eaves.
    {_x, _y, low, _x1, _y1, _high} = objects[ac].box
    assert low > roof_layer.z

    # A quarter turn: the array is 3 columns and 7 rows.
    {:ok, turned} = Build.turn_item(build, panels)
    [roof_layer] = Enum.filter(Cutaway.view(turned).levels, &(&1.id == "roof"))
    assert Enum.any?(roof_layer.objects, &(&1.id == panels))
  end

  test "panels in a yard stand on a rack, and a planned item shows as a plan" do
    build = house()
    {build, panels} = add(build, room(build, "Backyard"), "solar_panels", %{"watts" => "2400"})
    {:ok, build} = Build.flag_item(build, panels, :planned, true)
    html = html(build)
    assert html =~ "p-pad"
    assert html =~ ~r/class="p-item p-planned"[^>]*data-item="#{panels}"/
  end

  test "a model turns: a face that looks away does not show" do
    frame = fn turn, camera ->
      %{at: {0, 0, 0}, size: {1.0, 2.6, 1.25}, turn: turn, camera: camera}
    end

    # The van shows one of its two sides in each turn, for each camera. The
    # part of the side under the belt is upright. It has the profile of the
    # van: more than 6 corners on one plane (x or y).
    for turn <- 0..3, camera <- [Camera.house(), Camera.van()] do
      sides =
        for {:poly, corners, "i-white" <> _} <- Shapes.placed("camper_van", frame.(turn, camera)),
            length(corners) > 6,
            {xs, ys, _zs} = unzip3(corners),
            length(Enum.uniq(xs)) == 1 or length(Enum.uniq(ys)) == 1,
            do: 1

      assert sides == [1]
    end

    # The space of a turned item: d by w.
    {xs, ys} =
      Shapes.placed("fridge", %{
        at: {0, 0, 0},
        size: {0.9, 0.7, 1.8},
        turn: 3,
        camera: Camera.house()
      })
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.map(fn {x, y, _z} -> {x, y} end)
      |> Enum.unzip()

    assert_in_delta Enum.max(xs) - Enum.min(xs), 0.7, 0.05
    assert_in_delta Enum.max(ys) - Enum.min(ys), 0.9, 0.05

    model = [{:face, [{0, 0, 0}, {2, 0, 0}, {2, 1, 0}], {0, 0, 1}, "x"}]

    assert [{:poly, _corners, "x"}] =
             Shapes.placed_model(model, %{at: {1, 1, 0}, turn: 2, camera: Camera.house()})
  end

  test "for each kind, each turn and each camera, no part of a model paints after a part in front of it" do
    m = 0.0254

    for type <- Catalog.types() ++ stations(),
        turn <- 0..3,
        camera <- [Camera.house(), Camera.van()] do
      {w, d, h} = look_size(type)
      frame = %{at: {0, 0, 0}, size: {w * m, d * m, h * m}, turn: turn}
      indexed = type |> Shapes.model() |> Shapes.parts(frame, camera) |> Enum.with_index()

      for {a, i} <- indexed,
          {b, j} <- indexed,
          i < j,
          overlap?(part_screen(a, camera), part_screen(b, camera)) do
        refute behind?(b.box, a.box) and not behind?(a.box, b.box),
               "#{inspect(type)} at turn #{turn}, #{camera.name}: part #{b.id} is behind part #{a.id}"
      end
    end
  end

  # The looks of the models of power stations (`DIYWeb.Icon.StationShapes`).
  defp stations, do: for(key <- StationShapes.models(), do: {"power_station", key})

  # The size of a look in inches: of its kind, or of its model of station.
  defp look_size({"power_station", key}), do: Catalog.station_size(key)
  defp look_size({type, _ports}), do: Catalog.size(type)
  defp look_size(type), do: Catalog.size(type)

  # The box of the polygons of a part on the screen.
  defp part_screen(part, camera) do
    {xs, ys} =
      part.polys
      |> Enum.flat_map(&elem(&1, 0))
      |> Enum.map(&Camera.at(camera, {0, 0}, &1))
      |> Enum.unzip()

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp unzip3(points) do
    {Enum.map(points, &elem(&1, 0)), Enum.map(points, &elem(&1, 1)),
     Enum.map(points, &elem(&1, 2))}
  end

  defp overlap?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01

  test "each piece of furniture paints from the back at each turn: a depth check" do
    camera = Camera.house()

    # All the models: the pieces of large rooms of each name that the app
    # knows, with no item.
    rooms =
      for name <- ~w(Bedroom Living Kitchen Bathroom Garage Laundry Attic Office),
          do: %{name: name, place: :indoor, plan: %{x: 0, y: 0, w: 400, d: 400}}

    yard = %{name: "Backyard", place: :outdoor, plan: %{x: 0, y: 0, w: 400, d: 400}}

    models =
      for(room <- [yard | rooms], {model, _x, _y, _turn} <- Decor.pieces(room, []), do: model)
      |> Enum.uniq()

    assert length(models) == 22

    # A ball of leaves (or a rug) looks to the camera at the turn 0 only. A
    # piece with leaves stays at the turn 0 on the plan.
    for model <- models,
        turn <- if(Enum.any?(model, &match?({:face, _, nil, _}, &1)), do: [0], else: 0..3) do
      frame = %{at: {0, 0, 0}, turn: turn, camera: camera}
      polys = for {:poly, corners, _class} <- Shapes.placed_model(model, frame), do: corners
      assert depth_faults(polys, camera, 0.01) == [], "#{inspect(hd(model))} at turn #{turn}"
    end
  end

  test "on the plan, the small faces of an item keep two decimals, and the furniture keeps one" do
    build = house()
    {build, bus} = add(build, room(build, "Garage"), "dc_bus")
    objects = Enum.flat_map(Cutaway.view(build).levels, & &1.objects)
    two = ~r/\d\.\d\d(?:[ ,]|$)/

    # The green light of the busbar is a small face: it keeps its shape.
    %{polys: polys} = Enum.find(objects, &(&1.id == bus))
    assert Enum.any?(polys, fn {points, class} -> class =~ "i-led" and points =~ two end)

    # The walls and the furniture keep one decimal.
    others = for %{kind: kind, polys: polys} <- objects, kind != :item, poly <- polys, do: poly
    assert length(others) > 100
    refute Enum.any?(others, fn {points, _class} -> points =~ two end)
  end

  test "the furniture is on the plan: fixed, with no tap, and a rug under the pieces" do
    build = house()
    [ground | _] = Cutaway.view(build).levels
    living = room(build, "Living room")
    decor = for %{kind: :fixture, id: "decor-" <> id} = o <- ground.objects, do: {id, o}
    assert Enum.any?(decor, fn {id, _o} -> String.starts_with?(id, living <> "-") end)

    # The rug of the living room paints before the table on it.
    ids = Enum.map(ground.objects, & &1.id)
    index = fn id -> Enum.find_index(ids, &(&1 == id)) end
    assert index.("decor-#{living}-0") < index.("decor-#{living}-2")

    # A tap goes through the furniture to the floor: no data of an item.
    html = html(build)
    assert html =~ ~s(id="plan-fixture-decor-#{living}-0" class="p-fixture")
    # A piece moves with its room in a drag (the hook).
    assert html =~ ~r/id="plan-fixture-decor-#{living}-0"[^>]*data-with="#{living}"/
    refute html =~ ~r/id="plan-fixture-decor-[^"]+"[^>]*data-item/
  end

  test "each kind and each model of van paint from the back at each turn: a depth check" do
    m = 0.0254

    for turn <- 0..3, camera <- [Camera.house(), Camera.van()] do
      for {model, _name, _numbers, _source} <- Catalog.van_models() do
        frame = %{at: {0, 0, 0}, turn: turn, camera: camera}

        polys =
          for {:poly, corners, _class} <- Shapes.placed_model(Shapes.van(model), frame),
              do: corners

        assert depth_faults(polys, camera) == [], "#{model} at turn #{turn}, #{camera.name}"
      end

      # The margin of the depth is 1% of the largest side of an item (3 cm
      # at most). Thus the check of a small item is at its scale. A busbar
      # has a look for each number of its positions.
      for type <- Catalog.types() ++ [{"dc_bus", 1}, {"dc_bus", 7}, {"dc_bus", 24}] ++ stations() do
        {w, d, h} = look_size(type)
        frame = %{at: {0, 0, 0}, size: {w * m, d * m, h * m}, turn: turn, camera: camera}
        polys = for {:poly, corners, _class} <- Shapes.placed(type, frame), do: corners
        margin = min(0.03, 0.01 * Enum.max([w, d, h]) * m)

        assert depth_faults(polys, camera, margin) == [],
               "#{inspect(type)} at turn #{turn}, #{camera.name}"
      end
    end
  end

  test "a prism with a loop that is not convex paints from the back at each turn" do
    # An L, a C, and a C that lies along x and along y. The arms of the C
    # are long, so a long side can hide a short one.
    l = [{0, 0}, {1, 0}, {1, 0.3}, {0.3, 0.3}, {0.3, 1}, {0, 1}]

    c =
      for {u, v} <- [
            {-20, -4},
            {4, -4},
            {4, -0.5},
            {0.3, -0.5},
            {0.3, 0.2},
            {4, 0.2},
            {4, 0.5},
            {-20, 0.5}
          ],
          do: {u / 10, v / 10}

    models = [
      [{:prism, l, 0.0, 0.5, "white"}],
      [{:prism, c, 0.0, 0.6, "white"}],
      [{:prism, :x, c, 0.0, 0.6, "white"}],
      [{:prism, :y, c, 0.0, 0.6, "white"}]
    ]

    for model <- models, turn <- 0..3, camera <- [Camera.house(), Camera.van()] do
      frame = %{at: {0, 0, 0}, turn: turn, camera: camera}
      polys = for {:poly, corners, _class} <- Shapes.placed_model(model, frame), do: corners
      assert depth_faults(polys, camera, 0.005) == [], "#{inspect(model)} at turn #{turn}"
    end
  end

  # The pairs of polygons (in the order of the paint) where the first one
  # is nearer to the eye at a point that both cover. Then the second one
  # paints over it. A larger depth (`DIYWeb.Camera.depth/2`) is nearer.
  defp depth_faults(polys, camera, margin \\ 0.03) do
    prepared = polys |> Enum.map(&prepare(&1, camera)) |> Enum.with_index()

    for {a, i} <- prepared,
        {b, j} <- prepared,
        i < j,
        a.plane && b.plane,
        nearer?(a, b, camera, margin),
        do: {i, j}
  end

  defp prepare(corners, camera) do
    screen = Enum.map(corners, &Camera.at(camera, {0, 0}, &1))
    {xs, ys} = Enum.unzip(screen)

    %{
      screen: screen,
      plane: plane(corners, camera),
      box: {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
    }
  end

  defp nearer?(a, b, camera, margin) do
    {ax0, ay0, ax1, ay1} = a.box
    {bx0, by0, bx1, by1} = b.box
    {x0, y0, x1, y1} = {max(ax0, bx0), max(ay0, by0), min(ax1, bx1), min(ay1, by1)}

    x1 - x0 >= 0.05 and y1 - y0 >= 0.05 and
      Enum.any?(
        for(i <- 1..7, j <- 1..7, do: {x0 + (x1 - x0) * i / 8, y0 + (y1 - y0) * j / 8}),
        fn point ->
          in_poly?(point, a.screen) and in_poly?(point, b.screen) and
            depth(a.plane, point, camera) > depth(b.plane, point, camera) + margin
        end
      )
  end

  defp in_poly?({px, py}, poly) do
    n = length(poly)

    poly
    |> Enum.with_index()
    |> Enum.reduce(false, fn {{xi, yi}, i}, inside ->
      {xj, yj} = Enum.at(poly, rem(i + n - 1, n))

      if yi > py != yj > py and px < (xj - xi) * (py - yi) / (yj - yi + 1.0e-12) + xi,
        do: not inside,
        else: inside
    end)
  end

  defp sub({a, b, c}, {x, y, z}), do: {a - x, b - y, c - z}
  defp cross({a, b, c}, {x, y, z}), do: {b * z - c * y, c * x - a * z, a * y - b * x}
  defp dot({a, b, c}, {x, y, z}), do: a * x + b * y + c * z

  # The plane of a polygon: a normal and a point. A polygon that is not flat,
  # or that the eye sees on its edge, has no plane (nil).
  defp plane([p | rest] = corners, camera) do
    normals =
      for {q, r} <- Enum.zip(rest, tl(rest)),
          n = cross(sub(q, p), sub(r, p)),
          dot(n, n) > 1.0e-12,
          do: n

    with [n | _] <- normals,
         length = :math.sqrt(dot(n, n)),
         true <- Enum.all?(corners, &(abs(dot(n, sub(&1, p))) / length < 1.0e-4)),
         true <- abs(dot(n, camera.eye)) >= 1.0e-9 do
      {n, p}
    else
      _ -> nil
    end
  end

  # The depth on a plane at a point of the screen. The points of the world
  # on that point of the screen are on a line along the eye: p0 + t eye.
  # p0 is the point at z = 0.
  defp depth({n, c}, {sx, sy}, camera) do
    {rx, ry} = camera.right
    {dx, dy, _dz} = camera.down
    det = rx * dy - ry * dx
    p0 = {(sx * dy - ry * sy) / det, (rx * sy - dx * sx) / det, 0.0}
    t = (dot(n, c) - dot(n, p0)) / dot(n, camera.eye)
    dot(p0, camera.eye) + t
  end

  test "three boxes that are each behind the next one still get an order" do
    square = [{[{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}], "x"}]
    object = fn id, box -> %{id: id, box: box, key: 0, loose: false, polys: square} end
    # a is behind b along x, b behind c along y, and c behind a along z.
    a = object.("a", {0, 0, 1, 1, 2, 2})
    b = object.("b", {1, 0, 0, 2, 1, 2})
    c = object.("c", {0, 1, 0, 2, 2, 1})
    camera = Camera.house()
    assert Camera.order([c, b, a], camera) |> Enum.map(& &1.id) |> Enum.sort() == ["a", "b", "c"]
    # With no cycle: the box at the back first, whatever its key.
    assert Camera.order([%{b | key: -1}, a], camera) |> Enum.map(& &1.id) == ["a", "b"]
  end

  ## The property

  # A random house: random items in random rooms, at random places, with
  # random turns and sizes.
  defp builds do
    gen all(
          floors <- integer(1..3),
          steps <-
            list_of(
              tuple({
                integer(0..20),
                member_of(Catalog.types()),
                integer(-50..600),
                integer(-50..600),
                integer(0..3),
                one_of([constant(nil), integer(1..300)])
              }),
              max_length: 15
            )
        ) do
      Enum.reduce(steps, house(floors), fn {r, type, x, y, turn, side}, build ->
        rooms = Enum.reject(build.rooms, &Build.van_level?(&1.level))
        room = Enum.at(rooms, rem(r, length(rooms)))

        with {:ok, build, id} <- Build.add_item(build, room.id, type),
             {:ok, build} <- Build.place_item(build, id, room.id, %{x: x, y: y}),
             {:ok, build} <- Build.size_item(build, id, side && %{w: side, d: side, h: side}) do
          Enum.reduce(1..turn//1, build, fn _, build -> elem(Build.turn_item(build, id), 1) end)
        else
          _ -> build
        end
      end)
    end
  end

  property "each point is in the box of the SVG, each id is one of a kind, and the back paints first" do
    check all(build <- builds(), max_runs: 40) do
      view = Cutaway.view(Build.house_view(build))
      html = render_component(&Cutaway.cutaway/1, view: view, selected: nil)
      [x, y, w, h] = box(html)

      for [px, py] <- points(html),
          do: assert(px >= x - 0.1 and px <= x + w + 0.1 and py >= y - 0.1 and py <= y + h + 0.1)

      ids = for [_, id] <- Regex.scan(~r/ id="([^"]+)"/, html), do: id
      assert Enum.uniq(ids) == ids

      # An item larger than its room goes through its walls: then no order
      # is right. The order is for the items that fit in their rooms.
      big = MapSet.new(for item <- build.items, not fits?(build, item), do: item.id)

      # A flat piece (a rug) lies on its floor, and it paints first. A part
      # that stands on that floor behind it does not cover it on the screen.
      for level <- view.levels do
        indexed =
          level.objects
          |> Enum.reject(&MapSet.member?(big, &1.id))
          |> Enum.map(&{&1, screen(&1)})
          |> Enum.with_index()

        for {{a, sa}, i} <- indexed,
            {{b, sb}, j} <- indexed,
            i < j,
            not on_floor?(a, b),
            cover?(sa, sb) do
          refute behind?(b.box, a.box) and not behind?(a.box, b.box),
                 "#{b.id} is behind #{a.id}, but it paints after it: #{inspect({b.box, a.box, sb, sa})}"
        end
      end
    end
  end

  defp fits?(build, item) do
    case Build.room(build, item.room) do
      {:ok, %{plan: %{w: w, d: d}}} ->
        {ew, ed} = DIY.Layout.extent(item)
        ew <= w and ed <= d

      _van ->
        true
    end
  end

  defp behind?({_, _, _, ax1, ay1, az1}, {bx0, by0, bz0, _, _, _}),
    do: ax1 <= bx0 + 1.0e-6 or ay1 <= by0 + 1.0e-6 or az1 <= bz0 + 1.0e-6

  # True when the boxes of two objects on the screen overlap.
  defp cover?({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}),
    do: ax0 < bx1 - 0.01 and bx0 < ax1 - 0.01 and ay0 < by1 - 0.01 and by0 < ay1 - 0.01

  # True when a is flat (2 cm high at most), and b stands on its floor or
  # over it.
  defp on_floor?(%{box: {_, _, az0, _, _, az1}}, %{box: {_, _, bz0, _, _, _}}),
    do: az1 - az0 <= 0.02 and bz0 >= az0 - 1.0e-6

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
