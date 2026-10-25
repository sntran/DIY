defmodule DIY.Solar do
  @moduledoc """
  The help of the sheet of solar panels. It gives the panels that the
  roof holds, the limit of the stations, and a typical price. Each number
  shows where it comes from (honesty rule 1).

  ## The roof

  The roof covers the top floor: the size of the house ÷ its floors. One
  side of a gable roof is half of the roof. A slope of 6 in 12 makes it
  1.12 times larger than the floor under it. A flat roof is all one side.
  The app uses 2/3 of the side. The rest is for the paths and the space
  at the ridge of the fire code (International Residential Code 2021,
  R324.6).
  This is a simple model of the app. A hip roof has 4 sides, so one side
  holds near half of that. The panel is the panel of `DIY.Layout`: 400 W,
  45 by 68 in.

  ## The station

  The panels give 80% of their watts in full sun (`DIY.Power.derate/0`).
  A station takes at most the watts of its solar input. In full sun, the
  rest is lost. The page Power gives the kWh that is lost in one year.

  ## The price

  The note gives the price for each watt of a system on a roof in Texas,
  with the installation, before any credit. SolarReviews (October 2026)
  gives it for each size from 4 to 10 kW. The app rounds the watts to the
  nearest kW, so it uses the price of 4 kW from 3,500 W. EnergySage
  (October 2026) gives $2.25 for a system of 13 kW. The US tax credit for
  home solar (section 25D) stops for a system that the installer
  completes after 2025 (Public Law 119-21).
  """

  alias DIY.{Build, Estimate, Layout, Power}

  # The sun of the positions of a tracker in a picture (`track_sun/1`): the
  # sun of an equinox at 30° of latitude (the middle of Texas). A tracker
  # does not tilt its panels lower than 20° over the horizon.
  @track_latitude 30
  @track_low 20

  @doc """
  The direction that the panels of a tracker face at a solar hour, as a
  unit vector. The x goes to the east, y to the south, and z up. It is the direction of
  the sun of an equinox at 30° of latitude. The height of the sun gives
  its azimuth. Then the panels do not go lower than 20° over the horizon.
  At 18:00, the sun is at the horizon in the west, so the panels face the
  west at 20°. With no hour (the night), the panels lie flat.
  """
  @spec track_sun(number() | nil) :: {float(), float(), float()}
  def track_sun(nil), do: {0.0, 0.0, 1.0}

  def track_sun(hour) do
    lat = @track_latitude * :math.pi() / 180
    w = (hour - 12) * 15 * :math.pi() / 180
    high = :math.asin(:math.cos(lat) * :math.cos(w))
    # The azimuth from the north (the declination is 0 at an equinox): the
    # sun is in the east before noon.
    cos_a = -:math.sin(high) * :math.sin(lat) / (:math.cos(high) * :math.cos(lat))
    a = :math.acos(min(max(cos_a, -1.0), 1.0))
    a = if hour < 12, do: a, else: 2 * :math.pi() - a
    high = max(high, @track_low * :math.pi() / 180)
    {:math.cos(high) * :math.sin(a), -:math.cos(high) * :math.cos(a), :math.sin(high)}
  end

  @slope 1.12
  @usable 2 / 3

  # SolarReviews, Texas, October 2026: the price for each watt of a
  # system of 4 to 10 kW.
  @per_watt %{4 => 3.40, 5 => 3.15, 6 => 2.98, 7 => 2.86, 8 => 2.77, 9 => 2.70, 10 => 2.65}
  @large 2.25

  @doc "The panels of 400 W that one side of the roof of a house holds, and their watts."
  def roof(%{size: size, floors: floors}, facing) do
    {w, d} = Layout.panel()
    side = size / floors * if(facing == "flat", do: 1.0, else: 0.5 * @slope)
    panels = trunc(side * @usable / (w * d / 144))
    %{panels: panels, watts: panels * Layout.panel_watts()}
  end

  @doc """
  A typical price in Texas for a system of some watts on a roof, in
  dollars for each watt: `{low, high}`. For a system of 4 to 10 kW, the
  two are the same. Under 4 kW, it is nil: a small system costs more.
  """
  def per_watt(watts) when watts < 3_500, do: nil
  def per_watt(watts) when watts >= 10_500, do: {@large, @per_watt[10]}

  def per_watt(watts) do
    price = @per_watt[round(watts / 1000)]
    {price, price}
  end

  @doc """
  The notes of the sheet of solar panels, at most 2:

  - the roof, for panels on the roof;
  - the limit of the stations, for panels that charge a station;
  - a typical price in Texas, for panels on the roof and on the grid.
  """
  def notes(%Build{} = build, %{type: "solar_panels"} = item) do
    on_roof = match?({:ok, %{place: :roof}}, Build.room(build, item.room))

    [
      on_roof && roof_note(build, item),
      station_note(build, item),
      on_roof && price_note(build, item)
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp roof_note(build, %{params: p}) do
    %{panels: panels, watts: watts} = roof(build.house, p["facing"])
    {w, d} = Layout.panel()

    {part, hip} =
      if p["facing"] == "flat",
        do: {"The roof", ""},
        else: {"One side of the roof", " A hip roof holds less."}

    "#{part} holds near #{count(panels)} of #{Layout.panel_watts()} W (#{w} by #{d} in): near #{Estimate.fmt(watts)} W. This is a simple model of the app, from the size and the floors of the house.#{hip}#{if p["watts"] > watts, do: " #{Estimate.fmt(p["watts"])} W is more than that."}"
  end

  defp count(1), do: "1 panel"
  defp count(n), do: "#{n} panels"

  defp station_note(build, %{params: %{"to" => "station"}}) do
    items = Build.house_view(build).items
    stations = Enum.filter(items, &(&1.type == "power_station"))
    input = stations |> Enum.map(& &1.params["solar_w"]) |> Enum.sum()

    sun =
      for(%{type: "solar_panels", params: %{"to" => "station"} = p} <- items, do: p["watts"])
      |> Enum.sum()
      |> Kernel.*(Power.derate())

    cond do
      stations == [] ->
        "No power station is in the house, so these panels charge nothing. Add a station, or choose \"The house and the grid\"."

      input == 0 ->
        "The stations of the house take no sun: their solar input is 0 W. Give the solar input of a station, or choose \"The house and the grid\"."

      sun > input ->
        "In full sun, the panels give near #{Estimate.fmt(sun)} W (80% of their labels). The stations take at most #{Estimate.fmt(input)} W: the rest is lost. The page Power gives the kWh of one year. Use fewer panels, a station with more solar input, or \"The house and the grid\"."

      true ->
        nil
    end
  end

  defp station_note(_build, _item), do: nil

  defp price_note(%{zip: zip}, %{params: %{"to" => "grid", "watts" => watts}}) do
    with {:ok, %{state: "TX"}} <- DIY.Zip.lookup(zip) do
      price_text(per_watt(watts), watts) <>
        " A system that is complete after 2025 gets no US tax credit for its owner (section 25D, Public Law 119-21)."
    else
      _other -> nil
    end
  end

  defp price_note(_build, _item), do: nil

  defp price_text(nil, _watts),
    do:
      "On a roof in Texas, a system of 4 kW costs near $3.40 for each watt, with the installation (SolarReviews, October 2026). A smaller system costs more for each watt."

  defp price_text({same, same}, watts),
    do:
      "On a roof in Texas, a system of #{round(watts / 1000)} kW costs near $#{dollars(same)} for each watt, with the installation (SolarReviews, October 2026). For #{Estimate.fmt(watts)} W: near $#{Estimate.fmt(watts * same)}."

  defp price_text({low, high}, watts),
    do:
      "On a roof in Texas, a large system costs near $#{dollars(low)} to $#{dollars(high)} for each watt, with the installation. The sources are EnergySage (13 kW) and SolarReviews (10 kW), October 2026. For #{Estimate.fmt(watts)} W: near $#{Estimate.fmt(watts * low)} to $#{Estimate.fmt(watts * high)}."

  defp dollars(price), do: :erlang.float_to_binary(price, decimals: 2)
end
