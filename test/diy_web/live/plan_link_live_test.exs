defmodule DIYWeb.PlanLinkLiveTest do
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Plan, PlanLink, Stubs}

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  @market %{
    choice: true,
    utility: "Oncor",
    median: 14.1,
    plans: 168,
    source: "ptc"
  }

  defp credit_plan do
    %{
      Plan.new("8.9¢ with a $125 credit")
      | energy: [{0, 14.4}],
        tdu_base: 4.9,
        tdu_cents: 6.5333,
        credits: [%{dollars: 125.0, min_kwh: 1000, months: nil}],
        min_fee: %{dollars: 4.99, below_kwh: 400}
    }
  end

  defp flat_plan,
    do: %{
      Plan.new("14.9¢ with no credit")
      | energy: [{0, 7.88}],
        tdu_base: 4.9,
        tdu_cents: 6.5333
    }

  defp link(plans \\ [credit_plan(), flat_plan()]) do
    {:ok, data} = PlanLink.encode(plans)
    data
  end

  defp restore(view, build) do
    payload =
      if build,
        do: %{"text" => Build.to_json(build), "stamp" => build.stamp},
        else: %{"text" => nil, "stamp" => ""}

    render_hook(view, "device:restore", payload)
    settle(view)
  end

  defp house(market \\ @market) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    # A market of today: the page asks again for an old market
    # (`DIY.Market.old?/2`), and the stub has a different market.
    today = Date.to_iso8601(Date.utc_today())
    build = if market, do: Build.set_market(build, Map.put(market, :date, today)), else: build
    Build.put_house(build, house, rooms, items)
  end

  defp with_plans(build, plans) do
    Enum.reduce(plans, build, fn plan, build ->
      {:ok, build, _id} = Build.add_plan(build, plan)
      build
    end)
  end

  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build

  describe "the page of a link of plans" do
    test "the chart, the numbers of each plan, and the tags of the preview", %{conn: conn} do
      data = link()
      html = conn |> get(~p"/p/#{data}") |> html_response(200)
      title = "2 plans: the price for each kWh at each use"
      assert html =~ ~s(<meta property="og:title" content="#{title}")
      assert html =~ ~s(content="http://www.example.com/p/#{data}/picture.png")
      assert html =~ ~s(<meta property="og:url" content="http://www.example.com/p/#{data}")

      assert html =~
               "8.9¢ with a $125 credit, 14.9¢ with no credit. The price for each kWh changes"

      assert html =~ ~r/<title[^>]*>#{title}</

      {:ok, view, _html} = live(conn, ~p"/p/#{data}")
      assert has_element?(view, "#plan-link h1", "2 plans to compare")
      assert has_element?(view, "#link-chart svg polyline")
      assert has_element?(view, "#link-chart-table")
      assert has_element?(view, "#link-plan-1 li", "Credit: $125.00 for 1,000 kWh or more.")
      assert has_element?(view, "#link-plan-2 li", "Energy charge: 7.88¢ for each kWh.")
      # The button waits for the build of the device. The page has no bar of
      # the parts of a build.
      assert has_element?(view, "#plan-link-add[disabled]")
      refute has_element?(view, "nav a[href='/inside']")
      refute render(view) =~ "The page reads your build from this device."

      {:ok, view, _html} = live(conn, ~p"/p/#{link([flat_plan()])}")
      assert has_element?(view, "#plan-link h1", "A plan to compare")
    end

    test "a link that is not a link of plans", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/p/2abc")
      assert has_element?(view, "#plan-link-error")
      assert has_element?(view, "#plan-link-start")
      refute render(view) =~ "og:title"

      # A different page has no tags of the link.
      render_patch(view, ~p"/")
      assert :sys.get_state(view.pid).socket.assigns.meta == nil
    end

    test "the picture of the preview", %{conn: conn} do
      data = link()
      conn = get(conn, ~p"/p/#{data}/picture.png")
      assert <<0x89, "PNG", _rest::binary>> = response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

      assert build_conn() |> get(~p"/p/2abc/picture.png") |> response(404)
    end

    test "the log does not show the path of a link of plans" do
      assert DIYWeb.Endpoint.log_level(%Plug.Conn{path_info: ["p", link()]}) == false
    end
  end

  describe "the plans of a link go into the worksheet" do
    test "a new device: the first screens, then the worksheet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/p/#{link()}")
      restore(view, nil)
      view |> element("#plan-link-add") |> render_click()
      assert_patch(view, ~p"/plans?step=4")
      assert render(view) =~ "The worksheet has the plans of the link now."
      assert Enum.map(build(view).plans, & &1.name) == [credit_plan().name, flat_plan().name]
      assert build(view).lesson == 4

      # The device has no house: the first screens come first.
      render_click(view, "door", %{"door" => "my_house"})
      view |> form("#zip-form", %{"zip" => "75070"}) |> render_submit()
      settle(view)

      view
      |> form("#preset-form", %{
        "preset" => %{"size" => "medium", "age" => "2000s", "floors" => "2", "heat" => "gas"}
      })
      |> render_submit(%{"preset" => %{"start" => "preset"}})

      settle(view)
      assert has_element?(view, "#worksheet-table th", "8.9¢ with a $125 credit")
      assert has_element?(view, "#worksheet-chart svg circle.pc-month")
    end

    test "a house in Texas: the worksheet, with no plan two times", %{conn: conn} do
      data = link()
      {:ok, view, _html} = live(conn, ~p"/p/#{data}")
      restore(view, with_plans(house(), [flat_plan()]))
      view |> element("#plan-link-add") |> render_click()
      assert_patch(view, ~p"/plans?step=4")
      assert Enum.map(build(view).plans, & &1.name) == [flat_plan().name, credit_plan().name]
      assert has_element?(view, "#worksheet")

      {:ok, view, _html} = live(conn, ~p"/p/#{data}")
      restore(view, with_plans(house(), [flat_plan(), credit_plan()]))
      view |> element("#plan-link-add") |> render_click()
      assert render(view) =~ "The worksheet has these plans already."
      assert length(build(view).plans) == 2
    end

    test "a full worksheet keeps the plans that fit", %{conn: conn} do
      nine = for n <- 1..9, do: %{flat_plan() | name: "Plan #{n}"}
      {:ok, view, _html} = live(conn, ~p"/p/#{link()}")
      restore(view, with_plans(house(), nine))
      view |> element("#plan-link-add") |> render_click()
      assert render(view) =~ "Some plans of the link are not in it."
      assert length(build(view).plans) == 10
      assert List.last(build(view).plans).name == credit_plan().name
    end

    test "a house that is not in an area with retail choice", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/p/#{link()}")
      restore(view, house(%{@market | choice: false}))
      view |> element("#plan-link-add") |> render_click()
      assert render(view) =~ "These plans are for Texas"
      assert build(view).plans == []
    end
  end

  describe "the worksheet" do
    test "the chart, the months with no credit, and the link of the plans", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/plans?step=4")
      restore(view, %{with_plans(house(), [credit_plan(), flat_plan()]) | lesson: 4})

      assert has_element?(view, "#worksheet-chart polyline.pc-1")
      assert has_element?(view, "#worksheet-chart li", "Your months")
      # A month under 1,000 kWh does not get the credit of $125.
      assert has_element?(view, "#worksheet-table td span.sr-only", "(no credit of $125.00)")
      assert has_element?(view, "#worksheet-missed")

      path = view |> element("#plan-share-button") |> render() |> attr("data-path")
      "/p/" <> data = path
      assert {:ok, [_, _]} = PlanLink.decode(data)
      assert has_element?(view, ~s(#plan-share-link[value="http://www.example.com#{path}"]))
      refute render(view) =~ "(the first 6)"
      refute has_element?(view, "#worksheet p", "The chart shows the first 6 plans.")
    end

    test "more than 6 plans: the chart and the link have the first 6", %{conn: conn} do
      seven = for n <- 1..7, do: %{flat_plan() | name: "Plan #{n}"}
      {:ok, view, _html} = live(conn, ~p"/plans?step=4")
      restore(view, %{with_plans(house(), seven) | lesson: 4})
      assert has_element?(view, "#worksheet p", "The chart shows the first 6 plans.")
      assert render(view) =~ "(the first 6)"
      refute has_element?(view, "#worksheet-chart polyline.pc-7")
      refute has_element?(view, "#worksheet-missed")

      "/p/" <> data = view |> element("#plan-share-button") |> render() |> attr("data-path")
      assert {:ok, plans} = PlanLink.decode(data)
      assert length(plans) == 6
    end

    test "plans with names too long for a link", %{conn: conn} do
      long = %{flat_plan() | name: "a" <> String.duplicate("́", 3000)}
      plans = for n <- 1..3, do: %{long | base: n * 1.0}
      {:ok, view, _html} = live(conn, ~p"/plans?step=4")
      restore(view, %{with_plans(house(), plans) | lesson: 4})
      assert has_element?(view, "#plan-share-too-large")
      refute has_element?(view, "#plan-share")
    end

    test "the page waits for the weather, and tells when it failed", %{conn: conn} do
      # A slow weather service: the page waits.
      Req.Test.stub(DIY.Weather, fn conn ->
        Process.sleep(300)
        Req.Test.json(conn, DIY.Stubs.power())
      end)

      {:ok, view, _html} = live(conn, ~p"/plans")
      render_hook(view, "device:restore", %{"text" => Build.to_json(house()), "stamp" => ""})
      assert has_element?(view, "#plans-loading")
      settle(view)
      refute has_element?(view, "#plans-loading")
      assert has_element?(view, "#lesson")

      # The weather service is down: the page tells it, and it can try
      # again.
      Stubs.weather(:down)
      {:ok, view, _html} = live(conn, ~p"/plans")
      restore(view, house())
      refute has_element?(view, "#plans-loading")
      assert has_element?(view, "#plans-failed[role=alert] p.text-error")
      assert has_element?(view, "#plans-failed", "The page needs the weather")

      Stubs.weather()
      view |> element("#plans-failed button", "Try again") |> render_click()
      settle(view)
      refute has_element?(view, "#plans-failed")
      assert has_element?(view, "#lesson")
    end
  end

  defp attr(html, name) do
    [_, value] = Regex.run(~r/#{name}="([^"]*)"/, html)
    value
  end
end
