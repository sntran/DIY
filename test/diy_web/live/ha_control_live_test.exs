defmodule DIYWeb.HaControlLiveTest do
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}
  alias DIYWeb.HomeAssistant

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp build do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp connected(view) do
    render_hook(view, "ha:status", %{
      "state" => "connected",
      "url" => "https://ha.example.com",
      "name" => "Home"
    })
  end

  @areas [%{"id" => "kitchen", "name" => "Kitchen", "floor" => nil}]

  @devices [
    %{"id" => "d1", "name" => "Kitchen Lights", "area" => "kitchen", "domains" => ["light"]},
    %{"id" => "d2", "name" => "Kitchen TV", "area" => "kitchen", "domains" => ["media_player"]}
  ]

  # The page Rooms with the lights of the kitchen in the house, and their
  # panel open.
  defp page(conn) do
    build = build()
    {:ok, view, _html} = live(conn, ~p"/inside")
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    connected(view)
    render_hook(view, "ha:devices", %{"devices" => @devices, "areas" => @areas})
    render_hook(view, "ha_add_device", %{"id" => "d1"})
    item = Build.device_item(:sys.get_state(view.pid).socket.assigns.build, "d1")
    assert_patch(view, ~p"/inside?#{[item: item]}")
    {view, item}
  end

  defp states(view, states), do: render_hook(view, "ha:states", %{"states" => states})

  test "the state of a light: on the plan, in the list of the rooms, and in its panel", %{
    conn: conn
  } do
    {view, item} = page(conn)

    # Before the hook tells the state: the switch waits.
    assert has_element?(view, "#part-link #ha-power #ha-switch[role=switch][aria-checked=false]")
    assert has_element?(view, "#ha-switch[aria-disabled=true]")
    assert has_element?(view, "#ha-power-state[role=status]", "The app waits for its state.")
    refute has_element?(view, "#plan-svg [data-ha]")

    states(view, %{"d1" => "on", "d2" => "on"})
    assert has_element?(view, "#plan-svg g[data-item=#{item}][data-ha=on]")
    assert has_element?(view, "#item-stage .stage[data-ha=on]")
    assert has_element?(view, "#item-#{item}", "Lights")
    assert view |> element("#item-#{item}") |> render() =~ ", on now"
    assert has_element?(view, "#ha-switch[aria-checked=true][aria-disabled=false]")
    assert has_element?(view, "#ha-switch[phx-value-on=false]")
    assert has_element?(view, "#ha-power-state", "It is on.")

    states(view, %{"d1" => "off"})
    assert has_element?(view, "#plan-svg g[data-item=#{item}][data-ha=off]")
    assert has_element?(view, "#item-stage .stage[data-ha=off]")
    assert view |> element("#item-#{item}") |> render() =~ ", off now"
    assert has_element?(view, "#ha-switch[aria-checked=false][phx-value-on=true]")
    assert has_element?(view, "#ha-power-state", "It is off.")

    states(view, %{"d1" => "unavailable"})
    assert has_element?(view, "#plan-svg g[data-item=#{item}][data-ha=unavailable]")

    assert view |> element("#item-#{item}") |> render() =~
             ", Home Assistant cannot reach it now"

    assert has_element?(view, "#ha-switch[aria-disabled=true]")
    assert has_element?(view, "#ha-power-state", "Home Assistant cannot reach it now.")

    # A tap on the switch with no state changes nothing.
    view |> element("#ha-switch") |> render_click()
    refute_push_event(view, "ha:control", _payload)
  end

  test "the switch turns the device on and off, and tells the end", %{conn: conn} do
    {view, item} = page(conn)
    states(view, %{"d1" => "on"})

    view |> element("#ha-switch") |> render_click()
    assert_push_event(view, "ha:control", %{device: "d1", on: false})
    assert has_element?(view, "#ha-switch[aria-disabled=true]")
    assert has_element?(view, "#ha-power-state", "Home Assistant turns it off.")

    # While the control waits, a second tap changes nothing.
    view |> element("#ha-switch") |> render_click()
    refute_push_event(view, "ha:control", _payload)

    # The new state comes with the watch, then the end.
    states(view, %{"d1" => "off"})
    render_hook(view, "ha:control_done", %{"device" => "d1", "error" => nil})
    assert has_element?(view, "#ha-switch[aria-checked=false][aria-disabled=false]")
    assert has_element?(view, "#ha-power-state", "It is off.")

    # Home Assistant refuses: the error and the state.
    render_click(view, "ha_switch", %{"item" => item, "on" => "true"})
    assert_push_event(view, "ha:control", %{device: "d1", on: true})
    assert has_element?(view, "#ha-power-state", "Home Assistant turns it on.")
    render_hook(view, "ha:control_done", %{"device" => "d1", "error" => "failed"})

    assert has_element?(
             view,
             "#ha-power-state",
             "Home Assistant did not do it. Try again. It is off."
           )

    # A new control clears the error. An end that comes late, or for no
    # control, changes nothing.
    render_hook(view, "ha:control_done", %{"device" => "d1", "error" => nil})
    assert has_element?(view, "#ha-power-state", "Home Assistant did not do it.")
    render_hook(view, "ha:control_done", %{"device" => "d9", "error" => "failed"})
    render_hook(view, "ha:control_done", %{"device" => "d1", "error" => "bad"})
    render_hook(view, "ha:control_done", %{"nothing" => true})
    view |> element("#ha-switch") |> render_click()
    assert_push_event(view, "ha:control", %{device: "d1", on: true})
    refute has_element?(view, "#ha-power-state", "did not do it")
    render_hook(view, "ha:control_done", %{"device" => "d1", "error" => "offline"})

    assert has_element?(
             view,
             "#ha-power-state",
             "The link to Home Assistant closed before the end. Try again."
           )

    # A switch value that the page does not know, and an item with no
    # device.
    render_click(view, "ha_switch", %{"item" => item, "on" => "maybe"})
    render_click(view, "ha_switch", %{"item" => "nothing", "on" => "true"})
    refute_push_event(view, "ha:control", _payload)
  end

  test "no switch for a device that the app does not turn on and off, or with no link", %{
    conn: conn
  } do
    {view, item} = page(conn)
    states(view, %{"d1" => "on"})

    # The TV of Home Assistant is a media player: no switch.
    render_hook(view, "ha_add_device", %{"id" => "d2"})
    tv = Build.device_item(:sys.get_state(view.pid).socket.assigns.build, "d2")
    assert_patch(view, ~p"/inside?#{[item: tv]}")
    assert has_element?(view, "#ha-device", "This is Kitchen TV in Home Assistant.")
    refute has_element?(view, "#ha-switch")

    # The link closes: the switch stays, so that it keeps the focus, but it
    # has no state. The plan has no states. A state that comes then does
    # not count, and a tap changes nothing.
    render_patch(view, ~p"/inside?#{[item: item]}")
    assert has_element?(view, "#ha-switch")
    render_click(view, "ha_switch", %{"item" => item, "on" => "false"})
    assert_push_event(view, "ha:control", %{device: "d1", on: false})
    render_hook(view, "ha:status", %{"state" => "offline", "url" => "https://ha.example.com"})
    assert has_element?(view, "#ha-switch[aria-disabled=true][aria-checked=false]")
    assert has_element?(view, "#ha-power-state", "The app has no link to Home Assistant now.")
    view |> element("#ha-switch") |> render_click()
    refute_push_event(view, "ha:control", _payload)
    refute has_element?(view, "#plan-svg [data-ha]")
    states(view, %{"d1" => "on"})
    refute has_element?(view, "#plan-svg [data-ha]")
    assert :sys.get_state(view.pid).socket.assigns.ha_control == %{}

    # Connected again: the states come again from the hook.
    connected(view)
    assert has_element?(view, "#ha-power-state", "The app waits for its state.")
    states(view, %{"d1" => "on"})
    assert has_element?(view, "#plan-svg g[data-item=#{item}][data-ha=on]")

    # A disconnect forgets the devices: no switch then.
    render_hook(view, "ha:status", %{"state" => "none"})
    refute has_element?(view, "#ha-switch")
  end

  test "a new state of the device ends the error of its last control", %{conn: conn} do
    {view, item} = page(conn)
    states(view, %{"d1" => "off"})
    render_click(view, "ha_switch", %{"item" => item, "on" => "true"})
    render_hook(view, "ha:control_done", %{"device" => "d1", "error" => "failed"})
    assert has_element?(view, "#ha-power-state", "Home Assistant did not do it.")

    # The same state keeps the error. A person turns the light on in Home
    # Assistant: the error goes.
    states(view, %{"d1" => "off"})
    assert has_element?(view, "#ha-power-state", "Home Assistant did not do it.")
    states(view, %{"d1" => "on"})
    assert has_element?(view, "#ha-power-state", "It is on.")
    refute has_element?(view, "#ha-power-state", "did not do it")

    # The word Power is the label of the switch: a tap on it is a tap on
    # the switch.
    assert has_element?(view, "label#ha-power-label[for=ha-switch]", "Power")
  end

  property "the page takes only the states that it knows" do
    conn = Phoenix.ConnTest.build_conn()
    {view, item} = page(conn)

    check all(
            states <-
              map(
                list_of(
                  tuple(
                    {one_of([constant("d1"), string(:alphanumeric, max_length: 4)]),
                     one_of([
                       member_of(~w(on off unavailable)),
                       string(:printable, max_length: 4)
                     ])}
                  ),
                  max_length: 4
                ),
                &Map.new/1
              ),
            max_runs: 40
          ) do
      before = :sys.get_state(view.pid).socket.assigns.ha_states
      states(view, states)
      now = :sys.get_state(view.pid).socket.assigns.ha_states

      if Enum.all?(states, fn {_id, state} -> state in ~w(on off unavailable) end),
        do: assert(now == states),
        else: assert(now == before)

      case now["d1"] do
        nil -> refute has_element?(view, "#plan-svg [data-ha]")
        state -> assert has_element?(view, "#plan-svg g[data-item=#{item}][data-ha=#{state}]")
      end
    end
  end

  test "a payload of states that the page cannot read changes nothing", %{conn: conn} do
    {view, _item} = page(conn)
    states(view, %{"d1" => "on"})
    many = Map.new(1..1001, &{"x#{&1}", "on"})
    long = %{String.duplicate("x", 256) => "on"}

    for payload <- [%{"states" => many}, %{"states" => long}, %{"states" => ["on"]}, %{}] do
      render_hook(view, "ha:states", payload)
      assert :sys.get_state(view.pid).socket.assigns.ha_states == %{"d1" => "on"}
    end
  end

  test "the words of the switch, and the states of the items" do
    assert HomeAssistant.power_text(%{pending: true, state: "off", error: nil}) ==
             "Home Assistant turns it on."

    assert HomeAssistant.item_states(%{ha: %{state: "offline"}}) == %{}

    build = %{devices: %{"i1" => "d1", "i2" => "d2"}}

    assert HomeAssistant.item_states(%{
             ha: %{state: "connected"},
             build: build,
             ha_states: %{"d1" => "on"}
           }) == %{"i1" => "on"}

    assert HomeAssistant.controls?(%{domains: ["sensor", "fan"]})
    refute HomeAssistant.controls?(%{domains: ["media_player"]})
  end
end
