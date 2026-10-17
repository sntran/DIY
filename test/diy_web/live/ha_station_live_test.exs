defmodule DIYWeb.HaStationLiveTest do
  @moduledoc "A power station of Pecron through Home Assistant: its numbers and its outlets."
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, Catalog, House, Stubs}
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

  defp status(view, state) do
    render_hook(view, "ha:status", %{
      "state" => state,
      "url" => "https://ha.example.com",
      "name" => "Home"
    })
  end

  @areas [%{"id" => "garage", "name" => "Garage", "floor" => nil}]

  # The devices: a station of Pecron with its model, and a station of a
  # model that the app does not know. Also a DELTA Pro 3 of EcoFlow, a
  # station with no switch of its DC outlets, and a plug.
  @devices [
    %{
      "id" => "s1",
      "name" => "Garage battery",
      "area" => "garage",
      "domains" => ["sensor", "switch"],
      "station" => "pecron",
      "switches" => ["ac", "dc"],
      "model" => "E3800LFP"
    },
    %{
      "id" => "s2",
      "name" => "Old station",
      "area" => "garage",
      "domains" => ["sensor", "switch"],
      "station" => "pecron",
      "switches" => ["ac", "dc"],
      "model" => "E1500LFP"
    },
    %{
      "id" => "e1",
      "name" => "Backup",
      "area" => "garage",
      "domains" => ["sensor", "switch"],
      "station" => "ecoflow",
      "switches" => ["ac", "dc"],
      "model" => "DELTA_PRO_3"
    },
    %{
      "id" => "s3",
      "name" => "Shed battery",
      "area" => "garage",
      "domains" => ["sensor", "switch"],
      "station" => "pecron",
      "switches" => ["ac"],
      "model" => "E3600LFP"
    },
    %{"id" => "p1", "name" => "Garage plug", "area" => "garage", "domains" => ["switch"]}
  ]

  defp build_of(view), do: :sys.get_state(view.pid).socket.assigns.build

  # The page Rooms with the station of a device in the garage, and its
  # panel open.
  defp page(conn, device \\ "s1") do
    build = build()
    {:ok, view, _html} = live(conn, ~p"/inside")
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    status(view, "connected")
    render_hook(view, "ha:devices", %{"devices" => @devices, "areas" => @areas})
    render_hook(view, "ha_add_device", %{"id" => device})
    item = Build.device_item(build_of(view), device)
    assert_patch(view, ~p"/inside?#{[item: item]}")
    {view, item}
  end

  defp stations(view, stations), do: render_hook(view, "ha:stations", %{"stations" => stations})

  defp parts(fields \\ %{}) do
    Map.merge(
      %{
        "battery" => 64,
        "input" => 0,
        "output" => 1250.5,
        "ac" => "on",
        "dc" => "off",
        "link" => true
      },
      fields
    )
  end

  test "a station of Pecron comes with its model, and its panel shows its numbers", %{conn: conn} do
    {view, item} = page(conn)

    # A ghost of Pecron is a station, and the item has the model of its
    # device: its numbers and its size.
    {:ok, station} = Build.item(build_of(view), item)
    assert station.type == "power_station"
    assert station.params["model"] == "pecron_e3800lfp"
    assert station.params["kwh"] == 3.84
    assert has_element?(view, "#item-stage-title", "Pecron E3800LFP")
    assert has_element?(view, "#ha-device", "This is Garage battery in Home Assistant.")

    # No switch of the whole device: a switch for each outlet.
    refute has_element?(view, "#ha-power")

    # Before the hook tells the numbers: the panel waits. The texts of the
    # station are in one element that stays, above the switches.
    assert has_element?(
             view,
             "#ha-station-info #ha-station-wait",
             "The app waits for the numbers of the station."
           )

    refute has_element?(view, "#ha-station")
    assert has_element?(view, "#ha-ac-label", "AC outlets")
    assert has_element?(view, "#ha-dc-label", "DC outlets")

    assert has_element?(
             view,
             "#ha-switch-ac[role=switch][aria-disabled=true][aria-checked=false]"
           )

    assert has_element?(view, "#ha-ac-state[role=status]", "The app waits for its state.")
    assert has_element?(view, "#ha-switch-ac[aria-describedby=ha-ac-state]")
    assert has_element?(view, "#ha-switch-dc[aria-describedby=ha-dc-state]")

    # The numbers and the states. The numbers are not a live region.
    stations(view, %{"s1" => parts(), "s9" => parts()})
    refute has_element?(view, "#ha-station-wait")
    assert has_element?(view, "#ha-station-info #ha-station dt", "Battery level")
    assert has_element?(view, "#ha-battery", "64%")
    assert has_element?(view, "#ha-input", "0 W")
    assert has_element?(view, "#ha-output", "1,251 W")
    refute has_element?(view, "#ha-station[role]")
    refute has_element?(view, "#ha-station[aria-live]")
    refute has_element?(view, "#ha-station [aria-live]")
    refute has_element?(view, "#ha-station-link")
    assert has_element?(view, "#ha-switch-ac[aria-checked=true][aria-disabled=false]")
    assert has_element?(view, "#ha-switch-ac[phx-value-on=false][phx-value-part=ac]")
    assert has_element?(view, "#ha-ac-state", "It is on.")
    assert has_element?(view, "#ha-switch-dc[aria-checked=false][phx-value-on=true]")
    assert has_element?(view, "#ha-dc-state", "It is off.")

    # A number that Home Assistant does not give, a switch that it cannot
    # reach, and a switch with a state that the page cannot read. The
    # station has the part, so the switch stays.
    stations(view, %{
      "s1" => parts(%{"battery" => 99.6, "output" => nil, "ac" => "unavailable", "dc" => nil})
    })

    assert has_element?(view, "#ha-battery", "100%")
    assert has_element?(view, "#ha-output", "Not known")
    assert has_element?(view, "#ha-ac-state", "Home Assistant cannot reach it now.")
    assert has_element?(view, "#ha-dc-state", "The app waits for its state.")
    assert has_element?(view, "#ha-switch-dc[aria-disabled=true]")

    stations(view, %{
      "s1" => parts(%{"battery" => nil, "output" => nil, "ac" => "unavailable", "dc" => nil})
    })

    assert has_element?(view, "#ha-battery", "Not known")

    # A tap on a switch with no state changes nothing.
    render_click(view, "ha_station_switch", %{"item" => item, "part" => "dc", "on" => "true"})
    view |> element("#ha-switch-ac") |> render_click()
    refute_push_event(view, "ha:control", _payload)
  end

  test "a switch turns the outlets of a station on and off, and tells the end", %{conn: conn} do
    {view, item} = page(conn)
    stations(view, %{"s1" => parts()})

    view |> element("#ha-switch-ac") |> render_click()
    assert_push_event(view, "ha:control", %{device: "s1", on: false, part: "ac"})
    assert has_element?(view, "#ha-switch-ac[aria-disabled=true]")
    assert has_element?(view, "#ha-ac-state", "Home Assistant turns it off.")

    # The other switch does not wait. A second tap on the first changes
    # nothing.
    assert has_element?(view, "#ha-switch-dc[aria-disabled=false]")
    view |> element("#ha-switch-ac") |> render_click()
    refute_push_event(view, "ha:control", _payload)

    # The end of a control of the whole device, or of the other part, does
    # not end it.
    render_hook(view, "ha:control_done", %{"device" => "s1", "part" => nil, "error" => nil})
    render_hook(view, "ha:control_done", %{"device" => "s1", "part" => "dc", "error" => nil})
    assert has_element?(view, "#ha-ac-state", "Home Assistant turns it off.")

    # The new state, then the end. The new state does not end the
    # control: the switch waits for the end.
    stations(view, %{"s1" => parts(%{"ac" => "off"})})
    assert has_element?(view, "#ha-switch-ac[aria-disabled=true]")
    assert has_element?(view, "#ha-ac-state", "Home Assistant turns it off.")
    render_hook(view, "ha:control_done", %{"device" => "s1", "part" => "ac", "error" => nil})
    assert has_element?(view, "#ha-switch-ac[aria-checked=false][aria-disabled=false]")
    assert has_element?(view, "#ha-ac-state", "It is off.")

    # Home Assistant refuses: the error stays until a new state of the part.
    render_click(view, "ha_station_switch", %{"item" => item, "part" => "dc", "on" => "true"})
    assert_push_event(view, "ha:control", %{device: "s1", on: true, part: "dc"})
    assert has_element?(view, "#ha-dc-state", "Home Assistant turns it on.")
    render_hook(view, "ha:control_done", %{"device" => "s1", "part" => "dc", "error" => "failed"})

    assert has_element?(
             view,
             "#ha-dc-state",
             "Home Assistant did not do it. Try again. It is off."
           )

    # A new number or a new state of the other part keeps the error.
    stations(view, %{"s1" => parts(%{"ac" => "on", "battery" => 50})})
    assert has_element?(view, "#ha-dc-state", "Home Assistant did not do it.")
    stations(view, %{"s1" => parts(%{"ac" => "on", "battery" => 50, "dc" => "on"})})
    assert has_element?(view, "#ha-dc-state", "It is on.")
    refute has_element?(view, "#ha-dc-state", "Try again")

    # A tap with no item, with a part that is not a switch, or with a value
    # that is not true or false: nothing.
    render_click(view, "ha_station_switch", %{"item" => "x", "part" => "ac", "on" => "true"})

    render_click(view, "ha_station_switch", %{"item" => item, "part" => "battery", "on" => "true"})

    render_click(view, "ha_station_switch", %{"item" => item, "part" => "ac", "on" => "yes"})
    refute_push_event(view, "ha:control", _payload)
  end

  test "the parts of the stations are only for a connected link", %{conn: conn} do
    {view, item} = page(conn)
    stations(view, %{"s1" => parts()})
    render_click(view, "ha_station_switch", %{"item" => item, "part" => "ac", "on" => "false"})

    # The link closes: the page forgets the numbers and the controls. The
    # switches stay, so that they keep the focus.
    status(view, "offline")
    refute has_element?(view, "#ha-station")
    refute has_element?(view, "#ha-station-wait")
    assert has_element?(view, "#ha-switch-ac[aria-disabled=true]")
    assert has_element?(view, "#ha-ac-state", "The app has no link to Home Assistant now.")

    # A late message changes nothing.
    stations(view, %{"s1" => parts()})
    refute has_element?(view, "#ha-station")
    render_hook(view, "ha:control_done", %{"device" => "s1", "part" => "ac", "error" => nil})
    assert %{ha_stations: %{}, ha_control: %{}} = :sys.get_state(view.pid).socket.assigns

    # The link comes back.
    status(view, "connected")
    stations(view, %{"s1" => parts()})
    assert has_element?(view, "#ha-battery", "64%")
  end

  test "the panel tells the link of the station, and with no link the switches do not work",
       %{conn: conn} do
    {view, item} = page(conn)

    # Home Assistant does not tell the link (pecron-monitor).
    stations(view, %{"s1" => Map.delete(parts(), "link")})

    assert has_element?(
             view,
             "#ha-station-link",
             "Home Assistant does not tell if it has a link to the station now. A number can be old."
           )

    assert has_element?(view, "#ha-switch-ac[aria-disabled=false]")

    # No link: the last numbers, and the last states of the switches.
    stations(view, %{"s1" => parts(%{"link" => false})})

    assert has_element?(
             view,
             "#ha-station-link",
             "Home Assistant has no link to the station now. These are its last numbers."
           )

    assert has_element?(view, "#ha-battery", "64%")
    assert has_element?(view, "#ha-switch-ac[aria-checked=true][aria-disabled=true]")

    assert has_element?(
             view,
             "#ha-ac-state",
             "Home Assistant has no link to the station now. The last state was on."
           )

    assert has_element?(view, "#ha-dc-state", "The last state was off.")
    view |> element("#ha-switch-ac") |> render_click()
    render_click(view, "ha_station_switch", %{"item" => item, "part" => "dc", "on" => "true"})
    refute_push_event(view, "ha:control", _payload)

    # No link and no numbers: EcoFlow BLE with no Bluetooth link.
    stations(view, %{
      "s1" =>
        parts(%{
          "link" => false,
          "battery" => nil,
          "input" => nil,
          "output" => nil,
          "ac" => "unavailable",
          "dc" => "unavailable"
        })
    })

    assert has_element?(
             view,
             "#ha-station-link",
             "Home Assistant has no link to the station now."
           )

    refute has_element?(view, "#ha-station-link", "last numbers")
    assert has_element?(view, "#ha-ac-state", "Home Assistant has no link to the station now.")
    refute has_element?(view, "#ha-ac-state", "last state")

    # The link comes back.
    stations(view, %{"s1" => parts()})
    refute has_element?(view, "#ha-station-link")
    view |> element("#ha-switch-ac") |> render_click()
    assert_push_event(view, "ha:control", %{device: "s1", on: false, part: "ac"})
  end

  test "a part that the page cannot read is not known, and the other parts and stations stay",
       %{conn: conn} do
    {view, _item} = page(conn)
    stations(view, %{"s1" => parts(), "e1" => parts()})
    ha_stations = fn -> :sys.get_state(view.pid).socket.assigns.ha_stations end

    # One number out of range of one station, and a new state of the other
    # station.
    stations(view, %{"s1" => parts(%{"battery" => 101}), "e1" => parts(%{"ac" => "off"})})
    assert has_element?(view, "#ha-battery", "Not known")
    assert has_element?(view, "#ha-output", "1,251 W")
    assert has_element?(view, "#ha-ac-state", "It is on.")
    assert ha_stations.()["e1"]["ac"] == "off"

    # The page keeps a number with an atom key, and a switch with its part.
    for {part, key, value} <- [
          {"battery", :battery, -1},
          {"battery", :battery, "64"},
          {"input", :input, 1_000_001},
          {"input", :input, -5},
          {"output", :output, "many"},
          {"ac", "ac", "maybe"},
          {"dc", "dc", true},
          {"link", :link, "yes"}
        ] do
      stations(view, %{"s1" => parts(%{part => value}), "e1" => parts(%{"battery" => 12})})
      read = ha_stations.()
      assert Map.fetch!(read["s1"], key) == nil

      assert read["s1"]["ac"] == if(part == "ac", do: nil, else: "on")
      assert read["e1"].battery == 12
    end

    # The highest numbers.
    stations(view, %{"s1" => parts(%{"battery" => 100, "input" => 1_000_000})})
    assert has_element?(view, "#ha-battery", "100%")
    assert has_element?(view, "#ha-input", "1,000,000 W")

    # A station with an id or parts that the page cannot read does not
    # count.
    long = String.duplicate("x", 256)
    stations(view, %{"s1" => parts(), long => parts(), "e1" => "parts"})
    assert Map.keys(ha_stations.()) == ["s1"]

    # A payload with too many stations changes nothing. 1,000 stations is
    # the limit.
    stations(view, Map.new(1..1001, &{"s#{&1}", parts(%{"battery" => 10})}))
    assert has_element?(view, "#ha-battery", "64%")
    stations(view, Map.new(1..1000, &{"s#{&1}", parts(%{"battery" => 10})}))
    assert has_element?(view, "#ha-battery", "10%")

    render_hook(view, "ha:stations", %{"stations" => "none"})
    render_hook(view, "ha:stations", %{})
    assert has_element?(view, "#ha-battery", "10%")
  end

  test "a part that the station does not have has no switch, also with no link to Home Assistant",
       %{conn: conn} do
    {view, item} = page(conn, "s3")

    # Before the numbers: a switch of the AC outlets only. The DC outlets
    # have their name and their status.
    assert has_element?(view, "#ha-switch-ac")
    refute has_element?(view, "#ha-switch-dc")
    assert has_element?(view, "span#ha-dc-label", "DC outlets")
    assert has_element?(view, "#ha-dc-state", "The app has no switch for it.")

    # A state of the DC outlets from the hook does not add a switch.
    stations(view, %{"s3" => parts()})
    assert has_element?(view, "#ha-switch-ac[aria-disabled=false]")
    refute has_element?(view, "#ha-switch-dc")
    render_click(view, "ha_station_switch", %{"item" => item, "part" => "dc", "on" => "true"})
    refute_push_event(view, "ha:control", _payload)

    # The link to Home Assistant closes and comes back. The page keeps the
    # devices, so the DC outlets get no switch, and the AC switch stays.
    for state <- ~w(offline connecting connected) do
      status(view, state)
      assert has_element?(view, "#ha-switch-ac")
      refute has_element?(view, "#ha-switch-dc")
      assert has_element?(view, "#ha-dc-state", "The app has no switch for it.")
    end

    assert has_element?(view, "#ha-ac-state", "The app waits for its state.")
  end

  test "the item of a station has no switch of the whole device, also when its device is not a station now",
       %{conn: conn} do
    {view, item} = page(conn)
    stations(view, %{"s1" => parts()})

    # The person disables the battery of the station in Home Assistant.
    # The device is not a station now, but it has switches.
    devices =
      for device <- @devices do
        if device["id"] == "s1",
          do: Map.merge(device, %{"station" => nil, "switches" => []}),
          else: device
      end

    refute has_element?(view, "#ha-not-station")
    render_hook(view, "ha:devices", %{"devices" => devices, "areas" => @areas})
    render_hook(view, "ha:states", %{"states" => %{"s1" => "on"}})
    refute has_element?(view, "#ha-switch")
    refute has_element?(view, "#ha-switch-ac")
    render_click(view, "ha_switch", %{"item" => item, "on" => "false"})
    refute_push_event(view, "ha:control", _payload)
    assigns = :sys.get_state(view.pid).socket.assigns
    assert HomeAssistant.power(assigns, item) == nil

    # The plan shows no state of the device: it is "on" when one of its
    # modes is on. The panel tells why the numbers and the switches went.
    assert HomeAssistant.item_states(assigns) == %{}
    assert has_element?(view, "#plan-item-#{item}")
    refute has_element?(view, ~s(#plan-item-#{item}[data-ha]))

    assert has_element?(
             view,
             "#ha-not-station",
             "Home Assistant does not give the battery and the power out of this station now."
           )
  end

  test "the page reads the switches that a station has, and no other part", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/inside")
    status(view, "connected")

    device = fn id, station, switches ->
      %{
        "id" => id,
        "name" => id,
        "area" => "garage",
        "domains" => ["switch"],
        "station" => station,
        "switches" => switches
      }
    end

    devices = [
      device.("a", "pecron", ["dc", "eco", 5, "ac", "dc"]),
      device.("b", "ecoflow", "ac"),
      device.("c", nil, ["ac"]),
      Map.delete(device.("d", "pecron", nil), "switches")
    ]

    render_hook(view, "ha:devices", %{"devices" => devices, "areas" => @areas})
    %{devices: read} = :sys.get_state(view.pid).socket.assigns.ha_devices

    assert Enum.map(read, &{&1.id, &1.switches}) == [
             {"a", ["ac", "dc"]},
             {"b", []},
             {"c", []},
             {"d", []}
           ]
  end

  test "a station of a model that the app does not know is another station", %{conn: conn} do
    {view, item} = page(conn, "s2")
    {:ok, station} = Build.item(build_of(view), item)
    assert station.params["model"] == "other"
    assert station.params["kwh"] == Catalog.defaults("power_station")["kwh"]
    assert has_element?(view, "#ha-switch-ac")
  end

  test "a DELTA Pro 3 of EcoFlow comes with its model, its numbers and its outlets", %{conn: conn} do
    {view, item} = page(conn, "e1")
    {:ok, station} = Build.item(build_of(view), item)
    assert station.params["model"] == "ecoflow_delta_pro_3"
    assert station.params["kwh"] == 4.096
    assert has_element?(view, "#item-stage-title", "EcoFlow DELTA Pro 3")

    # The DC part of EcoFlow is its 12 V outlets only.
    assert has_element?(view, "#ha-ac-label", "AC outlets")
    assert has_element?(view, "#ha-dc-label", "12 V outlets")

    stations(view, %{"e1" => parts(%{"battery" => 90})})
    assert has_element?(view, "#ha-battery", "90%")
    assert has_element?(view, "#ha-ac-state", "It is on.")
    assert has_element?(view, "#ha-dc-state", "It is off.")

    view |> element("#ha-switch-ac") |> render_click()
    assert_push_event(view, "ha:control", %{device: "e1", on: false, part: "ac"})
  end

  test "the panel of a station with a device that is not a station, and with no devices" do
    station = %{
      ha: %{state: "connected"},
      build: %{devices: %{"i1" => "p1", "i2" => "s1"}},
      ha_devices: %{
        devices: [
          %{id: "p1", domains: ["switch"], station: nil, switches: []},
          %{id: "s1", domains: ["switch"], station: "ecoflow", switches: ["ac"]}
        ]
      },
      ha_stations: %{},
      ha_control: %{}
    }

    assert HomeAssistant.station(station, "i1") == nil
    assert HomeAssistant.station(station, "i9") == nil
    assert HomeAssistant.station(%{station | ha_devices: nil}, "i2") == nil

    assert %{device: "s1", known: false, battery: nil, link: nil, switches: switches} =
             HomeAssistant.station(station, "i2")

    # The state of a switch is nil before the hook tells it. A part that
    # the station does not have is "none", also with no numbers.
    assert Enum.map(switches, &{&1.part, &1.name, &1.state}) == [
             {"ac", "AC outlets", nil},
             {"dc", "12 V outlets", "none"}
           ]

    # A station has no switch of the whole device. A plug has one.
    refute HomeAssistant.controls?(%{domains: ["switch"], station: "pecron"})
    assert HomeAssistant.controls?(%{domains: ["switch"], station: nil})
  end

  property "the page keeps each part that it can read, and no other part" do
    number =
      one_of([
        constant(nil),
        integer(-10..110),
        integer(999_990..1_000_010),
        float(min: -10.0, max: 1.1e6),
        member_of([0, 100, 100.5, 1_000_000, 1_000_001, -0.5, "64", true])
      ])

    switch = member_of([nil, "on", "off", "unavailable", "unknown", 5])
    link = member_of([nil, true, false, "on", 1])

    check all(
            battery <- number,
            input <- number,
            output <- number,
            ac <- switch,
            dc <- switch,
            link <- link,
            other <- member_of([nil, "parts", %{"battery" => 5}])
          ) do
      sent = %{
        "battery" => battery,
        "input" => input,
        "output" => output,
        "ac" => ac,
        "dc" => dc,
        "link" => link
      }

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          ha: %{state: "connected"},
          ha_stations: %{},
          ha_control: %{}
        }
      }

      payload = if other, do: %{"s1" => sent, "s2" => other}, else: %{"s1" => sent}

      {:halt, socket} =
        HomeAssistant.handle_event("ha:stations", %{"stations" => payload}, socket)

      power = &if(is_number(&1) and &1 >= 0 and &1 <= 1_000_000, do: &1)
      state = &if(&1 in ["on", "off", "unavailable"], do: &1)

      assert socket.assigns.ha_stations["s1"] == %{
               :battery =>
                 if(is_number(battery) and battery >= 0 and battery <= 100, do: battery),
               :input => power.(input),
               :output => power.(output),
               :link => if(is_boolean(link), do: link),
               "ac" => state.(ac),
               "dc" => state.(dc)
             }

      # A station with parts that are not a map does not count.
      assert Map.has_key?(socket.assigns.ha_stations, "s2") == is_map(other)
    end
  end
end
