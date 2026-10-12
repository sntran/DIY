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

    # The person adds a wire to the busbar. A status tells it.
    view |> form("#add-wire", %{"to" => bus}) |> render_submit()
    [wire] = build_of(view).wires
    id = "#wire-#{wire.id}"

    assert has_element?(
             view,
             "#item-said[role=status]",
             "A wire from Power station to DC busbar or distributor is added."
           )

    assert has_element?(view, "#{id}-title", "Power station to DC busbar or distributor")
    assert has_element?(view, "#{id}-system option[selected][value='12']")
    # A busbar with no battery is on DC: the choice has no AC.
    assert has_element?(view, "#{id}-system option[value='48']")
    refute has_element?(view, "#{id}-system option[value='120']")
    assert has_element?(view, "#{id}-amps[value='30'][step=any][inputmode=decimal]")
    assert has_element?(view, "#{id} [role=switch][name='wire[two_way]'][checked]")

    # The busbar takes no fuse less than 40 A (MEGA fuses): 8 AWG carries
    # 50 A.
    assert has_element?(
             view,
             "#{id}-advice",
             "Current: 125% of 30 A is 37.5 A. This is for a load all the time: 3 hours or more (NEC Article 100, 210.19(A) and 215.2(A)(1))."
           )

    assert has_element?(view, "#{id}-advice", "Wire: 8 AWG copper or larger, rated 75 °C")

    assert has_element?(
             view,
             "#{id}-advice",
             "At Power station: a breaker or a fuse of 40 A to 50 A, rated for DC at 14.6 V or more."
           )

    assert has_element?(
             view,
             "#{id}-advice",
             "At DC busbar or distributor: a breaker or a fuse of 40 A to 50 A"
           )

    assert has_element?(
             view,
             "#{id}-advice",
             "14.6 V is the voltage of a full LiFePO4 battery of 12 V DC: 4 cells at 3.65 V."
           )

    refute has_element?(view, "#{id}-advice", "takes no fuse less than")

    # A busbar with fuses of 60 A at least: the wire must carry 60 A. The
    # panel of the busbar shows the wire too.
    render_patch(view, ~p"/inside?#{[item: bus]}")
    view |> form("#item-form", %{"item" => %{"fuse_min" => "60"}}) |> render_change()
    assert has_element?(view, "#{id}-advice", "Wire: 6 AWG copper or larger")

    assert has_element?(
             view,
             "#{id}-advice",
             "DC busbar or distributor takes no fuse less than 60 A: the wire must carry it."
           )

    render_patch(view, ~p"/inside?#{[item: station]}")

    assert has_element?(
             view,
             "#{id}-advice",
             "At DC busbar or distributor: a breaker or a fuse of 60 A to 70 A"
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
             "The wire is too small: 10 AWG carries 35 A, and the wire needs 37.5 A. This is 125% of 30 A (NEC 210.19(A) and 215.2(A)(1))."
           )

    assert has_element?(
             view,
             check,
             "The breaker or the fuse at Power station is too small: 30 A is less than 37.5 A. It can open at the normal current (NEC 210.20(A) and 215.3)."
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
             "The breaker or the fuse at DC busbar or distributor does not protect the wire: 10 AWG takes 30 A at most, and it is 60 A. Use a larger wire or a smaller breaker (NEC 240.4)."
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
             "The wire has no breaker or fuse at DC busbar or distributor. That end also gives current: it can feed a fault on the wire (NEC 705.30(A))."
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

    assert has_element?(
             view,
             check,
             "The voltage drop is 6.1%. The NEC advises 3% or less: use a larger wire or a shorter wire (an informational note of NEC 210.19(A))."
           )

    # A number that is not valid: the field tells it, and nothing changes.
    view |> form("#{id}-form", %{"wire" => %{"amps" => "0"}}) |> render_change()
    assert has_element?(view, "#{id}-amps[aria-invalid=true]")
    assert has_element?(view, "#{id}-amps-error", "Give a number from 1 to 1000, or nothing.")

    assert has_element?(
             view,
             "#{id}-amps[aria-describedby='#{String.slice(id, 1..-1//1)}-amps-unit #{String.slice(id, 1..-1//1)}-amps-help #{String.slice(id, 1..-1//1)}-amps-error']"
           )

    assert hd(build_of(view).wires).amps == 30.0

    view |> form("#{id}-form", %{"wire" => %{"feet" => "0"}}) |> render_change()
    assert has_element?(view, "#{id}-feet-error", "Give a number from 1 to 500, or nothing.")

    # The breakers and the DC ratings are whole numbers.
    for {key, field, max} <- [
          {"from_ocpd", "from-ocpd", 2000},
          {"to_ocpd", "to-ocpd", 2000},
          {"from_dc", "from-dc", 1500},
          {"to_dc", "to-dc", 1500}
        ] do
      assert has_element?(view, "#{id}-#{field}[step='1'][inputmode=numeric]")
      view |> form("#{id}-has", %{"wire" => %{key => "58.4"}}) |> render_change()

      assert has_element?(
               view,
               "#{id}-#{field}-error",
               "Give a whole number from 1 to #{max}, or nothing."
             )
    end

    view |> form("#{id}-form", %{"wire" => %{"amps" => "30"}}) |> render_change()
    refute has_element?(view, ".stage-error")

    # The current comes from the busbar: the ends change places. The
    # radios stay in their order: only the radio that is on changes.
    [first, last] = Enum.sort([station, bus])
    radio = &"#{id}-end-#{&1}[value=#{&2}]"
    assert has_element?(view, radio.(0, first)) and has_element?(view, radio.(1, last))

    assert has_element?(
             view,
             radio.(if(station == first, do: 0, else: 1), station) <> "[checked]"
           )

    view |> form("#{id}-form", %{"wire" => %{"from" => bus}}) |> render_change()
    assert has_element?(view, "#{id}-title", "DC busbar or distributor to Power station")
    assert hd(build_of(view).wires).from == bus
    assert has_element?(view, radio.(0, first)) and has_element?(view, radio.(1, last))
    assert has_element?(view, radio.(if(bus == first, do: 0, else: 1), bus) <> "[checked]")
    refute has_element?(view, "#{id} [name='wire[from]'][value=#{station}][checked]")

    # A wire at a busbar stays on DC.
    render_change(view, "wire", %{"wire_id" => wire.id, "wire" => %{"system" => "120"}})
    assert hd(build_of(view).wires).system == "12"
    assert has_element?(view, "#{id} [name='wire[two_way]']")

    # The busbar shows the same wire in its panel, and its positions.
    render_patch(view, ~p"/inside?#{[item: bus]}")
    assert has_element?(view, "#{id}-title", "DC busbar or distributor to Power station")

    assert has_element?(
             view,
             "#wire-ports.stage-help[role=status]",
             "It has 4 positions for wires. 1 of them has a wire."
           )

    view |> form("#add-wire", %{"to" => station}) |> render_submit()
    assert has_element?(view, "#wire-ports", "2 of them have a wire.")

    # Two wires between the same two items: their titles have a number.
    [_, second] = build_of(view).wires
    assert has_element?(view, "#{id}-title", "DC busbar or distributor to Power station, wire 1")

    assert has_element?(
             view,
             "#wire-#{second.id}-title",
             "DC busbar or distributor to Power station, wire 2"
           )

    # 4 wires: all the positions have a wire, with no fault.
    for _n <- 1..2, do: view |> form("#add-wire", %{"to" => station}) |> render_submit()
    assert has_element?(view, "#wire-ports.stage-help", "4 of them have a wire.")
    [_, _, third, fourth] = build_of(view).wires

    assert has_element?(
             view,
             "#item-said",
             "A wire from DC busbar or distributor to Power station is added: wire 4."
           )

    # The same status two times: it is empty for a short time first, so a
    # screen reader reads it again.
    view |> element("#wire-#{third.id}-remove") |> render_click()
    assert has_element?(view, "#item-said", "The wire is removed.")
    view |> element("#wire-#{fourth.id}-remove") |> render_click()
    Process.sleep(150)
    assert has_element?(view, "#item-said", "The wire is removed.")
    # A late status of a different item changes nothing.
    send(view.pid, {:wire_said, "i0", "A late status."})
    refute render(view) =~ "A late status."

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

    # The removal of a wire asks first, in the card of the wire.
    assert has_element?(view, "#wire-#{second.id}-ask-remove", "Remove the wire")

    assert has_element?(
             view,
             "#wire-#{second.id}-confirm[role=group].hidden",
             "Remove this wire: DC busbar or distributor to Power station, wire 2?"
           )

    assert has_element?(view, "#wire-#{second.id}-keep", "Keep it")
    view |> element("#wire-#{second.id}-remove") |> render_click()
    assert has_element?(view, "#item-said", "The wire is removed.")
    view |> form("#item-form", %{"item" => %{"ports" => "4"}}) |> render_change()

    # A wire that is not there changes nothing. The person removes the wire.
    render_change(view, "wire", %{"wire_id" => "w0", "wire" => %{"amps" => "5"}})
    render_click(view, "delete_wire", %{"id" => "w0"})
    view |> element("#{id}-remove") |> render_click()
    assert build_of(view).wires == []
    refute has_element?(view, id)
    render_submit(view, "add_wire", %{"from" => bus, "to" => bus})
    assert build_of(view).wires == []
  end

  test "an item with its most wires", %{conn: conn} do
    build = preset()
    {build, station} = add(build, room(build, "Garage"), "power_station")
    {build, bus} = add(build, room(build, "Garage"), "dc_bus")
    {build, other} = add(build, room(build, "Garage"), "power_station")

    build =
      Enum.reduce(1..24, build, fn _n, build ->
        {:ok, build, _id} = Build.add_wire(build, station, bus)
        build
      end)

    view = open(conn, ~p"/inside?#{[item: station]}", build)
    refute has_element?(view, "#add-wire")

    assert has_element?(
             view,
             "#wire-full",
             "This item has 24 wires, the most for an item. Remove a wire of this item to add a different one."
           )

    # The station and the busbar are full: the other station cannot add a
    # wire to them.
    render_patch(view, ~p"/inside?#{[item: other]}")
    refute has_element?(view, "#add-wire")

    assert has_element?(
             view,
             "#wire-full",
             "Each other item that takes wires here has 24 wires, the most for an item."
           )

    refute has_element?(view, "#wire-none")

    # A build with 100 wires (a stored build).
    [one | _] = build.wires
    many = %{build | wires: for(n <- 1..100, do: %{one | id: "w#{1000 + n}"})}
    view = open(conn, ~p"/inside?#{[item: other]}", many)

    assert has_element?(
             view,
             "#wire-full",
             "The build has 100 wires, the most for a build. Remove a wire to add a different one."
           )
  end

  test "a battery, a busbar and an inverter in a van: the wires at the busbar have the voltage of the battery",
       %{conn: conn} do
    build = preset()
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway"), "camper_van")
    bay = Build.zone(build, van, :bay).id
    {build, battery} = add(build, bay, "van_battery")
    {build, bus} = add(build, bay, "dc_bus")
    {build, inverter} = add(build, bay, "inverter")
    {:ok, build} = Build.update_item(build, battery, %{"volts" => "48"})
    {:ok, build, _id} = Build.add_wire(build, battery, bus)
    {:ok, build, id} = Build.add_wire(build, bus, inverter)
    view = open(conn, ~p"/van?#{[id: van, item: inverter]}", build)

    assert has_element?(
             view,
             "p#wire-#{id}-system",
             "System: 48 V DC, the voltage of the battery at DC busbar or distributor. Change it in the part of the battery."
           )

    assert has_element?(view, "#wire-#{id}-advice", "rated for DC at 58.4 V or more.")

    # A second busbar with a wire to the first one: the wire between the
    # busbars shows the system as a text.
    {build, bus2} = add(build, bay, "dc_bus")
    {:ok, build, link} = Build.add_wire(build, bus2, bus)
    view = open(conn, ~p"/van?#{[id: van, item: bus2]}", build)

    assert has_element?(
             view,
             "p#wire-#{link}-system",
             "System: 48 V DC, the voltage of the battery at DC busbar or distributor."
           )

    refute has_element?(view, "#wire-volts p")

    # A second battery of 12 V on the busbar: a fault.
    {build, small} = add(build, bay, "van_battery")
    {:ok, build, _id} = Build.add_wire(build, small, bus2)
    view = open(conn, ~p"/van?#{[id: van, item: bus2]}", build)

    assert has_element?(
             view,
             "#wire-volts[role=status] .wire-over",
             "Batteries of 12 V and 48 V are on this busbar. The batteries on one busbar must have the same voltage. The app checks the wires for 48 V."
           )

    assert DIYWeb.Wires.volts_text(~w(12 24 48)) =~ "Batteries of 12 V, 24 V and 48 V are"
  end

  test "a wire on AC: one way, and no DC rating", %{conn: conn} do
    build = preset()
    {build, station} = add(build, room(build, "Garage"), "power_station")
    {build, switch} = add(build, room(build, "Garage"), "transfer_switch")
    {:ok, build, id} = Build.add_wire(build, station, switch)
    view = open(conn, ~p"/inside?#{[item: station]}", build)
    id = "#wire-#{id}"
    assert has_element?(view, "#{id}-system option[selected][value='120']")
    refute has_element?(view, "#{id} [name='wire[two_way]']")
    refute has_element?(view, "#{id}-from-dc")
    refute has_element?(view, "#{id}-to-ocpd")
    refute has_element?(view, "#{id}-advice", "rated for DC")
    assert has_element?(view, "#{id}-advice", "At Power station: a breaker or a fuse of 40 A")
  end

  test "an item with no second item that takes wires, and an item with no wires", %{conn: conn} do
    build = preset()
    {build, station} = add(build, room(build, "Garage"), "power_station")
    view = open(conn, ~p"/inside?#{[item: station]}", build)

    assert has_element?(
             view,
             "#wire-none",
             "Add a second item that takes wires: a power station, a busbar or a transfer switch."
           )

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

    assert has_element?(view, "#param-fuse_min[value='40']")
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

    # A battery with no second item in its van.
    {:ok, alone} = Build.delete_item(build, Enum.find(build.items, &(&1.type == "inverter")).id)
    view = open(conn, ~p"/van?#{[id: van, item: battery]}", alone)

    assert has_element?(
             view,
             "#wire-none",
             "a battery, a busbar, an inverter, a power station, an alternator charger or a shore power inlet."
           )

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

    # The system is the voltage of the battery: no choice in the card.
    assert has_element?(
             view,
             "p#wire-#{wire.id}-system",
             "System: 48 V DC, the voltage of Battery bank. Change it in the part of the battery."
           )

    assert has_element?(view, "#wire-#{wire.id}-advice", "rated for DC at 58.4 V or more.")
    refute has_element?(view, "#wire-#{wire.id}-lead-acid")

    # The battery changes: the wire changes with it.
    view
    |> form("#item-form", %{"item" => %{"volts" => "24", "chemistry" => "agm"}})
    |> render_change()

    assert has_element?(view, "#wire-#{wire.id}-advice", "rated for DC at 29.2 V or more.")

    assert has_element?(
             view,
             "#wire-#{wire.id}-lead-acid",
             "Battery bank is lead acid. The app uses the voltages of LiFePO4: ask the maker of the battery for its highest voltage."
           )

    # A wire of a station that went home: the panel of the house shows no
    # wire to the van.
    {:ok, build} = Build.take_to_van(build_of(view), house_station, van)
    {:ok, build, _id} = Build.add_wire(build, house_station, battery)
    {:ok, build} = Build.bring_home(build, house_station)
    view = open(conn, ~p"/inside?#{[item: house_station]}", build)
    assert has_element?(view, "#part-wires")
    refute has_element?(view, "#part-wires .wire")

    # The battery does not show it either. It shows again when the station
    # is in the van again.
    view = open(conn, ~p"/van?#{[id: van, item: battery]}", build)
    assert has_element?(view, "#part-wires .wire", "Inverter")
    refute has_element?(view, "#part-wires .wire", "Power station")
    {:ok, build} = Build.take_to_van(build, house_station, van)
    view = open(conn, ~p"/van?#{[id: van, item: battery]}", build)
    assert has_element?(view, "#part-wires .wire", "Power station")
  end
end
