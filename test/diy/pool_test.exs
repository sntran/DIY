defmodule DIY.PoolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, Estimate, House, Layout, Power, Profile, Stubs, Weather}

  defp climate do
    {:ok, climate} = Weather.parse(Stubs.power(), 33.25, -96.75, 2016, 2025)
    climate
  end

  defp build do
    {house, rooms, items} =
      House.preset(%{size: 2000, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  defp add(build, room_id, type, params \\ %{}) do
    {:ok, build, id} = Build.add_item(build, room_id, type)
    {:ok, build} = Build.update_item(build, id, params)
    {build, id}
  end

  describe "a pool room" do
    test "is a room of the kind pool, inside or outside, with water of 30 by 15 ft" do
      {:ok, build, outdoor} = Build.add_room(build(), "Pool", "outside", :outdoor, "pool")
      {:ok, build, indoor} = Build.add_room(build, "Spa", "f1", :indoor, "pool")
      {:ok, out} = Build.room(build, outdoor)
      {:ok, ins} = Build.room(build, indoor)

      assert Build.pool?(out) and Build.pool?(ins)
      refute Build.pool?(room(build, "Kitchen"))
      assert {out.plan.w, out.plan.d} == {432, 336}
      assert {ins.plan.w, ins.plan.d} == {432, 336}
      assert Layout.water(out.plan) == %{x: 36, y: 120, w: 360, d: 180}
      assert Layout.max_room() >= 432
    end

    test "is never on the roof or in the attic, and has no other kind" do
      assert Build.add_room(build(), "Pool", "roof", :roof, "pool") == {:error, :pool_place}
      assert Build.add_room(build(), "Pool", "roof", :indoor, "pool") == {:error, :pool_place}
      attic = room(build(), "Attic").id
      assert Build.set_pool(build(), attic, true) == {:error, :pool_place}
      refute Build.pool_place?(room(build(), "Attic"))
      assert Build.pool_place?(room(build(), "Kitchen"))
      assert Build.add_room(build(), "Pool", "outside", :outdoor, "lake") == {:error, :kind}
      assert Build.add_room(Build.new(), "Pool", "outside", :outdoor, "pool") == {:error, :house}
    end

    test "keeps its kind in the file of the build; a bad kind is lost" do
      {:ok, build, id} = Build.add_room(build(), "Pool", "outside", :outdoor, "pool")
      {:ok, back} = build |> Build.to_json() |> Build.from_json()
      assert {:ok, %{kind: "pool"}} = Build.room(back, id)

      map = Jason.decode!(Build.to_json(build))

      rooms =
        Enum.map(map["rooms"], fn
          %{"id" => ^id} = room -> Map.put(room, "kind", "lake")
          %{"name" => name} = room when name in ["Roof", "Attic"] -> Map.put(room, "kind", "pool")
          room -> room
        end)

      {:ok, back} = Build.from_json(Jason.encode!(%{map | "rooms" => rooms}))
      refute back.rooms |> Enum.any?(&Build.pool?/1)
    end

    test "a link of a shared house keeps the pool" do
      {:ok, build, id} = Build.add_room(build(), "Pool", "outside", :outdoor, "pool")
      {:ok, build, _tub} = Build.add_item(build, id, "hot_tub")
      summary = DIY.Share.summary(List.duplicate(1000, 12), 1500, "en")
      {:ok, data} = DIY.Share.encode(build, summary)
      {:ok, shared, _s} = DIY.Share.decode(data)
      assert {:ok, %{kind: "pool"}} = Build.room(shared, id)
      assert Enum.any?(shared.items, &(&1.type == "hot_tub" and &1.room == id))
    end

    test "turns on and off; a pool inside keeps the items that only a pool takes" do
      kitchen = room(build(), "Kitchen").id
      {:ok, build} = Build.set_pool(build(), kitchen, true)
      assert Build.pool?(room(build, "Kitchen"))
      {build, _pump} = add(build, kitchen, "pool_pump")

      assert Build.set_pool(build, kitchen, false) == {:error, :items}

      roof = room(build, "Roof").id
      assert Build.set_pool(build, roof, true) == {:error, :pool_place}
      assert Build.set_pool(build, "r999", true) == {:error, :room}

      # Outside, a pool pump goes in any room: the pool can stop.
      {:ok, build, pool} = Build.add_room(build, "Pool", "outside", :outdoor, "pool")
      {build, _pump} = add(build, pool, "pool_pump")
      assert {:ok, build} = Build.set_pool(build, pool, false)
      refute build |> Build.room(pool) |> elem(1) |> Build.pool?()
    end
  end

  describe "the deck of a pool" do
    test "a small room has a narrow deck, and water in it" do
      assert Layout.water(%{w: 24, d: 24}) == %{x: 4, y: 9, w: 16, d: 11}
      assert Layout.water(%{w: 120, d: 120}) == %{x: 20, y: 45, w: 80, d: 55}
    end

    property "the water is in the room, with a deck on each side" do
      check all(
              w <- integer(Layout.min_room()..Layout.max_room()),
              d <- integer(Layout.min_room()..Layout.max_room())
            ) do
        water = Layout.water(%{w: w, d: d})
        assert water.x > 0 and water.y > 0 and water.w > 0 and water.d > 0
        assert water.x + water.w < w and water.y + water.d < d
      end
    end

    test "a new item of a pool goes on the deck, not on the water" do
      {:ok, build, pool} = Build.add_room(build(), "Pool", "outside", :outdoor, "pool")
      {:ok, room} = Build.room(build, pool)
      water = Layout.water(room.plan)

      build =
        Enum.reduce(~w(pool_pump pool_heater hot_tub lights), build, fn type, build ->
          {:ok, build, _id} = Build.add_item(build, pool, type)
          build
        end)

      for item <- build.items, item.room == pool do
        refute Layout.overlap?(Layout.item_box(item), water), "#{item.type} is on the water"
      end
    end
  end

  describe "the items of a pool" do
    test "go outside or in a pool, not in a different room inside" do
      build = build()
      kitchen = room(build, "Kitchen").id
      backyard = room(build, "Backyard").id
      {:ok, build, spa} = Build.add_room(build, "Spa", "f1", :indoor, "pool")

      for type <- ~w(pool_pump pool_heater hot_tub) do
        kind = Catalog.kind(type)
        assert Build.add_item(build, kitchen, type) == {:error, :place}
        assert {:ok, _build, _id} = Build.add_item(build, backyard, type)
        assert {:ok, _build, _id} = Build.add_item(build, spa, type)
        refute Catalog.fits?(kind, room(build, "Kitchen"))
        assert kind in Catalog.kinds_for_room(elem(Build.room(build, spa), 1))
      end

      {build, tub} = add(build, spa, "hot_tub")
      assert Build.move_item(build, tub, kitchen) == {:error, :place}
      assert {:ok, _build} = Build.move_item(build, tub, backyard)
    end
  end

  describe "the search of the kinds" do
    test "finds a kind by its name or by its more words, with no difference of capitals" do
      types = &Enum.map(Catalog.search(&1), fn kind -> kind.type end)

      assert "ev" in types.("Tesla")
      assert "ev" in types.("wall connector")
      assert Enum.all?(~w(pool_pump pool_heater), &(&1 in types.("pool")))
      assert Enum.all?(~w(pool_pump pool_heater hot_tub), &(&1 in types.("Spa")))
      assert "hot_tub" in types.("Jacuzzi")
      assert "fridge" in types.("refrigerator")
      assert types.("zzz") == []
      # A word of the text is the start of a word.
      assert "ev" in types.("tes")
      assert "ev" in types.("TESLA, wall")
      assert "ac" in types.("heat pump")
      refute "pool_pump" in types.("ump")
      assert types.("tesla zzz") == []
      assert length(Catalog.search("  ")) == length(Catalog.house_kinds())
      refute Enum.any?(Catalog.house_kinds(), &(&1.type == "van_fan"))
    end

    test "each more word is for a kind of the house" do
      for {type, words} <- Catalog.words() do
        assert %{} = kind = Catalog.kind(type)
        assert kind in Catalog.house_kinds()
        assert words != []
      end
    end

    test "tells where a kind goes" do
      assert Catalog.where(Catalog.kind("pool_pump")) == "a room outside or a pool"
      assert Catalog.where(Catalog.kind("lights")) == "a room inside or a room outside"
      assert Catalog.where(Catalog.kind("dishwasher")) == "a room inside"

      assert Catalog.where(Catalog.kind("other")) ==
               "a room inside, a room outside or the roof"
    end
  end

  describe "the use of the new items" do
    test "a pool heater: a heat pump uses power, a gas heater burns gas; a hot tub" do
      build = build()
      backyard = room(build, "Backyard").id
      {build, pump} = add(build, backyard, "pool_heater", %{"watts" => "5000", "hours" => "4"})

      {build, gas} =
        add(build, backyard, "pool_heater", %{"fuel" => "gas", "kbtu" => "400", "hours" => "2"})

      {build, tub} = add(build, backyard, "hot_tub", %{"kwh_day" => "6"})
      estimate = Estimate.run(build, climate())

      # July: 31 days, in the season "warm" (April to October).
      july = Enum.at(estimate.months, 6)
      assert_in_delta july.items[pump].kwh, 5000 * 4 * 31 / 1000, 0.01
      assert july.items[gas].kwh == 0.0
      assert_in_delta july.items[gas].therms, 400_000 * 2 * 31 / 100_000, 0.01
      assert_in_delta july.items[tub].kwh, 6 * 31, 0.01

      # January: the heaters are off, the hot tub runs all year.
      january = hd(estimate.months)
      assert january.items[pump].kwh == 0.0
      assert january.items[gas].therms == 0.0
      assert_in_delta january.items[tub].kwh, 6 * 31, 0.01

      for id <- [pump, gas, tub], month <- 1..12 do
        {:ok, item} = Build.item(build, id)
        assert Enum.all?(Estimate.explain(item, month, estimate), &is_binary/1)
      end

      {:ok, gas_item} = Build.item(build, gas)
      assert Enum.any?(Estimate.explain(gas_item, 7, estimate), &(&1 =~ "It burns gas"))
      assert Enum.any?(Estimate.explain(gas_item, 1, estimate), &(&1 =~ "It is off in January"))
      {:ok, tub_item} = Build.item(build, tub)
      assert Enum.any?(Estimate.explain(tub_item, 1, estimate), &(&1 =~ "6 kWh in one day"))

      {:ok, tub_off} = Build.update_item(build, tub, %{"season" => "summer"})
      {:ok, off_item} = Build.item(tub_off, tub)
      off = Estimate.run(tub_off, climate())
      assert Enum.any?(Estimate.explain(off_item, 1, off), &(&1 =~ "It is off in January"))

      assert Profile.watts(gas_item) == 300.0
      assert Profile.watts(tub_item) == 5_500.0
      # A heat pump has a compressor, and a gas heater has a blower. An
      # electric heater has no motor.
      assert Profile.motor?(%{type: "pool_heater", params: %{"fuel" => "heat_pump"}})
      assert Profile.motor?(gas_item)
      refute Profile.motor?(%{type: "pool_heater", params: %{"fuel" => "electric"}})
      refute Profile.motor?(tub_item)
    end

    test "a Tesla Wall Connector charges at 11.5 kW" do
      build = build()
      garage = room(build, "Garage").id
      {build, car} = add(build, garage, "ev", %{"charger" => "l2_48", "miles" => "40"})
      {:ok, item} = Build.item(build, car)

      assert Profile.charger_kw("l2_48") == 11.5
      assert Profile.watts(item) == 11_500.0
      assert Estimate.charge_efficiency("l2_48") == 0.9
      assert_in_delta Profile.charge_hours(item, 23.0), 2.0, 0.001

      estimate = Estimate.run(build, climate())
      july = Enum.at(estimate.months, 6)
      assert_in_delta july.items[car].kwh, 40 * 31 / item.params["mi_kwh"] / 0.9, 0.01
      assert Power.system(build.items).chargers |> Enum.map(& &1.id) == [car]
    end
  end

  describe "the model of specs/Pool.tla" do
    property "each item fits its room after any steps, and no pool is on the roof" do
      base = build()
      {:ok, base, _id} = Build.add_room(base, "Pool", "outside", :outdoor, "pool")
      rooms = Enum.map(base.rooms, & &1.id)
      types = ~w(hot_tub pool_pump pool_heater dishwasher lights fridge)

      step =
        one_of([
          tuple({constant(:add), member_of(rooms), member_of(types)}),
          tuple({constant(:move), integer(0..30), member_of(rooms)}),
          tuple({constant(:pool), member_of(rooms), boolean()})
        ])

      check all(steps <- list_of(step, max_length: 25)) do
        build = Enum.reduce(steps, base, &run/2)

        for item <- build.items, item.room in rooms do
          {:ok, room} = Build.room(build, item.room)
          assert Catalog.fits?(Catalog.kind(item.type), room), "#{item.type} in #{room.name}"
        end

        refute Enum.any?(build.rooms, &(Build.pool?(&1) and not Build.pool_place?(&1)))
      end
    end
  end

  defp run({:add, room, type}, build) do
    case Build.add_item(build, room, type) do
      {:ok, build, _id} -> build
      {:error, :place} -> build
    end
  end

  defp run({:move, n, room}, build) do
    item = Enum.at(build.items, rem(n, length(build.items)))

    case Build.move_item(build, item.id, room) do
      {:ok, build} -> build
      {:error, _reason} -> build
    end
  end

  defp run({:pool, room, pool}, build) do
    case Build.set_pool(build, room, pool) do
      {:ok, build} -> build
      {:error, reason} when reason in [:items, :pool_place] -> build
    end
  end
end
