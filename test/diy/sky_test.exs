defmodule DIY.SkyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Sky, Stubs}

  defp at(text), do: NaiveDateTime.from_iso8601!(text <> ":00")

  describe "parse/1" do
    test "a clear night in Plano" do
      assert {:ok, sky} = Sky.parse(Stubs.open_meteo())
      assert sky.time == "night"
      assert sky.weather == "sun"
      assert sky.temp == 59.1
      assert sky.local == at("2026-10-24T21:30")
      assert sky.sunrise == at("2026-10-24T07:38")
      assert sky.sunset == at("2026-10-24T18:43")
    end

    test "the time of the place gives the time of day" do
      for {time, expected} <- [
            {"2026-10-24T03:00", "night"},
            {"2026-10-24T07:10", "sunset"},
            {"2026-10-24T08:09", "day"},
            {"2026-10-24T12:00", "day"},
            {"2026-10-24T18:14", "sunset"},
            {"2026-10-24T19:13", "sunset"},
            {"2026-10-24T19:14", "night"}
          ] do
        assert {:ok, %{time: ^expected}} = Sky.parse(Stubs.open_meteo(time)), time
      end
    end

    test "an answer that the app cannot read" do
      assert {:error, _} = Sky.parse(%{})
      assert {:error, _} = Sky.parse(put_in(Stubs.open_meteo(), ["current", "time"], "soon"))
      assert {:error, _} = Sky.parse(put_in(Stubs.open_meteo(), ["current", "time"], 5))
      assert {:error, _} = Sky.parse(put_in(Stubs.open_meteo(), ["daily", "sunset"], ["x"]))
      assert {:error, _} = Sky.parse(put_in(Stubs.open_meteo(), ["daily", "sunrise"], ["x"]))
      assert {:error, _} = Sky.parse(put_in(Stubs.open_meteo(), ["current", "weather_code"], "0"))
    end
  end

  test "the codes of the weather" do
    for code <- [0, 1], do: assert(Sky.weather(code) == "sun")
    for code <- [2, 3, 45, 48, 4, 100], do: assert(Sky.weather(code) == "clouds")
    for code <- [51, 61, 67, 80, 82, 95, 99], do: assert(Sky.weather(code) == "rain")
    for code <- [71, 75, 77, 85, 86], do: assert(Sky.weather(code) == "snow")
  end

  describe "now/3" do
    test "asks Open-Meteo for the point" do
      Req.Test.stub(DIY.Sky, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["latitude"] == "33.25"
        assert conn.query_params["longitude"] == "-96.75"
        assert conn.query_params["timezone"] == "auto"
        Req.Test.json(conn, Stubs.open_meteo("2026-10-24T12:00", 61))
      end)

      assert {:ok, %{time: "day", weather: "rain"}} = Sky.now(33.25, -96.75)
    end

    test "the errors of the service" do
      Stubs.sky(503)
      assert {:error, "The service of the sky answered 503."} = Sky.now(33.25, -96.75)
      Stubs.sky(:down)
      assert {:error, "The service of the sky did not answer" <> _} = Sky.now(33.25, -96.75)
      Stubs.sky(%{"a" => 1})
      assert {:error, _} = Sky.now(33.25, -96.75)
    end
  end

  describe "time_of_day/3" do
    property "a day goes from night to sunset, day, sunset and night" do
      check all(
              rise <- integer(240..540),
              length <- integer(120..900),
              step <- integer(1..30)
            ) do
        day = ~N[2026-06-21 00:00:00]
        sunrise = NaiveDateTime.add(day, rise, :minute)
        sunset = NaiveDateTime.add(sunrise, length, :minute)

        times =
          0..(24 * 60 - 1)//step
          |> Enum.map(&Sky.time_of_day(NaiveDateTime.add(day, &1, :minute), sunrise, sunset))
          |> Enum.dedup()

        assert times in [
                 ~w(night sunset day sunset night),
                 ~w(sunset day sunset night),
                 ~w(night sunset day sunset)
               ]
      end
    end
  end

  describe "pick/2" do
    property "a choice of the person wins, else the sky of now, else a day with sun" do
      now = %{time: "night", weather: "snow"}

      check all(
              time <- member_of(["now", nil, "noon" | Sky.times()]),
              weather <- member_of(["now", nil, "hail" | Sky.weathers()]),
              live <- member_of([now, nil])
            ) do
        pick = Sky.pick(%{"time" => time, "weather" => weather}, live)

        cond do
          time in Sky.times() -> assert pick.time == time
          live -> assert pick.time == "night"
          true -> assert pick.time == "day"
        end

        cond do
          weather in Sky.weathers() -> assert pick.weather == weather
          live -> assert pick.weather == "snow"
          true -> assert pick.weather == "sun"
        end
      end
    end
  end
end
