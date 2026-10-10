defmodule DIY.BuildTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, House}

  defp house(overrides),
    do: Map.merge(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil}, overrides)

  # A build with the preset of a house.
  defp preset(overrides \\ %{}) do
    {house, rooms, items} = House.preset(house(overrides))
    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room_named(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  test "a new build has no revision, no stamp and no door" do
    assert %Build{version: 1, revision: 0, stamp: "", door: nil, rooms: [], items: []} =
             Build.new()

    assert Build.version() == 1
    assert Build.doors() == ["my_house", "planning"]
    assert Build.heats() == ["gas", "heat_pump", "electric"]
  end

  test "each change adds 1 to the revision and makes a new stamp" do
    {:ok, one} = Build.choose_door(Build.new(), "my_house")
    {:ok, two} = Build.choose_door(one, "planning")
    assert {one.revision, two.revision} == {1, 2}
    assert one.stamp != "" and two.stamp != one.stamp
    assert two.door == "planning"
  end

  test "a door that is not a door is an error" do
    assert Build.choose_door(Build.new(), "garage") == {:error, :door}
  end

  test "a restart keeps the revision and clears the build" do
    build = preset()
    restarted = Build.restart(build)
    assert restarted.revision == build.revision + 1
    assert %{door: nil, house: nil, rooms: [], items: []} = restarted
  end

  test "the levels of a house, from the roof to the ground" do
    assert Build.levels(1) == ["roof", "f1", "outside"]
    assert Build.levels(3) == ["roof", "f3", "f2", "f1", "outside"]
    assert Build.level_name("roof") == "Roof and attic"
    assert Build.level_name("f2") == "Floor 2"
    assert Build.level_name("outside") == "Around the house"
  end

  test "the ZIP code, the market and the price" do
    {:ok, build} = Build.set_zip(Build.new(), " 75070 ")
    assert build.zip == "75070"
    assert Build.set_zip(build, "00000") == {:error, :zip}

    market = %{
      choice: true,
      utility: "Oncor",
      median: 13.4,
      plans: 168,
      date: "2026-10-08",
      source: "ptc"
    }

    build = Build.set_market(build, market)
    assert build.market == market
    {:ok, other} = Build.set_zip(build, "78701")
    assert other.market == nil
    # The same ZIP code makes no change: the market stays.
    assert Build.set_zip(build, "75070") == {:ok, build}

    assert {:ok, %{price: 14.5}} = Build.set_price(build, 14.5)
    assert {:ok, %{price: 14.0}} = Build.set_price(build, 14)
    assert {:ok, %{price: nil}} = Build.set_price(build, nil)

    # The kWh of a real bill and its month.
    assert {:ok, %{bill: %{month: 7, kwh: 1150.0}}} =
             Build.set_bill(build, %{month: 7, kwh: 1150})

    assert {:ok, %{bill: nil}} = Build.set_bill(build, nil)

    for bad <- [%{month: 13, kwh: 1000}, %{month: 7, kwh: 0}, %{month: nil, kwh: 1}, "July"],
        do: assert(Build.set_bill(build, bad) == {:error, :bill})

    assert Build.set_price(build, 0) == {:error, :price}
    assert Build.set_price(build, 500) == {:error, :price}
    assert Build.set_price(build, "14") == {:error, :price}
  end

  test "a preset gives the rooms and the typical items, with new ids" do
    build = preset()
    assert length(build.rooms) == 12
    assert Enum.all?(build.items, & &1.typical)
    ids = Enum.map(build.rooms, & &1.id) ++ Enum.map(build.items, & &1.id)
    assert ids == Enum.uniq(ids)
    assert build.seq == length(ids)
    assert room_named(build, "Kitchen").level == "f1"
    assert room_named(build, "Bedroom 1").level == "f2"

    assert Build.rooms_on(build, "outside") |> Enum.map(& &1.name) == [
             "Garage",
             "Backyard",
             "Driveway"
           ]

    assert [%{type: "ac"}] = Build.items_in(build, room_named(build, "Backyard").id)
  end

  test "the numbers of the house change, if the rooms fit the floors" do
    build = preset()
    assert {:ok, %{house: %{size: 2000}}} = Build.update_house(build, %{size: 2000})
    assert {:ok, %{house: %{floors: 3}}} = Build.update_house(build, %{floors: 3})
    assert Build.update_house(build, %{floors: 1}) == {:error, :floors}
    assert Build.update_house(build, %{size: 10}) == {:error, :house}
    assert Build.update_house(build, %{heat: "wood"}) == {:error, :house}
    # A build with no house yet.
    assert Build.update_house(Build.new(), %{size: 2000}) == {:error, :house}
    assert Build.add_room(Build.new(), "Office", "f1", :indoor) == {:error, :house}
  end

  test "rooms: add, rename and remove" do
    build = preset()
    assert {:ok, build, id} = Build.add_room(build, "Office", "f2", :indoor)
    assert {:ok, %{name: "Office", level: "f2", place: :indoor}} = Build.room(build, id)
    assert Build.add_room(build, " ", "f2", :indoor) == {:error, :name}
    assert Build.add_room(build, "Loft", "f3", :indoor) == {:error, :level}
    assert Build.add_room(build, "Loft", "f2", :basement) == {:error, :place}

    assert {:ok, build} = Build.rename_room(build, id, "Studio")
    assert {:ok, %{name: "Studio"}} = Build.room(build, id)
    assert Build.rename_room(build, "r999", "x") == {:error, :room}
    assert Build.rename_room(build, id, nil) == {:error, :name}

    kitchen = room_named(build, "Kitchen")
    assert Build.items_in(build, kitchen.id) != []
    assert {:ok, build} = Build.delete_room(build, kitchen.id)
    assert Build.items_in(build, kitchen.id) == []
    assert Build.delete_room(build, kitchen.id) == {:error, :room}
  end

  test "the links of the rooms to the areas of Home Assistant" do
    build = preset()
    kitchen = room_named(build, "Kitchen")
    assert build.areas == %{}
    assert {:ok, build} = Build.link_area(build, kitchen.id, "kitchen")
    assert build.areas == %{kitchen.id => "kitchen"}
    assert Build.from_json(Build.to_json(build)) == {:ok, build}
    assert Build.link_area(build, "r999", "den") == {:error, :room}
    assert Build.link_area(build, kitchen.id, "") == {:error, :area}
    assert Build.link_area(build, kitchen.id, String.duplicate("a", 101)) == {:error, :area}
    assert Build.link_area(build, kitchen.id, 5) == {:error, :area}
    assert {:ok, %{areas: areas}} = Build.link_area(build, kitchen.id, nil)
    assert areas == %{}

    # A zone of a van has no area.
    {:ok, build, van} = Build.add_item(build, room_named(build, "Driveway").id, "camper_van")
    [zone | _zones] = Build.zones(build, van)
    assert Build.link_area(build, zone.id, "van") == {:error, :room}

    # The link goes with its room.
    assert {:ok, %{areas: areas}} = Build.delete_room(build, kitchen.id)
    assert areas == %{}
  end

  test "items: add, change, check, move and remove" do
    build = preset()
    kitchen = room_named(build, "Kitchen")
    garage = room_named(build, "Garage")
    backyard = room_named(build, "Backyard")

    assert {:ok, build, id} = Build.add_item(build, kitchen.id, "freezer")
    assert {:ok, %{typical: false, params: %{"kwh_year" => 400}}} = Build.item(build, id)
    assert Build.add_item(build, kitchen.id, "rocket") == {:error, :type}
    assert Build.add_item(build, kitchen.id, "pool_pump") == {:error, :place}
    assert Build.add_item(build, "r999", "freezer") == {:error, :room}

    assert {:ok, build} = Build.update_item(build, id, %{"kwh_year" => "350"})
    assert {:ok, %{params: %{"kwh_year" => 350}}} = Build.item(build, id)
    assert Build.update_item(build, id, %{"kwh_year" => "-1"}) == {:error, {:param, "kwh_year"}}
    assert Build.update_item(build, "i999", %{}) == {:error, :item}

    [fridge] = Enum.filter(build.items, &(&1.type == "fridge"))
    assert fridge.typical
    assert {:ok, build} = Build.check_item(build, fridge.id)
    assert {:ok, %{typical: false}} = Build.item(build, fridge.id)
    assert Build.check_item(build, "i999") == {:error, :item}

    assert {:ok, build} = Build.move_item(build, id, garage.id)
    assert {:ok, %{room: room}} = Build.item(build, id)
    assert room == garage.id
    assert Build.move_item(build, id, backyard.id) == {:error, :place}
    assert Build.move_item(build, id, "r999") == {:error, :room}
    assert Build.move_item(build, "i999", garage.id) == {:error, :item}

    assert {:ok, build} = Build.delete_item(build, id)
    assert Build.item(build, id) == {:error, :item}
    assert Build.delete_item(build, id) == {:error, :item}
  end

  test "the real usage goes in the build, and out of it" do
    {:ok, usage} =
      DIY.Usage.read(%{
        "source" => "smt",
        "months" => [
          %{"month" => "2025-07", "kwh" => 900, "export" => 0, "days" => 31}
        ]
      })

    build = Build.set_usage(preset(), usage)
    assert build.usage == usage
    assert Build.from_json(Build.to_json(build)) == {:ok, build}
    assert Build.set_usage(build, nil).usage == nil

    # A new house with no smart meter keeps no real usage.
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 1, heat: "gas", lot: nil})

    assert Build.put_house(build, house, rooms, items).usage == nil
  end

  test "the flags of an item, the power, and the build of today" do
    build = preset()
    fridge = Enum.find(build.items, &(&1.type == "fridge"))
    assert {:ok, build} = Build.flag_item(build, fridge.id, :backup, true)
    assert {:ok, %{backup: true, planned: false}} = Build.item(build, fridge.id)
    assert {:ok, build} = Build.flag_item(build, fridge.id, :planned, true)
    assert Build.flag_item(build, "i999", :planned, true) == {:error, :item}
    refute Enum.any?(Build.today(build).items, &(&1.id == fridge.id))
    assert length(Build.today(build).items) == length(build.items) - 1

    power = %{DIY.Power.settings() | mode: "night", night_cents: 3.5}
    build = Build.set_power(build, power)
    assert {:ok, %{power: ^power}} = Build.from_json(Build.to_json(build))
  end

  test "hints close one time" do
    assert {:ok, build} = Build.close_hint(Build.new(), "swipe")
    assert {:ok, %{hints: ["swipe"]}} = Build.close_hint(build, "swipe")
    assert Build.close_hint(build, "other") == {:error, :hint}
  end

  test "an import puts the build of a file in the place of the build" do
    build = preset()
    other = Build.restart(build)
    assert {:ok, imported} = Build.import(other, Build.export(build))
    assert imported.revision == other.revision + 1
    assert imported.items == build.items
    assert imported.stamp not in ["", build.stamp]
    assert Build.import(other, "not a build") == {:error, :not_json}
    assert Jason.decode!(Build.export(build))["stamp"] == ""
  end

  test "from_json gives the reason for a text that is not a build" do
    good = Jason.decode!(Build.to_json(preset()))
    bad = fn changes -> Build.from_json(Jason.encode!(Map.merge(good, changes))) end

    assert Build.from_json(nil) == {:error, :not_json}
    assert Build.from_json("{") == {:error, :not_json}
    assert Build.from_json("[1]") == {:error, :not_a_build}
    assert Build.from_json("{}") == {:error, :not_a_build}
    assert Build.from_json(~s({"version": 2})) == {:error, {:version, 2}}
    assert bad.(%{"revision" => -1}) == {:error, :revision}
    assert bad.(%{"stamp" => 5}) == {:error, :stamp}
    assert bad.(%{"door" => "attic"}) == {:error, :door}
    assert bad.(%{"zip" => "00000"}) == {:error, :zip}
    assert bad.(%{"market" => %{"choice" => 1}}) == {:error, :market}
    assert bad.(%{"price" => "cheap"}) == {:error, :price}
    assert bad.(%{"bill" => %{"month" => 0, "kwh" => 1000}}) == {:error, :bill}
    assert bad.(%{"bill" => "July"}) == {:error, :bill}
    assert bad.(%{"house" => %{"size" => 5}}) == {:error, :house}
    assert bad.(%{"house" => [1]}) == {:error, :house}
    assert bad.(%{"rooms" => "kitchen"}) == {:error, :rooms}
    assert bad.(%{"rooms" => [%{"id" => "r1"}]}) == {:error, :rooms}
    assert bad.(%{"rooms" => good["rooms"] ++ [hd(good["rooms"])]}) == {:error, :rooms}
    assert bad.(%{"rooms" => [Map.put(hd(good["rooms"]), "level", "f9")]}) == {:error, :rooms}
    assert bad.(%{"rooms" => [Map.put(hd(good["rooms"]), "place", "moon")]}) == {:error, :rooms}
    assert bad.(%{"items" => "fridge"}) == {:error, :items}
    assert bad.(%{"items" => [1]}) == {:error, :items}
    assert {:ok, %{items: []}} = bad.(%{"items" => [%{"id" => "i1"}]})
    assert bad.(%{"items" => good["items"] ++ [hd(good["items"])]}) == {:error, :items}
    # An item in a room that is not there was in a zone of a van that is
    # lost: it goes away.
    assert {:ok, %{items: []}} = bad.(%{"items" => [Map.put(hd(good["items"]), "room", "r999")]})
    assert bad.(%{"items" => [Map.put(hd(good["items"]), "type", "rocket")]}) == {:error, :items}

    assert bad.(%{"items" => [Map.put(hd(good["items"]), "params", %{"tons" => 99})]}) ==
             {:error, :items}

    assert bad.(%{"seq" => nil}) == {:error, :seq}
    assert bad.(%{"usage" => %{"source" => "x"}}) == {:error, :usage}
    assert bad.(%{"power" => %{"mode" => "turbo"}}) == {:error, :power}
    assert bad.(%{"items" => [Map.put(hd(good["items"]), "planned", "yes")]}) == {:error, :items}
    assert bad.(%{"items" => [Map.put(hd(good["items"]), "backup", 1)]}) == {:error, :items}

    # A build of an older version has no power, and its items have no
    # planned and no backup.
    old = %{good | "items" => Enum.map(good["items"], &Map.drop(&1, ["planned", "backup"]))}
    assert {:ok, build} = Build.from_json(Jason.encode!(Map.delete(old, "power")))
    assert build.power == DIY.Power.settings()
    assert Enum.all?(build.items, &(&1.planned == false and &1.backup == false))

    # A small seq gets the number of the last id, so that a new id is new.
    {:ok, build} = bad.(%{"seq" => 0})
    assert build.seq == preset().seq
    {:ok, _build, id} = Build.add_room(build, "Office", "f1", :indoor)
    assert id == "r#{preset().seq + 1}"
    room = %{hd(good["rooms"]) | "id" => "kitchen"}
    assert {:ok, %{seq: 0}} = bad.(%{"seq" => 0, "rooms" => [room], "items" => []})
    assert bad.(%{"hints" => ["x"]}) == {:error, :hints}
    assert bad.(%{"hints" => "swipe"}) == {:error, :hints}
    assert bad.(%{"areas" => ["kitchen"]}) == {:error, :areas}
    assert bad.(%{"areas" => %{"r1" => 5}}) == {:error, :areas}
    assert bad.(%{"areas" => %{"r1" => ""}}) == {:error, :areas}
    # A link of a room that is not there goes away. A build of an older
    # version has no links.
    assert {:ok, %{areas: %{}}} = bad.(%{"areas" => %{"r999" => "den"}})
    assert {:ok, %{areas: %{}}} = Build.from_json(Jason.encode!(Map.delete(good, "areas")))
    # An AC cannot be in a kitchen (inside).
    kitchen = Enum.find(good["rooms"], &(&1["name"] == "Kitchen"))
    ac = Enum.find(good["items"], &(&1["type"] == "ac"))
    assert bad.(%{"items" => [Map.put(ac, "room", kitchen["id"])]}) == {:error, :items}
  end

  # A random build: a preset of a random house, and random changes.
  defp build do
    gen all(
          size <- member_of([1200, 1800, 2500, 3500]),
          year <- integer(1950..2026),
          floors <- integer(1..3),
          heat <- member_of(Build.heats()),
          lot <- one_of([constant(nil), integer(100..100_000)]),
          price <- one_of([constant(nil), float(min: 1.0, max: 50.0)]),
          bill <-
            one_of([
              constant(nil),
              fixed_map(%{month: integer(1..12), kwh: float(min: 1.0, max: 5000.0)})
            ]),
          market <-
            one_of([
              constant(nil),
              fixed_map(%{
                choice: boolean(),
                utility: one_of([constant(nil), string(:alphanumeric, min_length: 1)]),
                median: one_of([constant(nil), float(min: 1.0, max: 50.0)]),
                plans: integer(0..300),
                date: constant("2026-10-08"),
                source: member_of(["ptc", "user"])
              })
            ]),
          changes <- list_of({member_of(Catalog.types()), integer(0..20)}, max_length: 6),
          links <-
            list_of({integer(0..20), string(:alphanumeric, min_length: 1, max_length: 20)},
              max_length: 3
            )
        ) do
      {house, rooms, items} =
        House.preset(%{size: size, year: year, floors: floors, heat: heat, lot: lot})

      {:ok, build} = Build.choose_door(Build.new(), "my_house")
      {:ok, build} = Build.set_zip(build, "75070")
      {:ok, build} = Build.set_price(build, price)
      {:ok, build} = Build.set_bill(build, bill)
      build = if market, do: Build.set_market(build, market), else: build
      build = Build.put_house(build, house, rooms, items)

      build =
        Enum.reduce(changes, build, fn {type, index}, build ->
          room = Enum.at(build.rooms, rem(index, length(build.rooms)))

          case Build.add_item(build, room.id, type) do
            {:ok, build, _id} -> build
            {:error, _reason} -> build
          end
        end)

      Enum.reduce(links, build, fn {index, area}, build ->
        room = Enum.at(build.rooms, rem(index, length(build.rooms)))

        case Build.link_area(build, room.id, area) do
          {:ok, build} -> build
          {:error, _reason} -> build
        end
      end)
    end
  end

  property "to_json and from_json give the same build" do
    check all(build <- build()) do
      assert Build.from_json(Build.to_json(build)) == {:ok, build}
    end
  end

  property "from_json never raises for a build with one bad value" do
    check all(
            build <- build(),
            index <- integer(0..10_000),
            value <- bad_value()
          ) do
      map = build |> Build.to_json() |> Jason.decode!()
      all = paths(map, [])
      text = map |> put_at(Enum.at(all, rem(index, length(all))), value) |> Jason.encode!()
      assert {status, _} = Build.from_json(text)
      assert status in [:ok, :error]
    end
  end

  @bad [
    nil,
    [],
    %{},
    [1],
    %{"a" => 1},
    10 ** 400,
    -(10 ** 400),
    1.0e300,
    "2026-13-40",
    "-2025-07",
    "+2025-01",
    "0000-01",
    "2025-7",
    :delete
  ]

  test "from_json never raises for a build with a bad value at any place" do
    build = preset()
    {:ok, build, _id} = Build.add_item(build, room_named(build, "Kitchen").id, "other")
    {:ok, build} = Build.link_area(build, room_named(build, "Kitchen").id, "kitchen")
    map = build |> Build.to_json() |> Jason.decode!()

    map = %{
      map
      | "market" => %{
          "choice" => true,
          "utility" => "Oncor",
          "median" => 13.4,
          "plans" => 3,
          "date" => "2026-10-08",
          "source" => "ptc"
        },
        "price" => 12.5,
        "usage" => %{
          "source" => "smt",
          "months" => [
            %{"month" => "2025-07", "kwh" => 1500, "export" => 0, "days" => 31},
            %{"month" => "2025-08", "kwh" => 1600.5, "export" => 2.5, "days" => 20}
          ]
        }
    }

    assert {:ok, %{usage: %{months: [_, _]}}} = map |> Jason.encode!() |> Build.from_json()

    # A month with more days than the month has.
    february =
      put_at(map, ["usage", "months", 1], %{
        "month" => "2025-02",
        "kwh" => 1,
        "export" => 0,
        "days" => 29
      })

    assert Build.from_json(Jason.encode!(february)) == {:error, :usage}

    for path <- paths(map, []), value <- @bad do
      text = map |> put_at(path, value) |> Jason.encode!()
      assert {status, _} = Build.from_json(text), inspect({path, value})
      assert status in [:ok, :error]
    end
  end

  defp bad_value do
    one_of([integer(), float(), string(:printable), boolean(), member_of(@bad)])
  end

  # The path of each value of a JSON map: its keys and its list indexes.
  defp paths(map, path) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [path ++ [key] | paths(value, path ++ [key])] end)

  defp paths(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, i} -> [path ++ [i] | paths(value, path ++ [i])] end)
  end

  defp paths(_value, _path), do: []

  defp put_at(map, [key], :delete) when is_map(map), do: Map.delete(map, key)
  defp put_at(list, [i], :delete) when is_list(list), do: List.delete_at(list, i)
  defp put_at(_data, [], value), do: value

  defp put_at(map, [key | rest], value) when is_map(map),
    do: Map.put(map, key, put_at(map[key], rest, value))

  defp put_at(list, [i | rest], value) when is_list(list),
    do: List.replace_at(list, i, put_at(Enum.at(list, i), rest, value))

  property "from_json never raises" do
    check all(text <- one_of([string(:printable), json()])) do
      assert {status, _} = Build.from_json(text)
      assert status in [:ok, :error]
    end
  end

  # A JSON text of a map with some of the keys of a build, and random values.
  defp json do
    value =
      one_of([
        integer(),
        string(:printable),
        boolean(),
        constant(nil),
        constant([]),
        constant(%{})
      ])

    keys =
      member_of(
        ~w(version revision stamp door zip market price house rooms items seq hints other)
      )

    likely = member_of([1, "my_house", "planning", "75070"])

    gen all(pairs <- list_of({keys, one_of([value, likely])}, max_length: 8)) do
      pairs |> Map.new() |> Jason.encode!()
    end
  end
end
