defmodule DIYWeb.SkyLiveTest do
  @moduledoc "The sky at the house on the page House and in a shared link (DIY.Sky)."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Share, Stubs}

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp house(zip \\ "75070") do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, zip)
    Build.put_house(build, house, rooms, items)
  end

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    restore(view, build)
    settle(view)
    view
  end

  defp restore(view, build) do
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
  end

  defp sky(view), do: :sys.get_state(view.pid).socket.assigns.sky

  defp scene(view) do
    html = view |> element("#house-picture svg") |> render()
    [_, time] = Regex.run(~r/data-scene="(\w+)"/, html)
    [_, weather] = Regex.run(~r/data-weather="(\w+)"/, html)
    {time, weather}
  end

  test "the picture of the house has the sky at the house now", %{conn: conn} do
    view = open(conn, ~p"/", house())
    assert scene(view) == {"day", "sun"}
    assert has_element?(view, "#sky-form option[value=now][selected]", "Now (Day)")
    assert has_element?(view, "#sky-form option[value=now]", "Now (Sun)")
    assert has_element?(view, "#sky-form-now", "Now at the house: 59 °F, day, sun.")

    assert has_element?(
             view,
             ~s(#house-picture[aria-label$="you in front of the door, on a day with a clear sky."])
           )

    # A night with rain.
    Stubs.sky(Stubs.open_meteo(time: "night", code: 63))
    view = open(conn, ~p"/", house("75071"))
    assert scene(view) == {"night", "rain"}
    assert has_element?(view, ~s(#house-picture[aria-label$="on a night with rain."]))
    refute render(view) =~ "p-moon"
    assert render(view) =~ ~s(class="p-rain")

    # Near the sunrise, the sky of now is a sunrise; the picture is the
    # same as at a sunset.
    Req.Test.stub(DIY.Sky, &Req.Test.json(&1, Stubs.open_meteo(time: "dawn")))
    view = open(conn, ~p"/", house("75075"))
    assert scene(view) == {"sunset", "sun"}
    assert has_element?(view, "#sky-form option[value=now]", "Now (Sunrise)")
    assert has_element?(view, "#sky-form-now", "Now at the house: 59 °F, sunrise, sun.")
  end

  test "the person chooses a time of day and a weather, and then now again", %{conn: conn} do
    view = open(conn, ~p"/", house())

    view |> form("#sky-form", %{"time" => "night", "weather" => "snow"}) |> render_change()
    assert scene(view) == {"night", "snow"}
    assert has_element?(view, "#sky-form option[value=night][selected]")

    view |> form("#sky-form", %{"time" => "sunset", "weather" => "now"}) |> render_change()
    assert scene(view) == {"sunset", "sun"}
    assert render(view) =~ ~s(class="p-dusk")

    # A value that the app does not know is "now".
    render_change(view, "sky_pick", %{"time" => "noon", "weather" => 5})
    assert scene(view) == {"day", "sun"}
    render_change(view, "sky_pick", %{})
    assert scene(view) == {"day", "sun"}
  end

  test "with no answer of the sky, the picture is a day with sun", %{conn: conn} do
    Stubs.sky(503)
    view = open(conn, ~p"/", house("75072"))
    assert sky(view).status == :error
    assert scene(view) == {"day", "sun"}
    assert has_element?(view, "#sky-form option[value=now]", ~r/^\s*Now\s*$/)
    refute has_element?(view, "#sky-form-now")
    # The page asks again in 5 minutes.
    assert Process.read_timer(sky(view).timer) in (4 * 60_000)..(5 * 60_000)
  end

  test "an error keeps the sky of before", %{conn: conn} do
    Stubs.sky(Stubs.open_meteo(time: "night"))
    view = open(conn, ~p"/", house())
    assert scene(view) == {"night", "sun"}
    old_local = sky(view).now.local
    Stubs.sky(503)
    send(view.pid, {:sky_again, "75070"})
    settle(view)
    assert sky(view).status == :error
    assert scene(view) == {"night", "sun"}
    # The sky of before has the clock of now.
    assert NaiveDateTime.diff(sky(view).now.local, old_local, :microsecond) > 0
  end

  test "with no change of the time of day (near a pole), the page asks again in 30 minutes",
       %{conn: conn} do
    Stubs.sky(Stubs.open_meteo(time: "polar"))
    view = open(conn, ~p"/", house())
    assert scene(view) == {"night", "sun"}
    assert Process.read_timer(sky(view).timer) > 29 * 60_000
  end

  test "the page asks again at the next change of the time of day", %{conn: conn} do
    # The sunset is in 35 minutes: the time of day changes in 5 minutes.
    at = DateTime.add(DateTime.utc_now(), 25, :minute)
    Req.Test.stub(DIY.Sky, &Req.Test.json(&1, Stubs.open_meteo(time: "sunset", at: at)))
    view = open(conn, ~p"/", house())
    assert scene(view) == {"day", "sun"}
    assert Process.read_timer(sky(view).timer) in (4 * 60_000)..(5 * 60_000 + 2_000)
  end

  test "the link of a share carries the sky of the picture", %{conn: conn} do
    view = open(conn, ~p"/?sheet=share", house())
    assert has_element?(view, "#share-sky")

    view |> form("#share-sky", %{"time" => "night", "weather" => "clouds"}) |> render_change()
    assert scene(view) == {"night", "clouds"}
    url = view |> element("#share-link") |> render() |> attr("value")
    "http://www.example.com/s/" <> data = url
    assert {:ok, _build, %{sky: %{time: "night", weather: "clouds"}}} = Share.decode(data)
    assert has_element?(view, ~s(#share-sheet img[src="/s/#{data}/picture.png"]))

    # With no ZIP code in the link, "now" is a day with sun: the sky of now
    # can tell the place.
    Stubs.sky(Stubs.open_meteo(time: "night", code: 71))
    view = open(conn, ~p"/?sheet=share", house("75074"))
    assert scene(view) == {"night", "snow"}
    assert {:ok, _build, %{sky: %{time: "night", weather: "snow"}}} = link(view)
    view |> form("#share-zip", %{"zip" => "false"}) |> render_change()
    assert {:ok, _build, %{sky: %{time: "day", weather: "sun"}}} = link(view)
    # The choice "Now" of the sheet does not name the sky of now.
    assert has_element?(view, "#share-sky option[value=now]", ~r/^\s*Now\s*$/)
    refute has_element?(view, "#share-sky-now")
    view |> form("#share-sky", %{"time" => "night", "weather" => "now"}) |> render_change()
    assert {:ok, _build, %{sky: %{time: "night", weather: "sun"}}} = link(view)

    # The page of the link draws the house with the sky of the link.
    {:ok, shared, _html} = live(build_conn(), ~p"/s/#{data}")
    html = shared |> element("#shared svg") |> render()
    assert html =~ ~s(data-scene="night")
    assert html =~ ~s(data-weather="clouds")
    assert has_element?(shared, ~s(#shared [role=img][aria-label$=", on a night with clouds"]))
  end

  test "the page asks for the sky again after 30 minutes, and keeps the sky of before",
       %{conn: conn} do
    view = open(conn, ~p"/", house())
    %{zip: "75070", status: :ok, timer: timer} = sky(view)
    assert Process.read_timer(timer) > 29 * 60_000

    test = self()

    # The service answers when the test tells it to.
    Req.Test.stub(DIY.Sky, fn conn ->
      send(test, {:asked, self()})

      receive do
        :answer -> Req.Test.json(conn, Stubs.open_meteo(time: "sunset", code: 3))
      end
    end)

    send(view.pid, {:sky_again, "75070"})
    assert_receive {:asked, service}, 2_000
    # While the page asks, the picture keeps the sky of before.
    assert scene(view) == {"day", "sun"}
    send(service, :answer)
    settle(view)
    assert scene(view) == {"sunset", "clouds"}
    new = sky(view).timer
    assert new != timer and is_integer(Process.read_timer(new))

    # A timer for a different ZIP code asks nothing.
    send(view.pid, {:sky_again, "99999"})
    refute_receive {:asked, _service}, 200
  end

  test "a new ZIP code asks for its sky, and cancels the timer of the old one", %{conn: conn} do
    view = open(conn, ~p"/", house())
    timer = sky(view).timer
    render_click(view, "zip", %{"zip" => "10001"})
    settle(view)
    assert sky(view).zip == "10001"
    assert Process.read_timer(timer) == false

    # A build with no ZIP code has no sky.
    timer = sky(view).timer
    render_click(view, "restart", %{})
    assert sky(view) == %{zip: nil, status: :none, now: nil, timer: nil}
    assert Process.read_timer(timer) == false
  end

  test "the answer for a ZIP code that the page left goes away" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, sky: %{zip: "10001", status: :loading, now: nil, timer: nil}}
    }

    assert {:noreply, ^socket} =
             DIYWeb.HomeLive.handle_async({:sky, "75070"}, {:ok, {:error, "x"}}, socket)
  end

  defp link(view) do
    "http://www.example.com/s/" <> data =
      view |> element("#share-link") |> render() |> attr("value")

    Share.decode(data)
  end

  defp attr(html, name) do
    [_, value] = Regex.run(~r/#{name}="([^"]*)"/, html)
    value
  end
end
