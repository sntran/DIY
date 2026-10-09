defmodule DIYWeb.LessonLiveTest do
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Lesson, Stubs, Usage}

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
    settle(view)
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

  # The answers of a user for the month with the most use: each part to
  # the cent, and the total from the parts.
  defp answers(view, plan) do
    {months, _source} = Lesson.months(build(view), assigns(view).bill)
    month = Lesson.exercise_month(months)
    bill = Lesson.bill(plan, month, assigns(view).shares[{plan.id, month.month}])
    cent = &(Float.round(&1 * 100) / 100)
    parts = Map.new(Lesson.parts(plan) -- [:total], &{&1, cent.(Map.fetch!(bill, &1))})
    total = Enum.sum(for {part, v} <- parts, do: if(part == :credits, do: -v, else: v))

    parts
    |> Map.put(:total, total)
    |> Map.new(fn {part, v} ->
      {Atom.to_string(part), :erlang.float_to_binary(v, decimals: 2)}
    end)
  end

  defp number(text), do: text |> String.replace(",", "") |> Float.parse() |> elem(0)

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
    assert html =~ ~r/hero-x-mark[^<]*<\/span>\s*check it/
    assert html =~ ~r/hero-check[^<]*<\/span>\s*right/
    assert html =~ "give a number of dollars"
    assert has_element?(view, "#exercise p[role=status]", "of 5 right.")
    refute has_element?(view, "#exercise-done")
    # The answers stay in the form after the check.
    assert has_element?(view, ~s(#answer-base[value="9.95"]))
    assert has_element?(view, ~s(#answer-total[value="x"]))
    # The months of the estimate show their range.
    assert has_element?(view, "#your-months", " to ")

    right = answers(view, Lesson.example_plan())
    view |> form("#exercise", %{"answer" => right}) |> render_submit()
    assert has_element?(view, "#exercise-done")

    assert build(view).lesson_plan == "example"

    view |> element("#exercise-done button", "Next: fewer hints") |> render_click()
    assert_patch(view, ~p"/plans?step=3")
    assert build(view).lesson == 3

    # Step 3 with one plan: the plan of step 2 was the example plan, so the
    # new plan is the plan of step 3.
    assert render(view) =~ "Add a second plan"

    view
    |> form("#plan-form", %{"plan" => %{"name" => "Broker plan", "energy" => "9.5"}})
    |> render_submit()

    assert render(view) =~ "The bill of"
    assert has_element?(view, "#exercise input[name=plan][value=#{hd(build(view).plans).id}]")
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
    assert has_element?(view, "#efl-result[phx-hook=EflLinks]")
    assert has_element?(view, "#efl-check")
    # The EFL gives no delivery charges: the page tells where they come from.
    assert html =~ "the table of the app, Oncor, October 2026"
    assert has_element?(view, "#efl-check .sr-only", "the same")

    view |> form("#efl-add", %{"name" => "TXU 1000"}) |> render_submit()
    assert [%{name: "TXU 1000", id: id}] = build(view).plans
    refute has_element?(view, "#efl-result")

    # The exercise uses the plan of the EFL now.
    assert render(view) =~ "$100.00 for 1,000 kWh or more"
    right = answers(view, hd(build(view).plans))
    view |> form("#exercise", %{"answer" => right}) |> render_submit()
    assert has_element?(view, "#exercise-done")
    assert has_element?(view, ~s(#answer-total[value="#{right["total"]}"]))
    # A different plan: the answers of the plan before go away.
    render_change(view, "lesson_plan", %{"plan" => id})
    refute has_element?(view, "#answer-total[value]")

    # An EFL with no averages, a file that is not a PDF, and an EFL that the
    # app cannot read in full.
    assert render_hook(view, "efl", %{
             "name" => "x.pdf",
             "lines" => [%{"page" => 1, "text" => "A letter"}]
           }) =~
             "The app cannot read this EFL"

    assert render_hook(view, "efl_error", %{}) =~ "Open the PDF of an EFL"
    refute has_element?(view, "#efl-result")

    long = List.duplicate(%{"page" => 1, "text" => String.duplicate("x", 2000)}, 33)

    assert render_hook(view, "efl", %{"name" => "long.pdf", "lines" => long}) =~
             "The app cannot read the text of this file."

    # An EFL with no base charge.
    render_hook(view, "efl", %{"name" => "g.pdf", "lines" => efl("gexa-eco-choice-3")})
    assert render(view) =~ "the EFL gives no base charge"

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
    assert has_element?(view, ~s(#answer-total[value="1"]))
    right = answers(view, plan)
    view |> form("#exercise", %{"answer" => %{"total" => right["total"]}}) |> render_submit()
    assert has_element?(view, "#exercise-done")
    view |> element("#exercise-done button", "Next: on your own") |> render_click()
    assert build(view).lesson == 4
  end

  test "step 4: the worksheet, in the order of the user", %{conn: conn} do
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

    assert view
           |> form("#plan-form", %{"plan" => %{"name" => "Fee", "fee" => "9.95", "fee_kwh" => ""}})
           |> render_submit() =~ "Give the kWh of the minimum usage fee"

    # The range of the year, and the kWh at night of the plan of the EFL.
    assert render(view) =~ "Range of the year"
    [_first, chariot_plan] = build(view).plans

    assert has_element?(
             view,
             "#night-#{chariot_plan.id}",
             "come from the model of a day of your house"
           )

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
      Lesson.plan_from_form(
        %{"name" => "Fee plan", "energy" => "10", "fee" => "9.95", "fee_kwh" => "1000"},
        false
      )

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

    # The plan of the night, from the text of the page: the user can do
    # each step.
    render_change(view, "lesson_plan", %{"plan" => chariot.id})
    html = render(view)
    assert html =~ "At night (23:00 to 6:00)"
    assert html =~ "come from the model of a day of your house"

    [_, day, day_cents, night, night_cents] =
      Regex.run(
        ~r/Day: ([\d,]+) kWh × ([\d.]+)¢ ÷ 100, and night: ([\d,]+) kWh × ([\d.]+)¢/,
        html
      )

    [_, tdu_base, kwh, tdu_cents] =
      Regex.run(~r/\$([\d.]+) \+ ([\d,]+) kWh × ([\d.]+)¢ ÷ 100/, html)

    [_, base] = Regex.run(~r/The base charge of the plan: \$(\d+\.\d\d)/, html)
    assert number(day) + number(night) == number(kwh)
    cent = &(Float.round(&1 * 100) / 100)

    energy =
      cent.(number(day) * number(day_cents) / 100 + number(night) * number(night_cents) / 100)

    tdu = cent.(number(tdu_base) + number(kwh) * number(tdu_cents) / 100)
    total = energy + number(base) + tdu
    money = &:erlang.float_to_binary(&1, decimals: 2)

    view
    |> form("#exercise", %{
      "answer" => %{
        "energy" => money.(energy),
        "base" => base,
        "tdu" => money.(tdu),
        "credits" => "0",
        "total" => money.(total)
      }
    })
    |> render_submit()

    assert has_element?(view, "#exercise-done")
    assert has_element?(view, "#exercise-done th", "At night")

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

    # A fee under 500 kWh: the averages do not check it.
    render_hook(view, "efl", %{"name" => "je.pdf", "lines" => efl("just-energy-smart-choice-12")})
    assert has_element?(view, "#efl-result", "do not check the minimum usage fee")
  end

  test "a worksheet with no plan", %{conn: conn} do
    view = open(conn, ~p"/plans?step=4", Build.set_lesson(house(), 4))
    assert render(view) =~ "No plan yet."
  end

  test "a utility that the app does not know: the user gives its delivery charges", %{
    conn: conn
  } do
    view =
      open(
        conn,
        ~p"/plans?step=4",
        Build.set_lesson(house(%{@market | utility: "Entergy Texas"}), 4)
      )

    assert has_element?(view, "#plan-form input[name='plan[tdu_base]'][required]")
    assert render(view) =~ "Give the delivery charges of your utility"

    assert view
           |> form("#plan-form", %{"plan" => %{"name" => "A plan", "energy" => "10"}})
           |> render_submit() =~ "Give the delivery charges of your utility: its EFL gives them."

    view
    |> form("#plan-form", %{
      "plan" => %{
        "name" => "A plan",
        "energy" => "10",
        "tdu_base" => "4.39",
        "tdu_cents" => "5.6"
      }
    })
    |> render_submit()

    assert [%{tdu_base: 4.39, tdu_cents: 5.6}] = build(view).plans
  end

  test "a utility with no name, an exercise with no answer, and EFLs with no delivery charges", %{
    conn: conn
  } do
    view = open(conn, ~p"/plans?step=2", Build.set_lesson(house(%{@market | utility: nil}), 2))

    render_submit(view, "exercise", %{"plan" => "example"})
    assert has_element?(view, "#exercise p[role=status]", "0 of 5 right.")

    lines = fn texts -> Enum.map(texts, &%{"page" => 1, "text" => &1}) end

    # No delivery charges, and no utility of the table: from the averages.
    render_hook(view, "efl", %{
      "name" => "a.pdf",
      "lines" =>
        lines.(["Average price per kWh 15.4¢ 15.0¢ 14.8¢", "Energy Charge 7.7174¢ per kWh"])
    })

    assert render(view) =~ "(from the averages of the EFL)"
    assert render(view) =~ "only the average at 1,000 kWh checks these numbers"

    # No energy charge either: no fit.
    render_hook(view, "efl", %{
      "name" => "b.pdf",
      "lines" => lines.(["Average price per kWh 15.4¢ 15.0¢ 14.8¢"])
    })

    assert render(view) =~ "(the EFL gives no number)"
  end

  test "the kWh at night from the EFL, and a plan with tiers and a price at night" do
    plan = %{
      Lesson.example_plan()
      | id: "p1",
        name: "Tiers at night",
        credits: [],
        energy: [{0, 5.0}, {1000, 10.0}],
        night: %{cents: 1.0, from: 22, to: 6, share: 0.3}
    }

    build = %{Build.set_lesson(house(), 4) | plans: [plan]}

    bill = %{
      months: for(m <- 1..12, do: %{month: m, kwh: 1200.0, low: 1100.0, high: 1300.0})
    }

    assigns = %{build: build, bill: bill, step: 2, plan_id: "p1", shares: %{}}
    html = render_component(&DIYWeb.LessonPage.page/1, assigns)
    assert html =~ "(the price of the tiers for 1,200 kWh)"
    assert html =~ "30% of the month, as the EFL says"

    html = render_component(&DIYWeb.LessonPage.page/1, %{assigns | step: 4})
    assert html =~ "They come from the part that the EFL says."
  end

  test "a meter file with a month of 0 kWh", %{conn: conn} do
    months =
      for m <- 1..12 do
        name = "2025-#{String.pad_leading("#{m}", 2, "0")}"

        %{
          "month" => name,
          "kwh" => if(m == 4, do: 0, else: 900),
          "export" => 0,
          "days" => Usage.days_in(name)
        }
      end

    {:ok, usage} = Usage.read(%{"source" => "smt", "months" => months})

    {:ok, build, _id} =
      Build.add_plan(Build.set_lesson(house(), 4), %{Lesson.example_plan() | name: "First"})

    view = open(conn, ~p"/plans?step=2", Build.set_usage(build, usage))
    right = answers(view, Lesson.example_plan())
    view |> form("#exercise", %{"answer" => right}) |> render_submit()
    assert has_element?(view, "#exercise-done td", "–")

    # A year of 0 kWh (an empty house): no price for each kWh.
    zero = Enum.map(months, &%{&1 | "kwh" => 0})
    {:ok, usage} = Usage.read(%{"source" => "smt", "months" => zero})
    view = open(conn, ~p"/plans?step=4", Build.set_usage(build, usage))
    assert has_element?(view, "#worksheet-table th", "–")
  end
end
