defmodule DIY.Weather do
  @moduledoc """
  The weather history of a place, by month, from the POWER project of NASA
  (https://power.larc.nasa.gov). The service is free and needs no key. One
  request gives 10 years of months for a point:

  - `CDD18_3` and `HDD18_3`: the cooling and the heating degree days, base
    18.3 °C (65 °F). The app uses °F: one degree day in °C is 1.8 in °F.
  - `T2M`: the mean air temperature at 2 m.
  - `ALLSKY_SFC_SW_DWN`: the sun on a flat surface, in kWh/m² in one day.

  The data has a grid of 0.5° of latitude and 0.625° of longitude, so the
  app asks for the point on a grid of 0.25°, and the cache keeps it for all
  the ZIP codes near it.
  """

  alias DIY.Cache

  @url "https://power.larc.nasa.gov/api/temporal/monthly/point"
  @params "CDD18_3,HDD18_3,T2M,ALLSKY_SFC_SW_DWN"
  @years 10

  @type month :: %{
          cdd: float(),
          cdd_min: float(),
          cdd_max: float(),
          hdd: float(),
          hdd_min: float(),
          hdd_max: float(),
          t: float(),
          sun: float(),
          sun_min: float(),
          sun_max: float()
        }
  @type t :: %{
          lat: float(),
          lon: float(),
          first: pos_integer(),
          last: pos_integer(),
          t_year: float(),
          months: %{(1..12) => month()},
          series: %{{pos_integer(), 1..12} => map()}
        }

  @doc """
  The weather of the 10 full years before `today`, near a point. The
  result is in the cache after the first request.
  """
  @spec climate(float(), float(), Date.t()) :: {:ok, t()} | {:error, String.t()}
  def climate(lat, lon, today \\ Date.utc_today()) do
    lat = grid(lat)
    lon = grid(lon)
    last = today.year - 1
    first = last - @years + 1
    Cache.fetch({__MODULE__, lat, lon, last}, fn -> get(lat, lon, first, last) end)
  end

  defp grid(value), do: Float.round(round(value * 4) / 4, 2)

  defp get(lat, lon, first, last) do
    options =
      [
        url: @url,
        params: [
          parameters: @params,
          community: "RE",
          latitude: lat,
          longitude: lon,
          start: first,
          end: last,
          format: "JSON"
        ],
        receive_timeout: 20_000
      ]
      |> Keyword.merge(Application.get_env(:diy, __MODULE__, [])[:req] || [])

    case Req.get(options) do
      {:ok, %{status: 200, body: body}} ->
        parse(body, lat, lon, first, last)

      {:ok, %{status: status}} ->
        {:error, "The weather service answered #{status}."}

      {:error, error} ->
        {:error, "The weather service did not answer (#{Exception.message(error)})."}
    end
  end

  @doc false
  def parse(%{"properties" => %{"parameter" => parameter}}, lat, lon, first, last)
      when is_map(parameter) do
    series =
      for year <- first..last, month <- 1..12, into: %{} do
        key = "#{year}#{String.pad_leading("#{month}", 2, "0")}"
        {{year, month}, value(parameter, key)}
      end
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    months = for month <- 1..12, into: %{}, do: {month, month(series, month)}

    if Enum.any?(months, fn {_month, value} -> is_nil(value) end) do
      {:error, "The weather service has no data for this place."}
    else
      t_year = Enum.sum(Enum.map(months, fn {_, m} -> m.t end)) / 12

      {:ok,
       %{
         lat: lat,
         lon: lon,
         first: first,
         last: last,
         t_year: t_year,
         months: months,
         series: series
       }}
    end
  end

  def parse(_body, _lat, _lon, _first, _last),
    do: {:error, "The weather service gave an answer that the app cannot read."}

  # The values of one month of one year, in °F, or nil when a value is
  # missing (the fill value of POWER is -999).
  defp value(parameter, key) do
    values =
      for name <- ~w(CDD18_3 HDD18_3 T2M ALLSKY_SFC_SW_DWN) do
        case get_in(parameter, [name, key]) do
          value when is_number(value) and value > -999 -> value
          _ -> nil
        end
      end

    case values do
      [cdd, hdd, t, sun]
      when is_number(cdd) and is_number(hdd) and is_number(t) and is_number(sun) ->
        %{cdd: cdd * 1.8, hdd: hdd * 1.8, t: t * 1.8 + 32, sun: sun / 1}

      _ ->
        nil
    end
  end

  defp month(series, month) do
    values = for {{_year, ^month}, value} <- series, do: value

    if values == [] do
      nil
    else
      cdd = Enum.map(values, & &1.cdd)
      hdd = Enum.map(values, & &1.hdd)
      sun = Enum.map(values, & &1.sun)

      %{
        cdd: mean(cdd),
        cdd_min: Enum.min(cdd),
        cdd_max: Enum.max(cdd),
        hdd: mean(hdd),
        hdd_min: Enum.min(hdd),
        hdd_max: Enum.max(hdd),
        t: mean(Enum.map(values, & &1.t)),
        sun: mean(sun),
        sun_min: Enum.min(sun),
        sun_max: Enum.max(sun)
      }
    end
  end

  defp mean(values), do: Enum.sum(values) / length(values)
end
