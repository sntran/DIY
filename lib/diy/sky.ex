defmodule DIY.Sky do
  @moduledoc """
  The sky at a house now: the time of day and the weather, from Open-Meteo
  (https://open-meteo.com). The service is free and needs no key. The
  page House draws the house from the outside with this sky
  (docs/design.md, "The sky at the house").

  - The time of day is `"day"`, `"sunset"` or `"night"`. It is `"sunset"`
    from 30 minutes before to 30 minutes after the sunset, and also near
    the sunrise (then `dawn` is true). The times are the local times of
    the place, from the clock of the server and the offset of the place.
  - With no sunrise and no sunset in the day (near a pole), the time of
    day is `"day"` or `"night"` all day, from Open-Meteo. In a polar
    night, the sunrise and the sunset are the same time. In a polar day,
    the sunset is 24 hours or more after the sunrise.
  - The weather is `"sun"`, `"clouds"`, `"rain"` or `"snow"`, from the
    code of the weather of the World Meteorological Organization (WMO).

  The request has a point on a grid of 0.25°, as for `DIY.Weather`: many
  ZIP codes have the same point. The cache keeps the answer of a point
  for 30 minutes.
  """

  alias DIY.Cache

  @url "https://api.open-meteo.com/v1/forecast"
  @times ~w(day sunset night)
  @weathers ~w(sun clouds rain snow)
  # The minutes before and after the sunset (and the sunrise) that are
  # "sunset", and the milliseconds that the cache keeps an answer.
  @dusk 30
  @keep 30 * 60 * 1000

  @type t :: %{
          time: String.t(),
          dawn: boolean(),
          weather: String.t(),
          temp: float(),
          local: NaiveDateTime.t(),
          next: non_neg_integer() | nil,
          answer: map()
        }

  @doc "The times of day: `day`, `sunset` and `night`."
  def times, do: @times

  @doc "The weathers: `sun`, `clouds`, `rain` and `snow`."
  def weathers, do: @weathers

  @doc """
  The sky at a point at a time (`at`, UTC). It has the time of day and the
  local time at `at`. `next` is the seconds until the time of day
  changes, or nil after the last change of the day. `answer` is the
  answer of Open-Meteo, for `at/2`.
  """
  @spec now(float(), float(), DateTime.t()) :: {:ok, t()} | {:error, String.t()}
  def now(lat, lon, at \\ DateTime.utc_now()) do
    {lat, lon} = {grid(lat), grid(lon)}
    fetch = fn -> get(lat, lon) end

    with {:ok, answer} <- Cache.fetch({__MODULE__, lat, lon}, fetch, max_age: @keep) do
      {:ok, at(answer, at)}
    end
  end

  defp grid(value), do: Float.round(round(value * 4) / 4, 2)

  defp get(lat, lon) do
    options =
      [
        url: @url,
        params: [
          latitude: lat,
          longitude: lon,
          current: "weather_code,temperature_2m,is_day",
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
        "utc_offset_seconds" => offset,
        "current" => %{"weather_code" => code, "temperature_2m" => temp, "is_day" => day},
        "daily" => %{"sunrise" => [rise | _], "sunset" => [set | _]}
      })
      when is_integer(offset) and is_integer(code) and is_number(temp) and day in [0, 1] do
    with {:ok, sunrise} <- local(rise),
         {:ok, sunset} <- local(set) do
      {:ok,
       %{
         offset: offset,
         weather: weather(code),
         temp: temp / 1,
         day: day == 1,
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
  The sky of an answer of Open-Meteo (`now/3`, `answer`) at a time (UTC).
  When the service does not answer, the page uses the answer of before
  with the clock of now.
  """
  @spec at(map(), DateTime.t()) :: t()
  def at(answer, at) do
    local = at |> DateTime.to_naive() |> NaiveDateTime.add(answer.offset)
    %{sunrise: rise, sunset: set} = answer
    polar? = rise == set or NaiveDateTime.diff(set, rise, :hour) >= 24

    {time, next} =
      if polar?,
        do: {if(answer.day, do: "day", else: "night"), nil},
        else: {time_of_day(local, rise, set), next(local, rise, set)}

    %{
      time: time,
      dawn: time == "sunset" and near?(local, rise),
      weather: answer.weather,
      temp: answer.temp,
      local: local,
      next: next,
      answer: answer
    }
  end

  defp near?(local, time), do: abs(NaiveDateTime.diff(local, time, :second)) <= @dusk * 60

  # The seconds until the next change of the time of day, or nil. The
  # time of day is "sunset" from 30 minutes before to 30 minutes after the
  # sunset (or the sunrise), with the two ends. So it changes at the
  # start, and one second after the end.
  defp next(local, rise, set) do
    [rise, set]
    |> Enum.flat_map(&[NaiveDateTime.add(&1, -@dusk * 60), NaiveDateTime.add(&1, @dusk * 60 + 1)])
    |> Enum.map(&NaiveDateTime.diff(&1, local, :second))
    |> Enum.filter(&(&1 > 0))
    |> Enum.min(fn -> nil end)
  end

  @doc """
  The time of day at a local time, from the sunrise and the sunset of the
  day.
  """
  @spec time_of_day(NaiveDateTime.t(), NaiveDateTime.t(), NaiveDateTime.t()) :: String.t()
  def time_of_day(local, sunrise, sunset) do
    cond do
      near?(local, sunrise) or near?(local, sunset) -> "sunset"
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
