defmodule DIYWeb.HomeLiveTest do
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}

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

  defp open(conn, path \\ ~p"/", build \\ nil) do
    {:ok, view, _html} = live(conn, path)
    restore(view, build)
    view
  end

  # A build of the preset of a house in a ZIP code, as the device keeps it.
  defp house(zip \\ "75070", house \\ %{}) do
    house = Map.merge(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil}, house)
    {house, rooms, items} = House.preset(house)
    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, zip)
    Build.put_house(build, house, rooms, items)
  end

  # The cache of the weather is for all the tests: a test of an error of the
  # weather uses a ZIP code far from the others.

  # Waits for the weather and the market in the background.
  defp settle(view) do
    _ = :sys.get_state(view.pid)
    Process.sleep(20)
    render(view)
  end

  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build
  defp room(view, name), do: Enum.find(build(view).rooms, &(&1.name == name))
  defp item(view, type), do: Enum.find(build(view).items, &(&1.type == type))

  test "the page waits for the build of the device", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "The page reads your build"
    render_click(view, "door", %{"door" => "my_house"})
    refute_push_event view, "device:save", _payload
  end

  test "my house: the door, the ZIP code and a preset give the bill at once", %{conn: conn} do
    view = open(conn)
    assert has_element?(view, "#door-planning")
    view |> element("#door-my-house") |> render_click()

    html = view |> form("#zip-form", %{"zip" => "1234"}) |> render_submit()
    assert html =~ "The app does not know this ZIP code"

    view |> form("#zip-form", %{"zip" => "75070"}) |> render_submit()
    assert has_element?(view, "#preset-form")
    refute has_element?(view, "#lot")

    html =
      render_submit(view, "preset", %{"preset" => %{"size" => "medium", "start" => "preset"}})

    assert html =~ "Choose one of each"

    view
    |> form("#preset-form", %{
      "preset" => %{"size" => "medium", "age" => "2000s", "floors" => "2", "heat" => "gas"}
    })
    |> render_submit(%{"preset" => %{"start" => "preset"}})

    html = settle(view)
    assert html =~ "Your power bill, in an average month"
    assert has_element?(view, "#bill-average")
    assert has_element?(view, "#bill-month")
    assert html =~ "168 plans"
    assert html =~ "Oncor delivers the power"
    assert has_element?(view, "#go-in")

    assert %{house: %{size: 1800, year: 2005, floors: 2}, market: %{utility: "Oncor"}} =
             build(view)
  end

  test "a house that I plan: the lot, a house from nothing, and an AC for the estimate", %{
    conn: conn
  } do
    view = open(conn)
    view |> element("#door-planning") |> render_click()
    view |> form("#zip-form", %{"zip" => "75070"}) |> render_submit()
    assert has_element?(view, "#lot")

    view
    |> form("#preset-form", %{
      "preset" => %{"lot" => "8000", "size" => "large", "floors" => "1", "heat" => "heat_pump"}
    })
    |> render_submit(%{"preset" => %{"start" => "scratch"}})

    html = settle(view)
    assert html =~ "Add an AC to see the estimate"
    assert %{house: %{lot: 8000, year: year, floors: 1}, items: []} = build(view)
    assert year == Date.utc_today().year

    render_click(view, "add_item", %{"room" => room(view, "Kitchen").id, "type" => "fridge"})
    assert render_patch(view, ~p"/") =~ "Add an AC to see the estimate"

    render_click(view, "add_item", %{"room" => room(view, "Backyard").id, "type" => "ac"})
    render_patch(view, ~p"/")
    assert settle(view) =~ "Your power bill"
  end

  test "a house that I plan, from a preset of a new house", %{conn: conn} do
    view = open(conn)
    view |> element("#door-planning") |> render_click()
    view |> form("#zip-form", %{"zip" => "75070"}) |> render_submit()

    view
    |> form("#preset-form", %{
      "preset" => %{"size" => "small", "floors" => "1", "heat" => "electric"}
    })
    |> render_submit(%{"preset" => %{"start" => "preset"}})

    assert settle(view) =~ "Your power bill"
    assert item(view, "ac").params["seer2"] == 14.3
    assert item(view, "heat_strips")
  end

  test "a bad lot is an error", %{conn: conn} do
    view = open(conn)
    view |> element("#door-planning") |> render_click()
    view |> form("#zip-form", %{"zip" => "75070"}) |> render_submit()

    preset = %{"size" => "small", "floors" => "1", "heat" => "gas", "start" => "preset"}

    for lot <- ["5", "-5", "abc", "1e9"] do
      html = render_submit(view, "preset", %{"preset" => Map.put(preset, "lot", lot)})
      assert html =~ "Give the lot in square feet", lot
    end

    html = render_submit(view, "preset", %{"preset" => Map.delete(preset, "size")})
    assert html =~ "Choose one of each"
    render_submit(view, "preset", %{"preset" => Map.put(preset, "lot", "")})
    assert build(view).house.lot == nil
  end

  test "the door goes in: the rooms, the hint, and the items", %{conn: conn} do
    view = open(conn, ~p"/", house())
    settle(view)
    view |> element("#go-in") |> render_click()
    assert_patch view, ~p"/inside"

    html = render(view)
    assert html =~ "Swipe left or right"
    assert has_element?(view, "#level-f1")
    assert has_element?(view, "#pill")
    assert html =~ "Kitchen"
    assert html =~ "Typical"

    view |> element("#swipe-hint button") |> render_click()
    refute has_element?(view, "#swipe-hint")
    assert build(view).hints == ["swipe"]
    render_click(view, "hint", %{"hint" => "other"})
  end

  test "an item: its numbers, its math, a check, a move, and a remove", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    settle(view)
    fridge = item(view, "fridge")

    view |> element("#item-#{fridge.id}") |> render_click()
    assert_patch view, ~p"/inside?item=#{fridge.id}"
    html = render(view)
    assert html =~ "Energy in one year"
    assert html =~ "kWh in one year"
    assert html =~ "the usage estimate"
    assert html =~ "These numbers are a guess"

    html = view |> form("#item-form", %{"item" => %{"kwh_year" => "9999"}}) |> render_change()
    assert html =~ "Give a number from 100 to 2500"

    view |> form("#item-form", %{"item" => %{"kwh_year" => "650"}}) |> render_change()
    assert %{params: %{"kwh_year" => 650}, typical: false} = item(view, "fridge")
    refute render(view) =~ "These numbers are a guess"

    garage = room(view, "Garage")
    view |> form("#move-form", %{"room" => garage.id}) |> render_change()
    assert item(view, "fridge").room == garage.id

    view |> element("#delete-item") |> render_click()
    assert_patch view, ~p"/inside"
    refute item(view, "fridge")

    render_click(view, "item", %{"item_id" => "i999", "item" => %{}})
    render_click(view, "delete_item", %{"id" => "i999"})
    render_click(view, "move_item", %{"item_id" => "i999", "room" => garage.id})
  end

  test "an item of the kind Other has a name, and a typical item can be checked", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    settle(view)
    other = item(view, "other")
    view |> element("#item-#{other.id}") |> render_click()
    html = view |> form("#item-form", %{"item" => %{"name" => " "}}) |> render_change()
    assert html =~ "Give a name"

    tv = item(view, "tv")
    render_patch(view, ~p"/inside?item=#{tv.id}")
    html = view |> form("#item-form", %{"item" => %{"watts" => "-1"}}) |> render_change()
    assert html =~ "Give a number from"
    # The error stays with its item: a different item has no error.
    lights = item(view, "lights")
    refute render_patch(view, ~p"/inside?item=#{lights.id}") =~ "Give a number from"
    render_patch(view, ~p"/inside?item=#{tv.id}")
    view |> element("#item-sheet button", "Correct") |> render_click()
    refute item(view, "tv").typical
    render_click(view, "check_item", %{"id" => "i999"})

    ac = item(view, "ac")
    render_patch(view, ~p"/inside?item=#{ac.id}")
    view |> form("#item-form", %{"item" => %{"heat_pump" => "true"}}) |> render_change()
    assert item(view, "ac").params["heat_pump"]
    assert render(view) =~ "kWh of cooling + "

    furnace = item(view, "furnace")
    assert render_patch(view, ~p"/inside?item=#{furnace.id}") =~ "for January"

    assert render_patch(view, ~p"/inside?item=i999") =~ "Kitchen"
    refute has_element?(view, "#item-sheet")
  end

  test "add an item to a room", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    settle(view)
    backyard = room(view, "Backyard")

    view |> element("#add-#{backyard.id}") |> render_click()
    assert_patch view, ~p"/inside?add=#{backyard.id}"
    assert has_element?(view, "#add-pool_pump")
    refute has_element?(view, "#add-fridge")

    view |> element("#add-pool_pump") |> render_click()
    pool = item(view, "pool_pump")
    assert_patch view, ~p"/inside?item=#{pool.id}"
    refute pool.typical

    render_click(view, "add_item", %{"room" => backyard.id, "type" => "fridge"})
    assert render_patch(view, ~p"/inside?add=r999") =~ "Kitchen"
    refute has_element?(view, "#add-sheet")
  end

  test "rooms: add, rename and remove", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    settle(view)

    view
    |> form("#new-room-f2", %{"room" => %{"name" => "Office", "place" => "indoor"}})
    |> render_submit()

    office = room(view, "Office")
    assert office.level == "f2"

    html =
      view
      |> form("#new-room-f2", %{"room" => %{"name" => " ", "place" => "indoor"}})
      |> render_submit()

    assert html =~ "Give the room a name"

    view |> form("#rename-#{office.id}", %{"name" => "Studio"}) |> render_submit()
    assert room(view, "Studio")

    view |> element("#delete-#{office.id}") |> render_click()
    refute room(view, "Studio")
    render_click(view, "rename_room", %{"room_id" => "r999", "name" => "x"})
  end

  test "the smart meter turns on the real usage", %{conn: conn} do
    view = open(conn, ~p"/", house())
    html = settle(view)
    assert html =~ "add your smart meter"
    backyard = room(view, "Backyard")

    render_click(view, "add_item", %{"room" => backyard.id, "type" => "smart_meter"})
    meter = item(view, "smart_meter")
    assert_patch view, ~p"/inside?item=#{meter.id}"
    html = render(view)
    assert html =~ "your real usage, from the file of the meter"
    assert has_element?(view, "#usage-file[phx-hook=UsageFile]")
    refute has_element?(view, "#usage-months")
    assert render_patch(view, ~p"/") =~ "Open the file of your smart meter"

    months =
      for m <- 1..12 do
        name = "2025-#{String.pad_leading("#{m}", 2, "0")}"

        %{
          "month" => name,
          "kwh" => 800 + m * 50,
          "export" => 0,
          "days" => DIY.Usage.days_in(name)
        }
      end

    html = render_hook(view, "usage", %{"source" => "smt", "months" => months})
    assert html =~ "The page has 12 months of your usage"
    assert html =~ "From your meter, in an average month"
    assert %{source: "smt", months: [_ | _]} = build(view).usage

    html = render_patch(view, ~p"/estimate")
    assert has_element?(view, "#real-months")
    assert html =~ "real months in the range of the estimate"
    assert has_element?(view, "#fit")

    render_patch(view, ~p"/inside?item=#{meter.id}")
    assert render(view) =~ "Smart Meter Texas: 12 months, from January 2025 to December 2025"
    assert has_element?(view, ~s(#delete-item[data-confirm*="the real usage goes too"]))
    view |> element("#usage-months button", "Remove the real usage") |> render_click()
    assert build(view).usage == nil

    # The Bill page can remove the usage too, and so does the removal of the
    # meter.
    render_hook(view, "usage", %{"source" => "smt", "months" => months})
    render_patch(view, ~p"/estimate")
    view |> element("button", "Remove the real usage") |> render_click()
    assert build(view).usage == nil
    render_hook(view, "usage", %{"source" => "smt", "months" => months})
    render_click(view, "delete_item", %{"id" => meter.id})
    assert build(view).usage == nil

    # A month that is not "YYYY-MM", or with more days than the month has:
    # no crash, and no usage.
    for month <- [
          %{hd(months) | "month" => "-2025-07", "days" => 25},
          %{hd(months) | "month" => "2025-02", "days" => 31}
        ] do
      assert render_hook(view, "usage", %{"source" => "smt", "months" => [month]}) =~
               "The app cannot read the usage of this file"
    end

    assert build(view).usage == nil

    assert render_hook(view, "usage", %{"source" => "x"}) =~
             "The app cannot read the usage of this file"

    assert render_hook(view, "usage_error", %{
             "error" => "The file has no usage that the app can read."
           }) =~
             "The file has no usage"
  end

  test "a house with no room outside adds the meter inside", %{conn: conn} do
    build = house()

    build =
      Enum.reduce(Enum.filter(build.rooms, &(&1.place == :outdoor)), build, fn room, b ->
        elem(Build.delete_room(b, room.id), 1)
      end)

    view = open(conn, ~p"/", build)
    settle(view)
    inside = Enum.find(build.rooms, &(&1.place == :indoor))
    assert has_element?(view, ~s(#real a[href="/inside?add=#{inside.id}"]), "Add the meter")
  end

  test "a few months of usage show their mean, and a partial month has a note", %{conn: conn} do
    {:ok, usage} =
      DIY.Usage.read(%{
        "source" => "green_button",
        "months" => [
          %{"month" => "2025-07", "kwh" => 600, "export" => 0, "days" => 10}
        ]
      })

    view = open(conn, ~p"/estimate", Build.set_usage(house(), usage))
    html = settle(view)
    assert html =~ "July 2025 (part of the month)"
    assert html =~ "For a part of a month"
    refute has_element?(view, "#fit")
    assert has_element?(view, "#no-fit", "The weather of the app ends with 2025")
    html = render_patch(view, ~p"/")
    assert html =~ "1 month of real usage"
    assert html =~ "From your meter: the one month of the file"

    {:ok, two} =
      DIY.Usage.read(%{
        "source" => "csv",
        "months" => [
          %{"month" => "2025-07", "kwh" => 600, "export" => 0, "days" => 31},
          %{"month" => "2025-08", "kwh" => 700, "export" => 0, "days" => 31}
        ]
      })

    view = open(conn, ~p"/", Build.set_usage(house(), two))
    assert settle(view) =~ "From your meter: the mean of the 2 months of the file"
  end

  test "the math of the estimate", %{conn: conn} do
    view = open(conn, ~p"/estimate", house())
    html = settle(view)
    assert has_element?(view, "#months")
    assert html =~ "NASA POWER"
    assert html =~ "Cooling"
    assert html =~ "(typical)"
    assert html =~ "for its age"
  end

  test "the math of a house with no items", %{conn: conn} do
    {house, rooms, _items} =
      House.preset(%{size: 1800, year: 2005, floors: 1, heat: "gas", lot: nil})

    empty = Build.put_house(house(), house, rooms, [])
    view = open(conn, ~p"/estimate", empty)
    assert settle(view) =~ "Cooling: 0 kWh (0%)"
  end

  test "an AC that is small for the house has a note", %{conn: conn} do
    build = house()
    ac = Enum.find(build.items, &(&1.type == "ac"))
    {:ok, build} = Build.update_item(build, ac.id, %{"tons" => "1"})
    view = open(conn, ~p"/", build)
    assert settle(view) =~ "is small for the house"
  end

  test "the math waits for the weather", %{conn: conn} do
    Stubs.weather(503)
    view = open(conn, ~p"/estimate", house("99501"))
    assert settle(view) =~ "The estimate shows here when the house has its weather"
  end

  test "an error of the weather shows, and the page can try again", %{conn: conn} do
    Stubs.weather(503)
    view = open(conn, ~p"/", house("96701"))
    html = settle(view)
    assert html =~ "The weather service answered 503."

    Stubs.weather()
    view |> element("#bill button", "Try again") |> render_click()
    assert settle(view) =~ "Your power bill"
  end

  test "a weather service that stops gives an error", %{conn: conn} do
    Req.Test.stub(DIY.Weather, fn _conn -> exit(:boom) end)
    view = open(conn, ~p"/", house("04101"))
    assert settle(view) =~ "The weather service did not answer."
  end

  test "an error of Power to Choose shows, and the estimate uses the price of Texas", %{
    conn: conn
  } do
    Stubs.market(500)
    view = open(conn, ~p"/", house("75007"))
    html = settle(view)
    assert html =~ "Power to Choose answered 500."
    assert html =~ "Texas, January to July 2026"

    Req.Test.stub(DIY.Market, fn _conn -> exit(:boom) end)
    view |> element("#market button", "Try again") |> render_click()
    assert settle(view) =~ "Power to Choose did not answer."
  end

  test "a Texas area with no retail choice, and a place out of Texas", %{conn: conn} do
    Stubs.market(%{"success" => true, "data" => []})
    view = open(conn, ~p"/", house("78701"))
    assert settle(view) =~ "Your area has no retail choice"

    view = open(conn, ~p"/", house("10001"))
    html = settle(view)
    refute has_element?(view, "#market")
    assert html =~ "New York"
  end

  test "a market for an old ZIP code does not go into the build", %{conn: conn} do
    Req.Test.stub(DIY.Market, fn conn ->
      Process.sleep(150)
      Req.Test.json(conn, Stubs.ptc())
    end)

    view = open(conn, ~p"/settings", house("75009"))
    view |> form("#settings-zip", %{"zip" => "75010"}) |> render_submit()
    Process.sleep(400)
    settle(view)
    assert %{zip: "75010", market: %{utility: "Oncor"}} = build(view)
  end

  test "the same ZIP code again keeps the market", %{conn: conn} do
    view = open(conn, ~p"/settings", house("75013"))
    settle(view)
    assert %{utility: "Oncor"} = market = build(view).market
    view |> form("#settings-zip", %{"zip" => "75013"}) |> render_submit()
    settle(view)
    assert build(view).market == market
    refute render_patch(view, ~p"/") =~ "The page asks Power to Choose"
  end

  test "the answer for a ZIP code that the build left is thrown away", %{conn: conn} do
    Req.Test.stub(DIY.Market, fn conn ->
      Process.sleep(100)
      Req.Test.json(conn, Stubs.ptc())
    end)

    view = open(conn, ~p"/settings", house("75023"))
    view |> form("#settings-zip", %{"zip" => "10001"}) |> render_submit()
    Process.sleep(300)
    settle(view)
    assert build(view).market == nil

    # The build gets the ZIP code back: the page asks again.
    view |> form("#settings-zip", %{"zip" => "75023"}) |> render_submit()
    Process.sleep(300)
    settle(view)
    assert %{zip: "75023", market: %{utility: "Oncor"}} = build(view)
  end

  test "the events of a house come only after the house", %{conn: conn} do
    view = open(conn)
    view |> element("#door-my-house") |> render_click()
    view |> form("#zip-form", %{"zip" => "75070"}) |> render_submit()
    room = %{"name" => "Office", "level" => "f1", "place" => "indoor"}
    assert render_hook(view, "add_room", %{"room" => room}) =~ "Choose a house first."
    assert render_hook(view, "house", %{"house" => %{"size" => "2000"}}) =~ "Give numbers"
    assert build(view).house == nil

    view = open(conn, ~p"/inside", house())
    settle(view)

    assert render_hook(view, "add_room", %{"room" => %{room | "level" => "f9"}}) =~
             "Choose a floor of the house."

    assert render_hook(view, "add_room", %{"room" => %{room | "place" => "moon"}}) =~
             "Choose a place: inside, outside or the roof."

    assert render_hook(view, "add_room", %{"room" => %{room | "name" => " "}}) =~
             "Give the room a name."
  end

  test "the settings: ZIP code, utility, price, house, file and start again", %{conn: conn} do
    view = open(conn, ~p"/settings", house())
    html = settle(view)
    assert html =~ "The price of power"
    assert has_element?(view, "#export")

    view |> form("#settings-price", %{"price" => "12.5"}) |> render_submit()
    assert build(view).price == 12.5
    assert render(view) =~ "the price that you gave"

    assert view |> form("#settings-price", %{"price" => "cheap"}) |> render_submit() =~
             "Give the price in cents"

    view |> form("#settings-price", %{"price" => ""}) |> render_submit()
    assert build(view).price == nil

    view |> element("#utility button", "city utility") |> render_click()
    assert %{choice: false, source: "user"} = build(view).market
    view |> element("#utility button", "I choose") |> render_click()
    assert %{choice: true} = build(view).market

    view
    |> form("#settings-house", %{
      "house" => %{"size" => "2100", "year" => "1999", "floors" => "3", "heat" => "electric"}
    })
    |> render_submit()

    assert %{size: 2100, year: 1999, floors: 3, heat: "electric"} = build(view).house
    html = view |> form("#settings-house", %{"house" => %{"floors" => "1"}}) |> render_submit()
    assert html =~ "Remove the rooms of the top floor first"
    html = view |> form("#settings-house", %{"house" => %{"size" => "big"}}) |> render_submit()
    assert html =~ "Give numbers in the limits"

    view |> form("#settings-zip", %{"zip" => "10001"}) |> render_submit()
    assert build(view).zip == "10001"

    view |> element("#restart") |> render_click()
    assert_patch view, ~p"/"
    assert has_element?(view, "#door-my-house")
  end

  test "a file of a build opens on the page", %{conn: conn} do
    view = open(conn, ~p"/settings", house())
    settle(view)
    other = house("10001", %{size: 3500})

    file =
      file_input(view, "#import", :build_file, [
        %{name: "build.json", content: Build.export(other), type: "application/json"}
      ])

    render_upload(file, "build.json")
    assert build(view).zip == "10001"
    assert render(view) =~ "The page shows the build of the file now"

    bad =
      file_input(view, "#import", :build_file, [
        %{name: "bad.json", content: "{}", type: "application/json"}
      ])

    render_upload(bad, "bad.json")
    assert render(view) =~ "The file is not a build of this app"

    render_change(view, "upload", %{})
  end

  test "a build from a different tab updates the estimate", %{conn: conn} do
    view = open(conn, ~p"/", house())
    settle(view)
    # The revision of the other tab is larger.
    other = %{house("10001") | revision: 99}
    render_hook(view, "device:changed", %{"text" => Build.to_json(other), "stamp" => other.stamp})
    assert settle(view) =~ "New York"
  end

  test "an event that the page does not know changes nothing", %{conn: conn} do
    view = open(conn)
    render_click(view, "door", %{})
    render_click(view, "garage", %{})
    render_click(view, "door", %{"door" => "garage"})
    refute_push_event view, "device:save", _payload
  end
end
