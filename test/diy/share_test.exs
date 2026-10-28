defmodule DIY.ShareTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, House, Share}

  # The DATA of the link of a house that a link can carry.
  defp encode!(build, summary, opts \\ []) do
    {:ok, data} = Share.encode(build, summary, opts)
    data
  end

  # A build of a preset house, with links to Home Assistant and to a maker,
  # and the state of the app of the person.
  defp house(opts \\ []) do
    preset = %{
      size: Keyword.get(opts, :size, 1800),
      year: 2005,
      floors: Keyword.get(opts, :floors, 2),
      heat: Keyword.get(opts, :heat, "gas"),
      lot: nil
    }

    {house, rooms, items} = House.preset(preset)
    {:ok, build} = Build.choose_door(Build.new(), Keyword.get(opts, :door, "my_house"))
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp linked(build) do
    room = Enum.find(build.rooms, &Build.area_room?/1)
    {:ok, build} = Build.link_area(build, room.id, "living_room")
    {:ok, build, _id} = Build.add_device(build, room.id, "lights", "device_1")
    {:ok, build, station} = Build.add_item(build, room.id, "power_station")
    {:ok, build} = Build.link_unit(build, station, "ecoflow:MR51ZAS4PG340123")
    build = Build.set_lesson(build, 3)
    %{build | hints: ["plan"], stamp: "abc"}
  end

  defp summary(cost \\ 1890), do: Share.summary(Enum.map(1..12, &(900 + &1 * 37.5)), cost, "en")

  # The JSON of a link, compressed and in base64url: a link that a person
  # can write by hand.
  defp data(json) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 9, :deflated, -15, 9, :default)
    out = z |> :zlib.deflate(json, :finish) |> IO.iodata_to_binary()
    :zlib.close(z)
    "1" <> Base.url_encode64(out, padding: false)
  end

  defp json(build, s) do
    Jason.encode!(%{
      "b" => build |> Build.to_json() |> Jason.decode!(),
      "s" => s
    })
  end

  @s %{"m" => List.duplicate(1000, 12), "c" => 1500, "l" => "en"}

  describe "strip/2" do
    test "removes the links to Home Assistant and to the makers, and the state of the app" do
      build = house() |> linked()
      assert build.areas != %{} and build.devices != %{} and build.units != %{}

      stripped = Share.strip(build)
      assert stripped.areas == %{} and stripped.devices == %{} and stripped.units == %{}
      assert stripped.revision == 0 and stripped.stamp == "" and stripped.hints == []
      assert stripped.lesson == 1 and stripped.lesson_plan == nil and stripped.plans == []
      # The house, its rooms and its items stay.
      assert stripped.rooms == build.rooms and stripped.items == build.items
      assert stripped.zip == "75070"
    end

    test "removes the ZIP code with zip: false" do
      assert Share.strip(house(), zip: false).zip == nil
    end
  end

  # A house with `n` more items in its first room, and `rooms` more rooms.
  defp large(build, n, rooms \\ 0) do
    room = Enum.find(build.rooms, &(&1.name == "Kitchen")).id

    build =
      Enum.reduce(1..rooms//1, build, fn i, b ->
        {:ok, b, _id} = Build.add_room(b, "Room #{i}", "f1", :indoor)
        b
      end)

    Enum.reduce(1..n//1, build, fn _i, b ->
      {:ok, b, _id} = Build.add_item(b, room, "fridge")
      b
    end)
  end

  describe "the limits of a link" do
    test "a house with too many items or rooms has no link" do
      build = house()
      items = 150 - length(build.items)
      assert {:ok, _data} = build |> large(items) |> Share.encode(summary())
      assert {:error, :too_large} = build |> large(items + 1) |> Share.encode(summary())

      rooms = 50 - length(build.rooms)
      assert {:ok, _data} = build |> large(0, rooms) |> Share.encode(summary())
      assert {:error, :too_large} = build |> large(0, rooms + 1) |> Share.encode(summary())
    end

    property "a link never carries more than 150 items or 50 rooms" do
      check all(extra <- integer(0..200), rooms <- integer(0..60), max_runs: 25) do
        build = house() |> large(extra, rooms)
        json = json(build, @s)

        if length(build.items) <= 150 and length(build.rooms) <= 50 and
             byte_size(json) <= 32 * 1024 do
          assert {:ok, decoded, _s} = Share.decode(data(json))
          assert length(decoded.items) == length(build.items)
        else
          assert {:error, _reason} = Share.decode(data(json))
          assert {:error, :too_large} = Share.encode(build, summary())
        end
      end
    end

    test "a link with vans that get too many zones at the read is refused" do
      build = house()
      kitchen = Enum.find(build.rooms, &(&1.name == "Kitchen")).id
      map = build |> Build.to_json() |> Jason.decode!()
      [item | _] = map["items"]

      vans =
        for i <- 1..20,
            do: %{
              item
              | "id" => "v#{i}",
                "type" => "camper_van",
                "room" => kitchen,
                "params" => %{}
            }

      json = Jason.encode!(%{"b" => %{map | "items" => map["items"] ++ vans}, "s" => @s})
      assert Share.decode(data(json)) == {:error, :too_large}
    end

    test "a link that has too many items is refused before its house is read" do
      build = house() |> large(151 - length(house().items))
      assert Share.decode(data(json(build, @s))) == {:error, :too_large}
    end

    test "a summary out of the range of a link gets its limits" do
      s = Share.summary(List.duplicate(1.0e9, 12), 1.0e12, "en")
      assert s.months == List.duplicate(100_000, 12)
      assert s.cost == 10_000_000
      assert {:ok, _build, ^s} = house() |> encode!(s) |> Share.decode()
    end
  end

  describe "summary/5" do
    test "rounds the numbers, keeps them at 0 or more, and knows the locales" do
      s = Share.summary([1.4, -3 | List.duplicate(10.6, 10)], 99.5, "vi")
      assert s.months == [1, 0 | List.duplicate(11, 10)]
      assert s.cost == 100
      assert s.locale == "vi"
      assert Share.year(s) == 111

      assert Share.summary(List.duplicate(1, 12), nil, "fr") == %{
               months: List.duplicate(1, 12),
               cost: nil,
               locale: "en",
               sky: %{time: "day", weather: "sun"},
               items: []
             }

      assert Share.summary(List.duplicate(1, 12), -5, "es").cost == 0
    end

    test "keeps the 6 items with the most kWh, rounded, for the labels of the picture" do
      items =
        [{"i1", 6828.4, 908.2}, {"i2", 0.4, 0.05}, {"i3", 500, nil}, {"i4", 1.0e9, -3}] ++
          for(n <- 5..12, do: {"i#{n}", n * 10, n}) ++
          [{String.duplicate("i", 17), 9_000, 1}, {nil, 9_000, 1}]

      s = Share.summary(List.duplicate(1, 12), nil, "en", nil, items)

      assert s.items == [
               %{id: "i4", kwh: 1_200_000, cost: 0},
               %{id: "i1", kwh: 6828, cost: 908},
               %{id: "i3", kwh: 500, cost: nil},
               %{id: "i12", kwh: 120, cost: 12},
               %{id: "i11", kwh: 110, cost: 11},
               %{id: "i10", kwh: 100, cost: 10}
             ]
    end
  end

  describe "encode/3 and decode/1" do
    test "a typical house gives a short link that gives the house back" do
      build = house() |> linked()
      data = encode!(build, summary())
      assert String.starts_with?(data, "1")
      assert byte_size(data) < 2_000
      assert data =~ ~r/\A[A-Za-z0-9_-]+\z/

      assert {:ok, decoded, s} = Share.decode(data)
      assert decoded == Share.strip(build)
      assert s == summary()
    end

    test "a link keeps the rooms that are open to each other" do
      build = house()

      [kitchen, living] =
        for name <- ["Kitchen", "Living room"], do: Enum.find(build.rooms, &(&1.name == name))

      {:ok, build} = Build.set_open(build, kitchen.id, [living.id])
      assert {:ok, decoded, _s} = build |> encode!(summary()) |> Share.decode()
      assert decoded.open == [Enum.sort([kitchen.id, living.id])]
    end

    test "a link carries the sky of its picture" do
      s = Share.summary(List.duplicate(900, 12), 1200, "en", %{time: "night", weather: "rain"})

      assert {:ok, _build, %{sky: %{time: "night", weather: "rain"}}} =
               house() |> encode!(s) |> Share.decode()

      # A sky that DIY.Sky does not know is a day with sun.
      assert Share.summary(List.duplicate(1, 12), nil, "en", %{time: "noon", weather: "sun"}).sky ==
               %{time: "day", weather: "sun"}

      assert Share.summary(List.duplicate(1, 12), nil, "en", nil).sky == %{
               time: "day",
               weather: "sun"
             }
    end

    test "a link of an older version has no sky: a day with sun" do
      old = Map.drop(@s, ["t", "w"])

      assert {:ok, _build, %{sky: %{time: "day", weather: "sun"}}} =
               Share.decode(data(json(house(), old)))

      assert Share.decode(data(json(house(), Map.put(@s, "t", "noon")))) == {:error, :summary}
      assert Share.decode(data(json(house(), Map.put(@s, "w", 3)))) == {:error, :summary}
    end

    test "a link carries the items with labels; a link of an older version has none" do
      items = [{"i1", 6828, 908}, {"i3", 500, nil}]
      s = Share.summary(List.duplicate(900, 12), 1200, "en", nil, items)
      assert {:ok, _build, ^s} = house() |> encode!(s) |> Share.decode()
      assert {:ok, _build, %{items: []}} = Share.decode(data(json(house(), @s)))

      for bad <- [
            "x",
            [["i1", 5]],
            [["i1", 0, 1]],
            [["i1", 5, -1]],
            [["i1", 5.5, 1]],
            [[1, 5, 1]],
            [[String.duplicate("i", 17), 5, 1]],
            [["i1", 1_200_001, 1]],
            List.duplicate(["i1", 5, 1], 7)
          ] do
        assert Share.decode(data(json(house(), Map.put(@s, "i", bad)))) == {:error, :summary},
               inspect(bad)
      end
    end

    test "a link with no ZIP code" do
      {:ok, decoded, _s} = house() |> encode!(summary(nil), zip: false) |> Share.decode()
      assert decoded.zip == nil
    end

    property "a house gives the same stripped house and summary back" do
      check all(
              size <- integer(400..6_000),
              floors <- integer(1..3),
              heat <- member_of(Build.heats()),
              door <- member_of(["my_house", "planning"]),
              zip? <- boolean(),
              link? <- boolean(),
              months <- list_of(float(min: 0.0, max: 9_000.0), length: 12),
              cost <- one_of([constant(nil), float(min: 0.0, max: 50_000.0)]),
              locale <- member_of(["en", "es", "vi"]),
              time <- member_of(DIY.Sky.times()),
              weather <- member_of(DIY.Sky.weathers()),
              uses <- list_of(float(min: 0.0, max: 20_000.0), max_length: 12),
              cost? <- boolean()
            ) do
        build = house(size: size, floors: floors, heat: heat, door: door)
        build = if link?, do: linked(build), else: build

        items =
          for {item, kwh} <- Enum.zip(build.items, uses),
              do: {item.id, kwh, if(cost?, do: kwh * 0.133)}

        s = Share.summary(months, cost, locale, %{time: time, weather: weather}, items)

        assert {:ok, decoded, ^s} = build |> encode!(s, zip: zip?) |> Share.decode()
        assert decoded == Share.strip(build, zip: zip?)
        assert decoded.areas == %{} and decoded.devices == %{} and decoded.units == %{}
      end
    end

    test "a link that has the data of a link gets it removed" do
      build = house() |> linked()
      assert {:ok, decoded, _s} = build |> json(@s) |> data() |> Share.decode()
      assert decoded.areas == %{} and decoded.devices == %{} and decoded.units == %{}
      assert decoded.revision == 0 and decoded.stamp == "" and decoded.lesson == 1
      assert decoded.hints == []
    end

    property "a random text is never a house, and never a crash" do
      check all(text <- string(:printable, max_length: 200)) do
        assert {:error, _reason} = Share.decode(text)
        assert {:error, _reason} = Share.decode("1" <> text)
      end
    end

    property "random bytes in a link are never a house, and never a crash" do
      check all(bytes <- binary(max_length: 400), compress? <- boolean()) do
        bytes = if compress?, do: :zlib.compress(bytes), else: bytes
        assert {:error, _reason} = Share.decode("1" <> Base.url_encode64(bytes, padding: false))
        assert {:error, _reason} = Share.decode(data(bytes))
      end
    end

    test "the errors of a link" do
      assert Share.decode(nil) == {:error, :version}
      assert Share.decode("2abc") == {:error, :version}
      assert Share.decode("1!!") == {:error, :base64}
      assert Share.decode("1" <> String.duplicate("a", Share.max_data())) == {:error, :too_long}
      assert Share.decode(data("not json")) == {:error, :json}
      assert Share.decode(data("[1, 2]")) == {:error, :not_a_house}
      assert Share.decode(data(~s({"b": 1, "s": {}}))) == {:error, :not_a_house}
      assert Share.decode(data(json(house(), %{}))) == {:error, :summary}
      assert Share.decode(data(json(house(), %{@s | "m" => [1]}))) == {:error, :summary}
      assert Share.decode(data(json(house(), %{@s | "m" => "a"}))) == {:error, :summary}

      assert Share.decode(data(json(house(), %{@s | "m" => List.duplicate(-1, 12)}))) ==
               {:error, :summary}

      assert Share.decode(data(json(house(), %{@s | "m" => List.duplicate(1.5, 12)}))) ==
               {:error, :summary}

      assert Share.decode(data(json(house(), %{@s | "c" => -1}))) == {:error, :summary}
      assert Share.decode(data(json(house(), %{@s | "c" => 10_000_001}))) == {:error, :summary}
      assert Share.decode(data(json(house(), %{@s | "l" => "fr"}))) == {:error, :summary}

      assert Share.decode(data(~s({"b": {"version": 1}, "s": #{Jason.encode!(@s)}}))) ==
               {:error, :build}

      assert Share.decode(data(json(Build.new(), @s))) == {:error, :no_house}
    end

    test "a small link never inflates to a large text" do
      # 3 MB of the same letter: about 4,000 characters in a link.
      bomb = data(String.duplicate("a", 3_000_000))
      assert byte_size(bomb) < Share.max_data()
      assert Share.decode(bomb) == {:error, :too_large}

      # A text just over the limit in one piece.
      assert Share.decode(data(String.duplicate(" ", 32 * 1024 + 1))) == {:error, :too_large}
    end

    test "a link that ends before the end of its data" do
      data = house() |> encode!(summary())
      assert {:error, _reason} = Share.decode(binary_part(data, 0, div(byte_size(data), 2)))

      # A cut stream: the inflate gives no output and asks for more input.
      {:ok, cut} = Base.decode16("031CFBC9EA63C08B78DB4C28037C8EFFDB66A327")
      assert Share.decode("1" <> Base.url_encode64(cut, padding: false)) == {:error, :inflate}
    end
  end
end
