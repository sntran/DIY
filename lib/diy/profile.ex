defmodule DIY.Profile do
  @moduledoc """
  The shape of a day: how an item spreads its kWh over the 24 hours of an
  average day, and how the sun spreads the power of the panels. Each shape
  is 24 weights (hour 0 is from midnight to 1:00) with a sum of 1.

  The shapes are a simple model of the app, not a measurement:

  - Cooling is highest in the afternoon, and heat before the sunrise.
  - The lights and the other devices are mostly in the evening, the water
    heater in the morning and the evening, the laundry in the evening, and
    the pool pump in the day.
  - The fridge, the freezer and the devices that are always on use the
    same power at each hour.
  - A car charges at the power of its charger, from the start of the night
    or from 18:00.
  - The sun shines from the sunrise to the sunset of the latitude and the
    month, most at the noon of the sun (13:00 with daylight time).
  """

  @flat List.duplicate(1, 24)

  @doc "The hours of a day."
  def hours, do: 0..23

  @doc """
  The shape of an item in a month, for its part of the estimate
  (`:cooling`, `:heating` or `:other`). `night_from` is the hour when the
  night starts (for a car).
  """
  def shape(item, part, kwh_day, night_from \\ 22)

  def shape(_item, :cooling, _kwh_day, _night_from), do: normalize(cooling())
  def shape(_item, :heating, _kwh_day, _night_from), do: normalize(heating())

  def shape(%{type: "ev", params: p}, _part, kwh_day, night_from) do
    start = if p["when"] == "night", do: night_from, else: 18
    charge(kwh_day, charger_kw(p["charger"]), start)
  end

  def shape(%{type: type}, _part, _kwh_day, _night_from), do: normalize(weights(type))

  @doc "The power of a car charger, in kW."
  def charger_kw("l1"), do: 1.4
  def charger_kw("l2"), do: 7.2

  # A charge at the power of the charger from an hour, for as many hours as
  # it needs (at most one day).
  defp charge(kwh_day, kw, start) when kwh_day > 0 do
    hours = min(kwh_day / kw, 24.0)

    for h <- hours() do
      since = rem(h - start + 24, 24)
      min(max(hours - since, 0.0), 1.0) * kw
    end
    |> normalize()
  end

  defp charge(_kwh_day, _kw, _start), do: normalize(@flat)

  @doc "The hours that a car needs to charge in one day, or more than 24."
  def charge_hours(%{params: p}, kwh_day), do: kwh_day / charger_kw(p["charger"])

  defp cooling,
    do: for(h <- hours(), do: max(1 + 1.5 * :math.cos(2 * :math.pi() * (h - 16) / 24), 0.1))

  defp heating,
    do: for(h <- hours(), do: max(1 + 1.2 * :math.cos(2 * :math.pi() * (h - 5) / 24), 0.1))

  # The weights of a kind, before the sum of 1.
  defp weights(type) when type in ["lights", "tv", "computer", "other", "ceiling_fan"],
    do: for(h <- hours(), do: evening(h))

  defp weights("water_heater"),
    do: for(h <- hours(), do: if(h in 6..8 or h in 18..21, do: 3, else: 1))

  defp weights(type) when type in ["range", "microwave"],
    do: for(h <- hours(), do: if(h in [7, 12, 17, 18], do: 4, else: 0.2))

  defp weights(type) when type in ["washer", "dryer", "dishwasher"],
    do: for(h <- hours(), do: if(h in 18..21, do: 4, else: 0.2))

  defp weights("pool_pump"), do: for(h <- hours(), do: if(h in 9..16, do: 1, else: 0))
  defp weights("space_heater"), do: heating()
  defp weights(_type), do: @flat

  defp evening(h) when h in 17..22, do: 3
  defp evening(h) when h in 6..8, do: 1.5
  defp evening(h) when h in 0..5, do: 0.3
  defp evening(_h), do: 1

  defp normalize(weights) do
    sum = Enum.sum(weights)
    Enum.map(weights, &(&1 / sum))
  end

  @doc """
  The shape of the sun in a month at a latitude: the part of the power of
  one day in each hour.
  """
  def sun(latitude, month) do
    case day_length(latitude, month) do
      length when length > 0 ->
        for h <- hours() do
          x = (h + 0.5 - 13.0) / length
          if abs(x) < 0.5, do: :math.cos(:math.pi() * x), else: 0.0
        end
        |> normalize()

      # The night of a pole: no sun.
      _length ->
        List.duplicate(0.0, 24)
    end
  end

  @doc """
  The hours from the sunrise to the sunset in the middle of a month, at a
  latitude (°): from the angle of the sun to the equator.
  """
  def day_length(latitude, month) do
    day = Enum.at([17, 47, 75, 105, 135, 162, 198, 228, 258, 288, 318, 344], month - 1)
    declination = 23.44 * :math.sin(2 * :math.pi() * (284 + day) / 365)
    x = -:math.tan(rad(latitude)) * :math.tan(rad(declination))
    2 * deg(:math.acos(min(max(x, -1.0), 1.0))) / 15
  end

  defp rad(deg), do: deg * :math.pi() / 180
  defp deg(rad), do: rad * 180 / :math.pi()

  @doc """
  The running watts of an item: the power while it runs, for the check of
  the output of a power station.
  """
  def watts(%{type: "ac", params: p}), do: p["tons"] * 12_000 / (p["seer2"] * 0.82)
  def watts(%{type: "mini_split", params: p}), do: p["area"] * 25 / (p["seer2"] * 0.82)
  def watts(%{type: "furnace", params: p}), do: p["blower"] / 1
  def watts(%{type: "heat_strips", params: p}), do: p["kw"] * 1_000.0

  def watts(%{type: "water_heater", params: p}),
    do: %{"electric" => 4_500.0, "heat_pump" => 500.0, "gas" => 0.0}[p["fuel"]]

  def watts(%{type: type, params: p}) when type in ["fridge", "freezer"],
    do: max(p["kwh_year"] / 8_760 * 3_000, 50.0)

  def watts(%{type: "range", params: p}), do: if(p["fuel"] == "electric", do: 3_000.0, else: 50.0)
  def watts(%{type: "dishwasher"}), do: 1_200.0
  def watts(%{type: "washer"}), do: 500.0

  def watts(%{type: "dryer", params: p}),
    do: if(p["fuel"] == "electric", do: 5_000.0, else: 300.0)

  def watts(%{type: "lights", params: p}), do: p["bulbs"] * p["watts"] / 1
  def watts(%{type: "ceiling_fan", params: p}), do: p["count"] * p["watts"] / 1
  def watts(%{type: "ev", params: p}), do: charger_kw(p["charger"]) * 1_000

  def watts(%{type: type})
      when type in [
             "smart_meter",
             "power_station",
             "solar_panels",
             "transfer_switch",
             "camper_van"
           ],
      do: 0.0

  def watts(%{params: %{"watts" => watts}}), do: watts / 1

  @doc "True for an item with a motor that needs more power to start (a surge)."
  def motor?(%{type: type}), do: type in ["ac", "mini_split", "fridge", "freezer", "pool_pump"]
end
