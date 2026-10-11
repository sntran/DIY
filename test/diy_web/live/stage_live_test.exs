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

  defp add(build, room, type) do
    room = Enum.find(build.rooms, &(&1.name == room))
    {:ok, build, id} = Build.add_item(build, room.id, type)
    {:ok, item} = Build.item(build, id)
    {build, item}
  end

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

  # The place of each part in the page: the parts are in this order.
  defp order(html, ids), do: Enum.map(ids, &(:binary.match(html, ~s(id="#{&1}")) |> elem(0)))

  test "an item comes forward: the frames of its model, its tags, and its panel", %{conn: conn} do
    build = house()
    fridge = item(build, "fridge")
    view = open(conn, ~p"/inside?#{[item: fridge.id]}", build)

    # The hook is on an element of the item: a different item has a new
    # one. It is the dialog, so the tags are in the dialog too.
    stage = "#item-stage #item-stage-#{fridge.id}[phx-hook=Stage][data-item=#{fridge.id}]"
    assert has_element?(view, stage <> "[data-start][data-region]")

    assert has_element?(
             view,
             stage <> "[role=dialog][aria-modal=true][aria-labelledby=item-stage-title]"
           )

    refute has_element?(view, stage <> "[data-screen]")
    assert has_element?(view, "#item-stage-title[tabindex='-1']", "Fridge")
    assert has_element?(view, "#item-stage .stage-note", "In Kitchen (Floor 1)")
    refute has_element?(view, "#item-stage .stage-screen")

    # The frames of the flipbook: only the last (the front) shows before
    # the hook runs.
    frames = Stage.frame_count()
    html = render(view)
    assert length(Regex.scan(~r/class="stage-frame"/, html)) == frames
    assert has_element?(view, ".stage-frame[data-frame='#{frames - 1}']:not([hidden])")
    assert has_element?(view, ".stage-frame[data-frame='0'][hidden]")
    assert has_element?(view, "#item-stage-model-#{fridge.id}[phx-update=ignore][data-view]")

    # The tag of the number of the fridge: on its EnergyGuide label. Its
    # name starts with its text.
    assert has_element?(
             view,
             "#item-stage-spot-kwh_year[data-spot=kwh_year][data-at]" <>
               "[aria-label='kWh label: Energy in one year, on the yellow EnergyGuide label']",
             "kWh label"
           )

    assert has_element?(view, "#param-kwh_year-field button[data-show=kwh_year]", "Show me where")

    # The two close links put the item back: the scrim, and the key.
    assert has_element?(view, "#item-stage a.stage-scrim[data-close][href='/inside']")

    assert has_element?(
             view,
             "#item-stage a.stage-back[data-close][href='/inside']",
             "Put it back"
           )
  end

  test "the panel has the same parts in the same order for each item", %{conn: conn} do
    build = house()
    {build, hub} = add(build, "Living room", "home_assistant")

    for type <- ["fridge", "tv", "home_assistant"] do
      item = if type == "home_assistant", do: hub, else: item(build, type)
      view = open(conn, ~p"/inside?#{[item: item.id]}", build)
      html = render(view)
      use = if type == "home_assistant", do: "part-link", else: "part-use"
      parts = ["part-cost", "part-how", use, "part-where", "part-more"]
      positions = order(html, parts)
      assert positions == Enum.sort(positions), type

      # Each part has a heading that names it.
      for {part, title} <- [{use, nil}, {"part-where", "Where it is"}, {"part-more", "More"}] do
        assert has_element?(view, "##{part}[aria-labelledby='#{part}-title']"), type
        if title, do: assert(has_element?(view, "##{part}-title", title), type)
      end

      assert has_element?(view, "#part-cost[aria-labelledby=part-cost-title]"), type
      assert has_element?(view, "#part-cost-title.sr-only", "What it costs"), type
      assert has_element?(view, "#part-cost .stage-month", "a month"), type
      assert has_element?(view, "#item-year", "in one year"), type
      assert has_element?(view, "#part-how summary", "How the app gets this number"), type
      assert has_element?(view, "#part-more #flags-form input[name=planned][role=switch]"), type
      assert has_element?(view, "#part-where #move-form label[for=item-room]", "Room"), type
      assert has_element?(view, "#part-where #item-place"), type
    end
  end

  test "each kind of value has the same control", %{conn: conn} do
    build = house()
    tv = item(build, "tv")
    view = open(conn, ~p"/inside?#{[item: tv.id]}", build)

    # A number: − and +, a field and its unit, and the tag on the item. A
    # screen reader reads the unit with the field.
    field = "#param-watts-field"
    assert has_element?(view, "#{field} label[for=param-watts]", "Power")

    assert has_element?(
             view,
             "#{field} input#param-watts[type=number][min='5'][max='1000'][value='100']" <>
               "[aria-describedby=param-watts-unit]"
           )

    assert has_element?(view, "#{field} #param-watts-unit.stage-unit", "W")
    assert has_element?(view, "#{field} button[phx-value-by='-1'][aria-label='Less: Power']")
    assert has_element?(view, "#{field} button[phx-value-by='1'][aria-label='More: Power']")

    # The name of Show me where starts with its text, and names the number.
    assert has_element?(
             view,
             "#{field} button[data-show=watts][aria-label='Show me where: Power']",
             "Show me where"
           )

    assert has_element?(view, "#param-hours-field input[step=any]")

    # A choice is a row of buttons, with its name for the group.
    heater = item(build, "water_heater")
    render_patch(view, ~p"/inside?#{[item: heater.id]}")
    assert has_element?(view, "fieldset#param-fuel-field legend", "Fuel")
    assert has_element?(view, "#param-fuel-field input[type=radio][value=gas][checked]")
    refute has_element?(view, "#param-fuel-field select")
    refute has_element?(view, "#param-fuel-field button[data-show]")

    # A number with no unit has an empty unit, so + stays at its place. It
    # has no id: a screen reader reads nothing more.
    assert has_element?(view, "#param-people-field span.stage-unit:not([id])")
    assert has_element?(view, "input#param-people:not([aria-describedby])")

    view |> form("#item-form", %{"item" => %{"fuel" => "electric"}}) |> render_change()

    assert Build.item(build(view), heater.id) |> elem(1) |> Map.get(:params) |> Map.get("fuel") ==
             "electric"

    # Yes or no is a switch.
    ac = item(build, "ac")
    render_patch(view, ~p"/inside?#{[item: ac.id]}")

    assert has_element?(
             view,
             "#param-heat_pump-field input[type=checkbox][role=switch][name='item[heat_pump]']"
           )

    assert has_element?(view, "#param-heat_pump-field input[type=hidden][value=false]")

    # The note of a number or of a choice is read with it.
    {build, station} = add(build(view), "Living room", "power_station")
    view = open(conn, ~p"/inside?#{[item: station.id]}", build)

    assert has_element?(
             view,
             "input#param-solar_w[aria-describedby='param-solar_w-unit param-solar_w-help']"
           )

    assert has_element?(view, "#param-solar_w-help", "The most solar power that it takes.")
    assert has_element?(view, "fieldset#param-feeds-field[aria-describedby=param-feeds-help]")
    assert has_element?(view, "#param-feeds-help", "An inlet is a connector")

    # A name is a field, and a missing name is an error.
    {build, other} = add(build(view), "Kitchen", "other")
    view = open(conn, ~p"/inside?#{[item: other.id]}", build)
    assert has_element?(view, "#param-name-field input#param-name[type=text]")
    view |> form("#item-form", %{"item" => %{"name" => " "}}) |> render_change()

    assert has_element?(
             view,
             "input#param-name[aria-invalid=true][aria-describedby=param-name-error]"
           )

    assert has_element?(view, "#param-name-error.stage-error", "Give a name.")
    view |> form("#item-form", %{"item" => %{"watts" => "-1"}}) |> render_change()

    assert has_element?(
             view,
             "input#param-watts" <>
               "[aria-describedby='param-watts-unit param-watts-help param-watts-error']"
           )

    assert has_element?(view, "#param-watts-error.stage-error", "Give a number from 0 to")
  end

  test "− and + go to the next round value, in the range of the number", %{conn: conn} do
    build = house()
    tv = item(build, "tv")
    view = open(conn, ~p"/inside?#{[item: tv.id]}", build)

    param = fn key ->
      build(view) |> Build.item(tv.id) |> elem(1) |> Map.get(:params) |> Map.get(key)
    end

    # A screen reader hears the new value: the panel has a status for it.
    assert has_element?(view, "#part-use #item-said[role=status]", "")
    view |> element("#param-watts-field button[phx-value-by='1']") |> render_click()
    assert param.("watts") == 105
    assert has_element?(view, "input#param-watts[value='105']")
    assert has_element?(view, "#item-said", "Power: 105 W")
    view |> element("#param-watts-field button[phx-value-by='-1']") |> render_click()
    view |> element("#param-watts-field button[phx-value-by='-1']") |> render_click()
    assert param.("watts") == 95
    assert has_element?(view, "#item-said", "Power: 95 W")
    refute has_element?(view, "#item-said", "the")

    # In the range, − and + are not dimmed.
    refute has_element?(view, "#param-watts-field button[aria-disabled]")

    # At the start of the range: the least. − is dimmed for a screen reader,
    # but it is not disabled: it keeps the focus.
    view |> form("#item-form", %{"item" => %{"watts" => "6"}}) |> render_change()
    view |> element("#param-watts-field button[phx-value-by='-1']") |> render_click()
    assert param.("watts") == 5
    assert has_element?(view, "#item-said", "Power: 5 W, the least")
    assert has_element?(view, "#param-watts-field button[phx-value-by='-1'][aria-disabled=true]")
    refute has_element?(view, "#param-watts-field button[disabled]")
    refute has_element?(view, "#param-watts-field button[phx-value-by='1'][aria-disabled]")

    # Hours go by half an hour, and stop at 24.
    view |> element("#param-hours-field button[phx-value-by='1']") |> render_click()
    assert param.("hours") == 5.5
    view |> form("#item-form", %{"item" => %{"hours" => "24"}}) |> render_change()
    # A value that the person types: the status says nothing.
    refute has_element?(view, "#item-said", "Hours")
    refute has_element?(view, "#item-said", "Power")
    view |> element("#param-hours-field button[phx-value-by='1']") |> render_click()
    assert param.("hours") == 24.0
    assert eventually(view, "#item-said", "Hours in one day: 24 h, the most")
    assert has_element?(view, "#param-hours-field button[phx-value-by='1'][aria-disabled=true]")

    # A second tap at the end: the status is empty for a moment, and then
    # says the end again. So a screen reader reads it again.
    html = view |> element("#param-hours-field button[phx-value-by='1']") |> render_click()
    refute html =~ "the most"
    assert param.("hours") == 24.0
    assert eventually(view, "#item-said", "Hours in one day: 24 h, the most")

    # A status that comes late for a different item does not show, and a
    # message that the page does not know changes nothing.
    send(view.pid, {:item_said, "i999", "watts", 1, "Power: 1 W"})
    send(view.pid, :unknown)
    refute has_element?(view, "#item-said", "Power: 1 W")
    assert has_element?(view, "#item-said", "Hours in one day: 24 h, the most")

    # A status that comes late after a newer tap does not come back.
    late = {:item_said, tv.id, "hours", 24.0, "Hours in one day: 24 h, the most"}
    view |> element("#param-hours-field button[phx-value-by='-1']") |> render_click()
    send(view.pid, late)
    assert has_element?(view, "#item-said", "Hours in one day: 23.5 h")

    # Nor after a value that the person types.
    view |> form("#item-form", %{"item" => %{"hours" => "20"}}) |> render_change()
    send(view.pid, late)
    refute has_element?(view, "#item-said", "Hours")

    # Nor after a newer status of a different number of the item.
    late = {:item_said, tv.id, "hours", 20.0, "Hours in one day: 20 h"}
    view |> element("#param-watts-field button[phx-value-by='1']") |> render_click()
    send(view.pid, late)
    refute has_element?(view, "#item-said", "Hours")

    # The status is for its item only: it goes when a different item opens.
    render_patch(view, ~p"/inside?#{[item: item(build, "fridge").id]}")
    # Nor in the panel of a different item.
    send(view.pid, late)
    refute has_element?(view, "#item-said", "Hours")
    render_patch(view, ~p"/inside?#{[item: tv.id]}")
    refute has_element?(view, "#item-said", "Hours")

    # The change is a change of the person: the numbers are not a guess now.
    refute Build.item(build(view), tv.id) |> elem(1) |> Map.get(:typical)

    # A step that is not − or +, a number that the item does not have, or an
    # item that is not there: no change.
    before = build(view)
    render_click(view, "step_param", %{"id" => tv.id, "key" => "watts", "by" => "5"})
    render_click(view, "step_param", %{"id" => tv.id, "key" => "fuel", "by" => "1"})
    render_click(view, "step_param", %{"id" => "i999", "key" => "watts", "by" => "1"})
    assert build(view) == before
  end

  test "the remove asks on the panel, and the item can stay", %{conn: conn} do
    build = house()
    fridge = item(build, "fridge")
    view = open(conn, ~p"/inside?#{[item: fridge.id]}", build)

    # The question is on the panel: the browser shows it, and Keep it hides
    # it. Each moves the focus.
    assert has_element?(
             view,
             "#ask-remove[phx-click*='remove-confirm'][phx-click*='keep-item']",
             "Remove the item"
           )

    assert has_element?(view, "#remove-confirm.hidden[role=group][aria-labelledby=remove-text]")
    assert has_element?(view, "#remove-text", "Remove this item from the house?")
    assert has_element?(view, "#keep-item[phx-click*='ask-remove']", "Keep it")
    assert Build.item(build(view), fridge.id) == {:ok, fridge}

    view |> element("#delete-item") |> render_click()
    assert_patch(view, ~p"/inside")
    assert Build.item(build(view), fridge.id) == {:error, :item}
    refute has_element?(view, "#item-stage")
  end

  test "a Home Assistant hub has its address on its LED screen", %{conn: conn} do
    build = house()
    {build, hub} = add(build, "Living room", "home_assistant")
    view = open(conn, ~p"/inside?#{[item: hub.id]}", build)

    # The screen of the hub has only the address and Connect. The panel has
    # the rest of the link, and a way to the screen.
    assert has_element?(view, "#item-stage-#{hub.id}[data-screen]")

    assert has_element?(
             view,
             "#item-stage-screen[phx-mounted] #ha-form label[for=ha-url]",
             "Address of your Home Assistant"
           )

    assert has_element?(view, "#item-stage-screen #ha-form input#ha-url[name=url][type=url]")

    assert has_element?(
             view,
             "#item-stage-screen #ha-form input[name=back][value='/inside?item=#{hub.id}']"
           )

    assert has_element?(view, "#part-link #home-assistant-card #ha-status")
    refute has_element?(view, "#part-link #ha-form")
    assert has_element?(view, "#part-link #ha-show-screen.stage-link[data-show=screen]")

    # A bad address: the screen tells it next to the field, and a screen
    # reader reads the error of the panel with the field.
    refute has_element?(view, "#ha-url[aria-invalid]")
    view |> form("#ha-form", %{"url" => "home.example.com"}) |> render_submit()

    assert has_element?(
             view,
             "#ha-url[aria-invalid=true][aria-describedby='ha-screen-error ha-error']"
           )

    assert has_element?(view, "#item-stage-screen #ha-screen-error", "Check the address.")
    assert has_element?(view, "#part-link #ha-error", "Give the address")

    # When the link is open, the screen shows its state.
    render_hook(view, "ha:status", %{"state" => "connected", "url" => "https://home.example.com"})
    refute has_element?(view, "#ha-form")
    assert has_element?(view, "#item-stage-screen #ha-screen-state")
    refute has_element?(view, "#ha-show-screen")
    assert has_element?(view, "#part-link #ha-disconnect")
  end
end
