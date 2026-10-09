defmodule DIYWeb.VanPlanLiveTest do
  @moduledoc "The inside of a van at scale on the page Van (`DIYWeb.VanCutaway`)."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    settle(view)
    view
  end

  # A house with a van in the driveway: a fridge in the galley.
  defp van do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    build = Build.put_house(build, house, rooms, items)
    drive = Enum.find(build.rooms, &(&1.name == "Driveway")).id
    {:ok, build, van} = Build.add_item(build, drive, "camper_van")
    {:ok, build, fridge} = Build.add_item(build, Build.zone(build, van, :galley).id, "van_fridge")
    {build, van, fridge}
  end

  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build
  defp zone(view, van, place), do: Build.zone(build(view), van, place)
  defp item(view, id), do: elem(Build.item(build(view), id), 1)

  test "the van is cut open: its floor and its roof, with its zones and its items", %{conn: conn} do
    {build, van, fridge} = van()
    view = open(conn, ~p"/van?#{[id: van]}", build)
    galley = zone(view, van, :galley)

    assert has_element?(view, "#van-plan-#{van} button[data-focus=floor]", "Floor of the van")
    assert has_element?(view, "#van-plan-#{van} button[data-focus=roof]", "Roof of the van")
    assert has_element?(view, "polygon[data-room=#{galley.id}]")
    assert has_element?(view, "g[data-item=#{fridge}][data-in=#{galley.id}]")
    assert has_element?(view, "#plan-fixture-van-seat-driver")
    assert has_element?(view, "#plan-fixture-van-hood")
    assert has_element?(view, "button[data-zoom=fit][aria-label='Show all the van']")

    # In the house, the sheet of the van has no size: the model gives it.
    render_patch(view, ~p"/inside?#{[item: van]}")
    assert has_element?(view, "#item-place", "The model of the van gives its size")
    refute has_element?(view, "#size-form")
    render_patch(view, ~p"/van?#{[id: van]}")

    # The sizes of the model have their source, with the guesses of the app.
    assert has_element?(
             view,
             "#van-size-source",
             "The place of the front axle is a guess of the app"
           )

    assert has_element?(
             view,
             "#van-size-source",
             "The depth of the cab (3 ft) and the thickness of the doors at the back (3 in) are guesses of the app."
           )

    # The shell has no place on the plan: a tap adds an item to it.
    shell = zone(view, van, :shell)
    view |> element("#shell-add") |> render_click()
    assert_patch(view, ~p"/van?#{[id: van, add: shell.id]}")
    view |> element("#add-insulation") |> render_click()
    [insulation] = Build.items_in(build(view), shell.id)
    assert has_element?(view, "#shell-item-#{insulation.id}", "Insulation")
    render_patch(view, ~p"/van?#{[id: van]}")

    # The list: each zone, with its items and a link to add an item.
    assert has_element?(view, "#van-list #zone-#{galley.id} h3", "Galley")
    assert has_element?(view, "#van-item-#{fridge}[data-nudge=#{fridge}]")
    assert has_element?(view, "#choose-#{galley.id}[data-nudge-room=#{galley.id}]")
    cab = zone(view, van, :cab)
    refute has_element?(view, "#choose-#{cab.id}[data-nudge-room]")
  end

  test "a tap chooses a zone: a zone moves and gets a size; the cab stays", %{conn: conn} do
    {build, van, _fridge} = van()
    view = open(conn, ~p"/van?#{[id: van]}", build)
    living = zone(view, van, :living)

    render_hook(view, "select_room", %{"id" => living.id})
    assert_patch(view, ~p"/van?#{[id: van, room: living.id]}")
    assert has_element?(view, "#zone-bar", "Living area")
    assert has_element?(view, "#plan-selection [data-handle=x0]")

    # On the draft, the zone has no free place next to it: the buttons are
    # disabled (they keep the focus), and the bar says why. They use the
    # words of a van. They point as the move goes on the screen: the cab is
    # at the left, and the right side of the van at the top. A tap on one
    # gives the reason of the server.
    for {key, words} <- [
          {"left", "to the front"},
          {"up", "to the right side"},
          {"down", "to the left side"},
          {"right", "to the back"}
        ] do
      assert has_element?(
               view,
               "#move-room-#{key}[aria-disabled=true][aria-label='Move the zone 6 in #{words}']"
             )
    end

    assert has_element?(view, "#move-room-full", "Make it smaller first")
    html = view |> element("#move-room-right") |> render_click()
    assert html =~ "A room or a zone cannot go over a different one."

    view |> element("#bar-change") |> render_click()
    assert has_element?(view, "#zone-sheet")

    # The zone gets a size: the walls at the front move.
    view
    |> form("#size-#{living.id}", %{"w" => "4", "d" => "2"})
    |> render_submit()

    assert %{w: 48, d: 24} = zone(view, van, :living).plan
    refute has_element?(view, "#move-room-down[aria-disabled]")
    assert has_element?(view, "#move-room-up[aria-disabled=true]")

    # The buttons move it in the van; it does not go out of the van.
    x = zone(view, van, :living).plan.x
    view |> element("#move-room-down") |> render_click()
    assert zone(view, van, :living).plan.x == x + 6
    html = render_hook(view, "nudge_room", %{"id" => living.id, "dx" => 600, "dy" => 0})
    assert html =~ "A zone stays in the van."

    # An arrow key tells the new place of the zone.
    render_hook(view, "nudge_room", %{"id" => living.id, "dx" => 6, "dy" => 0})

    assert has_element?(
             view,
             "#plan-status",
             "Living area moved: 7 ft 1 in from the back of the van, 1 ft from its right side."
           )

    # The cab is fixed: no handles, no sheet, and it does not move.
    cab = zone(view, van, :cab)
    render_hook(view, "select_room", %{"id" => cab.id})
    assert has_element?(view, "#zone-bar", "It stays where it is.")
    refute has_element?(view, "#plan-selection [data-handle]")
    refute has_element?(view, "#bar-change")
    render_patch(view, ~p"/van?#{[id: van, room: cab.id, sheet: "zone"]}")
    refute has_element?(view, "#zone-sheet")
    html = render_hook(view, "nudge_room", %{"id" => cab.id, "dx" => -6, "dy" => 0})
    assert html =~ "The cab and the roof of the van stay where they are."

    # The bar closes.
    view |> element("#zone-bar a[aria-label=Close]") |> render_click()
    assert_patch(view, ~p"/van?#{[id: van]}")
    render_hook(view, "select_room", %{"id" => ""})
    assert_patch(view, ~p"/van?#{[id: van]}")
  end

  test "an item moves to a different zone, and its sheet has its place", %{conn: conn} do
    {build, van, fridge} = van()
    view = open(conn, ~p"/van?#{[id: van]}", build)
    living = zone(view, van, :living)

    render_hook(view, "open_item", %{"id" => fridge})
    assert_patch(view, ~p"/van?#{[id: van, item: fridge]}")
    assert has_element?(view, "#item-sheet #item-place")
    assert has_element?(view, "#item-where", "from the right side of Galley")
    assert has_element?(view, "#move-item-left[aria-label='Move the item 6 in to the front']")
    view |> element("#turn-item") |> render_click()
    assert item(view, fridge).turn == 1

    center = %{"x" => living.plan.x + 30, "y" => living.plan.y + 12}
    render_hook(view, "place_item", Map.merge(%{"id" => fridge, "room" => living.id}, center))
    assert item(view, fridge).room == living.id

    # An item of the shell has no place: it does not turn.
    shell = zone(view, van, :shell)
    {:ok, with_shell, insulation} = Build.add_item(build(view), shell.id, "insulation")
    view = open(conn, ~p"/van?#{[id: van]}", with_shell)
    refute has_element?(view, "#van-item-#{insulation}[data-nudge]")
    html = render_click(view, "turn_item", %{"id" => insulation})
    assert html =~ "This item or this room is not on the plan now."
  end

  test "the shell gives the materials, and a swivel seat takes the place of a seat", %{conn: conn} do
    {build, van, _fridge} = van()
    shell = Build.zone(build, van, :shell).id
    cab = Build.zone(build, van, :cab).id

    build =
      Enum.reduce(~w(insulation walls van_floor), build, fn type, build ->
        elem(Build.add_item(build, shell, type), 1)
      end)

    {:ok, build, _seat} = Build.add_item(build, cab, "swivel_seat")
    view = open(conn, ~p"/van?#{[id: van]}", build)
    html = render(view)
    assert html =~ "p-vinsul-t"
    assert html =~ "p-vpanel-r"
    assert html =~ "p-floor p-wood"
    # The swivel seat is at the back corner of the cab, at x = 0 (the right
    # side of the van). There, it takes the place of the seat of the
    # passenger.
    refute has_element?(view, "#plan-fixture-van-seat-passenger")
    assert has_element?(view, "#plan-fixture-van-seat-driver[class=p-fixture]")
  end
end
