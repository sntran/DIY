defmodule DIY.SolarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, House, Solar}

  # A house of 1,800 sq ft, with panels on the roof.
  defp house(zip \\ "75070", params \\ %{}, floors \\ 2) do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: floors, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, zip)
    build = Build.put_house(build, house, rooms, items)
    add(build, "Roof", "solar_panels", params)
  end

  defp add(build, room, type, params) do
    room = Enum.find(build.rooms, &(&1.name == room))
    {:ok, build, id} = Build.add_item(build, room.id, type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  defp notes({build, id}), do: Solar.notes(build, elem(Build.item(build, id), 1))

  defp station(build, solar_w, room \\ "Kitchen") do
    {build, _id} = add(build, room, "power_station", %{"solar_w" => "#{solar_w}"})
    build
  end

  test "the panels of 400 W that one side of a roof holds" do
    # The top floor has 900 sq ft. One side is half of the roof, × 1.12
    # for the slope. The panels use 2/3 of it, 21.25 sq ft for each panel.
    assert Solar.roof(%{size: 1800, floors: 2}, "south") == %{panels: 15, watts: 6000}
    assert Solar.roof(%{size: 1800, floors: 1}, "east") == %{panels: 31, watts: 12_400}
    assert Solar.roof(%{size: 1800, floors: 3}, "south") == %{panels: 10, watts: 4000}
    # A flat roof: all of it.
    assert Solar.roof(%{size: 1800, floors: 2}, "flat") == %{panels: 28, watts: 11_200}
    assert Solar.roof(%{size: 60, floors: 1}, "south") == %{panels: 1, watts: 400}
  end

  property "a larger house holds more panels, and more floors hold fewer" do
    check all(
            size <- integer(200..10_000),
            more <- integer(0..2_000),
            floors <- integer(1..2),
            facing <- member_of(~w(south southeast east flat))
          ) do
      roof = Solar.roof(%{size: size, floors: floors}, facing)
      assert roof.watts == roof.panels * 400
      assert Solar.roof(%{size: size + more, floors: floors}, facing).panels >= roof.panels
      assert Solar.roof(%{size: size, floors: floors + 1}, facing).panels <= roof.panels
    end
  end

  test "a typical price in Texas for each watt, from the size of the system" do
    assert Solar.per_watt(3_499) == nil
    assert Solar.per_watt(3_500) == {3.40, 3.40}
    assert Solar.per_watt(6_000) == {2.98, 2.98}
    assert Solar.per_watt(10_499) == {2.65, 2.65}
    assert Solar.per_watt(10_500) == {2.25, 2.65}
  end

  test "panels on the roof that charge a station" do
    # No station yet: the roof and the station.
    assert [roof, none] = notes(house())

    assert roof ==
             "One side of the roof holds near 15 panels of 400 W (45 by 68 in): near 6,000 W. This is a simple model of the app, from the size and the floors of the house. A hip roof holds less."

    assert none =~ "No power station is in the house, so these panels charge nothing."

    # A station that takes all of their sun: 800 W × 80% = 640 W.
    {build, id} = house()
    assert [_roof] = notes({station(build, 640), id})
    assert [_roof, _lost] = notes({station(build, 639), id})

    # Too many watts for the solar input of the station.
    {build, id} = house("75070", %{"watts" => "8000"})
    assert [roof, lost] = notes({station(build, 1000), id})
    assert roof =~ "A hip roof holds less. 8,000 W is more than that."

    # A flat roof: all of it, and no hip roof.
    {build, flat} = house("75070", %{"facing" => "flat"})
    assert [flat_roof, _none] = notes({build, flat})
    assert flat_roof =~ "The roof holds near 28 panels of 400 W (45 by 68 in): near 11,200 W."
    refute flat_roof =~ "hip"

    # A station with no solar input.
    {build, id} = house()
    assert [_roof, zero] = notes({station(build, 0), id})
    assert zero =~ "The stations of the house take no sun: their solar input is 0 W."

    assert lost ==
             "In full sun, the panels give near 6,400 W (80% of their labels). The stations take at most 1,000 W: the rest is lost. The page Power gives the kWh of one year. Use fewer panels, a station with more solar input, or \"The house and the grid\"."

    # As many watts as the roof holds: no word of more.
    {build, id} = house("75070", %{"watts" => "6000"})
    refute hd(notes({build, id})) =~ "more than that"

    # A very small roof holds 1 panel.
    tiny = %{build | house: %{build.house | size: 60, floors: 1}}
    assert hd(notes({tiny, id})) =~ "holds near 1 panel of 400 W"
  end

  test "the stations and the panels of the house add up; a station in a van does not count" do
    {build, id} = house("75070", %{"watts" => "1000"})
    {build, _yard} = add(build, "Backyard", "solar_panels", %{"watts" => "1000"})

    # 2,000 W × 80% = 1,600 W of sun: one station of 800 W takes half.
    one = station(build, 800)
    assert [_roof, lost] = notes({one, id})
    assert lost =~ "the panels give near 1,600 W"
    assert lost =~ "at most 800 W"

    # Two stations of 800 W take all of it.
    assert [_roof] = notes({station(one, 800, "Laundry"), id})

    # A station in a van is not in the house.
    {with_van, van} = add(build, "Driveway", "camper_van", %{})
    bay = Build.zone(with_van, van, :bay)
    {:ok, with_van, _station} = Build.add_item(with_van, bay.id, "power_station")
    assert [_roof, none] = notes({with_van, id})
    assert none =~ "No power station is in the house"
  end

  test "panels on the grid: a typical price in Texas" do
    assert [_roof, price] = notes(house("75070", %{"to" => "grid", "watts" => "6000"}))

    assert price ==
             "On a roof in Texas, a system of 6 kW costs near $2.98 for each watt, with the installation (SolarReviews, October 2026). For 6,000 W: near $17,880. A system that is complete after 2025 gets no US tax credit for its owner (section 25D, Public Law 119-21)."

    assert [_roof, small] = notes(house("75070", %{"to" => "grid"}))
    assert small =~ "a system of 4 kW costs near $3.40 for each watt"
    assert small =~ "A smaller system costs more for each watt."

    assert [_roof, large] = notes(house("75070", %{"to" => "grid", "watts" => "12000"}))
    assert large =~ "a large system costs near $2.25 to $2.65 for each watt"
    assert large =~ "For 12,000 W: near $27,000 to $31,800."

    # Outside Texas: no price.
    assert [_roof] = notes(house("10001", %{"to" => "grid"}))
  end

  test "panels in the yard: no note of the roof, and no price of a roof" do
    {build, id} = house("75070", %{"to" => "grid"})
    yard = Enum.find(build.rooms, &(&1.name == "Backyard"))
    {:ok, build} = Build.move_item(build, id, yard.id)
    assert notes({build, id}) == []
  end
end
