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
  # model that the app does not know. Also a DELTA Pro 3 of EcoFlow, and a
  # plug.
  @devices [
    %{
      "id" => "s1",
      "name" => "Garage battery",
      "area" => "garage",
      "domains" => ["sensor", "switch"],
      "station" => "pecron",
      "model" => "E3800LFP"
    },
    %{
      "id" => "s2",
      "name" => "Old station",
      "area" => "garage",
      "domains" => ["sensor", "switch"],
      "station" => "pecron",
      "model" => "E1500LFP"
    },
    %{
      "id" => "e1",
      "name" => "Backup",
      "area" => "garage",
      "domains" => ["sensor", "switch"],
      "station" => "ecoflow",
      "model" => "DELTA_PRO_3"
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
      %{"battery" => 64, "input" => 0, "output" => 1250.5, "ac" => "on", "dc" => "off"},
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

    # Before the hook tells the numbers: the panel waits.
    assert has_element?(view, "#ha-station-wait", "The app waits for the numbers of the station.")
    refute has_element?(view, "#ha-station")
    assert has_element?(view, "#ha-ac-label", "AC outlets")
    assert has_element?(view, "#ha-dc-label", "DC outlets")

    assert has_element?(
             view,
             "#ha-switch-ac[role=switch][aria-disabled=true][aria-checked=false]"
           )

    assert has_element?(view, "#ha-ac-state[role=status]", "The app waits for its state.")

    # The numbers and the states. The numbers are not a live region.
    stations(view, %{"s1" => parts(), "s9" => parts()})
    refute has_element?(view, "#ha-station-wait")
    assert has_element?(view, "#ha-battery", "64%")
    assert has_element?(view, "#ha-input", "0 W")
    assert has_element?(view, "#ha-output", "1,251 W")
    refute has_element?(view, "#ha-station[role]")
    assert has_element?(view, "#ha-switch-ac[aria-checked=true][aria-disabled=false]")
    assert has_element?(view, "#ha-switch-ac[phx-value-on=false][phx-value-part=ac]")
    assert has_element?(view, "#ha-ac-state", "It is on.")
    assert has_element?(view, "#ha-switch-dc[aria-checked=false][phx-value-on=true]")
    assert has_element?(view, "#ha-dc-state", "It is off.")

    # A number that Home Assistant does not give, a switch that it cannot
    # reach, and a switch that the station does not have.
    stations(view, %{
      "s1" => parts(%{"battery" => 99.6, "output" => nil, "ac" => "unavailable", "dc" => nil})
    })

    assert has_element?(view, "#ha-battery", "100%")
    assert has_element?(view, "#ha-output", "Not known")
    assert has_element?(view, "#ha-ac-state", "Home Assistant cannot reach it now.")
    assert has_element?(view, "#ha-dc-state", "Home Assistant has no switch for it.")
    assert has_element?(view, "#ha-switch-dc[aria-disabled=true]")

    stations(view, %{
      "s1" => parts(%{"battery" => nil, "output" => nil, "ac" => "unavailable", "dc" => nil})
    })

    assert has_element?(view, "#ha-battery", "Not known")

    # A tap on a switch with no state changes nothing.
    view |> element("#ha-switch-dc") |> render_click()
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

    # The new state, then the end.
    stations(view, %{"s1" => parts(%{"ac" => "off"})})
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

  test "a payload of the stations that the page cannot read changes nothing", %{conn: conn} do
    {view, _item} = page(conn)
    stations(view, %{"s1" => parts()})
    long = String.duplicate("x", 256)

    for bad <- [
          %{"s1" => parts(%{"battery" => 101})},
          %{"s1" => parts(%{"battery" => -1})},
          %{"s1" => parts(%{"battery" => "64"})},
          %{"s1" => parts(%{"input" => 2_000_000})},
          %{"s1" => parts(%{"output" => "many"})},
          %{"s1" => parts(%{"ac" => "maybe"})},
          %{"s1" => parts(%{"dc" => true})},
          %{"s1" => "parts"},
          %{long => parts()},
          Map.new(1..1001, &{"s#{&1}", parts()})
        ] do
      stations(view, bad)
      assert has_element?(view, "#ha-battery", "64%")
      assert has_element?(view, "#ha-ac-state", "It is on.")
    end

    render_hook(view, "ha:stations", %{"stations" => "none"})
    render_hook(view, "ha:stations", %{})
    assert has_element?(view, "#ha-battery", "64%")
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

    stations(view, %{"e1" => parts(%{"battery" => 90, "dc" => nil})})
    assert has_element?(view, "#ha-battery", "90%")
    assert has_element?(view, "#ha-ac-state", "It is on.")
    assert has_element?(view, "#ha-dc-state", "Home Assistant has no switch for it.")

    view |> element("#ha-switch-ac") |> render_click()
    assert_push_event(view, "ha:control", %{device: "e1", on: false, part: "ac"})
  end

  test "the panel of a station with a device that is not a station, and with no devices" do
    station = %{
      ha: %{state: "connected"},
      build: %{devices: %{"i1" => "p1", "i2" => "s1"}},
      ha_devices: %{
        devices: [
          %{id: "p1", domains: ["switch"], station: nil},
          %{id: "s1", domains: ["switch"], station: "ecoflow"}
        ]
      },
      ha_stations: %{},
      ha_control: %{}
    }

    assert HomeAssistant.station(station, "i1") == nil
    assert HomeAssistant.station(station, "i9") == nil
    assert HomeAssistant.station(%{station | ha_devices: nil}, "i2") == nil
    assert %{device: "s1", known: false, battery: nil} = HomeAssistant.station(station, "i2")

    # A station has no switch of the whole device. A plug has one.
    refute HomeAssistant.controls?(%{domains: ["switch"], station: "pecron"})
    assert HomeAssistant.controls?(%{domains: ["switch"], station: nil})
  end

  property "the page keeps the parts that it can read, and nothing else" do
    number = one_of([constant(nil), integer(-10..1_100_000), float(min: -10.0, max: 1.0e6)])
    switch = member_of([nil, "on", "off", "unavailable", "unknown", 5])

    check all(
            battery <- number,
            input <- number,
            output <- number,
            ac <- switch,
            dc <- switch
          ) do
      sent = %{"battery" => battery, "input" => input, "output" => output, "ac" => ac, "dc" => dc}

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          ha: %{state: "connected"},
          ha_stations: %{},
          ha_control: %{}
        }
      }

      {:halt, socket} =
        HomeAssistant.handle_event("ha:stations", %{"stations" => %{"s1" => sent}}, socket)

      valid =
        (is_nil(battery) or battery in 0..100 or
           (is_float(battery) and battery >= 0 and battery <= 100)) and
          Enum.all?([input, output], &(is_nil(&1) or abs(&1) <= 1_000_000)) and
          Enum.all?([ac, dc], &(&1 in [nil, "on", "off", "unavailable"]))

      if valid do
        assert socket.assigns.ha_stations == %{
                 "s1" => %{
                   :battery => battery,
                   :input => input,
                   :output => output,
                   "ac" => ac,
                   "dc" => dc
                 }
               }
      else
        assert socket.assigns.ha_stations == %{}
      end
    end
  end
end
