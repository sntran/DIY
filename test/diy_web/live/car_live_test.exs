defmodule DIYWeb.CarLiveTest do
  @moduledoc "The sheet of an electric car: its body, its color and its size."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  test "the body of a car gives its size, and a key gives that size again", %{conn: conn} do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    build = Build.put_house(build, house, rooms, items)
    garage = Enum.find(build.rooms, &(&1.name == "Garage")).id
    {:ok, build, id} = Build.add_item(build, garage, "ev")
    {:ok, build} = Build.update_item(build, id, %{"body" => "bolt", "color" => "blue"})

    {:ok, view, _html} = live(conn, ~p"/inside?#{[item: id]}")
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})

    assert has_element?(view, "#item-place", "These are the sizes of the body of the car.")
    assert has_element?(view, "#size-w[value='70']")

    view
    |> form("#size-form", %{"item_id" => id, "w" => "72", "d" => "175", "h" => "65"})
    |> render_submit()

    assert has_element?(view, "#item-place", "You gave this size.")
    assert has_element?(view, "#typical-size", "The size of the body")
  end
end
