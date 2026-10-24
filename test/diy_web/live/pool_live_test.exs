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

    assert html =~ "A pool is inside or outside, not on the roof."
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

    html = view |> form("#pool-#{kitchen}", %{"pool" => "false"}) |> render_change()
    assert html =~ "Move the items of the pool to a different room first."
    assert Build.pool?(room(view, "Kitchen"))

    # The roof has no box.
    roof = room(view, "Roof").id
    render_patch(view, ~p"/inside?#{[room: roof, sheet: "room"]}")
    refute has_element?(view, "#pool-#{roof}")
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

    view |> form("#add-search", %{"q" => "zzz"}) |> render_change()
    assert has_element?(view, "#add-none")

    # The search stays while the sheet stays open. A new sheet starts with
    # no search.
    render_patch(view, ~p"/inside?#{[add: kitchen, room: kitchen]}")
    assert has_element?(view, "#add-none")
    backyard = room(view, "Backyard").id
    render_patch(view, ~p"/inside?#{[add: backyard]}")
    assert has_element?(view, "#add-search input[value='']")
    assert has_element?(view, "#add-pool_pump")
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
