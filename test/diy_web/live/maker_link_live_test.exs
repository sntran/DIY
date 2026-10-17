defmodule DIYWeb.MakerLinkLiveTest do
  @moduledoc "The direct link to the cloud of Pecron, with no Home Assistant (`DIYWeb.MakerLink`)."
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}
  alias DIYWeb.MakerLink

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp preset do
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

  defp build_of(view), do: :sys.get_state(view.pid).socket.assigns.build

  defp status(view, state, error \\ nil),
    do:
      render_hook(view, "maker:status", %{"maker" => "pecron", "state" => state, "error" => error})

  defp stations(view, stations),
    do: render_hook(view, "maker:stations", %{"maker" => "pecron", "stations" => stations})

  # Two stations of the account: an E3800LFP in the garage, and a station
  # at a cabin that Pecron cannot reach now.
  defp e3800(fields \\ %{}) do
    Map.merge(
      %{
        "id" => "dev_1",
        "name" => "Garage battery",
        "model" => "E3800LFP",
        "online" => true,
        "battery" => 82,
        "input" => 640,
        "output" => 1250,
        "ac" => "on",
        "dc" => "off"
      },
      fields
    )
  end

  @cabin %{
    "id" => "dev_2",
    "name" => "Cabin",
    "model" => "X9",
    "online" => false,
    "battery" => 40,
    "input" => nil,
    "output" => nil,
    "ac" => "off",
    "dc" => nil
  }

  # The page Rooms with a power station in the garage, its panel open.
  defp station_page(conn) do
    build = preset()
    garage = Enum.find(build.rooms, &(&1.name == "Garage")).id
    {:ok, build, id} = Build.add_item(build, garage, "power_station")
    view = open(conn, ~p"/inside?#{[item: id]}", build)
    {view, id}
  end

  test "the card in Settings: the token goes to the hook, not to the LiveView", %{conn: conn} do
    view = open(conn, ~p"/settings", preset())

    # Before the hook tells the state, the card waits.
    assert has_element?(view, "#pecron-card h2", "Pecron")
    refute has_element?(view, "#pecron-form")

    status(view, "none")
    assert has_element?(view, "#pecron-status[role=status]", "Not connected.")

    assert has_element?(
             view,
             ~s(#pecron-form[data-maker=pecron] input[name=token][type=password][autocomplete=off])
           )

    form = view |> element("#pecron-form") |> render()
    assert form =~ "maker:connect"
    refute form =~ ~s(phx-submit="maker)
    refute has_element?(view, "#pecron-disconnect")

    # A token that is not a token of Pecron.
    status(view, "none", "format")
    assert has_element?(view, "#pecron-error[role=alert]", "A token of Pecron starts with phk_.")

    status(view, "connecting")
    assert has_element?(view, "#pecron-status", "The app connects to Pecron.")
    refute has_element?(view, "#pecron-form")
    refute has_element?(view, "#pecron-error")

    status(view, "connected")
    stations(view, [e3800(), @cabin])
    assert has_element?(view, "#pecron-status", "Connected to Pecron: 2 stations.")

    status(view, "offline", "unreachable")
    assert has_element?(view, "#pecron-status", "The app cannot reach Pecron now.")
    assert has_element?(view, "#pecron-error", "Pecron does not answer now.")

    status(view, "refused", "token")
    assert has_element?(view, "#pecron-status", "Pecron does not accept the token.")
    assert has_element?(view, "#pecron-form")

    view |> element("#pecron-disconnect") |> render_click()
    assert_push_event(view, "maker:disconnect", %{maker: "pecron"})
    render_click(view, "maker_disconnect", %{"maker" => "other"})
    refute_push_event(view, "maker:disconnect", _payload)
  end

  test "a station links to a station of the account, and shows its numbers", %{conn: conn} do
    {view, id} = station_page(conn)

    # With no link to Pecron, the panel has no part Pecron.
    refute has_element?(view, "#part-maker")
    status(view, "connected")
    stations(view, [e3800(), @cabin])

    # The stations of the account, to link.
    assert has_element?(view, "#part-maker-title", "Pecron")
    assert has_element?(view, "#maker-choice-0", "Garage battery (E3800LFP)")
    assert has_element?(view, "#maker-choice-1", "Cabin (X9)")

    # A unit that the page does not offer changes nothing.
    render_click(view, "maker_link", %{"item" => id, "unit" => "pecron:dev_9"})
    assert build_of(view).units == %{}

    # The link: the station gets the model of the E3800LFP.
    view |> element("#maker-choice-0") |> render_click()
    assert build_of(view).units == %{id => "pecron:dev_1"}
    {:ok, station} = Build.item(build_of(view), id)
    assert station.params["model"] == "pecron_e3800lfp"
    assert has_element?(view, "#item-stage-title", "Pecron E3800LFP")
    refute has_element?(view, "#maker-choices")

    # The numbers and the switches.
    assert has_element?(view, "#pecron-battery", "82%")
    assert has_element?(view, "#pecron-input", "640 W")
    assert has_element?(view, "#pecron-output", "1,250 W")

    assert has_element?(
             view,
             "#pecron-switch-ac[role=switch][aria-checked=true][aria-disabled=false]"
           )

    assert has_element?(view, "#pecron-ac-state[role=status]", "It is on.")
    assert has_element?(view, "#pecron-dc-state", "It is off.")

    # The other station is not a choice now: a second station links to it.
    garage = Enum.find(build_of(view).rooms, &(&1.name == "Garage")).id
    {:ok, build, other} = Build.add_item(build_of(view), garage, "power_station")
    {:ok, build} = Build.update_item(build, other, %{"model" => "anker_solix_f3800"})
    view = open(conn, ~p"/inside?#{[item: other]}", build)
    status(view, "connected")
    stations(view, [e3800(), @cabin])
    assert has_element?(view, "#maker-choice-0", "Cabin (X9)")
    refute has_element?(view, "#maker-choice-1")

    # A model that the person chose stays.
    view |> element("#maker-choice-0") |> render_click()
    {:ok, station} = Build.item(build_of(view), other)
    assert station.params["model"] == "anker_solix_f3800"

    # Pecron cannot reach this station: its last numbers, and no switch.
    assert has_element?(view, "#maker-unreachable", "Pecron cannot reach the station now.")
    assert has_element?(view, "#pecron-battery", "40%")
    assert has_element?(view, "#pecron-ac-state", "Pecron cannot reach the station now.")
    assert has_element?(view, "#pecron-dc-state", "Pecron has no switch for it.")
    assert has_element?(view, "#pecron-switch-ac[aria-disabled=true]")
    view |> element("#pecron-switch-ac") |> render_click()
    refute_push_event(view, "maker:control", _payload)

    # The end of the link: the choices again.
    view |> element("#maker-unlink") |> render_click()
    assert build_of(view).units == %{id => "pecron:dev_1"}
    assert has_element?(view, "#maker-choice-0", "Cabin (X9)")
    render_click(view, "maker_unlink", %{"item" => other})
    assert build_of(view).units == %{id => "pecron:dev_1"}
  end

  test "a switch turns the outlets on and off, and tells the end", %{conn: conn} do
    {view, id} = station_page(conn)
    status(view, "connected")
    stations(view, [e3800()])
    view |> element("#maker-choice-0") |> render_click()

    view |> element("#pecron-switch-ac") |> render_click()

    assert_push_event(view, "maker:control", %{
      maker: "pecron",
      device: "dev_1",
      part: "ac",
      on: false
    })

    assert has_element?(view, "#pecron-switch-ac[aria-disabled=true]")
    assert has_element?(view, "#pecron-ac-state", "Pecron turns it off.")

    # While the control waits, a second tap changes nothing, and new
    # numbers do not end it. The end of a different part, or of a
    # different device, does not end it.
    view |> element("#pecron-switch-ac") |> render_click()
    refute_push_event(view, "maker:control", _payload)
    stations(view, [e3800(%{"battery" => 81})])
    assert has_element?(view, "#pecron-ac-state", "Pecron turns it off.")

    done = fn device, part, error ->
      render_hook(view, "maker:control_done", %{
        "maker" => "pecron",
        "device" => device,
        "part" => part,
        "error" => error
      })
    end

    done.("dev_1", "dc", nil)
    done.("dev_2", "ac", nil)
    done.("dev_1", "ac", "bad error")
    assert has_element?(view, "#pecron-ac-state", "Pecron turns it off.")

    # The end, then the poll gives the new state.
    done.("dev_1", "ac", nil)
    stations(view, [e3800(%{"ac" => "off"})])
    assert has_element?(view, "#pecron-ac-state", "It is off.")
    assert has_element?(view, "#pecron-switch-ac[aria-checked=false]")

    # Pecron refuses: the error stays until a new state of the part.
    render_click(view, "maker_switch", %{"item" => id, "part" => "dc", "on" => "true"})
    assert_push_event(view, "maker:control", %{part: "dc", on: true})
    assert has_element?(view, "#pecron-dc-state", "Pecron turns it on.")
    done.("dev_1", "dc", "failed")
    assert has_element?(view, "#pecron-dc-state", "Pecron did not do it. Try again. It is off.")
    stations(view, [e3800(%{"ac" => "off", "battery" => 81})])
    assert has_element?(view, "#pecron-dc-state", "Pecron did not do it.")
    stations(view, [e3800(%{"ac" => "off", "dc" => "on"})])
    assert has_element?(view, "#pecron-dc-state", "It is on.")
    refute has_element?(view, "#pecron-dc-state", "Try again")

    # A tap with no unit, a part that is not a switch, or a value that is
    # not true or false: nothing.
    render_click(view, "maker_switch", %{"item" => "x", "part" => "ac", "on" => "true"})
    render_click(view, "maker_switch", %{"item" => id, "part" => "battery", "on" => "true"})
    render_click(view, "maker_switch", %{"item" => id, "part" => "ac", "on" => "yes"})
    refute_push_event(view, "maker:control", _payload)

    # A control that waits stays when a poll fails: its end comes from the
    # hook, with its error. With the link not connected, a switch does not
    # work, and the panel keeps the last numbers.
    render_click(view, "maker_switch", %{"item" => id, "part" => "ac", "on" => "true"})
    assert_push_event(view, "maker:control", %{part: "ac"})
    status(view, "offline", "offline")

    assert %{{"pecron", "dev_1", "ac"} => {:pending, true}} =
             :sys.get_state(view.pid).socket.assigns.maker_control

    render_hook(view, "maker:control_done", %{
      "maker" => "pecron",
      "device" => "dev_1",
      "part" => "ac",
      "error" => "offline"
    })

    assert has_element?(view, "#maker-notes #maker-offline", "The app cannot reach Pecron now.")
    assert has_element?(view, "#maker-offline", "These are its last numbers.")
    refute has_element?(view, "#maker-closed")
    assert has_element?(view, "#pecron-switch-ac[aria-disabled=true]")
    assert has_element?(view, "#pecron-ac-state", "The app has no link to Pecron now.")
    render_click(view, "maker_switch", %{"item" => id, "part" => "dc", "on" => "false"})
    refute_push_event(view, "maker:control", _payload)
    assert has_element?(view, "#pecron-battery", "82%")

    # A disconnect ends the controls that wait.
    status(view, "connected")
    render_click(view, "maker_switch", %{"item" => id, "part" => "dc", "on" => "false"})
    assert_push_event(view, "maker:control", %{part: "dc"})
    status(view, "none")
    assert :sys.get_state(view.pid).socket.assigns.maker_control == %{}
    assert has_element?(view, "#maker-closed", "The app has no link to Pecron now.")
  end

  test "a part that the station does not have has no switch, also while the page waits for a list",
       %{conn: conn} do
    {view, id} = station_page(conn)
    status(view, "connected")
    stations(view, [e3800(%{"dc" => nil})])
    view |> element("#maker-choice-0") |> render_click()
    assert has_element?(view, "#pecron-switch-ac[aria-disabled=false]")
    refute has_element?(view, "#pecron-switch-dc")
    assert has_element?(view, "span#pecron-dc-label", "DC outlets")

    # A new token, an error and a disconnect: the switches of the last
    # list stay. The DC outlets get no switch, and the AC switch stays.
    for {state, list} <- [
          {"connecting", nil},
          {"offline", nil},
          {"connected", [e3800(%{"dc" => nil})]},
          {"none", nil}
        ] do
      stations(view, list)
      status(view, state)
      assert has_element?(view, "#pecron-switch-ac")
      refute has_element?(view, "#pecron-switch-dc")
      assert has_element?(view, "#pecron-dc-state", "Pecron has no switch for it.")
    end

    assert has_element?(view, "#pecron-ac-state", "The app has no link to Pecron now.")

    # A new page: before the first list, the station has no switches. The
    # page does not know them. They come with the list.
    view = open(conn, ~p"/inside?#{[item: id]}", build_of(view))
    status(view, "connecting")
    assert has_element?(view, "#maker-connecting")
    refute has_element?(view, "#pecron-ac")
    refute has_element?(view, "#pecron-dc")
    status(view, "connected")
    stations(view, [e3800(%{"dc" => nil})])
    assert has_element?(view, "#pecron-switch-ac[aria-checked=true]")
    assert has_element?(view, "#pecron-dc-state", "Pecron has no switch for it.")
  end

  test "a station that the account does not have now, and a link that closes", %{conn: conn} do
    {view, id} = station_page(conn)
    status(view, "connected")
    stations(view, [e3800()])
    view |> element("#maker-choice-0") |> render_click()

    stations(view, [@cabin])

    assert has_element?(
             view,
             "#maker-gone",
             "Your account of Pecron does not have this station now."
           )

    refute has_element?(view, "#pecron-switch-ac")
    assert has_element?(view, "#maker-unlink")

    # The page waits for the stations of a new token. The last list did
    # not have the station, so the page does not know its switches.
    stations(view, nil)

    assert has_element?(
             view,
             "#pecron-station-wait",
             "The app waits for the numbers of the station."
           )

    refute has_element?(view, "#pecron-ac-state")

    # A disconnect: the panel tells it, and the link of the build stays.
    status(view, "none")
    assert has_element?(view, "#maker-closed")
    assert build_of(view).units == %{id => "pecron:dev_1"}
  end

  test "a payload that the page cannot read changes nothing", %{conn: conn} do
    {view, _id} = station_page(conn)
    status(view, "connected")
    stations(view, [e3800()])
    view |> element("#maker-choice-0") |> render_click()
    before = :sys.get_state(view.pid).socket.assigns.makers

    for bad <- [
          [e3800(), e3800(%{"id" => "a/b"})],
          List.duplicate(e3800(), 101),
          "stations"
        ] do
      stations(view, bad)
      assert :sys.get_state(view.pid).socket.assigns.makers == before
    end

    # A number that the page cannot read is not known. The other numbers
    # stay.
    for {part, value} <- [
          {"battery", 101},
          {"battery", "82"},
          {"output", 1_000_001},
          {"input", -5}
        ] do
      stations(view, [e3800(%{part => value})])
      assert has_element?(view, "#pecron-#{part}", "Not known")
      assert has_element?(view, "#pecron-ac-state", "It is on.")
    end

    stations(view, [e3800(%{"battery" => 100, "output" => 1_000_000})])
    assert has_element?(view, "#pecron-battery", "100%")
    assert has_element?(view, "#pecron-output", "1,000,000 W")
    stations(view, [e3800()])

    render_hook(view, "maker:stations", %{"maker" => "other", "stations" => []})
    render_hook(view, "maker:stations", %{"stations" => []})
    render_hook(view, "maker:status", %{"maker" => "pecron", "state" => "lost"})
    render_hook(view, "maker:status", %{"maker" => "other", "state" => "none"})
    render_hook(view, "maker:control_done", %{"maker" => "other"})
    render_hook(view, "maker:control_done", %{})
    assert :sys.get_state(view.pid).socket.assigns.makers == before

    # A station with an id that is not an id, or that is not a station.
    # Texts that are too long, and a switch with a state that the page does
    # not know, are nil.
    assert MakerLink.read_stations([e3800(), e3800(%{"id" => "a/b"})]) == :error
    assert MakerLink.read_stations([e3800(), "station"]) == :error

    [station] =
      MakerLink.read_stations([
        e3800(%{"name" => String.duplicate("x", 201), "model" => 5, "ac" => "maybe"})
      ])

    assert %{"name" => nil, "model" => nil, "ac" => nil, "dc" => "off"} = station
    assert MakerLink.status(%{state: "loading"}, "pecron") == nil
    assert MakerLink.message("storage", "pecron") =~ "cannot keep the token"
    assert MakerLink.message("token", "pecron") == "Pecron does not accept the token."
    assert MakerLink.message("timeout", "pecron") =~ "20 seconds"
    assert MakerLink.message("offline", "pecron") =~ "Look at the network"

    # A page with no links has no choices.
    assert DIYWeb.Inside.unit_choices(%{makers: %{}}, "x") == []
  end

  test "the states of the link in the panel and in the card, and the controls that the page refuses",
       %{conn: conn} do
    {view, _id} = station_page(conn)

    # While the link loads or connects: no choice, and no text of a link
    # that is not there.
    status(view, "connecting")
    stations(view, [e3800()])
    refute has_element?(view, "#maker-choices")
    status(view, "connected")
    view |> element("#maker-choice-0") |> render_click()
    status(view, "connecting")
    assert has_element?(view, "#maker-notes #maker-connecting", "The app connects to Pecron.")
    refute has_element?(view, "#maker-closed")

    # The page does not say "gone" while the link is not connected.
    status(view, "offline", "unreachable")
    stations(view, [@cabin])
    refute has_element?(view, "#maker-gone")
    assert has_element?(view, "#maker-offline", "The app cannot reach Pecron now.")
    refute has_element?(view, "#maker-offline", "last numbers")
    status(view, "connected")
    assert has_element?(view, "#maker-gone")

    # An error that the page does not know is no error.
    status(view, "offline", "<b>other</b>")
    assert :sys.get_state(view.pid).socket.assigns.makers["pecron"].error == nil

    # The end of a control that does not wait changes nothing.
    status(view, "connected")
    stations(view, [e3800()])

    render_hook(view, "maker:control_done", %{
      "maker" => "pecron",
      "device" => "dev_1",
      "part" => "ac",
      "error" => "failed"
    })

    assert :sys.get_state(view.pid).socket.assigns.maker_control == %{}

    # A control that Pecron refuses for the token: its own text.
    view |> element("#pecron-switch-ac") |> render_click()

    render_hook(view, "maker:control_done", %{
      "maker" => "pecron",
      "device" => "dev_1",
      "part" => "ac",
      "error" => "denied"
    })

    assert has_element?(
             view,
             "#pecron-ac-state",
             "Pecron does not let this token turn the outlets on or off."
           )
  end

  test "a model that the person chose stays when the station links", %{conn: conn} do
    {view, id} = station_page(conn)
    render_change(view, "item", %{"item_id" => id, "item" => %{"model" => "anker_solix_f3800"}})
    status(view, "connected")
    stations(view, [e3800()])
    view |> element("#maker-choice-0") |> render_click()
    {:ok, station} = Build.item(build_of(view), id)
    assert station.params["model"] == "anker_solix_f3800"
  end

  test "an item of a device of Home Assistant has no choice of a maker", %{conn: conn} do
    build = preset()
    garage = Enum.find(build.rooms, &(&1.name == "Garage")).id
    {:ok, build, id} = Build.add_device(build, garage, "power_station", "ha_1")
    view = open(conn, ~p"/inside?#{[item: id]}", build)
    status(view, "connected")
    stations(view, [e3800()])
    refute has_element?(view, "#maker-choices")
    refute has_element?(view, "#part-maker")
  end

  test "the card tells the access of the token, and a refused token one time", %{conn: conn} do
    view = open(conn, ~p"/settings", preset())
    status(view, "none")
    assert has_element?(view, "#pecron-card", "The token has the same access as your account")
    assert has_element?(view, "#pecron-card", "Allow HA to send control commands")
    status(view, "refused", "token")
    assert has_element?(view, "#pecron-status", "Pecron does not accept the token.")
    refute has_element?(view, "#pecron-error")
    status(view, "refused", "format")
    assert has_element?(view, "#pecron-error", "starts with phk_")
  end

  test "a station in a van links too", %{conn: conn} do
    build = preset()
    driveway = Enum.find(build.rooms, &(&1.name == "Driveway")).id
    {:ok, build, van} = Build.add_item(build, driveway, "camper_van")
    places = DIY.Catalog.kind("power_station").places
    zone = build |> Build.zones(van) |> Enum.find(&(&1.place in places))
    {:ok, build, id} = Build.add_item(build, zone.id, "power_station")
    view = open(conn, ~p"/van?#{[id: van, item: id]}", build)
    status(view, "connected")
    stations(view, [e3800()])
    view |> element("#maker-choice-0") |> render_click()
    assert build_of(view).units == %{id => "pecron:dev_1"}
    assert has_element?(view, "#pecron-battery", "82%")
  end

  property "the page keeps the stations that it can read, and nothing else" do
    number =
      one_of([
        constant(nil),
        integer(-10..110),
        integer(999_990..1_000_010),
        float(min: -10.0, max: 1.1e6),
        constant("9")
      ])

    switch = member_of([nil, "on", "off", "unknown", true])

    check all(
            battery <- number,
            output <- number,
            ac <- switch,
            id <- member_of(["dev_1", "a b", ""])
          ) do
      sent = e3800(%{"id" => id, "battery" => battery, "output" => output, "ac" => ac})
      result = MakerLink.read_stations([sent])

      good_number = fn
        nil, _max -> true
        value, max when is_number(value) -> value >= 0 and value <= max
        _value, _max -> false
      end

      read = fn value, max -> if is_number(value) and good_number.(value, max), do: value end

      if id == "dev_1" do
        assert [station] = result
        assert station["battery"] == read.(battery, 100)
        assert station["output"] == read.(output, 1_000_000)
        assert station["ac"] == if(ac in ["on", "off"], do: ac)
      else
        assert result == :error
      end
    end
  end
end
