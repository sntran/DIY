defmodule DIYWeb.MarketAgainTest do
  @moduledoc """
  An old market of Power to Choose in a build (`DIY.Market.old?/2`): the
  page asks again one time, in the background (`DIYWeb.HomeLive`).
  """
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}

  setup do
    Stubs.weather()
    :ok
  end

  # A house in 75070 with a market of Power to Choose of `days` ago.
  defp house(days, source \\ "ptc") do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    build = Build.put_house(build, house, rooms, items)

    Build.set_market(build, %{
      choice: true,
      utility: "Old utility",
      median: 9.9,
      plans: 3,
      date: Date.to_iso8601(Date.add(Date.utc_today(), -days)),
      source: source
    })
  end

  defp open(conn, build) do
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    view
  end

  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build

  # Power to Choose with its answer, and a message to the test at each ask.
  defp market(answer) do
    test = self()

    Req.Test.stub(DIY.Market, fn conn ->
      send(test, :asked)
      answer.(conn)
    end)
  end

  test "an old market comes again from Power to Choose, one time", %{conn: conn} do
    market(&Req.Test.json(&1, Stubs.ptc()))
    view = open(conn, house(8))
    render_async(view)
    assert_received :asked

    today = Date.to_iso8601(Date.utc_today())
    assert %{utility: "Oncor", date: ^today, source: "ptc"} = build(view).market
    assert render(view) =~ "(#{today})"

    # A new page of the build does not ask again.
    render_patch(view, ~p"/estimate")
    render_async(view)
    refute_received :asked
  end

  test "a new market, and a market of the user, do not change", %{conn: conn} do
    market(&Req.Test.json(&1, Stubs.ptc()))

    for build <- [house(6), house(30, "user")] do
      view = open(conn, build)
      render_async(view)
      settle(view)
      assert build(view).market == build.market
    end

    refute_received :asked
  end

  test "after an error, the build keeps its old market, with no error on the page", %{
    conn: conn
  } do
    market(&Plug.Conn.send_resp(&1, 500, ""))
    old = house(8)
    view = open(conn, old)
    html = render_async(view)
    assert_received :asked
    assert build(view).market == old.market
    refute html =~ "Power to Choose answered 500."
    assert html =~ "Old utility"

    # The page does not ask again for this ZIP code.
    render_patch(view, ~p"/plans")
    render_async(view)
    refute_received :asked
  end

  # The person can change the ZIP code or the market while the page waits.
  # Then the answer changes nothing.
  test "an answer for a build that changed while the page waited changes nothing" do
    new = %{utility: "Oncor", source: "ptc"}

    for build <- [
          %{zip: "75010", market: %{source: "ptc"}},
          %{zip: "75070", market: %{source: "user"}},
          %{zip: "75070", market: nil}
        ] do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, build: build}}

      assert DIYWeb.HomeLive.handle_async({:market_again, "75070"}, {:ok, {:ok, new}}, socket) ==
               {:noreply, socket}
    end
  end
end
