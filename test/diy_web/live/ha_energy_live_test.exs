defmodule DIYWeb.HaEnergyLiveTest do
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs, Usage}
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

  defp page(conn, path, build \\ build()) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    view
  end

  defp connected(view) do
    render_hook(view, "ha:status", %{
      "state" => "connected",
      "url" => "https://ha.example.com",
      "name" => "Home"
    })
  end

  defp build_of(view), do: :sys.get_state(view.pid).socket.assigns.build
  defp energy_of(view), do: :sys.get_state(view.pid).socket.assigns.ha_energy

  defp month(name, kwh, export \\ 0, days \\ 30),
    do: %{"month" => name, "kwh" => kwh, "export" => export, "days" => days}

  defp meter(months), do: %{"source" => "home_assistant", "months" => months}

  defp energy(view, meter, devices \\ []),
    do: render_hook(view, "ha:energy", %{"meter" => meter, "devices" => devices})

  test "Usage reads a meter of Home Assistant" do
    assert {:ok, %{source: "home_assistant"}} = Usage.read(meter([month("2026-09", 500)]))
    assert Usage.source_name("home_assistant") == "Home Assistant"
  end

  test "the energy data that the page reads" do
    fridge = %{
      "device" => "d1",
      "name" => "Fridge",
      "months" => [%{"month" => "2026-09", "kwh" => 30}]
    }

    plug = %{"device" => "d1", "name" => nil, "months" => [%{"month" => "2026-09", "kwh" => 2}]}
    tv = %{"device" => "d2", "name" => nil, "months" => [%{"month" => "2026-10", "kwh" => 9.5}]}

    # Two sensors of one device give the sum of their kWh. A device that the
    # page cannot read does not count.
    bad = [
      %{"device" => "d3", "name" => nil, "months" => []},
      %{"device" => 5, "name" => nil, "months" => [%{"month" => "2026-09", "kwh" => 1}]},
      %{"device" => "d4", "name" => 7, "months" => [%{"month" => "2026-09", "kwh" => 1}]},
      %{"device" => "d5", "name" => nil, "months" => [%{"month" => "26-09", "kwh" => 1}]},
      %{"device" => "d6", "name" => nil, "months" => [%{"month" => "2026-09", "kwh" => -1}]},
      %{
        "device" => "d7",
        "name" => nil,
        "months" => [%{"month" => "2026-09", "kwh" => 1}, %{"month" => "2026-09", "kwh" => 2}]
      },
      "d8"
    ]

    assert HomeAssistant.read_energy(%{
             "meter" => meter([month("2026-09", 500, 20, 30)]),
             "devices" => [fridge, plug, tv | bad]
           }) == %{
             meter: %{
               source: "home_assistant",
               months: [%{month: "2026-09", kwh: 500.0, export: 20.0, days: 30}]
             },
             devices: %{
               "d1" => %{name: "Fridge", months: [%{month: "2026-09", kwh: 32.0}]},
               "d2" => %{name: nil, months: [%{month: "2026-10", kwh: 9.5}]}
             }
           }

    assert HomeAssistant.read_energy(%{"meter" => nil, "devices" => []}) ==
             %{meter: nil, devices: %{}}

    assert HomeAssistant.read_energy(%{"error" => "failed"}) == %{error: "failed"}

    # A meter of a different source, a meter that Usage cannot read, too
    # many devices, or a payload that the page does not know.
    for payload <- [
          %{"meter" => %{"source" => "smt", "months" => [month("2026-09", 1)]}, "devices" => []},
          %{"meter" => meter([month("2026-02", 1, 0, 31)]), "devices" => []},
          %{"meter" => nil, "devices" => List.duplicate(fridge, 201)},
          %{"error" => "boom"},
          %{}
        ] do
      assert HomeAssistant.read_energy(payload) == nil
    end
  end

  property "the page takes only energy data that it can read" do
    month_data =
      fixed_map(%{
        "month" => one_of([constant("2026-09"), constant("2026-10"), string(:alphanumeric)]),
        "kwh" => one_of([float(min: -5.0, max: 2_000.0), constant("x")])
      })

    device =
      fixed_map(%{
        "device" => one_of([constant("d1"), constant("d2"), integer()]),
        "name" => one_of([constant(nil), string(:printable, max_length: 5)]),
        "months" => list_of(month_data, max_length: 3)
      })

    check all(devices <- list_of(device, max_length: 5)) do
      case HomeAssistant.read_energy(%{"meter" => nil, "devices" => devices}) do
        %{meter: nil, devices: read} ->
          for {id, %{months: months}} <- read do
            assert is_binary(id)
            assert months != []
            assert Enum.all?(months, &(&1.kwh >= 0 and &1.month =~ ~r/\A20\d\d-\d\d\z/))
            assert Enum.uniq_by(months, & &1.month) == months
          end
      end
    end
  end

  test "the page offers the meter of Home Assistant, and keeps its months", %{conn: conn} do
    view = page(conn, ~p"/")
    connected(view)
    assert_push_event(view, "ha:energy_fetch", %{})
    refute has_element?(view, "#use-ha-meter")

    # Home Assistant has the meter: the front offers it. The house has no
    # smart meter yet: the page adds one, outside.
    energy(view, meter([month("2026-08", 900), month("2026-09", 700, 0, 12)]))
    assert has_element?(view, "#real", "Home Assistant has the use of your meter: 2 months.")
    view |> element("#use-ha-meter") |> render_click()
    build = build_of(view)
    assert %{source: "home_assistant", months: [_, _]} = build.usage
    meter = Enum.find(build.items, &(&1.type == "smart_meter"))
    {:ok, room} = Build.room(build, meter.room)
    assert room.place == :outdoor
    assert render(view) =~ "The page has 2 months of your usage from Home Assistant."
    assert has_element?(view, "#real-average")
    refute has_element?(view, "#use-ha-meter")

    # New months of Home Assistant: the build follows. The same months
    # again change nothing.
    energy(
      view,
      meter([month("2026-08", 900), month("2026-09", 700), month("2026-10", 100, 0, 3)])
    )

    assert length(build_of(view).usage.months) == 3
    revision = build_of(view).revision

    energy(
      view,
      meter([month("2026-08", 900), month("2026-09", 700), month("2026-10", 100, 0, 3)])
    )

    assert build_of(view).revision == revision

    # The panel of the meter tells the source.
    render_patch(view, ~p"/inside?#{[item: meter.id]}")
    assert has_element?(view, "#usage-months", "Home Assistant: 3 months, from August 2026")
    refute has_element?(view, "#ha-meter")

    # The person removes the real usage: the new months of Home Assistant
    # do not come back by themselves. The panel offers them.
    view |> element("#usage-months button", "Remove the real usage") |> render_click()
    energy(view, meter([month("2026-09", 700)]))
    assert build_of(view).usage == nil
    assert has_element?(view, "#ha-meter", "Home Assistant has the use of this meter: 1 month")

    # A file of the meter: the build keeps it, and the panel offers Home
    # Assistant. A tap uses Home Assistant in place of the file.
    file = %{"source" => "smt", "months" => [month("2025-01", 800)]}
    render_hook(view, "usage", file)
    energy(view, meter([month("2026-09", 700)]))
    assert build_of(view).usage.source == "smt"
    view |> element("#ha-meter #use-ha-meter") |> render_click()
    assert build_of(view).usage.source == "home_assistant"
    assert Enum.count(build_of(view).items, &(&1.type == "smart_meter")) == 1
  end

  test "the energy of a device in the panel of its item, next to the estimate", %{conn: conn} do
    view = page(conn, ~p"/inside")
    connected(view)
    assert_push_event(view, "ha:energy_fetch", %{})

    render_hook(view, "ha:devices", %{
      "devices" => [
        %{"id" => "d1", "name" => "Kitchen Fridge", "area" => "kitchen", "domains" => ["sensor"]}
      ],
      "areas" => [%{"id" => "kitchen", "name" => "Kitchen", "floor" => nil}]
    })

    # The house has a fridge in the kitchen of the preset: the ghost makes a
    # second one, with the link.
    render_hook(view, "ha_add_device", %{"id" => "d1"})
    item = Build.device_item(build_of(view), "d1")
    assert_patch(view, ~p"/inside?#{[item: item]}")
    refute has_element?(view, "#ha-energy")

    months = for m <- ~w(2025-11 2025-12 2026-01), do: %{"month" => m, "kwh" => 40}
    energy(view, nil, [%{"device" => "d1", "name" => "Fridge", "months" => months}])

    # The estimate of the same months: November, December and January.
    by_month = :sys.get_state(view.pid).socket.assigns.full.items[item].months
    same = Enum.at(by_month, 10) + Enum.at(by_month, 11) + Enum.at(by_month, 0)

    assert has_element?(
             view,
             "#part-link #ha-energy",
             "Home Assistant measured 120 kWh in 3 months, from November 2025 to January 2026. " <>
               "The estimate for the same months: #{DIYWeb.Format.kwh(same)}."
           )

    one = [%{"month" => "2026-01", "kwh" => 41}]
    energy(view, nil, [%{"device" => "d1", "name" => nil, "months" => one}])
    assert has_element?(view, "#ha-energy", "in 1 month, in January 2026.")

    # The month that is not over does not count. With only this month, the
    # panel tells it, with no estimate.
    now = Calendar.strftime(Date.utc_today(), "%Y-%m")
    both = [%{"month" => "2026-01", "kwh" => 41}, %{"month" => now, "kwh" => 3}]
    energy(view, nil, [%{"device" => "d1", "name" => nil, "months" => both}])
    assert has_element?(view, "#ha-energy", "Home Assistant measured 41 kWh in 1 month")
    energy(view, nil, [%{"device" => "d1", "name" => nil, "months" => tl(both)}])

    assert has_element?(
             view,
             "#ha-energy",
             "Home Assistant measured 3 kWh in #{DIYWeb.Format.month(now)}, a part of the month."
           )

    # An error of Home Assistant, a link that closes, and a disconnect.
    render_hook(view, "ha:energy", %{"error" => "failed"})
    assert energy_of(view) == %{error: "failed"}
    refute has_element?(view, "#ha-energy")
    energy(view, nil, [%{"device" => "d1", "name" => nil, "months" => one}])
    render_hook(view, "ha:status", %{"state" => "offline", "url" => "https://ha.example.com"})
    assert has_element?(view, "#ha-energy")
    energy(view, nil, [])
    assert energy_of(view).devices != %{}
    render_hook(view, "ha:status", %{"state" => "none"})
    assert energy_of(view) == nil
    refute has_element?(view, "#ha-energy")

    # A tap on the offer with no meter of Home Assistant changes nothing.
    revision = build_of(view).revision
    render_click(view, "ha_use_meter", %{})
    assert build_of(view).revision == revision
  end

  test "a meter for a house with no room outside, and no meter for a house with no room", %{
    conn: conn
  } do
    build = build()

    inside =
      Enum.reduce(build.rooms, build, fn room, build ->
        if room.place == :indoor, do: build, else: elem(Build.delete_room(build, room.id), 1)
      end)

    view = page(conn, ~p"/", inside)
    connected(view)
    # A payload that the page cannot read changes nothing.
    render_hook(view, "ha:energy", %{"meter" => 5})
    assert energy_of(view) == nil
    energy(view, meter([month("2026-09", 700)]))
    render_click(view, "ha_use_meter", %{})
    build = build_of(view)
    meter = Enum.find(build.items, &(&1.type == "smart_meter"))
    assert {:ok, %{place: :indoor}} = Build.room(build, meter.room)

    empty = Enum.reduce(build.rooms, build, &elem(Build.delete_room(&2, &1.id), 1))
    view = page(conn, ~p"/", empty)
    connected(view)
    energy(view, meter([month("2026-09", 700)]))
    render_click(view, "ha_use_meter", %{})
    assert build_of(view).usage == nil
  end
end
