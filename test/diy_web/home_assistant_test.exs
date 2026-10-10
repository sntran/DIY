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

    # A way back that is not a page of the sign-in gives Settings.
    for bad <- ["//evil.example", "https://evil.example", "/plans", "/inside?item=a b", 5] do
      render_hook(view, "ha_connect", %{"url" => "https://ha.example.com", "back" => bad})
      assert_push_event(view, "ha:connect", %{back: "/settings"})
    end

    # The light of the hub on the plan follows the state of the link.
    status(view, %{"state" => "connected", "url" => "https://ha.example.com", "name" => "Home"})
    assert has_element?(view, "#inside[data-ha=connected]")
    assert has_element?(view, "#item-sheet #ha-status", "Connected to Home")
    assert render(view) =~ "i-ha-light"
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

  test "the other events of the page still work", %{conn: conn} do
    view = settings(conn)
    view |> form("#settings-zip", %{"zip" => "77002"}) |> render_submit()
    assert render(view) =~ "77002"
  end
end
