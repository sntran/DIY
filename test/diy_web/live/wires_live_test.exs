defmodule DIYWeb.WiresLiveTest do
  @moduledoc "The wires of an item in its panel (`DIYWeb.Wires`)."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp preset do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name)).id

  defp add(build, room, type) do
    {:ok, build, id} = Build.add_item(build, room, type)
    {build, id}
  end

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    view
  end

  defp build_of(view), do: :sys.get_state(view.pid).socket.assigns.build

  test "a wire from a power station to a busbar, with the rules of the NEC", %{conn: conn} do
    build = preset()
    {build, station} = add(build, room(build, "Garage"), "power_station")
    {build, bus} = add(build, room(build, "Garage"), "dc_bus")
    view = open(conn, ~p"/inside?#{[item: station]}", build)

    assert has_element?(view, "#part-wires #part-wires-title", "Wires")
    assert has_element?(view, "#part-more", "the checks of its wires (NEC)")

    assert has_element?(
             view,
             "#wire-to option[value=#{bus}]",
             "DC busbar or distributor, in Garage"
           )

    # The person adds a wire to the busbar.
    view |> form("#add-wire", %{"to" => bus}) |> render_submit()
    [wire] = build_of(view).wires
    id = "#wire-#{wire.id}"
    assert has_element?(view, "#{id}-title", "Power station to DC busbar or distributor")
    assert has_element?(view, "#{id}-system option[selected][value='12']")
    assert has_element?(view, "#{id}-amps[value='30']")
    assert has_element?(view, "#{id} [role=switch][name='wire[two_way]'][checked]")

    # The busbar takes no fuse less than 60 A: the wire must carry 60 A.
    assert has_element?(view, "#{id}-advice", "Wire: 6 AWG copper or larger, rated 75 °C")

    assert has_element?(
             view,
             "#{id}-advice",
             "At Power station: a breaker or a fuse of 40 A to 70 A"
           )

    assert has_element?(view, "#{id}-advice", "rated for DC at 14.6 V or more.")

    assert has_element?(
             view,
             "#{id}-advice",
             "At DC busbar or distributor: a breaker or a fuse of 60 A to 70 A"
           )

    assert has_element?(
             view,
             "#{id}-advice",
             "takes no fuse less than 60 A: the wire must carry it."
           )

    # On 48 V: the DC rating of a LiFePO4 battery when it is full.
    view |> form("#{id}-form", %{"wire" => %{"system" => "48"}}) |> render_change()
    assert has_element?(view, "#{id}-advice", "rated for DC at 58.4 V or more.")
    refute has_element?(view, "#{id}-check li")
    refute has_element?(view, "#{id}-check .wire-ok")

    # What the person has: 10 AWG, a breaker of 30 A for 48 V DC, and a
    # fuse of 60 A.
    view
    |> form("#{id}-has", %{
      "wire" => %{"awg" => "10", "from_ocpd" => "30", "from_dc" => "48", "to_ocpd" => "60"}
    })
    |> render_change()

    check = "#{id}-check[role=status]"

    assert has_element?(
             view,
             check,
             "The wire is too small: 10 AWG carries 35 A, and the wire needs 37.5 A. This is 125% of 30 A (NEC 210.19(A))."
           )

    assert has_element?(
             view,
             check,
             "The breaker or the fuse at Power station is too small: 30 A is less than 37.5 A."
           )

    assert has_element?(
             view,
             check,
             "has a DC rating of 48 V. The system can have 58.4 V (a full LiFePO4 battery)"
           )

    assert has_element?(view, check, "(NEC 706.31(C))")

    assert has_element?(
             view,
             check,
             "The breaker or the fuse at DC busbar or distributor does not protect the wire: 10 AWG takes 30 A at most, and it is 60 A."
           )

    # The fields of each end are in a group with the name of the end.
    assert has_element?(view, "#{id}-from-end legend", "At Power station")
    assert has_element?(view, "#{id}-to-end legend", "At DC busbar or distributor")

    assert has_element?(
             view,
             "#{id}-to-end label[for='#{String.slice(id, 1..-1//1)}-to-dc']",
             "Its DC rating"
           )

    # The advice does not change with what the person has.
    assert has_element?(
             view,
             "#{id}-advice",
             "At Power station: a breaker or a fuse of 40 A to 70 A"
           )

    # A wire with no breaker at an end.
    view |> form("#{id}-has", %{"wire" => %{"to_ocpd" => ""}}) |> render_change()

    assert has_element?(
             view,
             check,
             "The wire has no breaker or fuse at DC busbar or distributor. That end also gives current: it can feed a fault on the wire (NEC 705.30)."
           )

    view |> form("#{id}-has", %{"wire" => %{"from_ocpd" => ""}}) |> render_change()

    assert has_element?(
             view,
             check,
             "The wire has no breaker or fuse at Power station. A fault on the wire can then start a fire (NEC 240.21)."
           )

    # The advice of the app: no fault.
    view
    |> form("#{id}-has", %{
      "wire" => %{
        "awg" => "6",
        "from_ocpd" => "40",
        "from_dc" => "60",
        "to_ocpd" => "60",
        "to_dc" => "80"
      }
    })
    |> render_change()

    assert has_element?(view, "#{check} .wire-ok", "What you have meets these rules.")
    refute has_element?(view, "#{check} li")

    # A fuse at the busbar for 48 V DC only.
    view |> form("#{id}-has", %{"wire" => %{"to_dc" => "48"}}) |> render_change()

    assert has_element?(
             view,
             check,
             "The breaker or the fuse at DC busbar or distributor has a DC rating of 48 V."
           )

    view |> form("#{id}-has", %{"wire" => %{"to_dc" => "80"}}) |> render_change()

    # 1000 A: no wire of 4/0 AWG or less is enough.
    view |> form("#{id}-form", %{"wire" => %{"amps" => "1000"}}) |> render_change()
    assert has_element?(view, "#{id}-advice", "no single wire of 4/0 AWG or less is enough")

    assert has_element?(
             view,
             "#{id}-advice",
             "At Power station: a breaker or a fuse of 1600 A, rated"
           )

    view |> form("#{id}-form", %{"wire" => %{"amps" => "30"}}) |> render_change()

    # A long wire: the voltage drop.
    view |> form("#{id}-form", %{"wire" => %{"feet" => "100"}}) |> render_change()
    assert has_element?(view, check, "The voltage drop is 6.1%. The NEC advises 3% or less")

    # A number that is not valid: the field tells it, and nothing changes.
    view |> form("#{id}-form", %{"wire" => %{"amps" => "0"}}) |> render_change()
    assert has_element?(view, "#{id}-amps[aria-invalid=true]")
    assert has_element?(view, "#{id}-amps-error", "Give a number from 1 to 1000, or nothing.")

    assert has_element?(
             view,
             "#{id}-amps[aria-describedby='#{String.slice(id, 1..-1//1)}-amps-unit #{String.slice(id, 1..-1//1)}-amps-help #{String.slice(id, 1..-1//1)}-amps-error']"
           )

    assert hd(build_of(view).wires).amps == 30.0

    for {part, key, field} <- [{"form", "feet", "feet"}, {"has", "from_dc", "from-dc"}] do
      view |> form("#{id}-#{part}", %{"wire" => %{key => "0"}}) |> render_change()
      assert has_element?(view, "#{id}-#{field}-error", "Give a number from 1 to")
    end

    view |> form("#{id}-has", %{"wire" => %{"from_ocpd" => "0"}}) |> render_change()

    assert has_element?(
             view,
             "#{id}-from-ocpd-error",
             "Give a number from 1 to 2000, or nothing."
           )

    view |> form("#{id}-has", %{"wire" => %{"to_ocpd" => "0"}}) |> render_change()
    assert has_element?(view, "#{id}-to-ocpd-error")
    view |> form("#{id}-has", %{"wire" => %{"to_dc" => "0"}}) |> render_change()
    assert has_element?(view, "#{id}-to-dc-error")
    view |> form("#{id}-form", %{"wire" => %{"amps" => "30"}}) |> render_change()
    refute has_element?(view, ".stage-error")

    # The current comes from the busbar: the ends change places.
    view |> form("#{id}-form", %{"wire" => %{"from" => bus}}) |> render_change()
    assert has_element?(view, "#{id}-title", "DC busbar or distributor to Power station")
    assert hd(build_of(view).wires).from == bus

    # On AC, the far end has no breaker, and no DC rating.
    view |> form("#{id}-form", %{"wire" => %{"system" => "120"}}) |> render_change()
    refute has_element?(view, "#{id} [name='wire[two_way]']")
    refute has_element?(view, "#{id}-from-dc")
    refute has_element?(view, "#{id}-to-ocpd")
    refute has_element?(view, "#{id}-advice", "rated for DC")

    # The busbar shows the same wire in its panel, and its positions.
    render_patch(view, ~p"/inside?#{[item: bus]}")
    assert has_element?(view, "#{id}-title", "DC busbar or distributor to Power station")

    assert has_element?(
             view,
             "#wire-ports.stage-help",
             "It has 4 positions for wires. 1 of them has a wire."
           )

    view |> form("#add-wire", %{"to" => station}) |> render_submit()
    assert has_element?(view, "#wire-ports", "2 of them have a wire.")

    # A busbar with 1 position, and 2 wires: a fault. The model of the
    # busbar shows its positions.
    view |> form("#item-form", %{"item" => %{"ports" => "1"}}) |> render_change()

    assert has_element?(
             view,
             "#wire-ports.wire-over",
             "2 wires connect to the busbar, and it has 1 position for wires."
           )

    assert :sys.get_state(view.pid).socket.assigns.item_frames.shown == {{"dc_bus", 1}, :house}
    # The model has a new id, so the page gets its new frames.
    assert has_element?(
             view,
             "#item-stage-model-#{bus} #item-stage-frames-#{bus}-1[phx-update=ignore]"
           )

    [_, second] = build_of(view).wires
    view |> element("#wire-#{second.id} button", "Remove the wire") |> render_click()
    view |> form("#item-form", %{"item" => %{"ports" => "4"}}) |> render_change()

    # A wire that is not there changes nothing. The person removes the wire.
    render_change(view, "wire", %{"wire_id" => "w0", "wire" => %{"amps" => "5"}})
    view |> element("#{id} button", "Remove the wire") |> render_click()
    assert build_of(view).wires == []
    refute has_element?(view, id)
    render_submit(view, "add_wire", %{"from" => bus, "to" => bus})
    assert build_of(view).wires == []
  end

  test "an item with no second item that takes wires, and an item with no wires", %{conn: conn} do
    build = preset()
    {build, station} = add(build, room(build, "Garage"), "power_station")
    view = open(conn, ~p"/inside?#{[item: station]}", build)
    assert has_element?(view, "#wire-none", "Add a second item that takes wires")
    refute has_element?(view, "#add-wire")

    fridge = Enum.find(build.items, &(&1.type == "fridge"))
    render_patch(view, ~p"/inside?#{[item: fridge.id]}")
    refute has_element?(view, "#part-wires")

    # A busbar uses no power: no cost, and no switch of the backup.
    {build, bus} = add(build, room(build, "Garage"), "dc_bus")
    view = open(conn, ~p"/inside?#{[item: bus]}", build)
    assert has_element?(view, "#item-math", "A busbar connects the wires")

    assert has_element?(
             view,
             "#wire-ports",
             "It has 4 positions for wires. No position has a wire yet."
           )

    assert has_element?(view, "#param-fuse_min[value='60']")
    refute has_element?(view, "#flags-form [name=backup]")
  end

  test "the wires of a van, in the panel on the page of the van", %{conn: conn} do
    build = preset()
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway"), "camper_van")
    bay = Build.zone(build, van, :bay).id
    {build, battery} = add(build, bay, "van_battery")
    {build, _inverter} = add(build, bay, "inverter")
    {build, house_station} = add(build, room(build, "Garage"), "power_station")
    {:ok, build} = Build.update_item(build, battery, %{"volts" => "48"})

    view = open(conn, ~p"/van?#{[id: van, item: battery]}", build)
    assert has_element?(view, "#part-more", "the checks of its wires (NEC)")
    # Only the items of the van: not the station of the house.
    assert has_element?(view, "#wire-to option", "Inverter, in Electrical bay")
    refute has_element?(view, "#wire-to option[value=#{house_station}]")

    view |> element("#add-wire") |> render_submit(%{"to" => hd(Build.zones(build, van)).id})
    assert build_of(view).wires == []
    inverter = Enum.find(build.items, &(&1.type == "inverter")).id
    view |> form("#add-wire", %{"to" => inverter}) |> render_submit()
    [wire] = build_of(view).wires
    assert has_element?(view, "#wire-#{wire.id}-system option[selected][value='48']")
    assert has_element?(view, "#wire-#{wire.id}-advice", "rated for DC at 58.4 V or more.")

    # A wire of a station that went home: the panel of the house shows no
    # wire to the van.
    {:ok, build} = Build.take_to_van(build_of(view), house_station, van)
    {:ok, build, _id} = Build.add_wire(build, house_station, battery)
    {:ok, build} = Build.bring_home(build, house_station)
    view = open(conn, ~p"/inside?#{[item: house_station]}", build)
    assert has_element?(view, "#part-wires")
    refute has_element?(view, "#part-wires .wire")
  end
end
