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

  # A file of a build of October 2026: the JSON of a build, with the rooms
  # changed by a function.
  defp old_file(build, change) do
    map = build |> Build.to_json() |> Jason.decode!()
    Jason.encode!(%{map | "rooms" => Enum.map(map["rooms"], change)})
  end

  describe "a pool" do
    test "is an item of a room inside or outside, with water of 30 by 15 ft" do
      build = build()
      backyard = room(build, "Backyard").id
      {build, pool} = add(build, backyard, "pool")
      {:ok, item} = Build.item(build, pool)
      assert Layout.size(item) == {408, 228, 6}
      assert Layout.water(%{w: 408, d: 228}) == %{x: 24, y: 24, w: 360, d: 180}

      # A spa is a pool in a room inside.
      {:ok, build, spa} = Build.add_room(build, "Spa", "f1", :indoor)
      {build, _spa_pool} = add(build, spa, "pool")
      assert Enum.count(build.items, &(&1.type == "pool")) == 2

      # It uses no power: its pump and its heater are items.
      estimate = Estimate.run(build, climate())
      assert Enum.all?(estimate.months, &(&1.items[pool].kwh == 0.0))
      assert Profile.watts(item) == 0.0

      assert [_ | _] = Estimate.explain(item, 7, estimate)
      assert Enum.any?(Estimate.explain(item, 7, estimate), &(&1 =~ "uses no power"))
    end

    test "is never on the roof or in the attic, and nor is a hot tub" do
      build = build()

      for name <- ["Roof", "Attic"], type <- ~w(pool hot_tub) do
        refute Catalog.fits?(Catalog.kind(type), room(build, name))
        assert Build.add_item(build, room(build, name).id, type) == {:error, :place}
      end

      {build, tub} = add(build, room(build, "Backyard").id, "hot_tub")
      assert Build.move_item(build, tub, room(build, "Attic").id) == {:error, :place}
    end

    test "fills a room that is smaller than the pool" do
      {:ok, build, spa} = Build.add_room(build(), "Spa", "f1", :indoor)
      {:ok, room} = Build.room(build, spa)
      {build, pool} = add(build, spa, "pool")
      {:ok, item} = Build.item(build, pool)
      assert Layout.size(item) == {min(408, room.plan.w), min(228, room.plan.d), 6}
      assert item.at == %{x: 0, y: 0}
    end

    test "keeps its place and its size in the file and in a shared link" do
      build = build()
      {build, pool} = add(build, room(build, "Backyard").id, "pool")
      {:ok, build} = Build.size_item(build, pool, %{w: 300, d: 150, h: 6})
      {:ok, back} = build |> Build.to_json() |> Build.from_json()
      assert Build.item(back, pool) == Build.item(build, pool)

      summary = DIY.Share.summary(List.duplicate(1000, 12), 1500, "en")
      {:ok, data} = DIY.Share.encode(build, summary)
      {:ok, shared, _s} = DIY.Share.decode(data)
      assert {:ok, %{type: "pool", size: %{w: 300, d: 150}}} = Build.item(shared, pool)
    end

    test "a room of the kind pool of an older file gets a pool item at its water" do
      build = build()
      yard = room(build, "Backyard")
      attic = room(build, "Attic")
      {build, tub} = add(build, yard.id, "hot_tub")

      text =
        old_file(build, fn
          %{"id" => id} = room when id in [yard.id, attic.id] -> Map.put(room, "kind", "pool")
          room -> room
        end)

      {:ok, back} = Build.from_json(text)
      refute Enum.any?(back.rooms, &Map.has_key?(&1, :kind))
      assert {:ok, %{room: room}} = Build.item(back, tub)
      assert room == yard.id

      # The water of the room: a deck of 3 ft at the sides and at the
      # front, and of 10 ft at the back. The attic gets no pool.
      assert [pool] = Enum.filter(back.items, &(&1.type == "pool"))
      {side, front, rear} = {36, 36, min(120, div(yard.plan.d * 3, 8))}
      assert pool.room == yard.id
      assert pool.at == %{x: side, y: rear}
      assert pool.size == %{w: yard.plan.w - 2 * side, d: yard.plan.d - rear - front, h: 6}

      # Its id is new, and the next ids come after it.
      assert Enum.uniq_by(back.items, & &1.id) == back.items
      {:ok, next, id} = Build.add_item(back, yard.id, "lights")
      refute Enum.any?(back.items, &(&1.id == id))
      assert {:ok, _} = Build.item(next, pool.id)

      # A room of a different kind keeps no kind.
      {:ok, plain} = Build.from_json(old_file(build, &Map.put(&1, "kind", "lake")))
      refute Enum.any?(plain.items, &(&1.type == "pool"))

      # A bad room is the error of a bad room, as before.
      assert Build.from_json(old_file(build, fn _room -> 5 end)) == {:error, :rooms}
    end
  end

  describe "the water of a pool" do
    test "a small pool has a narrow coping" do
      assert Layout.water(%{w: 24, d: 24}) == %{x: 3, y: 3, w: 18, d: 18}
      assert Layout.water(%{w: 5, d: 400}) == %{x: 0, y: 0, w: 5, d: 400}
    end

    property "the water is in the pool, with the same coping on each side" do
      check all(w <- integer(1..1200), d <- integer(1..1200)) do
        water = Layout.water(%{w: w, d: d})
        assert water.x >= 0 and water.x == water.y
        assert water.w > 0 and water.d > 0
        assert water.x + water.w + water.x == w and water.y + water.d + water.y == d
      end
    end

    test "a new item goes next to the pool, not on the water" do
      # A yard of 60 by 40 ft, far from the house.
      {:ok, build, backyard} = Build.add_room(build(), "Yard", "outside", :outdoor)
      {:ok, build} = Build.size_room(build, backyard, %{x: 2400, y: 0, w: 720, d: 480})
      {build, pool} = add(build, backyard, "pool")
      {:ok, item} = Build.item(build, pool)

      build =
        Enum.reduce(~w(pool_pump pool_heater hot_tub lights), build, fn type, build ->
          {build, _id} = add(build, backyard, type)
          build
        end)

      for other <- build.items, other.room == backyard, other.id != pool do
        refute Layout.overlap?(Layout.item_box(other), Layout.item_box(item)),
               "#{other.type} is on the pool"
      end
    end
  end

  describe "the items of a pool" do
    test "go in a room inside or outside, next to a pool" do
      build = build()

      for type <- ~w(pool_pump pool_heater hot_tub), name <- ["Kitchen", "Backyard"] do
        assert {:ok, _build, _id} = Build.add_item(build, room(build, name).id, type)
      end

      assert Catalog.where(Catalog.kind("pool")) == "a room inside or a room outside"
    end
  end

  describe "the search of the kinds" do
    test "finds a kind by its name or by its more words, with no difference of capitals" do
      types = &Enum.map(Catalog.search(&1), fn kind -> kind.type end)

      assert "ev" in types.("Tesla")
      assert "ev" in types.("wall connector")
      assert Enum.all?(~w(pool pool_pump pool_heater), &(&1 in types.("pool")))
      assert Enum.all?(~w(pool pool_pump pool_heater hot_tub), &(&1 in types.("Spa")))
      assert "pool" in types.("swimming")
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
      assert Catalog.where(Catalog.kind("pool_pump")) == "a room inside or a room outside"
      assert Catalog.where(Catalog.kind("ac")) == "a room outside or the roof"
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
      rooms = Enum.map(base.rooms, & &1.id)
      types = ~w(pool hot_tub pool_pump dishwasher lights fridge)

      step =
        one_of([
          tuple({constant(:add), member_of(rooms), member_of(types)}),
          tuple({constant(:move), integer(0..30), member_of(rooms)}),
          tuple({constant(:place), integer(0..30), member_of(rooms)})
        ])

      check all(steps <- list_of(step, max_length: 25)) do
        build = Enum.reduce(steps, base, &run/2)

        for item <- build.items, item.room in rooms do
          {:ok, room} = Build.room(build, item.room)
          assert Catalog.fits?(Catalog.kind(item.type), room), "#{item.type} in #{room.name}"

          if Catalog.kind(item.type)[:heavy],
            do: assert(room.level != "roof", "#{item.type} in #{room.name}")
        end

        # The file of the build keeps each item in its room.
        {:ok, back} = build |> Build.to_json() |> Build.from_json()
        assert Enum.map(back.items, &{&1.id, &1.room}) == Enum.map(build.items, &{&1.id, &1.room})
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

  # A drag of an item on the plan, to a room or in its own room.
  defp run({:place, n, room}, build) do
    item = Enum.at(build.items, rem(n, length(build.items)))

    case Build.place_item(build, item.id, room, %{x: 12, y: 12}) do
      {:ok, build} -> build
      {:error, _reason} -> build
    end
  end
end
