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
    assert has_element?(view, "#plan-wall-van-seat-driver")
    assert has_element?(view, "#plan-wall-van-hood")
    assert has_element?(view, "button[data-zoom=fit][aria-label='Show all the van']")

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

    view |> element("#bar-change") |> render_click()
    assert has_element?(view, "#zone-sheet")

    # The zone gets a size: the walls at the front move.
    view
    |> form("#size-#{living.id}", %{"w" => "4", "d" => "2"})
    |> render_submit()

    assert %{w: 48, d: 24} = zone(view, van, :living).plan

    # The buttons move it in the van; it does not go out of the van.
    x = zone(view, van, :living).plan.x
    view |> element("#move-room-right") |> render_click()
    assert zone(view, van, :living).plan.x == x + 6
    html = render_hook(view, "nudge_room", %{"id" => living.id, "dx" => 600, "dy" => 0})
    assert html =~ "A zone stays in the van."

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
    # The swivel seat is at the back corner of the cab: on the left, at the
    # place of the seat of the driver.
    refute has_element?(view, "#plan-wall-van-seat-driver")
    assert has_element?(view, "#plan-wall-van-seat-passenger")
  end
end
