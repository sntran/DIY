defmodule DIY.Van do
  @moduledoc """
  The build of a camper van: its zones and items (`DIY.Build`), and its two
  budgets.

  ## The weight budget

  The payload is the weight rating of the van (GVWR) less its empty
  weight. The items, the water, the people and the gear take it. Each zone
  has a place from the front axle to the rear axle (`@places`): the part
  of the weight of a zone on the rear axle is that place, and the rest is
  on the front axle (a lever). A place over 1 is behind the rear axle: it
  takes weight from the front axle. The places are a simple model of the
  app: a typical layout, with the bed and the electrical bay over the rear
  axle.

  The water of a tank weighs 8.34 lb for each gallon (USGS, "Water
  density"). The people sit in the cab. The gear goes under the bed.

  ## The power budget

  For each month, the items use some Wh in one day: the power of each item
  for its hours (a fan in the warm months, a heater in the cold months).
  An item on an outlet of 120 V takes its power through the inverter: the
  app counts 90% for the inverter (the data sheets of inverters give 85% to
  94%). The day gets power from the sun (the panels in full sun for the
  hours of the sun of NASA POWER at the house, at 80%, as `DIY.Power`), and
  from the alternator charger when the engine runs (its amps at 12.8 V).
  The batteries keep power: a lithium battery (LiFePO4) gives 90% of its
  label, a lead acid or AGM battery 50% (it lasts longer when it gives
  only half), and a power station 95% (`DIY.Power`).

  The days off the grid: the batteries, divided by the power that the day
  uses more than it gets. When the sun and the engine give more than the
  use, the van stays off the grid with no limit.
  """

  alias DIY.{Build, Catalog}

  # The place of each zone, from the front axle (0) to the rear axle (1).
  @places %{
    cab: 0.1,
    galley: 0.4,
    living: 0.55,
    bed: 1.0,
    bay: 0.95,
    van_roof: 0.5,
    shell: 0.5
  }

  @water_lb 8.34
  @inverter 0.9
  @derate 0.8
  @charge_volts 12.8
  @usable %{"lifepo4" => 0.9, "agm" => 0.5}
  @station_usable 0.95

  # The kinds that burn fuel in the van.
  @fuel ~w(propane butane diesel)

  @doc "The camper vans of a build."
  def vans(build), do: Enum.filter(build.items, &(&1.type == "camper_van"))

  @doc "The items in the zones of a van, each with its zone."
  def items(build, van_id) do
    for zone <- Build.zones(build, van_id),
        item <- Build.items_in(build, zone.id),
        do: {zone.place, item}
  end

  @doc "The weight of an item, in pounds: with the water of a tank."
  def weight(%{type: "water_tank", params: p}), do: p["weight"] + p["gallons"] * @water_lb
  def weight(%{params: %{"weight" => weight}}), do: weight / 1

  @doc "The place of a zone, from the front axle (0) to the rear axle (1)."
  def place(zone), do: Map.fetch!(@places, zone)

  @doc """
  The weight budget of a van: the empty weight, the payload, the load (the
  items, the people and the gear), the weight on each axle and in all, the
  weight of each zone, and the limits that the van goes over (`:gvwr`,
  `:front`, `:rear`). A rating of 0 for an axle is not known: no check.
  """
  def weight(build, van) do
    p = van.params
    items = items(build, van.id)

    loads =
      Enum.map(items, fn {zone, item} -> {zone, weight(item)} end) ++
        [{:cab, p["people"] * p["person_lb"] / 1}, {:bed, p["gear_lb"] / 1}]

    rear = Enum.sum(for {zone, lb} <- loads, do: lb * place(zone))
    load = Enum.sum(for {_zone, lb} <- loads, do: lb)
    front = p["front_empty"] + load - rear
    rear = p["rear_empty"] + rear
    empty = p["front_empty"] + p["rear_empty"]

    zones =
      for {zone, _name} <- Catalog.zones(),
          do: {zone, Enum.sum(for {z, lb} <- loads, z == zone, do: lb)}

    %{
      empty: empty / 1,
      payload: (p["gvwr"] - empty) / 1,
      load: load,
      total: front + rear,
      front: front,
      rear: rear,
      gvwr: p["gvwr"],
      front_gawr: p["front_gawr"],
      rear_gawr: p["rear_gawr"],
      zones: zones,
      over:
        Enum.filter(
          [
            front + rear > p["gvwr"] && :gvwr,
            (p["front_gawr"] > 0 and front > p["front_gawr"]) && :front,
            (p["rear_gawr"] > 0 and rear > p["rear_gawr"]) && :rear
          ],
          & &1
        )
    }
  end

  @doc """
  The power budget of a van in each month, with the sun of a climate
  (`DIY.Weather`), or `nil` with no climate: the Wh that the items use in
  one day, the Wh from the sun and from the engine, the Wh that the
  batteries keep, and the days off the grid (`:unlimited` when the day
  gets more than it uses, `nil` with no battery).
  """
  def power(build, van, climate) do
    items = items(build, van.id)
    storage = items |> Enum.map(fn {_zone, item} -> storage(item) end) |> Enum.sum()
    panels = sum(items, "van_solar", "watts")
    drive = sum(items, "dc_charger", "amps") * @charge_volts * van.params["drive_hours"]

    months =
      for m <- 1..12 do
        sun = climate && climate.months[m].sun
        use = items |> Enum.map(fn {_zone, item} -> wh_day(item, m) end) |> Enum.sum()
        solar = if sun, do: panels * sun * @derate, else: 0.0
        net = use - solar - drive

        %{
          month: m,
          name: Enum.at(DIY.Estimate.month_names(), m - 1),
          use: use,
          sun: solar,
          drive: drive,
          days: days(storage, net)
        }
      end

    if climate, do: %{storage: storage, months: months}
  end

  defp sum(items, type, key),
    do: Enum.sum(for {_zone, %{type: ^type, params: p}} <- items, do: p[key] / 1)

  defp days(storage, _net) when storage <= 0, do: nil
  defp days(_storage, net) when net <= 0, do: :unlimited
  defp days(storage, net), do: storage / net

  # The Wh that a battery or a station gives.
  defp storage(%{type: "van_battery", params: p}),
    do: p["ah"] * String.to_integer(p["volts"]) * @usable[p["chemistry"]]

  defp storage(%{type: "power_station", params: p}),
    do: (p["kwh"] + p["extra_kwh"]) * 1_000 * @station_usable

  defp storage(_item), do: 0.0

  @doc "The Wh that an item uses in one day of a month."
  def wh_day(%{type: "van_fridge", params: p}, _month), do: p["wh_day"] / 1

  def wh_day(%{type: "stove", params: %{"fuel" => "induction"} = p}, _month),
    do: p["watts"] * p["minutes"] / 60 / @inverter

  def wh_day(%{type: "water_pump", params: p}, _month), do: p["watts"] * p["minutes"] / 60

  def wh_day(%{type: type, params: p}, month) when type in ["van_fan", "diesel_heater"],
    do: if(month in Catalog.season_months(p["season"]), do: p["watts"] * p["hours"], else: 0.0)

  def wh_day(%{type: "van_lights", params: p}, _month), do: p["watts"] * p["hours"]

  def wh_day(%{type: "devices", params: p}, _month),
    do: p["watts"] * p["hours"] / if(p["outlet"] == "ac", do: @inverter, else: 1)

  def wh_day(%{type: "inverter", params: p}, _month), do: p["idle_w"] * p["hours"]
  def wh_day(_item, _month), do: 0.0

  @doc """
  The safety notes of a van, where they apply:

  - `{:fuse, item}`: a battery with no fuse near its positive post. The
    ABYC standard E-11 for boats, which many van builders use, puts the
    fuse within 7 inches of the battery.
  - `:co`: a stove or a heater that burns fuel, with no alarm of carbon
    monoxide. It needs fresh air too.
  - `:propane`: a propane or butane stove: the alarm goes low, because
    propane is heavier than air.
  - `:inverter`: an item on an outlet of 120 V, with no inverter and no
    power station.
  - `:no_battery`: items that use power, with no battery and no station.
  """
  def warnings(build, van) do
    items = Enum.map(items(build, van.id), &elem(&1, 1))
    types = Enum.map(items, & &1.type)
    fuel = Enum.filter(items, &burns?/1)

    Enum.filter(
      for(%{type: "van_battery", params: %{"fused" => false}} = b <- items, do: {:fuse, b}) ++
        [
          (fuel != [] and "co_alarm" not in types) && :co,
          Enum.any?(fuel, &(&1.type == "stove" and &1.params["fuel"] in ["propane", "butane"])) &&
            :propane,
          (Enum.any?(items, &ac?/1) and
             not Enum.any?(types, &(&1 in ["inverter", "power_station"]))) &&
            :inverter,
          (Enum.any?(items, &(wh_day(&1, 7) > 0 or wh_day(&1, 1) > 0)) and
             not Enum.any?(types, &(&1 in ["van_battery", "power_station"]))) && :no_battery
        ],
      & &1
    )
  end

  defp burns?(%{type: "stove", params: p}), do: p["fuel"] in @fuel
  defp burns?(%{type: "diesel_heater"}), do: true
  defp burns?(_item), do: false

  defp ac?(%{type: "stove", params: p}), do: p["fuel"] == "induction"
  defp ac?(%{type: "devices", params: p}), do: p["outlet"] == "ac"
  defp ac?(_item), do: false

  @doc """
  The power stations of the house that can go in a van, and the stations
  of the house that are in a van now (with their van).
  """
  def stations(build) do
    house = Build.house_view(build)
    at_home = Enum.filter(house.items, &(&1.type == "power_station"))

    away =
      for van <- vans(build),
          {_zone, %{type: "power_station", home: home} = item} <- items(build, van.id),
          home != nil,
          do: {item, van}

    %{at_home: at_home, away: away}
  end
end
