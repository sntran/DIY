defmodule DIYWeb.StackLiveTest do
  @moduledoc "Items on items on the plan and on the House page (`DIY.Stack`)."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Layout, Stubs}
  alias DIYWeb.{Cutaway, Outside}

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
  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))
  defp first(build, type), do: Enum.find(build.items, &(&1.type == type))
  defp item(build, id), do: elem(Build.item(build, id), 1)

  test "a drop on an item puts it on the item, and the sheet tells it", %{conn: conn} do
    build = house()
    laundry = room(build, "Laundry")
    washer = first(build, "washer")
    dryer = first(build, "dryer")
    view = open(conn, ~p"/inside", build)

    # The hook sends the center of the item on the plan. 3 inches from the
    # center of the washer: the dryer snaps on it.
    {w, d} = Layout.extent(dryer)
    x = laundry.plan.x + washer.at.x + w / 2 + 3
    y = laundry.plan.y + washer.at.y + d / 2
    render_hook(view, "place_item", %{"id" => dryer.id, "room" => laundry.id, "x" => x, "y" => y})

    assert %{on: on, at: at} = item(build(view), dryer.id)
    assert {on, at} == {washer.id, washer.at}
    assert has_element?(view, "#plan-item-#{dryer.id}[data-on=#{washer.id}]")
    refute has_element?(view, "#plan-item-#{washer.id}[data-on]")

    # The dryer paints after the washer.
    [ground | _] = Cutaway.view(build(view)).levels
    ids = Enum.map(ground.objects, & &1.id)
    assert Enum.find_index(ids, &(&1 == washer.id)) < Enum.find_index(ids, &(&1 == dryer.id))

    # The dryer has no shadow: it is not on the floor.
    refute has_element?(view, "#plan-item-#{dryer.id} polygon.p-shadow")
    assert has_element?(view, "#plan-item-#{washer.id} polygon.p-shadow")

    render_hook(view, "open_item", %{"id" => dryer.id})
    assert has_element?(view, "#item-where", "Under it: Clothes washer.")

    # The arrow keys: the status tells the item under it too.
    render_hook(view, "nudge_item", %{"id" => dryer.id, "dx" => 6, "dy" => 0})
    assert has_element?(view, "#plan-status", "Under it: Clothes washer.")
  end

  test "the items on an item are on its top, in the rooms and on the House page" do
    build = house()
    backyard = room(build, "Backyard")
    {:ok, build, pool} = Build.add_item(build, backyard.id, "pool")
    {:ok, build, tub} = Build.add_item(build, backyard.id, "hot_tub")

    # Its center is on the coping at the front of the pool, 12 inches from
    # the front. The hot tub is 84 by 84.
    box = Layout.item_box(item(build, pool))
    at = %{x: box.x + 20, y: box.y + box.d - 12 - 42}
    {:ok, build} = Build.place_item(build, tub, backyard.id, at, true)
    assert item(build, tub).at == at

    assert item(build, tub).on == pool

    # The hot tub is on the coping of the pool. A pool is in the floor:
    # the hot tub is at the floor.
    assert [%{base_top: 0}] = Enum.filter(Cutaway.stacked(build.items), &(&1.id == tub))

    objects = Outside.view(build).level.objects
    %{box: {_, _, _, _, _, top}} = Enum.find(objects, &(&1.id == pool))
    %{box: {_, _, bottom, _, _, _}} = Enum.find(objects, &(&1.id == tub))
    assert_in_delta bottom, top, 1.0e-6

    [ground | _] = Cutaway.view(build).levels
    plan_tub = Enum.find(ground.objects, &(&1.id == tub))
    assert plan_tub.on == pool
  end
end
