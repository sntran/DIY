defmodule DIYWeb.HomeLiveTest do
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}
  alias DIYWeb.Format

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

  test "the House page: the house from the outside, and a tap on it goes in", %{conn: conn} do
    view = open(conn, ~p"/", house())
    settle(view)

    # The picture has the look of the plan, with the pole of the grid. Only
    # the page House makes it.
    assert has_element?(view, "#house-picture svg.cutaway-outside")
    assert has_element?(view, "#house-picture .p-chip-text", "Grid")
    assert :sys.get_state(view.pid).socket.assigns.outside

    view |> element("#house-picture") |> render_click()
    assert_patch view, ~p"/inside"
    assert has_element?(view, "#plan-svg")
    assert :sys.get_state(view.pid).socket.assigns.outside == nil
  end

  test "the door goes in: the rooms, the hint, and the items", %{conn: conn} do
    view = open(conn, ~p"/", house())
    settle(view)
    view |> element("#go-in") |> render_click()
    assert_patch view, ~p"/inside"

    html = render(view)
    assert html =~ "Drag an item to move it"
    assert has_element?(view, "#plan-svg[data-axes][data-arrows='1 0 0 1']")
    assert has_element?(view, "#list-f1")
    assert has_element?(view, "#pill")
    assert html =~ "Kitchen"
    assert html =~ "typical"

    view |> element("#plan-hint button") |> render_click()
    refute has_element?(view, "#plan-hint")
    assert build(view).hints == ["plan"]
    render_click(view, "hint", %{"hint" => "other"})
  end

  test "an item: its numbers, its math, a check, a move, and a remove", %{conn: conn} do
    view = open(conn, ~p"/inside", house())
    settle(view)
    fridge = item(view, "fridge")

    view |> element("#item-#{fridge.id}") |> render_click()
    assert_patch view, ~p"/inside?item=#{fridge.id}"
    html = render(view)
    # The plan shows the layer of the open item (the hook). An id that is
    # not an item of the house does not go to the plan.
    assert html =~ ~s(data-open="#{fridge.id}")
    refute render_patch(view, ~p"/inside?#{[item: ~s(x"])]}") =~ "data-open"
    html = render_patch(view, ~p"/inside?item=#{fridge.id}")
    assert html =~ "Energy in one year"
    assert html =~ "kWh in one year"
    assert html =~ "the estimate of your power bill"
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
    view |> element("#item-sheet button", "They are right") |> render_click()
    refute item(view, "tv").typical
    render_click(view, "check_item", %{"id" => "i999"})

    ac = item(view, "ac")
    render_patch(view, ~p"/inside?item=#{ac.id}")
    view |> form("#item-form", %{"item" => %{"heat_pump" => "true"}}) |> render_change()
    assert item(view, "ac").params["heat_pump"]
    assert render(view) =~ "kWh of cooling + "

    furnace = item(view, "furnace")

    assert render_patch(view, ~p"/inside?item=#{furnace.id}") =~
             "for one month: January, a cold month."

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

    view |> element("#add-room") |> render_click()
    assert_patch view, ~p"/inside?sheet=new_room"

    view
    |> form("#new-room", %{"room" => %{"name" => "Office", "level" => "f2", "place" => "indoor"}})
    |> render_submit()

    office = room(view, "Office")
    assert office.level == "f2"
    # The new room is the chosen room: the person then moves it.
    assert_patch view, ~p"/inside?room=#{office.id}"
    assert has_element?(view, "#room-bar", "Office")

    render_patch(view, ~p"/inside?sheet=new_room")

    html =
      view
      |> form("#new-room", %{"room" => %{"name" => " ", "level" => "f2", "place" => "indoor"}})
      |> render_submit()

    assert html =~ "Give the room a name"

    render_patch(view, ~p"/inside?#{[room: office.id]}")
    view |> element("#bar-change") |> render_click()
    view |> form("#rename-#{office.id}", %{"name" => "Studio"}) |> render_submit()
    assert room(view, "Studio")

    view |> element("#delete-#{office.id}") |> render_click()
    refute room(view, "Studio")
    render_click(view, "rename_room", %{"room_id" => "r999", "name" => "x"})
  end

  test "the smart meter turns on the real usage", %{conn: conn} do
    view = open(conn, ~p"/", house())
    html = settle(view)
    assert html =~ "A next small step: see the real use of your house."
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

  test "the chart of the bill: a button for each month gives its dollars", %{conn: conn} do
    view = open(conn, ~p"/", house())
    settle(view)
    months = :sys.get_state(view.pid).socket.assigns.bill.months
    now = Date.utc_today().month
    # A month that is not this month.
    other = rem(now, 12) + 1

    line = fn n ->
      "#{Enum.at(months, n - 1).name}: #{Format.money(Enum.at(months, n - 1).cost)}"
    end

    # The line starts with this month. Each button tells its month and its
    # dollars to a screen reader.
    assert has_element?(view, "#bill-month[aria-live=polite]", line.(now))
    assert has_element?(view, ~s(#chart-#{now}[aria-pressed="true"]))

    assert has_element?(
             view,
             ~s(#chart-#{other}[aria-label="#{line.(other)}"][aria-pressed="false"])
           )

    view |> element("#chart-#{other}") |> render_click()
    assert has_element?(view, "#bill-month", line.(other))
    assert has_element?(view, ~s(#chart-#{other}[aria-pressed="true"] .bg-primary))
    assert has_element?(view, ~s(#chart-#{now}[aria-pressed="false"]))

    # A month that is not a month: no change.
    render_click(view, "bill_month", %{"month" => "13"})
    assert has_element?(view, "#bill-month", line.(other))

    # A new build starts again with this month.
    view |> element("#chart-#{other}") |> render_click()
    render_patch(view, ~p"/settings")

    file =
      file_input(view, "#import", :build_file, [
        %{name: "build.json", content: Build.export(house()), type: "application/json"}
      ])

    render_upload(file, "build.json")
    assert :sys.get_state(view.pid).socket.assigns.bill_month == nil

    render_click(view, "bill_month", %{"month" => "#{other}"})
    view |> element("#restart") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.bill_month == nil
  end

  test "the price of the last bill of the person", %{conn: conn} do
    view = open(conn, ~p"/", house())
    settle(view)
    assert has_element?(view, "#my-bill", "Is this near your bill?")
    assert has_element?(view, "#my-bill", "The app also fits the estimate to its kWh.")

    # A bill of $150.00 for 1,100 kWh: 13.6¢ for each kWh. The month is the
    # month before now.
    last = rem(Date.utc_today().month + 10, 12) + 1
    view |> form("#my-bill", %{"dollars" => "$150.00", "kwh" => "1,100"}) |> render_submit()
    assert_in_delta build(view).price, 150 / 1100 * 100, 1.0e-9
    assert build(view).bill == %{month: last, kwh: 1100.0}

    assert render(view) =~ "The app now uses the price of your bill: 13.6¢ for each kWh."
    assert has_element?(view, "#bill-fit")

    # The form stays, closed, to change the numbers.
    refute has_element?(view, "#my-bill", "Is this near your bill?")
    assert has_element?(view, "#my-bill-again summary", "Type the numbers of my bill")
    assert has_element?(view, ~s(#my-bill select[name="month"] option[value="#{last}"][selected]))

    # A bill of July: the estimate of July is the bill.
    view
    |> form("#my-bill", %{"dollars" => "168", "kwh" => "1150", "month" => "7"})
    |> render_submit()

    assert has_element?(
             view,
             "#bill-fit",
             "The app changed its model to fit your bill of July: 1,150 kWh."
           )

    estimate = :sys.get_state(view.pid).socket.assigns.estimate
    assert estimate.fit.factor < 1
    render_patch(view, ~p"/estimate")
    assert render(view) =~ "The app also multiplies by 0."
    render_patch(view, ~p"/")

    # A bill of a mild month: the app keeps its model.
    view
    |> form("#my-bill", %{"dollars" => "100", "kwh" => "700", "month" => "4"})
    |> render_submit()

    assert has_element?(view, "#bill-fit", "In April, the heat and the cooling are a small part")
    assert :sys.get_state(view.pid).socket.assigns.estimate.fit.factor == 1.0

    # A bill that the model cannot meet: the app tells it.
    view
    |> form("#my-bill", %{"dollars" => "15", "kwh" => "100", "month" => "7"})
    |> render_submit()

    assert has_element?(view, "#bill-fit", "but the estimate of July cannot be less than")

    # No price in the settings: no bill either.
    render_patch(view, ~p"/settings")
    assert render(view) =~ "Then the app also forgets the kWh of your bill."
    view |> form("#settings-price", %{"price" => ""}) |> render_submit()
    assert {build(view).price, build(view).bill} == {nil, nil}

    # With no month (a page of an older version), only the price: the app
    # forgets the old bill.
    render_patch(view, ~p"/")

    view
    |> form("#my-bill", %{"dollars" => "168", "kwh" => "1150", "month" => "7"})
    |> render_submit()

    assert build(view).bill == %{month: 7, kwh: 1150.0}
    render_hook(view, "my_bill", %{"dollars" => "150", "kwh" => "1000"})
    assert render(view) =~ "The app now uses the price of your bill: 15.0¢ for each kWh."
    assert build(view).bill == nil
    refute has_element?(view, "#bill-fit")

    # A total or a kWh that is not a number, that is 0, or that is too
    # large: an error, and the price stays.
    view = open(conn, ~p"/", house())
    settle(view)

    for {dollars, kwh} <- [
          {"", "1000"},
          {"abc", "1000"},
          {"150", "0"},
          {"150", "12x"},
          {"1e307", "1"},
          {"150", "1e-320"}
        ] do
      view |> form("#my-bill", %{"dollars" => dollars, "kwh" => kwh}) |> render_submit()
      assert render(view) =~ "Give the total of the bill in dollars and its kWh"
      assert build(view).price == nil
    end

    # A typo gives a price that no bill has: the page asks to check it.
    for {dollars, kwh, cents} <- [{"150", "11,000", "1.4¢"}, {"9000", "1000", "900.0¢"}] do
      view |> form("#my-bill", %{"dollars" => dollars, "kwh" => kwh}) |> render_submit()

      assert render(view) =~
               "These numbers give #{cents} for each kWh. Check the total and the kWh"

      assert build(view).price == nil
    end
  end

  test "the bill of a house that the person plans gives only the price", %{conn: conn} do
    {:ok, plan} = Build.choose_door(house(), "planning")
    view = open(conn, ~p"/", plan)
    settle(view)
    refute has_element?(view, "#my-bill", "The app also fits the estimate to its kWh.")
    refute has_element?(view, ~s(#my-bill select[name="month"]))

    view |> form("#my-bill", %{"dollars" => "150", "kwh" => "1000"}) |> render_submit()
    assert {build(view).price, build(view).bill} == {15.0, nil}
    refute has_element?(view, "#bill-fit")

    # A bill with a month (a page of an older version): only the price too.
    render_hook(view, "my_bill", %{"dollars" => "100", "kwh" => "900", "month" => "7"})
    assert build(view).bill == nil
  end

  test "a camper van: the front page tells where it goes", %{conn: conn} do
    view = open(conn, ~p"/", house())
    settle(view)
    driveway = room(view, "Driveway")
    assert has_element?(view, "#van-card", "It goes in the driveway.")
    view |> element("#add-van") |> render_click()
    van = item(view, "camper_van")
    assert van.room == driveway.id
    assert_patch view, ~p"/inside?#{[item: van.id]}"
    # A house with a van: no card.
    view = open(conn, ~p"/", build(view))
    settle(view)
    refute has_element?(view, "#van-card")

    # With no driveway: the first room outside. With no room outside: no
    # card.
    build = house()
    {:ok, build} = Build.delete_room(build, Enum.find(build.rooms, &(&1.name == "Driveway")).id)
    view = open(conn, ~p"/", build)
    settle(view)
    assert has_element?(view, "#van-card", "It goes in the backyard.")

    build =
      Enum.reduce(Enum.filter(build.rooms, &(&1.place == :outdoor)), build, fn room, b ->
        elem(Build.delete_room(b, room.id), 1)
      end)

    view = open(conn, ~p"/", build)
    settle(view)
    refute has_element?(view, "#van-card")
  end

  test "the heat efficiency shows only for an AC that heats", %{conn: conn} do
    build = house()
    ac = Enum.find(build.items, &(&1.type == "ac"))
    view = open(conn, ~p"/inside?#{[item: ac.id]}", build)
    settle(view)
    assert has_element?(view, ~s(#item-form input[name="item[seer2]"]))
    refute has_element?(view, ~s(#item-form input[name="item[hspf2]"]))
    view |> form("#item-form", %{"item" => %{"heat_pump" => "true"}}) |> render_change()
    assert has_element?(view, ~s(#item-form input[name="item[hspf2]"]))

    # A choice has its note under it: an inlet is not an outlet.
    laundry = Enum.find(build.rooms, &(&1.name == "Laundry"))
    {:ok, build, station} = Build.add_item(build, laundry.id, "power_station")
    view = open(conn, ~p"/inside?#{[item: station]}", build)
    assert has_element?(view, "#item-form", "It is not an outlet: an electrician installs it.")
  end

  test "a fridge in the garage: its math gives the air outside", %{conn: conn} do
    build = house()
    garage = Enum.find(build.rooms, &(&1.name == "Garage"))
    {:ok, build, fridge} = Build.add_item(build, garage.id, "fridge")
    view = open(conn, ~p"/inside?#{[item: fridge]}", build)
    settle(view)
    assert has_element?(view, "#item-math", "the label, for a kitchen near 72 °F")

    assert has_element?(
             view,
             "#item-math",
             "Around the house, the app uses the mean air outside: 85.9 °F in July."
           )
  end

  test "the sheet of solar panels: the roof, the station, and a typical price", %{conn: conn} do
    build = house()
    roof = Enum.find(build.rooms, &(&1.name == "Roof"))
    {:ok, build, panels} = Build.add_item(build, roof.id, "solar_panels")
    view = open(conn, ~p"/inside?#{[item: panels]}", build)
    settle(view)
    assert has_element?(view, "#item-solar", "One side of the roof holds near 15 panels of 400 W")
    assert has_element?(view, "#item-solar", "No power station is in the house")

    view
    |> form("#item-form", %{"item" => %{"to" => "grid", "watts" => "6000"}})
    |> render_change()

    assert has_element?(view, "#item-solar", "For 6,000 W: near $17,880.")
    refute has_element?(view, "#item-solar", "No power station")

    # A fridge has no such notes.
    fridge = Enum.find(build.items, &(&1.type == "fridge"))
    render_patch(view, ~p"/inside?#{[item: fridge.id]}")
    refute has_element?(view, "#item-solar")
  end

  test "the sheet of a CPAP tells how to keep it on in an outage", %{conn: conn} do
    build = house()
    bedroom = Enum.find(build.rooms, &(&1.name == "Bedroom 1"))
    {:ok, build, cpap} = Build.add_item(build, bedroom.id, "cpap")
    view = open(conn, ~p"/inside?#{[item: cpap]}", build)
    settle(view)
    assert has_element?(view, "#item-medical", "A power station can run it for some hours")
    assert has_element?(view, "#item-medical", "On a battery, turn off the humidifier")
    # 50 W for 8 hours in the 31 days of July.
    assert has_element?(view, "#item-sheet", "12.4 kWh")

    # A fridge has no such note.
    fridge = Enum.find(build.items, &(&1.type == "fridge"))
    render_patch(view, ~p"/inside?#{[item: fridge.id]}")
    refute has_element?(view, "#item-medical")
  end

  test "two items with the same name: the bill gives the room of each one", %{conn: conn} do
    build = house()
    garage = Enum.find(build.rooms, &(&1.name == "Garage"))
    {:ok, build, _id} = Build.add_item(build, garage.id, "fridge")
    view = open(conn, ~p"/estimate", build)
    html = settle(view)
    assert html =~ "Fridge (Kitchen)"
    assert html =~ "Fridge (Garage)"
    refute html =~ "Clothes dryer ("
  end

  test "each page starts at its top: the key of the page changes with the page, not with a sheet",
       %{conn: conn} do
    build = house()
    fridge = Enum.find(build.items, &(&1.type == "fridge"))
    view = open(conn, ~p"/", build)
    assert has_element?(view, ~s(#top[data-page="front::"]))
    render_patch(view, ~p"/inside")
    assert has_element?(view, ~s(#top[data-page="inside::"]))
    render_patch(view, ~p"/inside?#{[item: fridge.id]}")
    assert has_element?(view, ~s(#top[data-page="inside::"]))
    render_patch(view, ~p"/plans?step=1")
    assert has_element?(view, ~s(#top[data-page="plans:1:"]))

    # A new van: its sheet opens over the same page, and the key stays.
    driveway = Enum.find(build.rooms, &(&1.name == "Driveway"))
    render_patch(view, ~p"/inside")
    render_click(view, "add_item", %{"room" => driveway.id, "type" => "camper_van"})
    assert has_element?(view, ~s(#top[data-page="inside::"]))
    van = Enum.find(build(view).items, &(&1.type == "camper_van"))
    render_patch(view, ~p"/van?#{[id: van.id]}")
    assert has_element?(view, ~s(#top[data-page="van::#{van.id}"]))

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ~s(#top[data-page="load"]))
  end

  test "a house with gas items has a gas bill; the plan shows its change", %{conn: conn} do
    build = house()
    view = open(conn, ~p"/", build)
    settle(view)
    estimate = :sys.get_state(view.pid).socket.assigns.estimate
    gas = DIY.Prices.gas(build)
    bill = &DIYWeb.Format.money(DIY.Prices.gas_bill(gas, &1))
    january = hd(estimate.months)

    # The bill: the fixed charge and the therms of an average month, with
    # the range, and the month with the most gas, with its range.
    assert has_element?(view, "#gas-bill", "Your gas bill, in an average month")
    assert has_element?(view, "#gas-average", bill.(estimate.therms / 12))

    assert has_element?(
             view,
             "#gas-range",
             "The range: #{bill.(estimate.therms_low / 12)} to #{bill.(estimate.therms_high / 12)}."
           )

    assert has_element?(
             view,
             "#gas-range",
             "The month with the most gas: January, #{bill.(january.therms)} (between #{bill.(january.therms_low)} and #{bill.(january.therms_high)})."
           )

    assert has_element?(
             view,
             "#gas-bill",
             "The gas items: gas furnace, water heater, stove and oven."
           )

    assert has_element?(view, "#gas-bill", "a fixed charge near $25.59 each month")
    assert has_element?(view, "#gas-bill", "near $0.95 for each therm")
    refute has_element?(view, "#whatif-gas")

    # The item, its list line and the math page give the gas.
    furnace = Enum.find(build.items, &(&1.type == "furnace"))
    render_patch(view, ~p"/inside?#{[item: furnace.id]}")

    assert has_element?(
             view,
             "#item-gas",
             "Gas in one year: #{DIYWeb.Format.therms(estimate.items[furnace.id].therms)}"
           )

    assert has_element?(view, "#item-sheet", "the estimate of your gas bill")

    assert has_element?(
             view,
             "#plan-list",
             ~r/Gas furnace: \d+ kWh and \d+ therms, \$\d+ a month/
           )

    render_patch(view, ~p"/estimate")
    assert has_element?(view, "#items", "therms of gas in one year")
    assert has_element?(view, "#gas-price", "The price of gas: a fixed charge near $25.59")

    # A planned heat pump heats in place of the furnace: less gas, with its
    # range.
    backyard = Enum.find(build.rooms, &(&1.name == "Backyard"))
    {:ok, build, pump} = Build.add_item(build, backyard.id, "ac")
    {:ok, build} = Build.update_item(build, pump, %{"heat_pump" => "true"})
    {:ok, build} = Build.flag_item(build, pump, :planned, true)
    view = open(conn, ~p"/", build)
    settle(view)
    %{today: today, plan: plan} = :sys.get_state(view.pid).socket.assigns.whatif.therms
    assert plan.therms < today.therms
    month = &DIYWeb.Format.money(round(DIY.Prices.gas_bill(gas, &1 / 12)))

    assert has_element?(
             view,
             "#whatif-gas",
             "The gas bill with the plan: #{month.(plan.therms)} (between #{month.(plan.therms_low)} and #{month.(plan.therms_high)}) · today #{month.(today.therms)}."
           )

    # With no other gas item, the plan uses no gas, but the house keeps its
    # furnace: the fixed charge stays.
    electric =
      for item <- build.items, item.params["fuel"] == "gas", reduce: build do
        build ->
          {:ok, build} = Build.update_item(build, item.id, %{"fuel" => "electric"})
          build
      end

    view = open(conn, ~p"/", electric)
    settle(view)

    assert has_element?(
             view,
             "#whatif-gas",
             "The gas bill with the plan: $26 (the fixed charge: the house keeps its gas items)"
           )

    # A house with no gas today, and a planned furnace: no gas bill today.
    plain = house("75070", %{heat: "electric"})
    attic = Enum.find(plain.rooms, &(&1.name == "Attic"))
    {:ok, plain, furnace} = Build.add_item(plain, attic.id, "furnace")
    {:ok, plain} = Build.flag_item(plain, furnace, :planned, true)
    view = open(conn, ~p"/", plain)
    settle(view)
    assert has_element?(view, "#whatif-gas", "· today $0.")

    # An all-electric house has no gas bill.
    view = open(conn, ~p"/", house("75070", %{heat: "electric"}))
    settle(view)
    refute has_element?(view, "#gas-bill")
  end

  test "the equipment, the meter and a van: a note on the sheet, and no kWh on the sheet or the lists",
       %{conn: conn} do
    build = house()
    place = &Enum.find(build.rooms, fn r -> r.name == &1 end).id

    {build, ids} =
      Enum.reduce(
        [
          {"Laundry", "power_station", "A power station keeps power for later."},
          {"Roof", "solar_panels", "The panels make power."},
          {"Laundry", "transfer_switch", "It uses no power."},
          {"Garage", "smart_meter", "The meter measures the power of the house."},
          {"Driveway", "camper_van", "A camper van has its own build"}
        ],
        {build, []},
        fn {room, type, note}, {build, ids} ->
          {:ok, build, id} = Build.add_item(build, place.(room), type)
          {build, [{id, type, note} | ids]}
        end
      )

    view = open(conn, ~p"/inside", build)
    settle(view)

    for {id, type, note} <- ids do
      render_patch(view, ~p"/inside?#{[item: id]}")
      assert has_element?(view, "#item-math", note), type
      refute has_element?(view, "#item-math", "In one year"), type
      refute has_element?(view, "#item-math", " kWh"), type

      # The list for a screen reader, and the page Bill: no kWh either.
      assert has_element?(view, "#plan-list a[href*='#{id}']")
      refute has_element?(view, "#plan-list a[href*='#{id}']", " kWh"), type
    end

    render_patch(view, ~p"/estimate")

    for {id, type, _note} <- ids,
        do: refute(has_element?(view, "#items a[href*='#{id}']"), type)

    # A fridge has its kWh and its math.
    fridge = Enum.find(build.items, &(&1.type == "fridge"))
    render_patch(view, ~p"/inside?#{[item: fridge.id]}")
    assert has_element?(view, "#item-math", "In one year")
  end

  test "a house with a van: the front gives a link to the build of each van", %{conn: conn} do
    build = house()
    view = open(conn, ~p"/", build)
    settle(view)
    refute has_element?(view, "#vans-card")
    view |> element("#add-van") |> render_click()
    [van] = DIY.Van.vans(build(view))
    render_patch(view, ~p"/")
    refute has_element?(view, "#van-card")

    assert has_element?(view, "#vans-card p", ~r/^\s*Your camper van\s*$/)

    view
    |> element("#open-van-#{van.id}", "Ram ProMaster 2500, 159 in, high roof")
    |> render_click()

    assert_patch(view, ~p"/van?#{[id: van.id]}")

    # Two vans, and a model that the app does not know.
    {:ok, build} = Build.update_item(build(view), van.id, %{"model" => "other"})
    driveway = Enum.find(build.rooms, &(&1.name == "Driveway"))
    {:ok, build, _second} = Build.add_item(build, driveway.id, "camper_van")
    view = open(conn, ~p"/", build)
    settle(view)
    assert has_element?(view, "#vans-card", "Your camper vans")
    assert has_element?(view, "#vans-card a", "Van 1: Another van")
    assert has_element?(view, "#vans-card a", "Van 2: Ram ProMaster")
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

    # The price of a bill ($168 for 1,150 kWh) shows with 2 decimals.
    view = open(conn, ~p"/settings", %{house() | price: 168 / 1150 * 100})
    settle(view)
    assert has_element?(view, ~s(#settings-price input[name="price"][value="14.61"]))
    view = open(conn, ~p"/settings", house())
    settle(view)

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
