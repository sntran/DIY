defmodule DIYWeb.FurnitureLiveTest do
  @moduledoc "Furniture from the sheet Add (`DIYWeb.Inside`)."
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

  test "a fireplace in the living room and a tree in the yard", %{conn: conn} do
    build = house()
    living = Enum.find(build.rooms, &(&1.name == "Living room")).id
    backyard = Enum.find(build.rooms, &(&1.name == "Backyard")).id
    view = open(conn, ~p"/inside?#{[add: living]}", build)

    # Inside: the fireplace, and no tree.
    assert has_element?(view, "#add-fireplace")
    refute has_element?(view, "#add-tree")
    render_click(view, "add_item", %{"room" => living, "type" => "fireplace"})
    assert [fire] = Enum.filter(build(view).items, &(&1.type == "fireplace"))
    assert has_element?(view, "#plan-item-#{fire.id} polygon.i-fire")

    # Its sheet has no use and no cost: furniture uses no power. A
    # station does not run it.
    render_patch(view, ~p"/inside?#{[item: fire.id]}")
    assert has_element?(view, "#item-math", "It is furniture: it uses no power.")
    refute has_element?(view, "#item-year")
    refute render(view) =~ "A power station runs it"

    # Outside: the tree, and it shows on the house from outside.
    render_patch(view, ~p"/inside?#{[add: backyard]}")
    assert has_element?(view, "#add-tree")
    render_click(view, "add_item", %{"room" => backyard, "type" => "tree"})
    assert [tree] = Enum.filter(build(view).items, &(&1.type == "tree"))
    render_patch(view, ~p"/")
    assert has_element?(view, "#outside-#{tree.id}")
  end
end
