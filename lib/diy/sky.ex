defmodule DIY.Sky do
  @moduledoc """
  The sky at a house now: the time of day and the weather, from Open-Meteo
  (https://open-meteo.com). The service is free and needs no key. The
  page House draws the house from the outside with this sky
  (docs/design.md, "The sky at the house").

  - The time of day is `"day"`, `"sunset"` or `"night"`. It is `"sunset"`
    from 30 minutes before to 30 minutes after the sunset, and also near
    the sunrise. The times are the local times of the place.
  - The weather is `"sun"`, `"clouds"`, `"rain"` or `"snow"`, from the
    code of the weather of the World Meteorological Organization (WMO).

  The request has the point of the ZIP code, as for `DIY.Weather`. The
  cache keeps the sky of a point for 30 minutes.
  """

  alias DIY.Cache

  @url "https://api.open-meteo.com/v1/forecast"
  @times ~w(day sunset night)
  @weathers ~w(sun clouds rain snow)
  # The minutes before and after the sunset (and the sunrise) that are
  # "sunset", and the seconds that the cache keeps a sky.
  @dusk 30
  @keep 30 * 60

  @type t :: %{
          time: String.t(),
          weather: String.t(),
          temp: float(),
          local: NaiveDateTime.t(),
          sunrise: NaiveDateTime.t(),
          sunset: NaiveDateTime.t()
        }

  @doc "The times of day: `day`, `sunset` and `night`."
  def times, do: @times

  @doc "The weathers: `sun`, `clouds`, `rain` and `snow`."
  def weathers, do: @weathers

  @doc """
  The sky now at a point. The answer stays in the cache for 30 minutes:
  the key has the half hour of `at`.
  """
  @spec now(float(), float(), DateTime.t()) :: {:ok, t()} | {:error, String.t()}
  def now(lat, lon, at \\ DateTime.utc_now()) do
    {lat, lon} = {Float.round(lat / 1, 2), Float.round(lon / 1, 2)}
    slot = div(DateTime.to_unix(at), @keep)
    Cache.fetch({__MODULE__, lat, lon, slot}, fn -> get(lat, lon) end)
  end

  defp get(lat, lon) do
    options =
      [
        url: @url,
        params: [
          latitude: lat,
          longitude: lon,
          current: "weather_code,temperature_2m",
          daily: "sunrise,sunset",
          timezone: "auto",
          forecast_days: 1,
          temperature_unit: "fahrenheit"
        ],
        receive_timeout: 15_000
      ]
      |> Keyword.merge(Application.get_env(:diy, __MODULE__, [])[:req] || [])

    case Req.get(options) do
      {:ok, %{status: 200, body: body}} ->
        parse(body)

      {:ok, %{status: status}} ->
        {:error, "The service of the sky answered #{status}."}

      {:error, error} ->
        {:error, "The service of the sky did not answer (#{Exception.message(error)})."}
    end
  end

  @doc false
  def parse(%{
        "current" => %{"time" => time, "weather_code" => code, "temperature_2m" => temp},
        "daily" => %{"sunrise" => [rise | _], "sunset" => [set | _]}
      })
      when is_integer(code) and is_number(temp) do
    with {:ok, local} <- local(time),
         {:ok, sunrise} <- local(rise),
         {:ok, sunset} <- local(set) do
      {:ok,
       %{
         time: time_of_day(local, sunrise, sunset),
         weather: weather(code),
         temp: temp / 1,
         local: local,
         sunrise: sunrise,
         sunset: sunset
       }}
    end
  end

  def parse(_body),
    do: {:error, "The service of the sky gave an answer that the app cannot read."}

  # A local time of Open-Meteo, for example "2026-10-24T18:43".
  defp local(text) when is_binary(text) do
    case NaiveDateTime.from_iso8601(text <> ":00") do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> local(nil)
    end
  end

  defp local(_text), do: {:error, "The service of the sky gave a time that the app cannot read."}

  @doc """
  The time of day at a local time, from the sunrise and the sunset of the
  day.
  """
  @spec time_of_day(NaiveDateTime.t(), NaiveDateTime.t(), NaiveDateTime.t()) :: String.t()
  def time_of_day(local, sunrise, sunset) do
    near? = &(abs(NaiveDateTime.diff(local, &1, :minute)) <= @dusk)

    cond do
      near?.(sunrise) or near?.(sunset) -> "sunset"
      NaiveDateTime.after?(local, sunrise) and NaiveDateTime.before?(local, sunset) -> "day"
      true -> "night"
    end
  end

  @doc """
  The weather of a WMO code. 0 and 1 are sun (a clear sky). 2, 3 and fog
  are clouds. Drizzle, rain, showers and storms are rain. Snow is snow. A
  code that the app does not know is clouds.
  """
  @spec weather(integer()) :: String.t()
  def weather(code) when code in [0, 1], do: "sun"
  def weather(code) when code in 51..67 or code in 80..82 or code in 95..99, do: "rain"
  def weather(code) when code in 71..77 or code in [85, 86], do: "snow"
  def weather(_code), do: "clouds"

  @doc """
  The sky that the picture shows: the choice of the person, or the sky of
  now (`"now"`). With no sky of now (no ZIP code, or no answer), the
  picture shows a day with sun.
  """
  @spec pick(map(), t() | nil) :: %{time: String.t(), weather: String.t()}
  def pick(choice, now) do
    %{
      time: one(choice["time"], @times, now && now.time, "day"),
      weather: one(choice["weather"], @weathers, now && now.weather, "sun")
    }
  end

  defp one(choice, values, now, default) do
    cond do
      choice in values -> choice
      now -> now
      true -> default
    end
  end
end
