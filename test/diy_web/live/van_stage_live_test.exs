defmodule DIYWeb.VanStageLiveTest do
  @moduledoc """
  An item of a van in front of the person, on the page Van. It has the same
  stage and panel as an item of the house (`DIYWeb.Inside.item_stage/1`). Also
  the size of an item with − and +, and the field of a ZIP code.
  """
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}
  alias DIYWeb.Stage

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

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id
  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build
  defp item(view, id), do: view |> build() |> Build.item(id) |> elem(1)

  defp with_van(build \\ house()) do
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway"), "camper_van")
    {build, van}
  end

  defp add(build, van, zone, type) do
    {:ok, build, id} = Build.add_item(build, Build.zone(build, van, zone).id, type)
    {build, id}
  end

  # The place of each part in the page: the parts are in this order.
  defp order(html, ids), do: Enum.map(ids, &(:binary.match(html, ~s(id="#{&1}")) |> elem(0)))

  # Waits until the view has the element with the text: 1 second at most.
  defp eventually(view, selector, text, tries \\ 50) do
    cond do
      has_element?(view, selector, text) ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(view, selector, text, tries - 1)
    end
  end

  test "an item of a van comes forward with the same panel", %{conn: conn} do
    {build, van} = with_van()
    {build, fridge} = add(build, van, :galley, "van_fridge")
    {build, _battery} = add(build, van, :bay, "van_battery")
    # The numbers of the fridge are a guess.
    items = Enum.map(build.items, &if(&1.id == fridge, do: %{&1 | typical: true}, else: &1))
    view = open(conn, ~p"/van?#{[id: van, item: fridge]}", %{build | items: items})

    # The stage of the item, with the frames from the camera of the van
    # plan. The close goes back to the van.
    stage = "#item-stage #item-stage-#{fridge}[phx-hook=Stage][role=dialog]"
    assert has_element?(view, stage)
    refute has_element?(view, "#item-sheet")
    assert has_element?(view, "#item-stage-title", "12 V fridge")
    assert has_element?(view, "#item-stage .stage-note", "In Galley, in the van")
    assert has_element?(view, "#item-stage a.stage-back[href='/van?id=#{van}']", "Put it back")

    %{start: {sx, sy, sw, sh}} = Stage.frames("van_fridge", :van)
    start = Enum.map_join([sx, sy, sw, sh], " ", &format/1)
    assert has_element?(view, "#{stage}[data-start='#{start}']")

    # The same parts in the same order. The first part has the weight and
    # the energy of a day.
    html = render(view)
    parts = ["part-cost", "part-use", "part-where", "part-more"]
    positions = order(html, parts)
    assert positions == Enum.sort(positions)
    assert has_element?(view, "#part-cost-title.sr-only", "Its weight and its energy")
    assert has_element?(view, "#part-cost .stage-month", "lb")
    assert has_element?(view, "#part-cost .stage-year", "Wh in a day of July")
    refute has_element?(view, "#part-how")

    assert has_element?(
             view,
             "#part-guess",
             "These numbers are a guess. Check them on the label."
           )

    # The same controls: a number has − and +, and the weight shows.
    assert has_element?(view, "#param-weight-field button[aria-label='More: Weight']")
    assert has_element?(view, "#param-weight-unit", "lb")

    # Where it is: the zones of the van where the item can go, and its place.
    assert has_element?(view, "#move-form label[for=item-room]", "Zone")
    assert has_element?(view, "#item-room option", "Galley")
    refute has_element?(view, "#item-room option", "Kitchen")
    assert has_element?(view, "#part-where #item-place #size-w-field")

    # More: no flags of the house, what the van uses it for, and Remove.
    refute has_element?(view, "#flags-form")
    assert has_element?(view, "#part-more", "the weight budget of the van")
    refute has_element?(view, "#part-more", "the estimate of your power bill")
    assert has_element?(view, "#remove-text", "Remove this item from the van?")

    # A change of a number, and of the zone.
    view |> element("#param-weight-field button[phx-value-by='1']") |> render_click()
    assert has_element?(view, "#item-said", "Weight:")
    living = Build.zone(build(view), van, :living)
    view |> form("#move-form", %{"room" => living.id}) |> render_change()
    assert item(view, fridge).room == living.id

    # The remove goes back to the van.
    view |> element("#delete-item") |> render_click()
    assert_patch(view, ~p"/van?#{[id: van]}")
    refute has_element?(view, "#item-stage")
  end

  test "the van itself: the part of an item of the house, and the numbers of its model",
       %{conn: conn} do
    {build, van} = with_van()
    view = open(conn, ~p"/van?#{[id: van, item: van]}", build)

    assert has_element?(view, "#item-stage-title", "Camper van")
    assert has_element?(view, "#part-cost-title", "Its energy")
    # The page of the van is its build: the text does not send the person
    # to it.
    assert has_element?(view, "#item-math", "its own batteries and power: this page.")
    refute has_element?(view, "#item-math", "Open the build of the van")
    assert has_element?(view, "#item-stage #use-model", "Use the numbers of the model")
    # On its own page: no key to its page, and no remove.
    refute has_element?(view, "#open-van")
    refute has_element?(view, "#item-remove")
    assert has_element?(view, "#flags-form")

    # On the page Rooms, the van has the key to its page and the remove.
    render_patch(view, ~p"/inside?#{[item: van]}")
    assert has_element?(view, "#item-math", "Open the build of the van")
    assert has_element?(view, "#open-van")
    assert has_element?(view, "#item-remove")
    assert has_element?(view, "#use-model")
  end

  test "a station in the van goes home from its panel", %{conn: conn} do
    {build, van} = with_van()
    {:ok, build, station} = Build.add_item(build, room(build, "Laundry"), "power_station")

    # In the house, the room list has no zone of a van. An item does not go
    # from the house to a van with the list.
    view = open(conn, ~p"/inside?#{[item: station]}", build)
    assert has_element?(view, "#item-room option", "Laundry")
    refute has_element?(view, "#item-room option", "Electrical bay")
    refute has_element?(view, "#bring-home")

    # From its panel in the van, the station goes home, and the panel
    # closes: the station is not in the van now.
    {:ok, build} = Build.take_to_van(build, station, van)
    view = open(conn, ~p"/van?#{[id: van, item: station]}", build)
    view |> element("#bring-home", "Bring it home") |> render_click()
    assert_patch(view, ~p"/van?#{[id: van]}")
    assert render(view) =~ "The power station is at home now."
    refute has_element?(view, "#item-stage")
    assert DIY.Van.stations(build(view)).at_home != []

    # On the page of a different van, the list brings it home with no
    # message: its panel is not open there.
    {build, other} = with_van(build(view))
    {:ok, build} = Build.take_to_van(build, station, van)
    view = open(conn, ~p"/van?#{[id: other, item: station]}", build)
    view |> element("#van-stations button", "Bring it home") |> render_click()
    assert DIY.Van.stations(build(view)).at_home != []
    refute render(view) =~ "The power station is at home now."
  end

  test "a planned van opens on its page", %{conn: conn} do
    {build, van} = with_van()
    view = open(conn, ~p"/van?#{[id: van, item: van]}", build)

    # The van becomes a plan: its part "Its energy" stays.
    view |> form("#flags-form", %{"item_id" => van, "planned" => "true"}) |> render_change()
    assert item(view, van).planned
    assert has_element?(view, "#part-cost-title", "Its energy")
    view = open(conn, ~p"/van?#{[id: van, item: van]}", build(view))
    assert has_element?(view, "#item-math")
  end

  test "a smart meter tells the new size to a screen reader", %{conn: conn} do
    {:ok, build, meter} = Build.add_item(house(), room(house(), "Garage"), "smart_meter")
    view = open(conn, ~p"/inside?#{[item: meter]}", build)
    refute has_element?(view, "#item-form")
    view |> element("#size-w-field button[phx-value-by='1']") |> render_click()
    assert has_element?(view, "#item-stage #item-said[role=status]", "Width:")
  end

  test "an item is on the stage of its own page only", %{conn: conn} do
    {build, van} = with_van()
    {build, fridge} = add(build, van, :galley, "van_fridge")
    view = open(conn, ~p"/inside?#{[item: fridge]}", build)
    refute has_element?(view, "#item-stage")

    tv = Enum.find(build.items, &(&1.type == "tv"))
    view = open(conn, ~p"/van?#{[id: van, item: tv.id]}", build)
    refute has_element?(view, "#item-stage")
  end

  test "the size of an item has − and +, a field and its unit", %{conn: conn} do
    build = house()
    fridge = Enum.find(build.items, &(&1.type == "fridge"))
    view = open(conn, ~p"/inside?#{[item: fridge.id]}", build)
    {w, _d, _h} = DIY.Layout.size(fridge)

    assert has_element?(view, "#size-w-field label[for=size-w]", "Width")
    assert has_element?(view, "#size-w[aria-describedby=size-w-unit][value='#{w}']")
    assert has_element?(view, "#size-w-unit", "in")
    assert has_element?(view, "#size-w-field button[phx-value-by='-1'][aria-label='Less: Width']")
    refute has_element?(view, "#size-form button[type=submit]")

    # + gives the next round number of inches, and the status tells it.
    view |> element("#size-w-field button[phx-value-by='1']") |> render_click()
    new = item(view, fridge.id).size.w
    assert new > w
    assert has_element?(view, "#item-said", "Width: #{new} in")
    assert has_element?(view, "#size-w[value='#{new}']")

    # A typed size applies at once. A side that is not valid: the panel
    # tells it under the size, and the fields have the error.
    view |> form("#size-form", %{"w" => "40", "d" => "30", "h" => "70"}) |> render_change()
    assert item(view, fridge.id).size == %{w: 40, d: 30, h: 70}
    view |> form("#size-form", %{"w" => "0", "d" => "30", "h" => "70"}) |> render_change()
    assert has_element?(view, "#size-error", "Give each side in inches, from 1 to 1200.")

    assert has_element?(
             view,
             "#size-w[aria-invalid=true][aria-describedby='size-w-unit size-error']"
           )

    # Only the sides that are not valid have the error.
    assert has_element?(view, "#size-d[aria-describedby=size-d-unit]")
    refute has_element?(view, "#size-d[aria-invalid]")
    view |> form("#size-form", %{"w" => "0", "d" => "x", "h" => "70"}) |> render_change()
    assert has_element?(view, "#size-d[aria-invalid=true]")
    refute has_element?(view, "#size-h[aria-invalid]")

    # A step clears the error. So does the key "The typical size".
    view |> element("#size-h-field button[phx-value-by='1']") |> render_click()
    refute has_element?(view, "#size-error")
    view |> form("#size-form", %{"w" => "0", "d" => "30", "h" => "70"}) |> render_change()
    view |> element("#typical-size") |> render_click()
    refute has_element?(view, "#size-error")
    assert item(view, fridge.id).size == nil

    # At 1 inch, − is dimmed, and a tap says the end again.
    view |> form("#size-form", %{"w" => "2", "d" => "30", "h" => "70"}) |> render_change()
    view |> element("#size-w-field button[phx-value-by='-1']") |> render_click()
    assert item(view, fridge.id).size.w == 1
    assert has_element?(view, "#item-said", "Width: 1 in, the least")
    assert has_element?(view, "#size-w-field button[phx-value-by='-1'][aria-disabled=true]")
    html = view |> element("#size-w-field button[phx-value-by='-1']") |> render_click()
    refute html =~ "the least"
    assert eventually(view, "#item-said", "Width: 1 in, the least")

    # A status that comes late for a side that changed does not show.
    view |> form("#size-form", %{"w" => "5", "d" => "30", "h" => "70"}) |> render_change()
    send(view.pid, {:item_said, fridge.id, {:size, :w}, 1, "Width: 1 in, the least"})
    refute has_element?(view, "#item-said", "Width")

    # No change for a step that is not − or +, or for an item that is not
    # there. No change for an item with no size of its own: the model of a
    # van gives its size.
    {build, van} = with_van(build(view))
    view = open(conn, ~p"/inside?#{[item: fridge.id]}", build)
    before = build(view)
    render_click(view, "step_size", %{"id" => fridge.id, "side" => "x", "by" => "1"})
    render_click(view, "step_size", %{"id" => fridge.id, "side" => "w", "by" => "2"})
    render_click(view, "step_size", %{"id" => "i999", "side" => "w", "by" => "1"})
    render_click(view, "step_size", %{"id" => van, "side" => "w", "by" => "1"})
    assert build(view) == before
  end

  test "a status that comes late for an item that is not there does nothing", %{conn: conn} do
    view = open(conn, ~p"/inside?#{[item: "i999"]}", house())
    send(view.pid, {:item_said, "i999", {:param, "watts"}, 1, "Power: 1 W"})
    refute render(view) =~ "Power: 1 W"
  end

  test "the field of a ZIP code keeps the text after an error", %{conn: conn} do
    # The start page.
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "device:restore", %{"text" => nil, "stamp" => ""})
    view |> element("#door-my-house") |> render_click()
    view |> form("#zip-form", %{"zip" => "00000"}) |> render_submit()
    assert has_element?(view, "#zip-error[role=alert]", "The app does not know this ZIP code.")

    assert has_element?(
             view,
             "#zip[value='00000'][aria-invalid=true][aria-describedby=zip-error]"
           )

    # Settings: the error shows there too, and the field keeps the text.
    view = open(conn, ~p"/settings", house())
    view |> form("#settings-zip", %{"zip" => "1234"}) |> render_submit()

    assert has_element?(
             view,
             "#settings-zip-error[role=alert]",
             "The app does not know this ZIP code."
           )

    assert has_element?(
             view,
             "#settings-zip input[value='1234'][aria-invalid=true][aria-describedby=settings-zip-error]"
           )

    # A different page: the error goes. A good ZIP code: no error.
    render_patch(view, ~p"/")
    render_patch(view, ~p"/settings")
    refute has_element?(view, "#settings-zip-error")
    assert has_element?(view, "#settings-zip input[value='75070']")
    view |> form("#settings-zip", %{"zip" => "1234"}) |> render_submit()
    view |> form("#settings-zip", %{"zip" => "75023"}) |> render_submit()
    refute has_element?(view, "#settings-zip-error")
    assert has_element?(view, "#settings-zip input[value='75023']")
  end

  # A number as the stage writes it: one decimal, with no zero at the end.
  defp format(n) do
    n = Float.round(n * 1.0, 1)
    if n == trunc(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n)
  end
end
