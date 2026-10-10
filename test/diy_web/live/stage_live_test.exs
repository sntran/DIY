defmodule DIYWeb.StageLiveTest do
  @moduledoc "An item in front of the person on the page Rooms (`DIYWeb.Stage`)."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}
  alias DIYWeb.Stage

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
    view
  end

  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build
  defp item(build, type), do: Enum.find(build.items, &(&1.type == type))

  # The page of the panel that shows, and the key of the page.
  defp shown?(view, page) do
    has_element?(view, "#page-#{page}:not([hidden])") and
      has_element?(view, "#key-#{page}[aria-selected=true]")
  end

  test "an item comes forward: the frames of its model, and its panel", %{conn: conn} do
    build = house()
    fridge = item(build, "fridge")
    view = open(conn, ~p"/inside?#{[item: fridge.id]}", build)

    stage = "#item-stage[phx-hook=Stage][data-item=#{fridge.id}]"
    assert has_element?(view, stage <> "[data-start][data-anchor]")
    assert has_element?(view, "#item-stage [role=dialog][aria-labelledby=item-stage-title]")
    assert has_element?(view, "#item-stage-title", "Fridge")
    assert has_element?(view, "#item-stage .stage-note", "In Kitchen (Floor 1)")
    assert has_element?(view, "#item-stage .stage-panel.panel-label")

    # The frames of the flipbook: only the last (the front) shows before
    # the hook runs.
    frames = Stage.frame_count()
    html = render(view)
    assert length(Regex.scan(~r/class="stage-frame"/, html)) == frames
    assert has_element?(view, ".stage-frame[data-frame='#{frames - 1}']:not([hidden])")
    assert has_element?(view, ".stage-frame[data-frame='0'][hidden]")
    assert has_element?(view, "#item-stage-model-#{fridge.id}[phx-update=ignore][data-view]")

    # The two close links put the item back: the scrim, and the key.
    assert has_element?(view, "#item-stage a.stage-scrim[data-close][href='/inside']")

    assert has_element?(
             view,
             "#item-stage a.stage-back[data-close][href='/inside']",
             "Put it back"
           )
  end

  test "the pages of the panel, and the keys", %{conn: conn} do
    build = house()
    fridge = item(build, "fridge")
    tv = item(build, "tv")
    view = open(conn, ~p"/inside?#{[item: fridge.id]}", build)

    assert has_element?(view, "[role=tablist] [role=tab]", "Use")
    refute has_element?(view, "#key-link")
    assert shown?(view, "use")
    assert has_element?(view, "#page-use #item-math", "In one year")
    assert has_element?(view, "#page-numbers[hidden] #item-form")

    view |> element("#key-numbers") |> render_click()
    assert shown?(view, "numbers")
    assert has_element?(view, "#page-use[hidden]")
    assert has_element?(view, "#page-numbers #flags-form")

    view |> element("#key-place") |> render_click()
    assert shown?(view, "place")
    assert has_element?(view, "#page-place #move-form")
    assert has_element?(view, "#page-place #item-place")

    # A page that the panel does not have shows the first page.
    render_click(view, "item_page", %{"page" => "link"})
    assert shown?(view, "use")

    # The same item keeps its page; a different item starts at its first.
    view |> element("#key-place") |> render_click()
    render_patch(view, ~p"/inside?#{[item: fridge.id]}")
    assert shown?(view, "place")
    render_patch(view, ~p"/inside?#{[item: tv.id]}")
    assert shown?(view, "use")
    assert has_element?(view, "#item-stage .stage-panel.panel-screen")
  end

  test "the remove asks on the panel, and the item can stay", %{conn: conn} do
    build = house()
    fridge = item(build, "fridge")
    view = open(conn, ~p"/inside?#{[item: fridge.id]}", build)

    view |> element("#key-remove") |> render_click()
    assert shown?(view, "remove")
    assert has_element?(view, "#page-remove", "Remove this item from the house?")
    view |> element("#page-remove button", "Keep it") |> render_click()
    assert shown?(view, "use")
    assert Build.item(build(view), fridge.id) == {:ok, fridge}

    view |> element("#key-remove") |> render_click()
    view |> element("#delete-item") |> render_click()
    assert_patch(view, ~p"/inside")
    assert Build.item(build(view), fridge.id) == {:error, :item}
    refute has_element?(view, "#item-stage")
  end

  test "a Home Assistant hub shows its link first, on its LED screen", %{conn: conn} do
    build = house()
    room = Enum.find(build.rooms, &(&1.name == "Living room"))
    {:ok, build, hub} = Build.add_item(build, room.id, "home_assistant")
    view = open(conn, ~p"/inside?#{[item: hub]}", build)

    assert has_element?(view, "#item-stage .stage-panel.panel-led")
    assert shown?(view, "link")
    assert has_element?(view, "#page-link #home-assistant-card #ha-form")
    view |> element("#key-use") |> render_click()
    assert shown?(view, "use")
    assert has_element?(view, "#page-link[hidden]")
  end
end
