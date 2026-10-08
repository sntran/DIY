defmodule DIYWeb.LessonLiveTest do
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Lesson, Plan, Stubs}

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
    date: "2026-10-08",
    source: "ptc"
  }

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    _ = :sys.get_state(view.pid)
    Process.sleep(20)
    view
  end

  defp house(market \\ @market, zip \\ "75070") do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, zip)
    build = if market, do: Build.set_market(build, market), else: build
    Build.put_house(build, house, rooms, items)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp build(view), do: assigns(view).build

  defp efl(name), do: "test/fixtures/efl/#{name}.json" |> File.read!() |> Jason.decode!()

  # The right answers of the exercise: the bill of the month with the most
  # use, with a plan.
  defp answers(view, plan) do
    {months, _source} = Lesson.months(build(view), assigns(view).bill)
    month = Lesson.exercise_month(months)
    bill = Plan.bill(plan, month.kwh, month.month, assigns(view).shares[{plan.id, month.month}])

    Map.new(Lesson.parts(plan), fn part ->
      {Atom.to_string(part), :erlang.float_to_binary(Map.fetch!(bill, part) / 1, decimals: 2)}
    end)
  end

  test "the lesson is only for an area of Texas with retail choice", %{conn: conn} do
    view = open(conn, ~p"/plans", house(nil, "10001"))
    assert has_element?(view, "#no-lesson")
    refute has_element?(view, "nav a", "Plans")

    view = open(conn, ~p"/plans", house(%{@market | choice: false}))
    assert has_element?(view, "#no-lesson")

    view = open(conn, ~p"/", house())
    assert has_element?(view, "nav a", "Plans")
  end

  test "step 1: the worked example, then step 2", %{conn: conn} do
    view = open(conn, ~p"/plans", house())
    html = render(view)
    assert html =~ "1. A worked example"
    assert html =~ "Each step of the bill of July"
    assert html =~ "not 11.3¢"
    refute has_element?(view, "nav[aria-label='The steps of the lesson'] a", "2.")

    # A step that the user did not reach shows the step that the user reached.
    assert render_patch(view, ~p"/plans?step=3") =~ "1. A worked example"

    view |> element("#example button", "Next: your data") |> render_click()
    assert_patch(view, ~p"/plans?step=2")
    assert build(view).lesson == 2
    assert render(view) =~ "2. Your data, with help"

    # Back to step 1: the lesson keeps step 2.
    render_click(view, "lesson", %{"step" => "1"})
    assert build(view).lesson == 2
    render_click(view, "lesson", %{"step" => "9"})
    assert build(view).lesson == 2
  end

  test "step 2: the user does each step, and the app checks it", %{conn: conn} do
    view = open(conn, ~p"/plans?step=2", Build.set_lesson(house(), 2))
    html = render(view)
    assert html =~ "The exercise uses the example plan"
    assert html =~ "From the estimate of your house"
    assert html =~ "kWh × 13.7¢ ÷ 100"

    wrong = %{"energy" => "1", "base" => "9.95", "tdu" => "", "credits" => "100", "total" => "x"}
    html = view |> form("#exercise", %{"answer" => wrong}) |> render_submit()
    assert html =~ "✗ check it"
    assert html =~ "✓ right"
    refute has_element?(view, "#exercise-done")

    right = answers(view, Lesson.example_plan())
    view |> form("#exercise", %{"answer" => right}) |> render_submit()
    assert has_element?(view, "#exercise-done")

    view |> element("#exercise-done button", "Next: fewer hints") |> render_click()
    assert_patch(view, ~p"/plans?step=3")
    assert build(view).lesson == 3
  end

  test "an EFL: its numbers with their lines, its check, and the worksheet", %{conn: conn} do
    view = open(conn, ~p"/plans?step=2", Build.set_lesson(house(), 2))

    render_hook(view, "efl", %{
      "name" => "txu-smart-1000-select-12.pdf",
      "lines" => efl("txu-smart-1000-select-12")
    })

    assert has_element?(view, "#efl-result")
    html = render(view)
    assert html =~ "The numbers of txu-smart-1000-select-12"
    assert html =~ "13.7¢"
    assert html =~ "data-efl-page=\"1\""
    assert has_element?(view, "#efl-check")

    view |> form("#efl-add", %{"name" => "TXU 1000"}) |> render_submit()
    assert [%{name: "TXU 1000", id: id}] = build(view).plans
    refute has_element?(view, "#efl-result")

    # The exercise uses the plan of the EFL now.
    assert render(view) =~ "$100.00 for 1,000 kWh or more"
    right = answers(view, hd(build(view).plans))
    view |> form("#exercise", %{"answer" => right}) |> render_submit()
    assert has_element?(view, "#exercise-done")
    render_change(view, "lesson_plan", %{"plan" => id})

    # An EFL with no averages, a file that is not a PDF, and an EFL that the
    # app cannot read in full.
    assert render_hook(view, "efl", %{
             "name" => "x.pdf",
             "lines" => [%{"page" => 1, "text" => "A letter"}]
           }) =~
             "The app cannot read this EFL"

    assert render_hook(view, "efl_error", %{}) =~ "Open the PDF of an EFL"

    render_hook(view, "efl", %{"name" => "c.pdf", "lines" => efl("champion-champ-saver-24")})
    assert render(view) =~ "These numbers do not give the averages of the EFL"
    refute has_element?(view, "#efl-add")
    render_submit(view, "add_efl_plan", %{"name" => "Champion"})
    assert length(build(view).plans) == 1

    # An EFL with numbers that agree with its averages, but an energy
    # charge over the range of the app (200¢): the build does not keep it.
    lines =
      Enum.map(efl("txu-smart-1000-select-12"), fn
        %{"text" => "Electricity  All kWh  13.7000¢"} = line ->
          %{line | "text" => "Electricity  All kWh  250.0000¢"}

        %{"text" => "Average Price per kWh  23.4¢  11.3¢  16.0¢"} = line ->
          %{line | "text" => "Average Price per kWh  259.7¢  247.6¢  252.3¢"}

        line ->
          line
      end)

    render_hook(view, "efl", %{"name" => "big.pdf", "lines" => lines})
    assert has_element?(view, "#efl-add")

    assert view |> form("#efl-add", %{"name" => "Big"}) |> render_submit() =~
             "The app cannot keep this plan"

    assert length(build(view).plans) == 1
  end

  test "step 3: a second plan, fewer hints", %{conn: conn} do
    # The plan of step 2 is the first plan of the worksheet: step 3 needs a
    # different one.
    {:ok, build, _id} =
      Build.add_plan(Build.set_lesson(house(), 3), %{Lesson.example_plan() | name: "First"})

    view = open(conn, ~p"/plans?step=3", build)
    assert render(view) =~ "Add a second plan"

    view
    |> form("#plan-form", %{
      "plan" => %{"name" => "Broker plan", "energy" => "9.5", "base" => "4.95"}
    })
    |> render_submit()

    assert [%{name: "First"}, %{name: "Broker plan"} = plan] = build(view).plans
    assert render(view) =~ "The bill of"
    refute has_element?(view, "#exercise ul")
    view |> element("#exercise button", "Show a hint") |> render_click()
    assert has_element?(view, "#exercise ul", "Energy charge:")

    view |> form("#exercise", %{"answer" => %{"total" => "1"}}) |> render_submit()
    refute has_element?(view, "#exercise-done")
    right = answers(view, plan)
    view |> form("#exercise", %{"answer" => %{"total" => right["total"]}}) |> render_submit()
    assert has_element?(view, "#exercise-done")
    view |> element("#exercise-done button", "Next: on your own") |> render_click()
    assert build(view).lesson == 4
  end

  test "step 4: the worksheet, with no ranking", %{conn: conn} do
    {:ok, build, _id} =
      Build.add_plan(Build.set_lesson(house(), 4), %{Lesson.example_plan() | name: "First"})

    view = open(conn, ~p"/plans?step=4", build)
    assert has_element?(view, "#worksheet-table")

    {:ok, %{plan: chariot}} = DIY.EFL.read(efl("chariot-bright-nights-8"))

    render_hook(view, "efl", %{"name" => "chariot.pdf", "lines" => efl("chariot-bright-nights-8")})

    view |> form("#efl-add", %{"name" => " "}) |> render_submit()
    assert [%{name: "First"}, %{name: "The plan of the EFL", night: night}] = build(view).plans
    assert night == chariot.night
    # The share of the night of each month comes from the day of the house.
    assert map_size(assigns(view).shares) == 12

    html =
      view
      |> form("#plan-form", %{"plan" => %{"name" => "x", "energy" => "300"}})
      |> render_submit()

    assert html =~ "Give each number of the plan in the limits"

    assert view |> form("#plan-form", %{"plan" => %{"name" => ""}}) |> render_submit() =~
             "Give the plan a name."

    # The order of the table is the order of the worksheet.
    html = render(view)
    assert :binary.match(html, "First") < :binary.match(html, "The plan of the EFL")

    [first | _] = build(view).plans
    view |> element("button[aria-label='Remove First']") |> render_click()
    assert [%{name: "The plan of the EFL"}] = build(view).plans
    render_click(view, "delete_plan", %{"id" => "p999"})

    # At most 10 plans.
    build =
      Enum.reduce(1..9, build(view), fn i, b ->
        {:ok, b, _id} = Build.add_plan(b, %{first | name: "P#{i}"})
        b
      end)

    assert {:error, :plans} = Build.add_plan(build, first)
    view = open(conn, ~p"/plans?step=4", Build.delete_plan(build, hd(build.plans).id) |> elem(1))

    view
    |> form("#plan-form", %{"plan" => %{"name" => "Eleventh", "energy" => "10"}})
    |> render_submit()

    assert view
           |> form("#plan-form", %{"plan" => %{"name" => "Twelfth", "energy" => "10"}})
           |> render_submit() =~
             "The worksheet has 10 plans"
  end

  test "step 2 with plans of each form: tiers, the night, a fee, a credit of each month", %{
    conn: conn
  } do
    read = fn name ->
      {:ok, %{plan: plan}} = DIY.EFL.read(efl(name))
      %{plan | name: name}
    end

    {:ok, fee} =
      Lesson.plan_from_form(%{
        "name" => "Fee plan",
        "energy" => "10",
        "fee" => "9.95",
        "fee_kwh" => "1000"
      })

    build =
      Enum.reduce(
        [
          read.("texans-choice-instant-12"),
          read.("chariot-bright-nights-8"),
          fee,
          read.("rhythm-digital-choice-24")
        ],
        Build.set_lesson(house(), 2),
        fn plan, b ->
          {:ok, b, _id} = Build.add_plan(b, plan)
          b
        end
      )

    view = open(conn, ~p"/plans?step=2", build)
    [texans, chariot, fee, rhythm] = build(view).plans
    assert render(view) =~ "Each part of the kWh at the price of its tier"
    assert render(view) =~ "above 1,000 kWh"

    render_change(view, "lesson_plan", %{"plan" => chariot.id})
    html = render(view)
    assert html =~ "the kWh of the night at the price of the night"
    assert html =~ "At night (23:00 to 6:00)"

    render_change(view, "lesson_plan", %{"plan" => fee.id})
    html = render(view)
    assert html =~ "Minimum usage fee"
    assert html =~ "$9.95 for a month under 1,000 kWh"
    assert has_element?(view, "#answer-fee")

    render_change(view, "lesson_plan", %{"plan" => rhythm.id})
    assert render(view) =~ "$5.00 each month"
    assert texans.id

    # An EFL with a minimum usage fee shows it with its line.
    render_hook(view, "efl", %{
      "name" => "fee.pdf",
      "lines" =>
        Enum.map(
          [
            "Average price per kWh 25.0¢ 15.4¢ 14.7¢",
            "Energy Charge 10¢ per kWh",
            "Minimum Usage Fee: $9.95 per month if usage is less than 1,000 kWh",
            "Oncor Delivery Charges $4.06 per month and 6.8673¢ per kWh"
          ],
          &%{"page" => 1, "text" => &1}
        )
    })

    assert has_element?(view, "#efl-result", "Minimum usage fee")
  end

  test "a worksheet with no plan", %{conn: conn} do
    view = open(conn, ~p"/plans?step=4", Build.set_lesson(house(), 4))
    assert render(view) =~ "No plan yet."
  end
end
