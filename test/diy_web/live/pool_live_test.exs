defmodule DIYWeb.PoolLiveTest do
  @moduledoc "A pool item and the search of the sheet Add (`DIYWeb.Inside`)."
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

  test "a pool from the sheet Add: water on the plan and on the house", %{conn: conn} do
    build = house()
    backyard = Enum.find(build.rooms, &(&1.name == "Backyard")).id
    view = open(conn, ~p"/inside?#{[add: backyard]}", build)

    assert has_element?(view, "#add-pool")
    render_click(view, "add_item", %{"room" => backyard, "type" => "pool"})
    assert [pool] = Enum.filter(build(view).items, &(&1.type == "pool"))
    assert pool.room == backyard
    assert has_element?(view, "#plan-item-#{pool.id} polygon.p-paver")
    assert has_element?(view, "#plan-item-#{pool.id} polygon.p-pool-wall")
    assert has_element?(view, "#plan-item-#{pool.id} polygon.p-water")
    assert has_element?(view, "#tex-water path.p-tex-wave")

    # A spa: a pool in a room inside.
    kitchen = room(view, "Kitchen").id
    render_patch(view, ~p"/inside?#{[add: kitchen]}")
    assert has_element?(view, "#add-pool")
    render_click(view, "add_item", %{"room" => kitchen, "type" => "pool"})
    assert Enum.count(build(view).items, &(&1.type == "pool")) == 2

    # The house from outside shows the water of the pool outside.
    render_patch(view, ~p"/")
    assert render(view) =~ "p-water"

    # The sheet of a room has no box of a pool, and the sheet New room
    # makes a room only.
    render_patch(view, ~p"/inside?#{[room: kitchen, sheet: "room"]}")
    refute render(view) =~ "This room is a pool"
    render_patch(view, ~p"/inside?sheet=new_room")
    refute has_element?(view, "#new-room input[name='room[pool]']")
    render_hook(view, "add_search", %{"q" => 5})

    # The attic has no pool.
    attic = room(view, "Attic").id
    render_patch(view, ~p"/inside?#{[add: attic]}")
    refute has_element?(view, "#add-pool")
  end

  test "the search of the sheet Add finds an item, and tells where a different item goes",
       %{conn: conn} do
    build = house()
    kitchen = Enum.find(build.rooms, &(&1.name == "Kitchen")).id
    view = open(conn, ~p"/inside?#{[add: kitchen]}", build)

    assert has_element?(view, "#add-search input[type=search]")
    assert has_element?(view, "#add-fridge")
    refute has_element?(view, "#add-solar_panels")

    view |> form("#add-search", %{"q" => "Tesla"}) |> render_change()
    assert has_element?(view, "#add-ev")
    refute has_element?(view, "#add-fridge")
    refute has_element?(view, "#add-elsewhere")

    # A spa goes in the kitchen: a pool, its pump, its heater and a hot
    # tub. "spa" is also the start of "space heater".
    view |> form("#add-search", %{"q" => "spa"}) |> render_change()
    assert has_element?(view, "#add-pool")
    assert has_element?(view, "#add-hot_tub")
    assert has_element?(view, "#add-count", "5 found. 0 go in a different place.")
    refute has_element?(view, "#add-elsewhere")

    view |> form("#add-search", %{"q" => "heat pump"}) |> render_change()
    assert has_element?(view, "#elsewhere-ac", "Central AC: in a room outside or the roof.")
    assert has_element?(view, "#add-count", "2 found. 1 goes in a different place.")
    assert has_element?(view, "#add-elsewhere h3", "Not for this room")

    view |> form("#add-search", %{"q" => "solar"}) |> render_change()
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

  test "a hot tub can move to a room inside or outside, not to the attic", %{conn: conn} do
    build = house()
    backyard = Enum.find(build.rooms, &(&1.name == "Backyard")).id
    {:ok, build, tub} = Build.add_item(build, backyard, "hot_tub")
    view = open(conn, ~p"/inside?#{[item: tub]}", build)

    # The list of the rooms has its own room, chosen, and the rooms inside.
    assert has_element?(view, ~s(option[value="#{backyard}"][selected]))
    assert has_element?(view, ~s(option[value="#{room(view, "Kitchen").id}"]))
    refute has_element?(view, ~s(option[value="#{room(view, "Attic").id}"]))
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

  test "the sheet of a pool has no switch of a station and no use", %{conn: conn} do
    build = house()
    backyard = Enum.find(build.rooms, &(&1.name == "Backyard")).id
    garage = Enum.find(build.rooms, &(&1.name == "Garage")).id
    {:ok, build, _station} = Build.add_item(build, garage, "power_station")
    {:ok, build, pool} = Build.add_item(build, backyard, "pool")
    {:ok, build, pump} = Build.add_item(build, backyard, "pool_pump")

    view = open(conn, ~p"/inside?#{[item: pool]}", build)
    assert has_element?(view, "#item-stage", "Pool")
    refute render(view) =~ "A power station runs it"
    refute render(view) =~ "The app uses it for"

    view = open(conn, ~p"/inside?#{[item: pump]}", build)
    assert render(view) =~ "A power station runs it"
    assert render(view) =~ "The app uses it for"
  end
end
