defmodule DIY.Market do
  @moduledoc """
  The utility area of a Texas ZIP code, from the API of Power to Choose,
  the official list of the retail plans of the Public Utility Commission of
  Texas (https://www.powertochoose.org).

  In an area with retail choice, the user picks a retail plan, and a
  utility (the TDU) delivers the power. Power to Choose lists the plans of
  each ZIP code. A ZIP code with no plans has no retail choice: for
  example Austin (Austin Energy), San Antonio (CPS Energy) and the areas of
  the co-ops.

  A market is a map:

  - `choice`: true when the ZIP code has retail choice.
  - `utility`: the name of the utility that delivers the power, or `nil`.
  - `median`: the median price of the plans at 1,000 kWh in one month, in
    cents for one kWh, with the delivery charges. It is not a rank of the
    plans: it is one number for the estimate, until the user gives a
    price.
  - `plans`: the number of plans.
  - `date`: the date of the data.
  - `source`: `"ptc"` (Power to Choose) or `"user"` (the user changed it).
  """

  alias DIY.Cache

  @url "https://api.powertochoose.org/api/PowerToChoose/plans"

  # The names of the utilities in Power to Choose, and their short names.
  @utilities %{
    "ONCOR ELECTRIC DELIVERY COMPANY" => "Oncor",
    "CENTERPOINT ENERGY HOUSTON ELECTRIC LLC" => "CenterPoint",
    "AEP TEXAS CENTRAL" => "AEP Texas Central",
    "AEP TEXAS NORTH" => "AEP Texas North",
    "TEXAS-NEW MEXICO POWER COMPANY" => "TNMP",
    "LUBBOCK POWER & LIGHT SYSTEM" => "Lubbock Power & Light"
  }

  @type t :: %{
          choice: boolean(),
          utility: String.t() | nil,
          median: float() | nil,
          plans: non_neg_integer(),
          date: String.t(),
          source: String.t()
        }

  @doc """
  The market of a Texas ZIP code, from Power to Choose. The cache keeps it
  for one day.
  """
  @spec fetch(String.t(), Date.t()) :: {:ok, t()} | {:error, String.t()}
  def fetch(zip, today \\ Date.utc_today()) do
    Cache.fetch({__MODULE__, zip, today}, fn -> get(zip, today) end)
  end

  defp get(zip, today) do
    options =
      [url: @url, params: [zip_code: zip], receive_timeout: 20_000]
      |> Keyword.merge(Application.get_env(:diy, __MODULE__, [])[:req] || [])

    case Req.get(options) do
      {:ok, %{status: 200, body: body}} -> parse(body, today)
      {:ok, %{status: status}} -> {:error, "Power to Choose answered #{status}."}
      {:error, error} -> {:error, "Power to Choose did not answer (#{Exception.message(error)})."}
    end
  end

  @doc false
  def parse(%{"success" => true, "data" => plans}, today) when is_list(plans) do
    plans = Enum.filter(plans, &is_map/1)

    utility =
      plans
      |> Enum.map(& &1["company_tdu_name"])
      |> Enum.filter(&is_binary/1)
      |> Enum.frequencies()
      |> Enum.max_by(fn {_name, count} -> count end, fn -> {nil, 0} end)
      |> elem(0)

    prices =
      for %{"price_kwh1000" => price} <- plans, is_number(price) and price > 0, do: price / 1

    {:ok,
     %{
       choice: plans != [],
       utility: utility && Map.get(@utilities, utility, titlecase(utility)),
       median: median(prices),
       plans: length(plans),
       date: Date.to_iso8601(today),
       source: "ptc"
     }}
  end

  def parse(_body, _today),
    do: {:error, "Power to Choose gave an answer that the app cannot read."}

  defp titlecase(name),
    do: name |> String.downcase() |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)

  @doc false
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  # The days that a market of Power to Choose stays good in a build. The
  # plans and their prices change: the page asks again after them.
  @days 7

  @doc """
  True when a market of Power to Choose in a build is old: #{@days} days or
  more. A market that the user gave does not get old.
  """
  @spec old?(t(), Date.t()) :: boolean()
  def old?(market, today \\ Date.utc_today())

  def old?(%{source: "ptc", date: date}, today),
    do: Date.diff(today, Date.from_iso8601!(date)) >= @days

  def old?(_market, _today), do: false

  @doc """
  The market that the user gives: the user knows that the utility is a
  city utility or a co-op (no choice), or the name of the utility.
  """
  @spec by_user(t() | nil, boolean(), Date.t()) :: t()
  def by_user(market, choice, today \\ Date.utc_today()) do
    base = market || %{utility: nil, median: nil, plans: 0}

    %{
      choice: choice,
      utility: if(choice, do: base.utility),
      median: if(choice, do: base.median),
      plans: base.plans,
      date: Date.to_iso8601(today),
      source: "user"
    }
  end

  @doc "Reads a market from a stored build."
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{"choice" => choice, "plans" => plans, "date" => date, "source" => source} = map)
      when is_boolean(choice) and is_integer(plans) and plans >= 0 and is_binary(date) and
             source in ["ptc", "user"] do
    # A median in cents, at most 200¢ (as the price of the user): a very
    # large integer has no float.
    with {:ok, _date} <- Date.from_iso8601(date),
         utility when is_nil(utility) or is_binary(utility) <- map["utility"],
         median when is_nil(median) or (is_number(median) and median > 0 and median <= 200) <-
           map["median"] do
      {:ok,
       %{
         choice: choice,
         utility: utility,
         median: median && median / 1,
         plans: plans,
         date: date,
         source: source
       }}
    else
      _ -> :error
    end
  end

  def from_map(_map), do: :error
end
