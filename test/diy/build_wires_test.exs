defmodule DIY.BuildWiresTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, House}

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

  # A house with a power station and a busbar in the garage.
  defp garage do
    build = preset()
    {build, station} = add(build, room(build, "Garage"), "power_station")
    {build, bus} = add(build, room(build, "Garage"), "dc_bus")
    {build, station, bus}
  end

  defp read(build), do: Build.from_json(Build.to_json(build))

  test "a wire from an item to an item, with typical numbers" do
    {build, station, bus} = garage()
    {:ok, wired, id} = Build.add_wire(build, station, bus)
    assert wired.revision == build.revision + 1
    assert id == "w#{wired.seq}"

    assert {:ok,
            %{
              id: ^id,
              from: ^station,
              to: ^bus,
              system: "12",
              amps: 30.0,
              feet: 6.0,
              two_way: true,
              awg: nil,
              from_ocpd: nil,
              to_ocpd: nil,
              from_dc: nil,
              to_dc: nil
            }} = Build.wire(wired, id)

    assert Build.wire(wired, "w0") == {:error, :wire}
    assert Build.wires_of(wired, station) == wired.wires
    assert Build.wires_of(wired, bus) == wired.wires
    fridge = Enum.find(wired.items, &(&1.type == "fridge"))
    assert Build.wires_of(wired, fridge.id) == []
    assert Build.wired?(%{type: "dc_bus"})
    refute Build.wired?(fridge)
    assert Build.world(wired, fridge) == :house

    # Two wires between the same items are two circuits.
    {:ok, two, _id} = Build.add_wire(wired, bus, station)
    assert length(Build.wires_of(two, station)) == 2

    # The errors: the same item, an item that takes no wires, and an item
    # that is not there.
    assert Build.add_wire(build, station, station) == {:error, :wire}
    assert Build.add_wire(build, station, fridge.id) == {:error, :wire}
    assert Build.add_wire(build, "i0", bus) == {:error, :item}
    assert Build.add_wire(build, station, "i0") == {:error, :item}
  end

  test "an item has 24 wires at most, and a build has 100 wires at most" do
    assert Build.max_wires() == {100, 24}
    {build, station, bus} = garage()
    {build, other} = add(build, room(build, "Garage"), "power_station")

    full =
      Enum.reduce(1..23, build, fn _n, build ->
        {:ok, build, _id} = Build.add_wire(build, station, bus)
        build
      end)

    refute Build.wires_full?(full, bus)
    {:ok, full, _id} = Build.add_wire(full, station, bus)
    assert Build.wires_full?(full, bus) and Build.wires_full?(full, station)
    refute Build.wires_full?(full, other)
    # The busbar at the far end is full too.
    assert Build.add_wire(full, other, bus) == {:error, :wires}
    assert Build.add_wire(full, station, other) == {:error, :wires}

    # 100 wires in the build: no item can get one more.
    {:ok, one, _id} = Build.add_wire(build, other, bus)
    many = %{one | wires: List.duplicate(hd(one.wires), 100)}
    assert Build.wires_full?(many, station)
    assert Build.add_wire(many, station, bus) == {:error, :wires}
  end

  test "the numbers of a wire change, and its ends can change places" do
    {build, station, bus} = garage()
    {:ok, build, id} = Build.add_wire(build, station, bus)

    {:ok, changed} =
      Build.update_wire(build, id, %{
        "system" => "48",
        "amps" => "25",
        "awg" => "6",
        "from_ocpd" => "40",
        "from_dc" => "60",
        "to_ocpd" => "60"
      })

    assert changed.revision == build.revision + 1

    assert {:ok, %{system: "48", amps: 25.0, awg: "6", from_ocpd: 40, from_dc: 60, to_ocpd: 60}} =
             Build.wire(changed, id)

    # The current comes from the other end: the breakers go with their
    # ends.
    {:ok, turned} = Build.update_wire(changed, id, %{"from" => bus, "amps" => "20"})

    assert {:ok,
            %{
              from: ^bus,
              to: ^station,
              amps: 20.0,
              from_ocpd: 60,
              from_dc: nil,
              to_ocpd: 40,
              to_dc: 60
            }} = Build.wire(turned, id)

    # The same end changes nothing of the ends.
    {:ok, same} = Build.update_wire(turned, id, %{"from" => bus})
    assert Build.wire(same, id) == Build.wire(turned, id)

    assert Build.update_wire(build, id, %{"amps" => "0"}) == {:error, :amps}
    assert Build.update_wire(build, id, %{"from_dc" => "58.4"}) == {:error, :from_dc}
    assert Build.update_wire(build, "w0", %{}) == {:error, :wire}

    {:ok, removed} = Build.delete_wire(changed, id)
    assert removed.wires == []
    assert Build.delete_wire(removed, id) == {:error, :wire}
  end

  test "a wire goes away with an item at its end" do
    {build, station, bus} = garage()
    {:ok, build, _id} = Build.add_wire(build, station, bus)
    {:ok, gone} = Build.delete_item(build, bus)
    assert gone.wires == []

    # With its room too.
    {:ok, gone} = Build.delete_room(build, room(build, "Garage"))
    assert gone.wires == []
  end

  test "the wires of a van, and a station that goes to the van and back" do
    build = preset()
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway"), "camper_van")
    bay = Build.zone(build, van, :bay).id
    {build, battery} = add(build, bay, "van_battery")
    {build, inverter} = add(build, bay, "inverter")
    {build, station} = add(build, room(build, "Garage"), "power_station")

    {:ok, build, id} = Build.add_wire(build, battery, inverter)
    {:ok, wire} = Build.wire(build, id)
    # The system of the battery: 12 V.
    assert %{system: "12", two_way: false} = wire
    {:ok, item} = Build.item(build, battery)
    assert Build.world(build, item) == "van:" <> van

    # A new wire joins two items of one place: the house, or one van.
    assert Build.add_wire(build, station, battery) == {:error, :wire}

    # A station of the house in the van, with a wire to the battery. The
    # wire stays when the station goes home.
    {:ok, trip} = Build.take_to_van(build, station, van)
    {:ok, trip, trip_wire} = Build.add_wire(trip, station, battery)
    {:ok, home} = Build.bring_home(trip, station)
    assert {:ok, _wire} = Build.wire(home, trip_wire)
    assert {:ok, _build} = read(home)

    # The removal of the van removes its items and their wires.
    {:ok, no_van} = Build.delete_item(home, van)
    assert no_van.wires == []

    # A stored build with no van: its zones and their items go when the
    # build loads, with their wires.
    map = Jason.decode!(Build.to_json(home))
    items = Enum.reject(map["items"], &(&1["id"] == van))
    assert {:ok, loaded} = Build.from_json(Jason.encode!(%{map | "items" => items}))
    assert loaded.wires == []
  end

  test "the system of a wire is the voltage of a battery at its end" do
    build = preset()
    {:ok, build, van} = Build.add_item(build, room(build, "Driveway"), "camper_van")
    bay = Build.zone(build, van, :bay).id
    {build, battery} = add(build, bay, "van_battery")
    {build, inverter} = add(build, bay, "inverter")
    {build, bus} = add(build, bay, "dc_bus")
    {:ok, build, id} = Build.add_wire(build, battery, inverter)
    {:ok, build, other} = Build.add_wire(build, bus, inverter)
    {:ok, build} = Build.update_wire(build, other, %{"system" => "24"})

    # The battery changes to 48 V: its wire changes with it. The wire with
    # no battery keeps its system.
    {:ok, changed} = Build.update_item(build, battery, %{"volts" => "48"})
    assert {:ok, %{system: "48"}} = Build.wire(changed, id)
    assert {:ok, %{system: "24"}} = Build.wire(changed, other)

    # The person cannot give a wire of a battery a different system.
    {:ok, same} = Build.update_wire(changed, id, %{"system" => "12", "amps" => "20"})
    assert {:ok, %{system: "48", amps: 20.0}} = Build.wire(same, id)

    # A stored wire with a different system gets the system of its battery.
    map = Jason.decode!(Build.to_json(changed))

    wires =
      Enum.map(map["wires"], fn wire ->
        if wire["id"] == id, do: %{wire | "system" => "12"}, else: wire
      end)

    assert {:ok, loaded} = Build.from_json(Jason.encode!(%{map | "wires" => wires}))
    assert {:ok, %{system: "48"}} = Build.wire(loaded, id)
  end

  test "the wires in the JSON of the build" do
    {build, station, bus} = garage()
    {:ok, build, id} = Build.add_wire(build, station, bus)
    {:ok, build} = Build.update_wire(build, id, %{"awg" => "6", "from_ocpd" => "40"})
    assert {:ok, read} = read(build)
    assert read.wires == build.wires

    map = Jason.decode!(Build.to_json(build))
    [stored] = map["wires"]

    # A build of an older version has no wires.
    {:ok, old} = Build.from_json(Jason.encode!(Map.delete(map, "wires")))
    assert old.wires == []

    # A wire that the app cannot read goes away: the build loads.
    fridge = Enum.find(build.items, &(&1.type == "fridge")).id

    for bad <- [
          %{stored | "id" => 5},
          %{stored | "from" => "i0"},
          %{stored | "to" => "i0"},
          %{stored | "to" => station},
          %{stored | "to" => fridge},
          %{stored | "amps" => -1},
          Map.delete(stored, "to"),
          "w1"
        ] do
      assert {:ok, %{wires: []}} = Build.from_json(Jason.encode!(%{map | "wires" => [bad]}))
    end

    # A wire with no numbers gets the typical numbers. A second wire with
    # the same id goes away.
    plain = Map.take(stored, ~w(id from to))
    twice = %{map | "wires" => [plain, %{stored | "amps" => 5}]}
    assert {:ok, %{wires: [wire]}} = Build.from_json(Jason.encode!(twice))
    assert %{amps: 30.0, awg: nil, system: "12"} = wire

    # 100 wires at most, and the ids of the wires count for the next id.
    many = for n <- 1..105, do: %{stored | "id" => "w#{n + 200}"}
    {:ok, loaded} = Build.from_json(Jason.encode!(%{map | "wires" => many}))
    assert length(loaded.wires) == 100
    assert List.last(loaded.wires).id == "w300"
    assert loaded.seq >= 300

    # The 100 wires are the first good wires: bad wires do not count.
    bad = for n <- 1..100, do: %{stored | "id" => "w#{n + 400}", "to" => "i0"}
    good = for n <- 1..5, do: %{stored | "id" => "w#{n + 600}"}
    {:ok, loaded} = Build.from_json(Jason.encode!(%{map | "wires" => bad ++ good}))
    assert Enum.map(loaded.wires, & &1.id) == ~w(w601 w602 w603 w604 w605)

    # A long id: the next id is longer, and the wires stay after a load.
    long = %{stored | "id" => "w" <> String.duplicate("9", 19)}
    {:ok, loaded} = Build.from_json(Jason.encode!(%{map | "wires" => [long]}))
    {:ok, more, _id} = Build.add_wire(loaded, station, bus)
    assert {:ok, %{wires: [_one, _two]}} = read(more)

    # Wires that are not a list: the build is not valid.
    assert Build.from_json(Jason.encode!(%{map | "wires" => %{}})) == {:error, :wires}
  end

  property "a wire always has an item that takes wires at each end" do
    {build, station, bus} = garage()
    {build, battery} = add(build, room(build, "Garage"), "power_station")
    ids = [station, bus, battery]

    steps =
      list_of(
        one_of([
          tuple({constant(:add), member_of(ids), member_of(ids)}),
          tuple({constant(:delete), member_of(ids)}),
          tuple({constant(:update), integer(0..3), member_of(["5", "0", "48"])})
        ]),
        max_length: 12
      )

    check all(steps <- steps) do
      final =
        Enum.reduce(steps, build, fn
          {:add, a, b}, build ->
            case Build.add_wire(build, a, b) do
              {:ok, build, _id} -> build
              {:error, _} -> build
            end

          {:delete, id}, build ->
            case Build.delete_item(build, id) do
              {:ok, build} -> build
              {:error, _} -> build
            end

          {:update, n, value}, build ->
            case Enum.at(build.wires, n) do
              nil ->
                build

              wire ->
                case Build.update_wire(build, wire.id, %{"amps" => value}) do
                  {:ok, build} -> build
                  {:error, :amps} -> build
                end
            end
        end)

      for wire <- final.wires do
        assert {:ok, a} = Build.item(final, wire.from)
        assert {:ok, b} = Build.item(final, wire.to)
        assert a.id != b.id and Build.wired?(a) and Build.wired?(b)
      end

      assert {:ok, read} = read(final)
      assert read.wires == final.wires
    end
  end
end
