defmodule DIYWeb.GhostLiveTest do
  use DIYWeb.ConnCase, async: true

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

  defp page(conn, path, build \\ build()) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    view
  end

  defp connected(view) do
    render_hook(view, "ha:status", %{
      "state" => "connected",
      "url" => "https://ha.example.com",
      "name" => "Home"
    })
  end

  defp device(id, name, area, domains),
    do: %{"id" => id, "name" => name, "area" => area, "domains" => domains, "model" => nil}

  @areas [
    %{"id" => "kitchen", "name" => "Kitchen", "floor" => nil},
    %{"id" => "living", "name" => "Living Room", "floor" => nil},
    %{"id" => "porch", "name" => "Porch", "floor" => nil}
  ]

  @devices [
    %{"id" => "d1", "name" => "Kitchen Lights", "area" => "kitchen", "domains" => ["light"]},
    %{
      "id" => "d2",
      "name" => "Living Room TV",
      "area" => "living",
      "domains" => ["media_player"]
    },
    %{"id" => "d3", "name" => "Porch light", "area" => "porch", "domains" => ["light"]},
    %{"id" => "d4", "name" => "Thermostat", "area" => "living", "domains" => ["climate"]}
  ]

  defp devices(view, devices \\ @devices, areas \\ @areas),
    do: render_hook(view, "ha:devices", %{"devices" => devices, "areas" => areas})

  defp build_of(view), do: :sys.get_state(view.pid).socket.assigns.build

  test "the page reads the devices when the link is connected, and forgets them after", %{
    conn: conn
  } do
    view = page(conn, ~p"/inside")
    connected(view)
    assert_push_event(view, "ha:devices_fetch", %{})
    # The status is on the page before its text: a screen reader reads the
    # text when it comes.
    assert has_element?(view, "#ha-ghosts[role=status]")
    refute has_element?(view, "#ha-ghosts p")

    devices(view)

    # A ghost for each device with a kind in the area of a room: the
    # kitchen lights and the TV. The porch has no room, and a thermostat
    # has no kind.
    assert has_element?(view, "#plan-svg g.p-ghost[data-ghost=d1] title", "Kitchen Lights")
    assert has_element?(view, "#plan-svg g.p-ghost[data-ghost=d2]")
    refute has_element?(view, "#plan-svg [data-ghost=d3]")
    refute has_element?(view, "#plan-svg [data-ghost=d4]")
    assert has_element?(view, "#plan-svg g.p-ghost-label[data-ghost=d1] text", "Kitchen Lights")

    assert has_element?(
             view,
             "#ha-ghosts[role=status]",
             "2 devices of Home Assistant are not in the house yet."
           )

    assert has_element?(view, "#ha-ghosts", "With a keyboard, use the list of the rooms.")
    refute has_element?(view, "#ha-ghosts", "The plan shows")

    assert has_element?(
             view,
             "#ha-ghosts",
             "1 device is in an area of Home Assistant with no room here."
           )

    assert has_element?(view, "#ha-ghosts a[href='/inside?sheet=ha_rooms']", "Match the rooms")

    # The list of the rooms has a key for each ghost, for a keyboard and a
    # screen reader.
    kitchen = Enum.find(build_of(view).rooms, &(&1.name == "Kitchen"))

    assert has_element?(
             view,
             "#room-#{kitchen.id} button#ghost-g1[phx-click=ha_add_device][phx-value-id=d1]",
             "Add Kitchen Lights from Home Assistant (Lights)"
           )

    porch_fan = %{"id" => "d5", "name" => "Porch fan", "area" => "porch", "domains" => ["fan"]}
    devices(view, @devices ++ [porch_fan])

    assert has_element?(
             view,
             "#ha-ghosts",
             "2 devices are in areas of Home Assistant with no room here."
           )

    # A second connect reads them again. A disconnect forgets them.
    render_hook(view, "ha:status", %{"state" => "offline", "url" => "https://ha.example.com"})
    assert has_element?(view, "#plan-svg [data-ghost=d1]")
    connected(view)
    assert_push_event(view, "ha:devices_fetch", %{})
    render_hook(view, "ha:status", %{"state" => "none"})
    refute has_element?(view, "#plan-svg [data-ghost]")
    refute has_element?(view, "#ha-ghosts p")
    # A late answer after the disconnect changes nothing.
    devices(view)
    refute has_element?(view, "#plan-svg [data-ghost]")
  end

  test "a tap on a ghost puts its item in the house, with a link to the device", %{conn: conn} do
    view = page(conn, ~p"/inside")
    connected(view)
    devices(view)
    before = length(build_of(view).items)

    # A device that is not a ghost changes nothing.
    render_hook(view, "ha_add_device", %{"id" => "d3"})
    render_hook(view, "ha_add_device", %{"id" => "nothing"})
    assert length(build_of(view).items) == before

    # The item comes at the place of its ghost. The other ghost stays at its
    # place.
    [lights, tv] = :sys.get_state(view.pid).socket.assigns.ghosts
    view |> element("#ghost-g1") |> render_click()
    build = build_of(view)
    assert length(build.items) == before + 1
    id = Build.device_item(build, "d1")
    {:ok, item} = Build.item(build, id)
    assert {item.type, item.params["bulbs"]} == {"lights", 1}
    assert item.at == lights.at
    assert :sys.get_state(view.pid).socket.assigns.ghosts == [tv]
    assert_patch(view, ~p"/inside?#{[item: id]}")

    # The panel of the item tells its device. The ghost is gone.
    assert has_element?(
             view,
             "#item-stage #part-link #ha-device",
             "This is Kitchen Lights in Home Assistant."
           )

    refute has_element?(view, "#ha-twin")
    refute has_element?(view, "#plan-svg [data-ghost=d1]")
    assert has_element?(view, "#ha-ghosts", "1 device of Home Assistant is not in the house yet.")

    # The TV: the house has a TV with no device. It can be the same TV.
    render_hook(view, "ha_add_device", %{"id" => "d2"})
    tv = Build.device_item(build_of(view), "d2")
    assert_patch(view, ~p"/inside?#{[item: tv]}")

    assert has_element?(
             view,
             "#ha-twin",
             "The house also has TV in Living room, with no link to Home Assistant. If it is the same TV, remove one of them."
           )

    # No ghost now. The porch light is still in an area with no room.
    refute has_element?(view, "#ha-ghosts", "not in the house yet")
    assert has_element?(view, "#ha-ghosts", "1 device is in an area")

    # Home Assistant does not have the device now.
    devices(view, tl(@devices))
    assert has_element?(view, "#ha-device", "This is Living Room TV in Home Assistant.")
    devices(view, Enum.drop(@devices, 2))
    assert has_element?(view, "#ha-device", "Its device is not in Home Assistant now.")
  end

  test "an item with a device and no devices on the page", %{conn: conn} do
    build = build()
    kitchen = Enum.find(build.rooms, &(&1.name == "Kitchen"))
    {:ok, build, id} = Build.add_device(build, kitchen.id, "fridge", "d9")
    view = page(conn, ~p"/inside?#{[item: id]}", build)
    assert has_element?(view, "#ha-device", "It has a link to a device of Home Assistant.")
    # The fridge of the preset can be the same fridge.
    assert has_element?(view, "#ha-twin", "The house also has Fridge in Kitchen")

    # Lights are many: no note.
    {:ok, build, lights} = Build.add_device(build, kitchen.id, "lights", "d8")
    view = page(conn, ~p"/inside?#{[item: lights]}", build)
    assert has_element?(view, "#ha-device")
    refute has_element?(view, "#ha-twin")
  end

  test "the devices that the page cannot read do not count" do
    ok = device("d1", "Lamp", nil, ["light"])
    long = String.duplicate("x", 256)

    assert HomeAssistant.read_devices(%{"error" => "offline"}) == %{error: "offline"}
    assert HomeAssistant.read_devices(%{"error" => "failed"}) == %{error: "failed"}
    assert HomeAssistant.read_devices(%{"error" => "other"}) == nil
    assert HomeAssistant.read_devices(%{"devices" => "x", "areas" => []}) == nil
    assert HomeAssistant.read_devices([1]) == nil

    assert HomeAssistant.read_devices(%{
             "devices" => List.duplicate(ok, 1001),
             "areas" => []
           }) == %{error: "too_many"}

    assert HomeAssistant.read_devices(%{"devices" => [], "areas" => List.duplicate(%{}, 501)}) ==
             %{error: "too_many"}

    bad = [
      %{ok | "id" => 5},
      %{ok | "id" => long},
      %{ok | "name" => nil},
      %{ok | "name" => long},
      %{ok | "area" => 5},
      %{ok | "area" => long},
      %{ok | "domains" => "light"},
      %{ok | "domains" => [5]},
      %{ok | "domains" => List.duplicate("light", 31)},
      %{"id" => "x"},
      "device"
    ]

    %{devices: devices, areas: areas} =
      HomeAssistant.read_devices(%{
        "devices" =>
          bad ++ [ok, %{ok | "name" => "Second"}, %{ok | "id" => "d2", "model" => long}],
        "areas" => [%{"id" => "a", "name" => "A", "floor" => nil}, %{"id" => 5}]
      })

    # The first device with an id counts. A model that is too long is nil.
    # The page reads the kind of each device one time.
    assert devices == [
             %{id: "d1", name: "Lamp", area: nil, domains: ["light"], model: nil, kind: "lights"},
             %{id: "d2", name: "Lamp", area: nil, domains: ["light"], model: nil, kind: "lights"}
           ]

    assert areas == [%{id: "a", name: "A", floor: nil}]
  end

  test "an answer that the page cannot read changes nothing", %{conn: conn} do
    view = page(conn, ~p"/inside")
    connected(view)
    devices(view)
    render_hook(view, "ha:devices", %{"nothing" => true})
    assert has_element?(view, "#plan-svg [data-ghost=d1]")
    render_hook(view, "ha:devices", %{"error" => "offline"})
    refute has_element?(view, "#plan-svg [data-ghost]")

    assert has_element?(
             view,
             "#ha-ghosts",
             "The app cannot read the devices of Home Assistant now."
           )

    render_hook(view, "ha:devices", %{
      "devices" => List.duplicate(hd(@devices), 1001),
      "areas" => @areas
    })

    assert has_element?(view, "#ha-ghosts", "more than 1,000 devices")

    # The sign-in page takes no devices.
    {:ok, tab, _html} = live(conn, ~p"/ha/sign-in")
    render_hook(tab, "ha:devices", %{"devices" => [], "areas" => []})
    render_hook(tab, "ha:status", %{"state" => "connected"})
    assert has_element?(tab, "#ha-status", "The app gets ready for the sign-in.")
    render_hook(tab, "ha:status", %{"state" => "done"})
    assert has_element?(tab, "#ha-status", "The sign-in is done.")
  end

  test "ghosts show only on the page Rooms", %{conn: conn} do
    view = page(conn, ~p"/")
    connected(view)
    devices(view)
    render_patch(view, ~p"/inside")
    assert has_element?(view, "#plan-svg [data-ghost=d1]")
    render_patch(view, ~p"/estimate")
    refute has_element?(view, "#ha-ghosts")
  end

  test "the plan shows some of many ghosts, and a hub with a link has one part of Home Assistant",
       %{conn: conn} do
    view = page(conn, ~p"/inside")
    connected(view)

    lamps =
      for i <- 1..10,
          do: %{
            "id" => "k#{i}",
            "name" => "Lamp #{i}",
            "area" => "kitchen",
            "domains" => ["light"]
          }

    devices(view, lamps)

    assert has_element?(
             view,
             "#ha-ghosts",
             "10 devices of Home Assistant are not in the house yet."
           )

    assert has_element?(view, "#ha-ghosts", "The plan shows 8 of them now.")
    assert view |> render() |> String.split("class=\"p-ghost\"") |> length() == 9

    # A stored build can link a hub to a device: its panel has one part
    # Home Assistant, the card of the link.
    build = build()
    living = Enum.find(build.rooms, &(&1.name == "Living room"))
    {:ok, build, hub} = Build.add_item(build, living.id, "home_assistant")
    build = %{build | devices: %{hub => "d9"}}
    view = page(conn, ~p"/inside?#{[item: hub]}", build)
    assert view |> render() |> String.split("id=\"part-link\"") |> length() == 2
    assert has_element?(view, "#part-link #home-assistant-card")
    # The pill of the hub on the plan has a space after its light.
    assert render(view) =~ ~r{<tspan class="i-ha-light">● </tspan>Home Assistant}
  end
end
