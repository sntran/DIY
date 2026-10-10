defmodule DIYWeb.HomeAssistantTest do
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, Catalog, Estimate, House, Stubs}
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

  # A page with the build on the device.
  defp page(conn, path, build \\ build()) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    view
  end

  defp settings(conn), do: page(conn, ~p"/settings")

  # The build with a Home Assistant hub in the living room.
  defp hub do
    build = build()
    room = Enum.find(build.rooms, &(&1.name == "Living room"))
    {:ok, build, id} = Build.add_item(build, room.id, "home_assistant")
    {build, id}
  end

  defp status(view, payload), do: render_hook(view, "ha:status", payload)

  test "the address of Home Assistant" do
    assert HomeAssistant.address("https://Home.Example.com/") == {:ok, "https://home.example.com"}
    assert HomeAssistant.address(" http://192.168.1.5:8123 ") == {:ok, "http://192.168.1.5:8123"}

    assert HomeAssistant.address("https://example.com:443/ha//?x=1#y") ==
             {:ok, "https://example.com/ha"}

    assert HomeAssistant.address("http://[::1]:8123") == {:ok, "http://[::1]:8123"}
    assert HomeAssistant.address("ftp://example.com") == :error
    assert HomeAssistant.address("home.example.com") == :error
    assert HomeAssistant.address("https://user:pass@example.com") == :error
    assert HomeAssistant.address("https://") == :error
    assert HomeAssistant.address("https://exa mple.com") == :error
    assert HomeAssistant.address(String.duplicate("a", 3000)) == :error
    assert HomeAssistant.address(nil) == :error
  end

  property "an address is the same address again, with no / at the end" do
    check all(
            scheme <- member_of(["http", "https", "ftp", ""]),
            host <- string(:alphanumeric, max_length: 12),
            port <- one_of([constant(""), map(integer(1..65_535), &":#{&1}")]),
            path <- list_of(string(:alphanumeric, max_length: 4), max_length: 3),
            slash <- member_of(["", "/", "//"])
          ) do
      text = "#{scheme}://#{host}#{port}/#{Enum.join(path, "/")}#{slash}"

      case HomeAssistant.address(text) do
        {:ok, url} ->
          assert url =~ ~r{^https?://}
          refute String.ends_with?(url, "/")
          assert HomeAssistant.address(url) == {:ok, url}

        :error ->
          assert scheme not in ["http", "https"] or host == ""
      end
    end
  end

  test "the words of each state and of each error" do
    ha = %{
      state: "none",
      url: "https://ha.example.com",
      name: "Home",
      version: "2026.10.0",
      error: nil
    }

    assert HomeAssistant.status(%{ha | state: "loading"}) == nil
    assert HomeAssistant.status(ha) == "Not connected."
    assert HomeAssistant.status(%{ha | state: "signed_out"}) == "Not connected."
    assert HomeAssistant.status(%{ha | state: "signing_in"}) =~ "sign-in"

    assert HomeAssistant.status(%{ha | state: "connecting"}) =~
             "connects to Home Assistant at https://ha.example.com"

    assert HomeAssistant.status(%{ha | state: "connected"}) ==
             "Connected to Home (Home Assistant 2026.10.0) at https://ha.example.com."

    assert HomeAssistant.status(%{ha | state: "connected", name: nil}) =~
             "Connected to Home Assistant ("

    assert HomeAssistant.status(%{ha | state: "offline"}) =~ "does not answer now"

    for error <- ~w(url blocked state denied token unreachable storage signed_out) do
      assert HomeAssistant.message(error) =~ ~r/^[A-Z].*\.$/
    end
  end

  test "the hook element is on each page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-assistant[phx-hook=HomeAssistant]")
  end

  test "Settings: the address, the sign-in, the state and the disconnect", %{conn: conn} do
    view = settings(conn)

    # Before the hook tells, the page shows the form and no state.
    assert has_element?(view, "#home-assistant-card #ha-form")
    refute has_element?(view, "#ha-status", "Not")

    # A bad address: the page tells it, and the hook gets nothing.
    view |> form("#ha-form", %{"url" => "home.example.com"}) |> render_submit()
    assert has_element?(view, "#ha-error", "Give the address")
    refute_push_event(view, "ha:connect", %{})

    view |> form("#ha-form", %{"url" => "https://HA.example.com/"}) |> render_submit()
    assert_push_event(view, "ha:connect", %{url: "https://ha.example.com", back: "/settings"})

    status(view, %{"state" => "none", "url" => nil, "error" => nil})
    assert has_element?(view, "#ha-status", "Not connected.")
    refute has_element?(view, "#ha-error")
    refute has_element?(view, "#ha-disconnect")

    status(view, %{"state" => "connecting", "url" => "https://ha.example.com"})

    assert has_element?(
             view,
             "#ha-status",
             "connects to Home Assistant at https://ha.example.com"
           )

    refute has_element?(view, "#ha-form")

    status(view, %{
      "state" => "connected",
      "url" => "https://ha.example.com",
      "name" => "Test house",
      "version" => "2026.10.0"
    })

    assert has_element?(
             view,
             "#ha-status",
             "Connected to Test house (Home Assistant 2026.10.0) at https://ha.example.com."
           )

    view |> element("#ha-disconnect") |> render_click()
    assert_push_event(view, "ha:disconnect", %{})

    # The end of a session: the form comes back, with the address.
    status(view, %{
      "state" => "signed_out",
      "url" => "https://ha.example.com",
      "error" => "signed_out"
    })

    assert has_element?(view, "#ha-error", "Home Assistant ended the sign-in")
    assert has_element?(view, "#ha-form input[name=url][value='https://ha.example.com']")

    status(view, %{"state" => "none", "url" => "http://ha.local:8123", "error" => "blocked"})
    assert has_element?(view, "#ha-error", "blocks an http address")
  end

  test "Settings: a status that the page cannot read changes nothing", %{conn: conn} do
    view = settings(conn)
    status(view, %{"state" => "connected", "url" => "https://ha.example.com", "name" => "Home"})

    for bad <- [
          %{"state" => "hacked"},
          %{"state" => 5},
          %{},
          %{"url" => "x"}
        ] do
      status(view, bad)
      assert has_element?(view, "#ha-status", "Connected to Home")
    end

    # Values out of their limits are nil.
    status(view, %{
      "state" => "connected",
      "url" => String.duplicate("u", 3000),
      "name" => %{"a" => 1},
      "version" => String.duplicate("v", 300),
      "error" => "other"
    })

    assert has_element?(view, "#ha-status", "Connected to Home Assistant (Home Assistant ) at .")
    refute has_element?(view, "#ha-error")
  end

  test "a Home Assistant hub: 2 W all the time, with the source of the number" do
    kind = Catalog.kind("home_assistant")
    assert kind.places == [:indoor]
    assert Catalog.size("home_assistant") == {4, 4, 1}
    [watts] = kind.params
    assert {watts.key, watts.default} == {"watts", 2}
    assert watts.note =~ "1.7 W at idle and 3 W under load"

    {build, id} = hub()
    {:ok, climate} = DIY.Weather.parse(Stubs.power(), 33.25, -96.75, 2016, 2025)
    estimate = Estimate.run(build, climate)
    {:ok, item} = Build.item(build, id)
    january = hd(estimate.months)
    assert_in_delta january.items[id].kwh, 2 * 24 * 31 / 1000, 1.0e-9
    assert hd(Estimate.explain(item, 1, estimate)) == "2 W × 24 hours × 31 days ÷ 1,000."
  end

  test "the sheet of a hub has the card, and the sign-in comes back to the sheet", %{conn: conn} do
    {build, id} = hub()
    view = page(conn, ~p"/inside?#{[item: id]}", build)

    assert has_element?(view, "#item-sheet #home-assistant-card")
    assert has_element?(view, "#item-sheet #ha-form input[name=back][value='/inside?item=#{id}']")
    refute has_element?(view, "#home-assistant-card h2")
    assert has_element?(view, "#inside[data-ha=loading]")

    view |> form("#ha-form", %{"url" => "https://ha.example.com"}) |> render_submit()
    assert_push_event(view, "ha:connect", %{url: "https://ha.example.com", back: back})
    assert back == "/inside?item=#{id}"

    # A way back that is not a page of the sign-in gives Settings, and no
    # way back too. The id of an item has 40 letters at most.
    for bad <- [
          "//evil.example",
          "/\\evil.example",
          "https://evil.example",
          "/plans",
          "/inside?item=a b",
          "/inside?item=x&y=1",
          "/inside?item=" <> String.duplicate("a", 41),
          5
        ] do
      render_hook(view, "ha_connect", %{"url" => "https://ha.example.com", "back" => bad})
      assert_push_event(view, "ha:connect", %{back: "/settings"})
    end

    render_hook(view, "ha_connect", %{"url" => "https://ha.example.com"})
    assert_push_event(view, "ha:connect", %{back: "/settings"})
    long = "/inside?item=" <> String.duplicate("a", 40)
    render_hook(view, "ha_connect", %{"url" => "https://ha.example.com", "back" => long})
    assert_push_event(view, "ha:connect", %{back: ^long})

    # The light of the hub on the plan follows the state of the link.
    status(view, %{"state" => "connected", "url" => "https://ha.example.com", "name" => "Home"})
    assert has_element?(view, "#inside[data-ha=connected]")
    assert has_element?(view, "#item-sheet #ha-status", "Connected to Home")
    assert has_element?(view, "#plan-item-#{id} .i-ha-light")

    # Over the small hub, a pill with the light: a part of the item for the
    # hook, so a tap on it opens the hub.
    {:ok, item} = Build.item(build, id)
    pill = "#plan-svg g.p-hub-label[data-item='#{id}'][data-in='#{item.room}']"
    assert has_element?(view, pill <> " text[data-rank='100000000'] tspan.i-ha-light")
    assert has_element?(view, pill <> " text", "Home Assistant")

    [ground | _] = DIYWeb.Cutaway.view(Build.house_view(build)).levels
    label = Enum.find(ground.labels, &(&1.id == id))
    {ew, ed} = DIY.Layout.extent(item)
    {:ok, room} = Build.room(build, item.room)

    assert label.item.at ==
             "#{round(room.plan.x + item.at.x + ew / 2)} #{round(room.plan.y + item.at.y + ed / 2)}"

    # The label of a room has no item.
    assert Enum.all?(ground.labels -- [label], &(not Map.has_key?(&1, :item)))
  end

  property "the way back is Settings or the sheet of an item, on the host of the app", %{
    conn: conn
  } do
    {build, id} = hub()
    view = page(conn, ~p"/inside?#{[item: id]}", build)

    check all(
            back <-
              one_of([
                string(:printable, max_length: 60),
                map(
                  string([?a..?z, ?0..?9, ?-, ?_, ?/, ?\\, ?&, ?=, ?.], max_length: 45),
                  &("/inside?item=" <> &1)
                ),
                member_of(["/settings", "//x", "/\\x", "/settings/", "javascript:alert(1)"])
              ])
          ) do
      render_hook(view, "ha_connect", %{"url" => "https://ha.example.com", "back" => back})
      assert_push_event(view, "ha:connect", %{back: pushed})
      assert pushed == "/settings" or pushed =~ ~r"\A/inside\?item=[A-Za-z0-9_-]{1,40}\z"
      assert pushed == back or pushed == "/settings"
      assert URI.parse("https://app.example" <> pushed).host == "app.example"
    end
  end

  test "Rooms shows an error of the link when no sheet of a hub is open", %{conn: conn} do
    {build, id} = hub()
    view = page(conn, ~p"/inside", build)
    refute has_element?(view, "#ha-alert")
    status(view, %{"state" => "none", "error" => "denied"})
    assert has_element?(view, "#ha-alert", "Home Assistant: Home Assistant did not give access.")
    assert has_element?(view, "#ha-alert a[href='/settings']")

    # The sheet of the hub has the card, with the error: no alert over it.
    view |> render_patch(~p"/inside?#{[item: id]}")
    refute has_element?(view, "#ha-alert")
    assert has_element?(view, "#item-sheet #ha-error", "did not give access")

    # The way back to a hub that went away: the alert shows.
    view |> render_patch(~p"/inside?#{[item: "i999"]}")
    assert has_element?(view, "#ha-alert")
    status(view, %{"state" => "connected", "url" => "https://ha.example.com", "name" => "Home"})
    refute has_element?(view, "#ha-alert")

    # Only the errors of a sign-in that came back, or of a session that
    # ended. Not an error of the store at each page, or of the card.
    for error <- ~w(state denied token unreachable signed_out) do
      status(view, %{"state" => "none", "error" => error})
      assert has_element?(view, "#ha-alert"), error
    end

    for error <- ~w(storage url blocked) do
      status(view, %{"state" => "none", "error" => error})
      refute has_element?(view, "#ha-alert"), error
    end
  end

  test "the pill of a planned hub is pale, as the hub", %{conn: conn} do
    {build, id} = hub()
    {:ok, build} = Build.flag_item(build, id, :planned, true)
    view = page(conn, ~p"/inside", build)
    assert has_element?(view, "#plan-item-#{id}.p-planned")
    assert has_element?(view, "g.p-hub-label.p-planned[data-item='#{id}']")

    {build, id} = hub()
    view = page(conn, ~p"/inside", build)
    assert has_element?(view, "g.p-hub-label[data-item='#{id}']")
    refute has_element?(view, "g.p-hub-label.p-planned")
  end

  test "Settings: a link to the hub, or a hint to add one", %{conn: conn} do
    view = settings(conn)
    assert has_element?(view, "#ha-hub", "add a Home Assistant hub to a room")

    {build, id} = hub()
    view = page(conn, ~p"/settings", build)
    assert has_element?(view, "#ha-hub", "Your hub is in Living room")
    view |> element("#ha-hub a") |> render_click()
    assert_patch(view, ~p"/inside?#{[item: id]}")
    assert has_element?(view, "#item-sheet #home-assistant-card")
  end

  ## The match of the rooms

  # The last build that the page saved on the device.
  defp saved(view) do
    assert_push_event(view, "device:save", %{text: text})
    %{proxy: {ref, _topic, _pid}} = view
    text = last_text(ref, text)
    {:ok, build} = Build.from_json(text)
    build
  end

  defp last_text(ref, text) do
    receive do
      {^ref, {:push_event, "device:save", %{text: newer}}} -> last_text(ref, newer)
    after
      0 -> text
    end
  end

  defp connected(view),
    do:
      status(view, %{"state" => "connected", "url" => "https://ha.example.com", "name" => "Home"})

  defp room_id(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id

  # The floors and the areas of Home Assistant, as the hook sends them.
  defp ha_rooms(admin \\ true) do
    %{
      "floors" => [%{"id" => "ground", "name" => "Ground", "level" => 0}],
      "areas" => [
        %{"id" => "living", "name" => "Living Room", "floor" => "ground"},
        %{"id" => "patio", "name" => "Patio", "floor" => nil},
        %{"id" => "suite", "name" => "Guest Suite", "floor" => "ground"},
        %{"id" => "den", "name" => "Den", "floor" => nil}
      ],
      "admin" => admin
    }
  end

  test "the card links to the match when Home Assistant is connected", %{conn: conn} do
    view = settings(conn)
    refute has_element?(view, "#ha-match")
    connected(view)
    assert has_element?(view, "#ha-match[href='/inside?sheet=ha_rooms']")
    # Settings has no sheet of the match: it does not read the areas.
    refute_push_event(view, "ha:rooms_fetch", %{})
  end

  test "the sheet of the match waits for the link and for the areas", %{conn: conn} do
    view = page(conn, ~p"/inside")
    render_patch(view, ~p"/inside?#{[sheet: "ha_rooms"]}")
    assert_push_event(view, "ha:rooms_fetch", %{})
    # The hook did not tell the state of the link yet.
    assert has_element?(view, "#ha-rooms-sheet #ha-rooms-wait", "The app reads the areas")
    status(view, %{"state" => "none"})
    assert has_element?(view, "#ha-rooms-wait", "Connect Home Assistant first")

    # The hook has no link yet: it tells offline. When the link comes, the
    # page asks again.
    render_hook(view, "ha:rooms", %{"error" => "offline"})
    assert has_element?(view, "#ha-rooms-wait", "Connect Home Assistant first")
    connected(view)
    assert_push_event(view, "ha:rooms_fetch", %{})
    assert has_element?(view, "#ha-rooms-wait", "The app reads the areas")
    render_hook(view, "ha:rooms", %{"error" => "offline"})
    assert has_element?(view, "#ha-rooms-wait[role=alert]", "does not answer now")

    # The areas come. A new status does not read them again.
    render_hook(view, "ha:rooms", ha_rooms())
    assert has_element?(view, "#ha-rooms")
    connected(view)
    refute_push_event(view, "ha:rooms_fetch", %{})

    # On a different sheet, a status does not read the areas.
    render_patch(view, ~p"/inside")
    render_hook(view, "ha:rooms", %{"error" => "offline"})
    connected(view)
    refute_push_event(view, "ha:rooms_fetch", %{})
  end

  test "the sheet shows the rooms in both, only in the app, and only in Home Assistant", %{
    conn: conn
  } do
    view = page(conn, ~p"/inside?#{[sheet: "ha_rooms"]}")
    connected(view)
    render_hook(view, "ha:rooms", ha_rooms())

    assert has_element?(view, "#ha-both h3", "In both (1)")
    assert has_element?(view, "#ha-both li", "Living room")
    refute has_element?(view, "#ha-both li", "in Home Assistant:")
    assert has_element?(view, "#ha-app input[type=checkbox][checked]")
    refute has_element?(view, "#ha-app input[disabled]")
    assert has_element?(view, "#ha-app label", "Add Kitchen to Home Assistant (Floor 1)")
    assert has_element?(view, "#ha-ha h3", "Only in Home Assistant (3)")

    assert has_element?(
             view,
             "select[name='ha[patio]'] option[value='outside outdoor'][selected]"
           )

    assert has_element?(view, "select[name='ha[suite]'] option[value='f1 indoor'][selected]")
    assert has_element?(view, "select[name='ha[den]'] option[value='f2 indoor']")
    assert has_element?(view, "select[name='ha[den]'] option[value='skip']", "Do not add it")

    # A room with a link to an area of a different name shows that name.
    {:ok, build} = Build.link_area(build(), room_id(build(), "Kitchen"), "den")
    view = page(conn, ~p"/inside?#{[sheet: "ha_rooms"]}", build)
    connected(view)
    render_hook(view, "ha:rooms", ha_rooms())
    assert has_element?(view, "#ha-both li", "Kitchen (in Home Assistant: Den)")

    # Not an admin: no rooms to add to Home Assistant.
    render_hook(view, "ha:rooms", ha_rooms(false))
    assert has_element?(view, "#ha-app", "Your user of Home Assistant is not an admin")
    assert has_element?(view, "#ha-app input[disabled]")
    refute has_element?(view, "#ha-app input[checked]")
  end

  test "the hook gives floors and areas that the page cannot read: no change", %{conn: conn} do
    view = page(conn, ~p"/inside?#{[sheet: "ha_rooms"]}")
    connected(view)
    good = ha_rooms()
    floor = hd(good["floors"])
    area = hd(good["areas"])

    for bad <- [
          %{},
          %{good | "admin" => "yes"},
          %{good | "floors" => "x"},
          %{good | "floors" => List.duplicate(floor, 101)},
          %{good | "areas" => List.duplicate(area, 501)},
          %{good | "floors" => [%{floor | "level" => "one"}]},
          %{good | "floors" => [%{floor | "id" => String.duplicate("f", 101)}]},
          %{good | "floors" => [1]},
          %{good | "areas" => [%{area | "floor" => 5}]},
          %{good | "areas" => [%{area | "name" => String.duplicate("n", 201)}]},
          %{good | "areas" => [%{area | "floor" => String.duplicate("f", 101)}]},
          %{good | "areas" => [nil]}
        ] do
      render_hook(view, "ha:rooms", bad)
      assert has_element?(view, "#ha-rooms-wait", "The app reads the areas")
    end

    # A floor with no level, and an area with no floor, are good.
    render_hook(view, "ha:rooms", %{
      good
      | "floors" => [%{floor | "level" => nil}],
        "areas" => [%{area | "floor" => nil}]
    })

    assert has_element?(view, "#ha-rooms")
  end

  test "a match links the rooms, adds the areas as rooms, and asks the hook for new areas", %{
    conn: conn
  } do
    view = page(conn, ~p"/inside?#{[sheet: "ha_rooms"]}")
    connected(view)
    render_hook(view, "ha:rooms", ha_rooms())
    kitchen = room_id(build(), "Kitchen")
    garage = room_id(build(), "Garage")
    attic = room_id(build(), "Attic")

    view
    |> form("#ha-rooms", %{
      "ha" => %{
        "patio" => "outside outdoor",
        "suite" => "f2 indoor",
        "den" => "skip"
      }
    })
    |> render_submit(%{"app" => [kitchen, garage, attic, "r999"]})

    assert_push_event(view, "ha:add_areas", %{areas: areas})

    assert Enum.sort_by(areas, & &1.name) == [
             %{room: attic, name: "Attic", level: nil, floor: "Roof and attic"},
             %{room: garage, name: "Garage", level: nil, floor: "Around the house"},
             %{room: kitchen, name: "Kitchen", level: 0, floor: "Floor 1"}
           ]

    build = saved(view)
    living = room_id(build, "Living room")
    patio = Enum.find(build.rooms, &(&1.name == "Patio"))
    suite = Enum.find(build.rooms, &(&1.name == "Guest Suite"))
    assert {patio.level, patio.place} == {"outside", :outdoor}
    assert {suite.level, suite.place} == {"f2", :indoor}
    refute Enum.any?(build.rooms, &(&1.name == "Den"))
    assert build.areas == %{living => "living", patio.id => "patio", suite.id => "suite"}

    assert has_element?(
             view,
             "#ha-sync",
             "The app linked 1 room and added 2 rooms. Home Assistant adds 3 areas."
           )

    # The answer of the hook: two new areas, and one error.
    render_hook(view, "ha:areas_added", %{
      "links" => [
        %{"room" => kitchen, "area" => "kitchen"},
        %{"room" => garage, "area" => "garage"},
        %{"room" => "r999", "area" => "x"},
        %{"room" => kitchen, "area" => String.duplicate("a", 101)},
        %{"room" => 5}
      ],
      "errors" => [
        %{"room" => attic, "message" => "Unauthorized"},
        %{"room" => kitchen, "message" => 5},
        %{"room" => "r999", "message" => "x"}
      ]
    })

    assert_push_event(view, "ha:rooms_fetch", %{})
    build = saved(view)
    assert build.areas[kitchen] == "kitchen"
    assert build.areas[garage] == "garage"

    assert has_element?(
             view,
             "#ha-sync",
             "The app linked 1 room and added 2 rooms. Home Assistant added 3 areas. " <>
               "Home Assistant did not add: Attic (Unauthorized), Kitchen (no reason)."
           )

    # The areas come again: the rooms are in both.
    areas = [
      %{"id" => "kitchen", "name" => "Kitchen", "floor" => "ground"},
      %{"id" => "garage", "name" => "Garage", "floor" => nil}
      | ha_rooms()["areas"]
    ]

    render_hook(view, "ha:rooms", %{ha_rooms() | "areas" => areas})
    assert has_element?(view, "#ha-both h3", "In both (5)")
    assert has_element?(view, "#ha-ha h3", "Only in Home Assistant (1)")
  end

  test "a match with no new areas reads the areas again, and the hook can answer late", %{
    conn: conn
  } do
    view = page(conn, ~p"/inside?#{[sheet: "ha_rooms"]}")
    connected(view)
    render_hook(view, "ha:rooms", ha_rooms(false))
    view |> form("#ha-rooms") |> render_submit(%{"ha" => %{"den" => "f9 indoor"}})
    refute_push_event(view, "ha:add_areas", %{})
    assert_push_event(view, "ha:rooms_fetch", %{})

    assert has_element?(
             view,
             "#ha-sync",
             "The app linked 1 room and added 2 rooms."
           )

    # Choices that the page cannot read: no new rooms.
    render_hook(view, "ha:rooms", ha_rooms(false))
    render_hook(view, "ha_sync", %{"ha" => "x", "app" => "y"})
    render_hook(view, "ha:rooms", ha_rooms(false))
    render_hook(view, "ha_sync", %{"ha" => %{"patio" => 5, "suite" => "f1 attic"}})
    assert has_element?(view, "#ha-sync", "The app linked 0 rooms and added 0 rooms.")

    # A match with no areas, or a bad answer of the hook: no change.
    render_hook(view, "ha_sync", %{})
    render_hook(view, "ha:areas_added", %{"links" => "x"})
    assert has_element?(view, "#ha-sync", "The app linked 0 rooms and added 0 rooms.")

    # An answer after the sheet opened again (no status of a match).
    render_patch(view, ~p"/inside")
    render_patch(view, ~p"/inside?#{[sheet: "ha_rooms"]}")
    refute has_element?(view, "#ha-sync")
    kitchen = room_id(build(), "Kitchen")

    render_hook(view, "ha:areas_added", %{
      "links" => [%{"room" => kitchen, "area" => "kitchen"}],
      "errors" => []
    })

    assert has_element?(
             view,
             "#ha-sync",
             "The app linked 0 rooms and added 0 rooms. Home Assistant added 1 area."
           )
  end

  test "the words of a match" do
    status = %{linked: 2, added: 0, missed: ["Loft"], sent: 0, done: nil, errors: []}

    assert HomeAssistant.sync_text(status) ==
             "The app linked 2 rooms and added 0 rooms. It did not add: Loft."
  end

  test "with no house, the events of the match change nothing", %{conn: conn} do
    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    view = page(conn, ~p"/inside", build)
    render_hook(view, "ha_sync", %{})
    render_hook(view, "ha:areas_added", %{"links" => [], "errors" => []})
    refute_push_event(view, "device:save", %{})
  end

  test "the other events of the page still work", %{conn: conn} do
    view = settings(conn)
    view |> form("#settings-zip", %{"zip" => "77002"}) |> render_submit()
    assert render(view) =~ "77002"
  end
end
