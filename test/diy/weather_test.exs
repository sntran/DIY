defmodule DIY.WeatherTest do
  use ExUnit.Case, async: true

  alias DIY.{Stubs, Weather}

  @today ~D[2026-10-08]

  # Each test uses its own point, so that the cache of one test does not
  # answer for a different test.
  test "the weather of a point, by month, in °F" do
    Stubs.weather()
    assert {:ok, climate} = Weather.climate(10.1, -10.1, @today)
    assert {climate.first, climate.last} == {2016, 2025}
    assert {climate.lat, climate.lon} == {10.0, -10.0}
    july = climate.months[7]
    assert july.cdd > 500 and july.cdd < 800
    assert july.cdd_min <= july.cdd and july.cdd <= july.cdd_max
    assert climate.months[1].hdd > 400
    assert july.sun > 5
    assert climate.t_year > 60 and climate.t_year < 75
    assert map_size(climate.series) == 120
  end

  test "the cache answers the second time" do
    Stubs.weather()
    assert {:ok, climate} = Weather.climate(11.0, -11.0, @today)
    Stubs.weather(500)
    assert Weather.climate(11.0, -11.0, @today) == {:ok, climate}
  end

  test "the errors of the service" do
    Stubs.weather(503)
    assert Weather.climate(12.0, -12.0, @today) == {:error, "The weather service answered 503."}
    Stubs.weather(:down)

    assert {:error, "The weather service did not answer" <> _} =
             Weather.climate(13.0, -13.0, @today)

    Stubs.weather(%{"messages" => ["no"]})

    assert Weather.climate(14.0, -14.0, @today) ==
             {:error, "The weather service gave an answer that the app cannot read."}
  end

  test "a month with no data is an error" do
    body = Stubs.power()
    parameter = body["properties"]["parameter"]

    no_july =
      Map.new(parameter, fn {name, values} ->
        {name,
         Map.new(values, fn {key, value} ->
           {key, if(String.ends_with?(key, "07"), do: -999.0, else: value)}
         end)}
      end)

    Stubs.weather(put_in(body, ["properties", "parameter"], no_july))

    assert Weather.climate(15.0, -15.0, @today) ==
             {:error, "The weather service has no data for this place."}
  end

  test "a month with a missing value is not in the series" do
    body = update_in(Stubs.power(), ["properties", "parameter", "T2M", "201601"], fn _ -> nil end)
    Stubs.weather(body)
    assert {:ok, climate} = Weather.climate(16.0, -16.0, @today)
    refute Map.has_key?(climate.series, {2016, 1})
    assert map_size(climate.series) == 119
  end
end
