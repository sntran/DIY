defmodule DIYWeb.PlanLiveTest do
  @moduledoc "The page of the plan at scale (`DIYWeb.Inside`, the hook Plan)."
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Layout, Stubs}
  alias DIYWeb.Inside

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    settle(view)
    view
  end

  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build
  defp room(view, name), do: Enum.find(build(view).rooms, &(&1.name == name))
  defp item(view, type), do: Enum.find(build(view).items, &(&1.type == type))
  defp item_id(view, id), do: elem(Build.item(build(view), id), 1)

  test "a tap chooses a room or opens an item; the bar of a room", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    kitchen = room(view, "Kitchen")

    # The plan has the note for the wheel. The button to add a room is under
    # the plan, not on it: so it does not hide the name of a room.
    assert has_element?(view, "#house-plan [data-hint]", "Use Ctrl and the mouse wheel to zoom.")
    assert has_element?(view, "#house-plan > div.flex > #add-room")
    refute has_element?(view, "#house-plan > div.relative > #add-room")

    render_hook(view, "select_room", %{"id" => kitchen.id})
    assert_patch view, ~p"/inside?#{[room: kitchen.id]}"
    assert has_element?(view, "#room-bar", "12 ft by 24 ft 6 in")
    assert has_element?(view, "#plan-selection [data-handle=x0]")
    assert has_element?(view, "polygon.p-chosen[data-room=#{kitchen.id}]")
    refute has_element?(view, "#add-room")

    # The pill of the name of the chosen room has the color of the choice.
    assert has_element?(view, "rect.p-pill-chosen[data-pill=#{kitchen.id}]")

    # The arrows of the bar go to the room before it and to the next room,
    # in the order of the list.
    assert has_element?(view, "#room-before[aria-label='Go to the room before: Bedroom 3']")
    view |> element("#room-next") |> render_click()
    assert_patch view, ~p"/inside?#{[room: room(view, "Living room").id]}"
    view |> element("#room-before") |> render_click()
    assert_patch view, ~p"/inside?#{[room: kitchen.id]}"

    # A tap on an item of the chosen room: the room stays chosen, and the
    # sheet of the item closes back to it.
    fridge = item(view, "fridge")
    render_hook(view, "open_item", %{"id" => fridge.id})
    assert_patch view, ~p"/inside?#{[item: fridge.id, room: kitchen.id]}"
    assert has_element?(view, "#room-bar", "Kitchen")
    assert has_element?(view, ~s(#item-stage a[data-close][href="/inside?room=#{kitchen.id}"]))

    # From the bar, the person adds an item to the room, and then deletes
    # it. The room stays chosen. In the list, an item also keeps the room.
    view |> element("#bar-add") |> render_click()
    assert has_element?(view, "#add-sheet")
    view |> element("#add-freezer") |> render_click()
    freezer = item(view, "freezer")
    assert_patch view, ~p"/inside?#{[item: freezer.id, room: kitchen.id]}"

    assert has_element?(
             view,
             ~s(#item-#{freezer.id}[href="/inside?item=#{freezer.id}&room=#{kitchen.id}"])
           )

    assert has_element?(
             view,
             ~s(#add-#{kitchen.id}[href="/inside?add=#{kitchen.id}&room=#{kitchen.id}"])
           )

    view |> element("#delete-item") |> render_click()
    assert_patch view, ~p"/inside?#{[room: kitchen.id]}"
    assert has_element?(view, "#room-bar", "Kitchen")

    # With no chosen room, a new item and a deleted item give the page of
    # the rooms.
    render_patch(view, ~p"/inside?#{[add: kitchen.id]}")
    view |> element("#add-freezer") |> render_click()
    freezer = item(view, "freezer")
    assert_patch view, ~p"/inside?#{[item: freezer.id]}"
    view |> element("#delete-item") |> render_click()
    assert_patch view, ~p"/inside"

    render_patch(view, ~p"/inside?#{[room: kitchen.id]}")
    view |> element("#bar-add") |> render_click()

    render_hook(view, "select_room", %{"id" => ""})
    assert_patch view, ~p"/inside"
    refute has_element?(view, "#room-bar")

    fridge = item(view, "fridge")
    render_hook(view, "open_item", %{"id" => fridge.id})
    assert_patch view, ~p"/inside?#{[item: fridge.id]}"
    assert has_element?(view, "#item-place")

    # A room that is not there: no bar.
    render_patch(view, ~p"/inside?room=r999")
    refute has_element?(view, "#room-bar")
  end

  test "an item goes to a place in its room, or in a different room", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    fridge = item(view, "fridge")
    kitchen = room(view, "Kitchen")
    living = room(view, "Living room")

    # The center of the fridge (33 by 33) at 100, 100: its corner at 84, 84.
    render_hook(view, "place_item", %{
      "id" => fridge.id,
      "room" => kitchen.id,
      "x" => 100,
      "y" => 100
    })

    assert item_id(view, fridge.id).at == %{x: 84, y: 84}

    render_hook(view, "place_item", %{
      "id" => fridge.id,
      "room" => living.id,
      "x" => 250,
      "y" => 50
    })

    assert %{room: room, at: %{x: 90, y: 34}} = item_id(view, fridge.id)
    assert room == living.id

    # A fridge does not go on the roof.
    html =
      render_hook(view, "place_item", %{
        "id" => fridge.id,
        "room" => room(view, "Roof").id,
        "x" => 10,
        "y" => 10
      })

    assert html =~ "This item cannot go in that room."
    assert item_id(view, fridge.id).room == living.id

    # A room or an item that is not there: no change.
    before = build(view)
    render_hook(view, "place_item", %{"id" => fridge.id, "room" => "r999", "x" => 1, "y" => 1})
    render_hook(view, "place_item", %{"id" => "i999", "room" => living.id, "x" => 1, "y" => 1})

    render_hook(view, "place_item", %{
      "id" => fridge.id,
      "room" => living.id,
      "x" => "a",
      "y" => 1
    })

    assert build(view) == before
  end

  test "a room moves, and its walls move", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    kitchen = room(view, "Kitchen")

    # On a grid of 6 inches.
    render_hook(view, "move_room", %{"id" => kitchen.id, "dx" => -40, "dy" => 2})
    assert room(view, "Kitchen").plan == %{kitchen.plan | x: -42, y: 0}

    html = render_hook(view, "move_room", %{"id" => kitchen.id, "dx" => 100, "dy" => 0})
    assert html =~ "A room or a zone cannot go over a different one."

    html = render_hook(view, "move_room", %{"id" => kitchen.id, "dx" => 20_000, "dy" => 0})
    assert html =~ "A wall of a room is from 2 to 200 feet long"

    plan = room(view, "Kitchen").plan

    for {edge, dx, dy, expected} <- [
          {"x0", -24, 0, %{plan | x: plan.x - 24, w: plan.w + 24}},
          {"y0", 0, 12, %{plan | x: plan.x - 24, w: plan.w + 24, y: 12, d: plan.d - 12}},
          {"y1", 0, -12, %{plan | x: plan.x - 24, w: plan.w + 24, y: 12, d: plan.d - 24}},
          {"x1", -12, 0, %{plan | x: plan.x - 24, w: plan.w + 12, y: 12, d: plan.d - 24}}
        ] do
      render_hook(view, "size_room", %{"id" => kitchen.id, "edge" => edge, "dx" => dx, "dy" => dy})

      assert room(view, "Kitchen").plan == expected
    end

    before = build(view)
    render_hook(view, "size_room", %{"id" => kitchen.id, "edge" => "z", "dx" => 6, "dy" => 6})
    render_hook(view, "size_room", %{"id" => "r999", "edge" => "x1", "dx" => 6, "dy" => 6})
    render_hook(view, "move_room", %{"id" => "r999", "dx" => 6, "dy" => 6})
    assert build(view) == before
  end

  test "the arrow keys of the list move an item or a room", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    fridge = item(view, "fridge")
    kitchen = room(view, "Kitchen")
    assert has_element?(view, "#item-#{fridge.id}[data-nudge=#{fridge.id}]")
    assert has_element?(view, "#choose-#{kitchen.id}[data-nudge-room=#{kitchen.id}]")

    render_hook(view, "nudge_item", %{"id" => fridge.id, "dx" => 24, "dy" => 6})
    assert item_id(view, fridge.id).at == %{x: 24, y: 6}

    assert has_element?(
             view,
             "#plan-status",
             "Fridge: 2 ft from the left wall of Kitchen, 6 in from the back wall."
           )

    render_hook(view, "nudge_room", %{"id" => kitchen.id, "dx" => -6, "dy" => 0})
    assert has_element?(view, "#plan-status", "Kitchen moved.")
    assert room(view, "Kitchen").plan.x == -6

    html = render_hook(view, "nudge_room", %{"id" => kitchen.id, "dx" => 24, "dy" => 0})
    assert html =~ "A room or a zone cannot go over a different one."

    before = build(view)
    render_hook(view, "nudge_item", %{"id" => "i999", "dx" => 6, "dy" => 0})
    render_hook(view, "nudge_room", %{"id" => "r999", "dx" => 6, "dy" => 0})
    render_hook(view, "nudge_item", %{"id" => fridge.id, "dx" => 0.5, "dy" => 0})
    assert build(view) == before
  end

  test "an item turns, and has a size", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    tv = item(view, "tv")
    render_patch(view, ~p"/inside?#{[item: tv.id]}")
    assert has_element?(view, "#item-place", "These are the typical sizes of this kind of item")
    refute has_element?(view, "#typical-size")

    view |> element("#turn-item") |> render_click()
    assert item_id(view, tv.id).turn == 1
    assert has_element?(view, "#plan-status", "TV turned. Its space is 10 in by 3 ft 8 in.")

    # The buttons move the item: 6 inches for each tap.
    at = item_id(view, tv.id).at
    view |> element("#move-item-right") |> render_click()
    view |> element("#move-item-down") |> render_click()
    assert item_id(view, tv.id).at == %{x: at.x + 6, y: at.y + 6}
    assert has_element?(view, "#move-item-left[aria-label='Move the item 6 in to the left']")
    assert has_element?(view, "#move-item-up[aria-label='Move the item 6 in to the back']")
    assert has_element?(view, "#move-item-down[aria-label='Move the item 6 in to the front']")
    assert has_element?(view, "#move-item-right[aria-label='Move the item 6 in to the right']")
    view |> element("#move-item-left") |> render_click()
    view |> element("#move-item-up") |> render_click()
    assert item_id(view, tv.id).at == at

    # The sheet tells the new place; the status does not tell it again.
    assert has_element?(
             view,
             "#item-where[aria-live=polite]",
             "from the left wall of Living room"
           )

    refute has_element?(view, "#plan-status", "TV:")

    view |> form("#size-form", %{"w" => "57", "d" => "12", "h" => "35"}) |> render_submit()
    assert item_id(view, tv.id).size == %{w: 57, d: 12, h: 35}
    assert has_element?(view, "#item-place", "You gave this size.")

    html = view |> form("#size-form", %{"w" => "0", "d" => "12", "h" => "35"}) |> render_submit()
    assert html =~ "Give each side in inches, from 1 to 1200."

    view |> element("#typical-size") |> render_click()
    assert item_id(view, tv.id).size == nil

    # The watts give the size of solar panels: no size fields.
    roof = room(view, "Roof")
    render_click(view, "add_item", %{"room" => roof.id, "type" => "solar_panels"})
    panels = item(view, "solar_panels")
    render_patch(view, ~p"/inside?#{[item: panels.id]}")
    assert has_element?(view, "#item-place", "The watts give the size of the panels:")
    assert has_element?(view, "#item-place", "inches for each panel of 400 W")
    refute has_element?(view, "#size-form")
  end

  test "the sheet of a room opens it to a room next to it: no wall", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    {kitchen, living} = {room(view, "Kitchen"), room(view, "Living room")}
    render_patch(view, ~p"/inside?#{[room: kitchen.id, sheet: "room"]}")

    # The rooms inside next to the kitchen, on its layer: not the backyard.
    assert has_element?(view, "#open-#{kitchen.id} legend", "No wall to")
    assert has_element?(view, "#open-#{kitchen.id}-#{living.id}")
    refute has_element?(view, "#open-#{kitchen.id}-#{room(view, "Backyard").id}")

    # Bedroom 2 touches the garage, but it is on floor 2.
    garage = room(view, "Garage")
    render_patch(view, ~p"/inside?#{[room: garage.id, sheet: "room"]}")
    assert has_element?(view, "#open-#{garage.id}-#{room(view, "Laundry").id}")
    refute has_element?(view, "#open-#{garage.id}-#{room(view, "Bedroom 2").id}")
    render_patch(view, ~p"/inside?#{[room: kitchen.id, sheet: "room"]}")

    view
    |> form("#open-#{kitchen.id}", %{"open" => [living.id]})
    |> render_change()

    assert Build.open_to(build(view), kitchen.id) == [living.id]
    assert has_element?(view, "#open-#{kitchen.id}-#{living.id}[checked]")

    # A change with no box checked closes it again.
    render_change(view, "room_open", %{"room_id" => kitchen.id, "open" => [""]})
    assert build(view).open == []
    render_change(view, "room_open", %{"room_id" => kitchen.id})
    assert build(view).open == []
  end

  test "the sheet of a room gives it doors, each at a place along the wall", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    {kitchen, living} = {room(view, "Kitchen"), room(view, "Living room")}
    yard = room(view, "Backyard")
    render_patch(view, ~p"/inside?#{[room: kitchen.id, sheet: "room"]}")

    # A door to a room inside or to a yard.
    assert has_element?(view, "#doors-#{kitchen.id} legend", "Doors")
    assert has_element?(view, "#door-#{kitchen.id}-#{living.id}")
    assert has_element?(view, "#door-#{kitchen.id}-#{yard.id}")
    refute has_element?(view, "#door-at-#{kitchen.id}-#{living.id}")

    # A new door is in the middle. Its range moves it.
    view
    |> form("#doors-#{kitchen.id}", %{"door" => [living.id]})
    |> render_change()

    assert [%{other: other, at: 147}] = Build.doorways_of(build(view), kitchen.id)
    assert other == living.id
    assert has_element?(view, "#door-#{kitchen.id}-#{living.id}[checked]")

    assert has_element?(
             view,
             "#door-at-#{kitchen.id}-#{living.id}[value='147'][min='20'][max='274']"
           )

    render_change(view, "room_doors", %{
      "room_id" => kitchen.id,
      "door" => [living.id, yard.id],
      "at" => %{living.id => "60", yard.id => "x"}
    })

    assert [%{at: 60}, %{other: yard_id, at: 72}] = Build.doorways_of(build(view), kitchen.id)
    assert yard_id == yard.id

    # A change with no box checked takes the doors away.
    render_change(view, "room_doors", %{"room_id" => kitchen.id, "door" => [""], "at" => "x"})
    assert build(view).doorways == []
    render_change(view, "room_doors", %{"room_id" => kitchen.id})
    assert build(view).doorways == []
  end

  test "the sheet of a room sets its size in feet", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    kitchen = room(view, "Kitchen")
    render_patch(view, ~p"/inside?#{[room: kitchen.id, sheet: "room"]}")
    assert has_element?(view, "#room-sheet")

    view |> form("#size-#{kitchen.id}", %{"w" => "10.5", "d" => "20"}) |> render_submit()
    assert %{w: 126, d: 240} = room(view, "Kitchen").plan

    html = view |> form("#size-#{kitchen.id}", %{"w" => "30", "d" => "20"}) |> render_submit()
    assert html =~ "A room or a zone cannot go over a different one."

    html = view |> form("#size-#{kitchen.id}", %{"w" => "ten", "d" => "20"}) |> render_submit()
    assert html =~ "A wall of a room is from 2 to 200 feet long"

    html = view |> form("#size-#{kitchen.id}", %{"w" => "1", "d" => "20"}) |> render_submit()
    assert html =~ "A wall of a room is from 2 to 200 feet long"

    # Too large, 0, or not a text: the room does not change.
    for {w, d} <- [{"1e308", "20"}, {"0", "20"}, {"20", "201"}] do
      html = view |> form("#size-#{kitchen.id}", %{"w" => w, "d" => d}) |> render_submit()
      assert html =~ "A wall of a room is from 2 to 200 feet long"
    end

    render_hook(view, "room_size", %{"room_id" => kitchen.id, "w" => 12, "d" => 12})
    assert %{w: 126, d: 240} = room(view, "Kitchen").plan

    # The buttons move the room: 2 feet for each tap. A good change clears
    # the message of an older change.
    x = room(view, "Kitchen").plan.x
    html = view |> element("#move-room-left") |> render_click()
    refute html =~ "A wall of a room is from 2 to 200 feet long"
    assert room(view, "Kitchen").plan.x == x - 24
    render_click(view, "nudge_room", %{"id" => kitchen.id, "dx" => "a", "dy" => "0"})
    assert room(view, "Kitchen").plan.x == x - 24

    # The removal of the room closes its sheet.
    view |> element("#delete-#{kitchen.id}") |> render_click()
    assert_patch view, ~p"/inside"
    refute room(view, "Kitchen")
    render_click(view, "delete_room", %{"id" => "r999"})
  end

  property "the arrows visit each room of the house one time, and come back" do
    check all(
            floors <- integer(1..3),
            extra <-
              list_of(tuple({integer(0..4), member_of([:indoor, :outdoor])}), max_length: 5),
            max_runs: 40
          ) do
      {house, rooms, items} =
        House.preset(%{size: 1800, year: 2005, floors: floors, heat: "gas", lot: nil})

      {:ok, build} = Build.choose_door(Build.new(), "my_house")
      build = Build.put_house(build, house, rooms, items)

      # More rooms, on random levels. A room outside is around the house.
      levels = Build.levels(floors)

      build =
        extra
        |> Enum.with_index()
        |> Enum.reduce(build, fn {{level, place}, i}, build ->
          level =
            if place == :outdoor,
              do: "outside",
              else: Enum.at(levels, rem(level, length(levels) - 1))

          {:ok, build, _id} = Build.add_room(build, "Room #{i}", level, place)
          build
        end)

      [first | _] = build.rooms
      walk = Stream.iterate(first, &elem(Inside.neighbors(build, &1), 1))
      steps = Enum.take(walk, length(build.rooms) + 1)

      # The next steps visit each room one time, and come back to the
      # first room.
      assert List.last(steps) == first

      assert steps |> Enum.drop(-1) |> Enum.map(& &1.id) |> Enum.sort() ==
               build.rooms |> Enum.map(& &1.id) |> Enum.sort()

      # The room before the next room is the same room.
      for room <- build.rooms do
        {_before, next} = Inside.neighbors(build, room)
        assert elem(Inside.neighbors(build, next), 0) == room
      end
    end
  end

  test "the room before a room and the next room: in the order of the list, in a loop" do
    build = house()
    names = fn {a, b} -> {a.name, b.name} end
    at = fn name -> Enum.find(build.rooms, &(&1.name == name)) end

    # The list: the roof and the attic, floor 2, floor 1, and around the
    # house.
    assert names.(Inside.neighbors(build, at.("Roof"))) == {"Driveway", "Attic"}
    assert names.(Inside.neighbors(build, at.("Bedroom 3"))) == {"Bathroom", "Kitchen"}
    assert names.(Inside.neighbors(build, at.("Driveway"))) == {"Backyard", "Roof"}

    # A house with one room: no arrows.
    one = %{build | rooms: [at.("Kitchen")]}
    assert Inside.neighbors(one, at.("Kitchen")) == nil
  end

  test "the list tells the usage and the flags of each item, and a station away" do
    assert Inside.feet(6) == "6 in"
    assert Inside.feet(144) == "12 ft"
    assert Inside.feet(150) == "12 ft 6 in"
    assert Layout.min_room() == 24
  end

  test "the list shows a station in a van in its room of the house", %{conn: conn} do
    build = house()
    laundry = Enum.find(build.rooms, &(&1.name == "Laundry")).id
    driveway = Enum.find(build.rooms, &(&1.name == "Driveway")).id
    {:ok, build, station} = Build.add_item(build, laundry, "power_station")
    {:ok, build, van} = Build.add_item(build, driveway, "camper_van")
    {:ok, build} = Build.take_to_van(build, station, van)
    {:ok, build} = Build.flag_item(build, station, :planned, true)
    view = open(conn, ~p"/inside", build)
    assert has_element?(view, "#room-#{laundry} #away-#{station}", "in the van now")
    # The station has its place in the van: the arrow keys move it there.
    render_hook(view, "nudge_item", %{"id" => station, "dx" => 6, "dy" => 0})
    assert elem(Build.item(build(view), station), 1).at.x == 6

    # On the plan, it does not go from the van to a room of the house.
    html =
      render_hook(view, "place_item", %{"id" => station, "room" => laundry, "x" => 10, "y" => 10})

    assert html =~ "This item cannot go in that room."
  end
end
