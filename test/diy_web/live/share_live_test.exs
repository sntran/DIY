defmodule DIYWeb.ShareLiveTest do
  # The test of the log changes the level of the log: no test runs at the
  # same time.
  use DIYWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias DIY.{Build, House, Share, Stubs}

  # The DATA of the link of a house that a link can carry.
  defp encode!(build, summary, opts \\ []) do
    {:ok, data} = Share.encode(build, summary, opts)
    data
  end

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp restore(view, build) do
    payload =
      if build,
        do: %{"text" => Build.to_json(build), "stamp" => build.stamp},
        else: %{"text" => nil, "stamp" => ""}

    render_hook(view, "device:restore", payload)
  end

  defp house(size \\ 1800) do
    {house, rooms, items} =
      House.preset(%{size: size, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build

  defp summary, do: Share.summary(Enum.map(1..12, &(1000 + 10 * &1)), 1500, "en")

  # The link of a shared house of 2,400 sq ft.
  defp link_data(opts \\ []), do: encode!(house(2400), summary(), opts)

  describe "the sheet of the share" do
    test "the page House shares the house of today, with its numbers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      restore(view, house())
      settle(view)

      view |> element("#share-open") |> render_click()
      assert_patch(view, ~p"/?sheet=share")
      assert has_element?(view, "#share-sheet")

      bill = :sys.get_state(view.pid).socket.assigns.bill
      kwh = DIYWeb.Format.kwh(Enum.sum(Enum.map(bill.months, &round(&1.kwh))))
      assert render(view) =~ kwh
      assert has_element?(view, "#share-sheet li", "ZIP code 75070")

      url = view |> element("#share-link") |> render() |> attr("value")
      assert url =~ ~r"\Ahttp://www.example.com/s/1[A-Za-z0-9_-]+\z"
      assert has_element?(view, ~s(#share-button[data-path="#{url}"]))
      assert has_element?(view, ~s(#share-sheet img[src$="/picture.png"]))

      # The link gives the house of the page.
      "http://www.example.com/s/" <> data = url
      {:ok, shared, s} = Share.decode(data)
      assert shared.house == build(view).house
      assert shared.zip == "75070"
      assert s.cost == round(bill.cost)
    end

    test "the box of the ZIP code takes it out of the link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?sheet=share")
      restore(view, house())
      settle(view)

      view |> form("#share-zip", %{"zip" => "false"}) |> render_change()
      refute has_element?(view, "#share-sheet li", "ZIP code")
      url = view |> element("#share-link") |> render() |> attr("value")
      "http://www.example.com/s/" <> data = url
      assert {:ok, %{zip: nil}, _s} = Share.decode(data)

      view |> form("#share-zip", %{"zip" => "true"}) |> render_change()
      assert has_element?(view, "#share-sheet li", "ZIP code 75070")
    end

    test "a house that is too large for a link has no link", %{conn: conn} do
      build = house()
      kitchen = Enum.find(build.rooms, &(&1.name == "Kitchen")).id

      build =
        Enum.reduce(1..(151 - length(build.items)), build, fn _i, b ->
          {:ok, b, _id} = Build.add_item(b, kitchen, "fridge")
          b
        end)

      {:ok, view, _html} = live(conn, ~p"/?sheet=share")
      restore(view, build)
      settle(view)
      assert has_element?(view, "#share-too-large", "150 items")
      refute has_element?(view, "#share-button")
      refute has_element?(view, "#share-sheet img")
    end

    test "a house with no bill yet has no share", %{conn: conn} do
      Stubs.weather(:down)
      {:ok, view, _html} = live(conn, ~p"/?sheet=share")
      restore(view, house())
      settle(view)
      refute has_element?(view, "#share-open")
      refute has_element?(view, "#share-sheet")
    end
  end

  describe "the page of a link" do
    test "the server gives the tags of the preview, in the language of the link", %{conn: conn} do
      data = link_data()
      html = conn |> get(~p"/s/#{data}") |> html_response(200)

      assert html =~
               ~s(<meta property="og:title" content="A house of 2,400 sq ft in 75070: 12,780 kWh a year")

      assert html =~
               ~s(<meta property="og:image" content="http://www.example.com/s/#{data}/picture.png")

      assert html =~ ~s(<meta property="og:url" content="http://www.example.com/s/#{data}")
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
      assert html =~ "$1,500 for the electricity of a year."
      assert html =~ "<title"
      assert html =~ "A shared house"
      # The page shows the house before the build of the device loads.
      assert html =~ "12,780 kWh"

      # A page in Vietnamese for a link in English. The page is in its own
      # language. The tags of the preview are in the language of the link.
      html =
        conn |> put_req_cookie("diy_language", "vi") |> get(~p"/s/#{data}") |> html_response(200)

      assert html =~ "Nhà 2,400 ft² ở 75070: 12,780 kWh mỗi năm</p>"
      assert html =~ ~s(<meta property="og:title" content="A house of 2,400 sq ft)

      vi = encode!(house(2400), %{summary() | cost: nil, locale: "vi"})
      html = conn |> get(~p"/s/#{vi}") |> html_response(200)
      assert html =~ ~s(content="Nhà 2,400 ft² ở 75070: 12,780 kWh mỗi năm")
      assert html =~ ~s(<meta name="description" content="Small Steps Home cho thấy)
    end

    test "a page with no link has no tags of a preview", %{conn: conn} do
      refute conn |> get(~p"/") |> html_response(200) =~ "og:title"
    end

    test "start from this house on a device with no house", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/s/#{link_data()}")
      assert has_element?(view, "#adopt[disabled]")
      refute has_element?(view, "nav a[href='/inside']")
      restore(view, nil)
      refute has_element?(view, "#adopt[disabled]")
      assert has_element?(view, ~s(#shared-months li[aria-label="January: 1,010 kWh"]))

      view |> element("#adopt") |> render_click()
      assert_patch(view, ~p"/")
      assert render(view) =~ "This house is your house now."
      assert build(view).house.size == 2400
      assert build(view).zip == "75070"
      assert_push_event(view, "device:save", _payload)
    end

    test "start from this house on a device with a house asks first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/s/#{link_data()}")
      restore(view, house(1800))

      view |> element("#adopt") |> render_click()
      assert has_element?(view, "#adopt-confirm", "takes the place of your house")
      assert has_element?(view, ~s(#adopt-confirm a[href="/settings"]))
      assert build(view).house.size == 1800

      view |> element("#adopt-cancel") |> render_click()
      refute has_element?(view, "#adopt-confirm")
      assert has_element?(view, "#adopt")

      view |> element("#adopt") |> render_click()
      view |> element("#adopt-sure") |> render_click()
      assert_patch(view, ~p"/")
      assert build(view).house.size == 2400
    end

    test "a link with no ZIP code starts at the ZIP code", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/s/#{link_data(zip: false)}")
      restore(view, nil)
      view |> element("#adopt") |> render_click()
      assert build(view).zip == nil
      assert has_element?(view, "#zip-form")
    end

    test "a bad link shows that it has no house", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/s/1abc")
      assert html =~ "This link has no house"
      assert has_element?(view, ~s(#shared-start[href="/"]))
      refute html =~ "og:title"
      restore(view, nil)
      render_click(view, "adopt", %{})
      assert build(view).house == nil
    end

    test "a different page after a link has no tags of the link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/s/#{link_data()}")
      restore(view, house())
      render_patch(view, ~p"/settings")
      assert :sys.get_state(view.pid).socket.assigns.meta == nil
      assert page_title(view) == "Small Steps Home"
    end
  end

  describe "the log" do
    test "a request for a link writes no line with the house" do
      data = link_data()
      assert DIYWeb.Endpoint.log_level(%Plug.Conn{path_info: ["s", data]}) == false
      assert DIYWeb.Endpoint.log_level(%Plug.Conn{path_info: ["settings"]}) == :info
      assert DIYWeb.Endpoint.log_level(%Plug.Conn{path_info: []}) == :info

      level = Logger.level()
      Logger.configure(level: :debug)

      try do
        log =
          capture_log([level: :debug], fn ->
            build_conn() |> get(~p"/s/#{data}") |> html_response(200)
            build_conn() |> get(~p"/s/#{data}/picture.png") |> response(200)
            build_conn() |> get(~p"/settings") |> html_response(200)
            # The mount of the LiveView logs its parameters.
            {:ok, view, _html} = live(build_conn(), ~p"/s/#{data}")
            render(view)
          end)

        refute log =~ data
        assert log =~ "GET /settings"
        assert log =~ ~s("data" => "[FILTERED]")
      after
        Logger.configure(level: level)
      end
    end
  end

  defp attr(html, name) do
    [_, value] = Regex.run(~r/#{name}="([^"]*)"/, html)
    value
  end
end
