defmodule DIYWeb.PoolLiveTest do
  @moduledoc "A pool room and the search of the sheet Add (`DIYWeb.Inside`)."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}

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

  test "a new room is a pool, with water on the plan and on the house", %{conn: conn} do
    view = open(conn, ~p"/inside?sheet=new_room", house())

    view
    |> form("#new-room", %{
      "room" => %{"name" => "Pool", "level" => "outside", "place" => "outdoor", "pool" => "true"}
    })
    |> render_submit()

    pool = room(view, "Pool")
    assert Build.pool?(pool)
    assert {pool.plan.w, pool.plan.d} == {432, 336}
    assert has_element?(view, "polygon.p-paver[data-room=#{pool.id}]")
    assert has_element?(view, "polygon.p-pool-wall")
    assert has_element?(view, "polygon.p-water")
    assert has_element?(view, "#tex-water path.p-tex-wave")

    # An indoor pool.
    render_patch(view, ~p"/inside?sheet=new_room")

    view
    |> form("#new-room", %{
      "room" => %{"name" => "Spa", "level" => "f1", "place" => "indoor", "pool" => "true"}
    })
    |> render_submit()

    assert Build.pool?(room(view, "Spa"))

    # The house from outside shows the water of the pool outside.
    render_patch(view, ~p"/")
    assert render(view) =~ "p-water"

    # A pool is never on the roof.
    render_patch(view, ~p"/inside?sheet=new_room")

    html =
      view
      |> form("#new-room", %{
        "room" => %{"name" => "Sky", "level" => "roof", "place" => "roof", "pool" => "true"}
      })
      |> render_submit()

    assert html =~ "A pool is inside or outside, not on the roof or in the attic."
  end

  test "the box of the sheet of a room makes it a pool, and keeps the items of a pool",
       %{conn: conn} do
    build = house()
    kitchen = Enum.find(build.rooms, &(&1.name == "Kitchen")).id
    view = open(conn, ~p"/inside?#{[room: kitchen, sheet: "room"]}", build)

    view |> form("#pool-#{kitchen}", %{"pool" => "true"}) |> render_change()
    assert Build.pool?(room(view, "Kitchen"))
    assert has_element?(view, "#pool-#{kitchen} input[type=checkbox][checked]")

    render_click(view, "add_item", %{"room" => kitchen, "type" => "hot_tub"})
    render_patch(view, ~p"/inside?#{[room: kitchen, sheet: "room"]}")

    assert has_element?(view, "#pool-box-#{kitchen}-0[checked]")
    html = view |> form("#pool-#{kitchen}", %{"pool" => "false"}) |> render_change()
    assert html =~ "Move the items of the pool to a different room first."
    assert Build.pool?(room(view, "Kitchen"))
    # The browser unchecked the box. The page draws a new box, checked.
    assert has_element?(view, "#pool-box-#{kitchen}-1[checked]")
    refute has_element?(view, "#pool-box-#{kitchen}-0")
    # The new box gets the focus. A new page starts again at 0.
    assert has_element?(view, "#pool-box-#{kitchen}-1[phx-mounted]")
    render_patch(view, ~p"/inside?#{[room: kitchen, sheet: "room"]}")
    assert has_element?(view, "#pool-box-#{kitchen}-0[checked]")
    refute has_element?(view, "#pool-box-#{kitchen}-0[phx-mounted]")

    # A stale room or a bad event shows an error, and no crash.
    render_hook(view, "room_pool", %{"room_id" => "r999", "pool" => "true"})
    assert render(view) =~ "This room is not in the house."
    render_hook(view, "add_search", %{"q" => 5})

    # The roof and the attic have no box.
    for name <- ["Roof", "Attic"] do
      id = room(view, name).id
      render_patch(view, ~p"/inside?#{[room: id, sheet: "room"]}")
      refute has_element?(view, "#pool-#{id}")
    end
  end

  test "the search of the sheet Add finds an item, and tells where a different item goes",
       %{conn: conn} do
    build = house()
    kitchen = Enum.find(build.rooms, &(&1.name == "Kitchen")).id
    view = open(conn, ~p"/inside?#{[add: kitchen]}", build)

    assert has_element?(view, "#add-search input[type=search]")
    assert has_element?(view, "#add-fridge")
    refute has_element?(view, "#add-pool_pump")

    view |> form("#add-search", %{"q" => "Tesla"}) |> render_change()
    assert has_element?(view, "#add-ev")
    refute has_element?(view, "#add-fridge")
    refute has_element?(view, "#add-elsewhere")

    view |> form("#add-search", %{"q" => "spa"}) |> render_change()
    refute has_element?(view, "#add-hot_tub")
    assert has_element?(view, "#elsewhere-hot_tub", "Hot tub: in a room outside or a pool.")

    assert has_element?(view, "#add-count", "1 found. 3 go in a different place.")
    assert has_element?(view, "#add-elsewhere h3", "Not for this room")

    view |> form("#add-search", %{"q" => "jacuzzi"}) |> render_change()
    assert has_element?(view, "#add-count", "0 found. 1 goes in a different place.")

    view |> form("#add-search", %{"q" => "zzz"}) |> render_change()
    assert has_element?(view, "#add-none")
    # "Other" takes any name: it always shows.
    assert has_element?(view, "#add-other")

    # The search stays while the sheet stays open. A new sheet starts with
    # no search.
    render_patch(view, ~p"/inside?#{[add: kitchen, room: kitchen]}")
    assert has_element?(view, "#add-none")
    backyard = room(view, "Backyard").id
    render_patch(view, ~p"/inside?#{[add: backyard]}")
    assert has_element?(view, "#add-search input[value='']")
    assert has_element?(view, "#add-pool_pump")
  end

  test "an item of a pool can move to a different pool inside", %{conn: conn} do
    {:ok, build, spa} = Build.add_room(house(), "Spa", "f1", :indoor, "pool")
    {:ok, build, spa2} = Build.add_room(build, "Spa 2", "f1", :indoor, "pool")
    {:ok, build, tub} = Build.add_item(build, spa, "hot_tub")
    view = open(conn, ~p"/inside?#{[item: tub]}", build)

    # The list of the rooms has the two pools and the rooms outside. Its
    # own room is chosen. A room inside that is not a pool is not there.
    assert has_element?(view, ~s(option[value="#{spa}"][selected]))
    assert has_element?(view, ~s(option[value="#{spa2}"]))
    assert has_element?(view, ~s(option[value="#{room(view, "Backyard").id}"]))
    refute has_element?(view, ~s(option[value="#{room(view, "Kitchen").id}"]))
  end

  test "a pool heater shows the field of its fuel only", %{conn: conn} do
    build = house()
    backyard = Enum.find(build.rooms, &(&1.name == "Backyard")).id
    {:ok, build, heater} = Build.add_item(build, backyard, "pool_heater")
    view = open(conn, ~p"/inside?#{[item: heater]}", build)
    assert has_element?(view, "#item-form input[name='item[watts]']")
    refute has_element?(view, "#item-form input[name='item[kbtu]']")

    {:ok, gas} = Build.update_item(build, heater, %{"fuel" => "gas"})
    view = open(conn, ~p"/inside?#{[item: heater]}", gas)
    refute has_element?(view, "#item-form input[name='item[watts]']")
    assert has_element?(view, "#item-form input[name='item[kbtu]']")
  end

  test "a pool shows the items of a pool first", %{conn: conn} do
    {:ok, build, spa} = Build.add_room(house(), "Spa", "f1", :indoor, "pool")
    view = open(conn, ~p"/inside?#{[add: spa]}", build)

    html = view |> element("#add-sheet ul") |> render()
    [first | _] = Regex.scan(~r/id="add-(\w+)"/, html, capture: :all_but_first)
    assert first in [["pool_pump"], ["pool_heater"], ["hot_tub"]]
    assert has_element?(view, "#add-fridge")
  end
end
