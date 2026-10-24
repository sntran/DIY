defmodule DIY.SkyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Sky, Stubs}

  # 21:30 in Plano (UTC − 5 hours).
  @at ~U[2026-10-25 02:30:00Z]

  defp answer(opts), do: Stubs.open_meteo(Keyword.put_new(opts, :at, @at))

  defp now(opts, at \\ @at) do
    Req.Test.stub(DIY.Sky, &Req.Test.json(&1, answer(opts)))
    Sky.now(33.25, -96.75, at)
  end

  describe "now/3" do
    test "the time of day and the local time, from the clock and the offset of the place" do
      assert {:ok, sky} = now(time: "night", code: 0)
      assert sky.time == "night"
      assert sky.weather == "sun"
      assert sky.temp == 59.1
      assert sky.local == ~N[2026-10-24 21:30:00]
      refute sky.dawn
      # The next change: 30 minutes before the sunrise, in 2 hours 30 minutes.
      assert sky.next == 150 * 60

      assert {:ok, %{time: "day", next: 12_600}} = now(time: "day")
      assert {:ok, %{time: "sunset", dawn: false, next: 2_401}} = now(time: "sunset")
      assert {:ok, %{time: "sunset", dawn: true, next: 2_401}} = now(time: "dawn")
    end

    test "after the last change of the day, there is no next change" do
      # The sunrise and the sunset were 10 and 4 hours ago.
      body =
        put_in(
          answer([])["daily"],
          %{"sunrise" => ["2026-10-24T11:30"], "sunset" => ["2026-10-24T17:30"]}
        )

      Req.Test.stub(DIY.Sky, &Req.Test.json(&1, body))
      assert {:ok, %{time: "night", next: nil}} = Sky.now(33.25, -96.75, @at)
    end

    test "near a pole, with no sunrise and no sunset, it is night or day all day" do
      # A polar day: the sunset is 24 hours after the sunrise.
      for at <- [~U[2026-06-21 05:10:00Z], ~U[2026-06-22 04:45:00Z]] do
        assert {:ok, %{time: "day", dawn: false, next: nil}} =
                 now([time: "polar_day", at: at], at)
      end

      assert {:ok, %{time: "night", dawn: false, next: nil}} = now(time: "polar")
      body = put_in(answer(time: "polar"), ["current", "is_day"], 1)
      Req.Test.stub(DIY.Sky, &Req.Test.json(&1, body))
      assert {:ok, %{time: "day", next: nil}} = Sky.now(33.25, -96.75, @at)
    end

    test "asks Open-Meteo for a point on the grid of 0.25°" do
      Req.Test.stub(DIY.Sky, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["latitude"] == "33.25"
        assert conn.query_params["longitude"] == "-96.75"
        assert conn.query_params["timezone"] == "auto"
        assert conn.query_params["current"] =~ "is_day"
        Req.Test.json(conn, answer(time: "day", code: 61))
      end)

      assert {:ok, %{time: "day", weather: "rain"}} = Sky.now(33.19, -96.70, @at)
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

  test "an answer that the app cannot read" do
    good = answer([])
    assert {:ok, _} = Sky.parse(good)
    assert {:error, _} = Sky.parse(%{})
    assert {:error, _} = Sky.parse(put_in(good, ["daily", "sunset"], ["x"]))
    assert {:error, _} = Sky.parse(put_in(good, ["daily", "sunrise"], [5]))
    assert {:error, _} = Sky.parse(put_in(good, ["current", "weather_code"], "0"))
    assert {:error, _} = Sky.parse(put_in(good, ["current", "is_day"], 2))
    assert {:error, _} = Sky.parse(Map.put(good, "utc_offset_seconds", "x"))
  end

  test "the codes of the weather" do
    for code <- [0, 1], do: assert(Sky.weather(code) == "sun")
    for code <- [2, 3, 45, 48, 4, 100], do: assert(Sky.weather(code) == "clouds")
    for code <- [51, 61, 67, 80, 82, 95, 99], do: assert(Sky.weather(code) == "rain")
    for code <- [71, 75, 77, 85, 86], do: assert(Sky.weather(code) == "snow")
  end

  describe "time_of_day/3" do
    test "the times near the sunrise and the sunset" do
      {rise, set} = {~N[2026-10-24 07:38:00], ~N[2026-10-24 18:43:00]}

      for {time, expected} <- [
            {~N[2026-10-24 03:00:00], "night"},
            {~N[2026-10-24 07:08:00], "sunset"},
            {~N[2026-10-24 08:09:00], "day"},
            {~N[2026-10-24 18:13:00], "sunset"},
            {~N[2026-10-24 19:13:00], "sunset"},
            {~N[2026-10-24 19:14:00], "night"}
          ] do
        assert Sky.time_of_day(time, rise, set) == expected, NaiveDateTime.to_string(time)
      end
    end

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

    property "the time of day does not change before the next change" do
      check all(second <- one_of([integer(0..(24 * 3600 - 1)), member_of(boundaries())])) do
        at = DateTime.add(~U[2026-10-24 05:00:00Z], second)
        {:ok, sky} = now([time: "day", at: ~U[2026-10-24 17:00:00Z]], at)

        if sky.next do
          {:ok, later} =
            now([time: "day", at: ~U[2026-10-24 17:00:00Z]], DateTime.add(at, sky.next - 1))

          assert later.time == sky.time

          {:ok, next} =
            now([time: "day", at: ~U[2026-10-24 17:00:00Z]], DateTime.add(at, sky.next + 1))

          assert next.time != sky.time
        end
      end
    end
  end

  # The seconds after 05:00 UTC (00:00 local) of the changes of the stub
  # "day" at 17:00 UTC. Its sunrise is at 08:00 and its sunset at 16:00
  # local. Also one second before and after each change.
  defp boundaries do
    for change <- [7.5 * 3600, 8.5 * 3600 + 1, 15.5 * 3600, 16.5 * 3600 + 1],
        d <- [-1, 0, 1],
        do: round(change) + d
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
