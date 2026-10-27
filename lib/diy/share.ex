defmodule DIY.Share do
  @moduledoc """
  The link of a shared house (docs/design.md, "A shared house"): the
  path `/s/DATA`. `DATA` is the version of the format (`1`), then the
  shared house as JSON, compressed with raw DEFLATE, in base64url
  (`DIY.Pack`).

  The JSON has the stripped build (`strip/2`) and its summary
  (`summary/5`). The picture and the title of the preview are in the
  language of the summary.

  The server keeps no copy of a shared house: it reads it only to answer
  the request of its link.
  """

  alias DIY.Build

  @version "1"

  # The languages of the app (`DIY.Gettext`).
  @locales Application.compile_env!(:diy, [DIY.Gettext, :allowed_locales])

  # The largest DATA, and the largest JSON after the inflate. A typical
  # house is about 8 KB of JSON.
  @max_data 6_000
  @max_json 32 * 1024

  # The most items and rooms of a shared house. A picture of a house with
  # more items takes too much time of the VM (docs/design.md, "The link").
  @max_items 150
  @max_rooms 50

  # The largest kWh of a month, and the largest cost of a year.
  @max_kwh 100_000
  @max_cost 10_000_000

  # The most items with a label in the picture, and the longest id of an
  # item.
  @max_labels 6
  @max_id 16

  # The fields of the build that a link never has. They are the links to
  # Home Assistant and to the makers, and the state of the app and of the
  # lesson. A decode puts these values back, whatever the link has.
  @forced %{
    "revision" => 0,
    "stamp" => "",
    "lesson" => 1,
    "lesson_plan" => nil,
    "plans" => [],
    "hints" => [],
    "areas" => %{},
    "devices" => %{},
    "units" => %{}
  }

  @type summary :: %{
          months: [non_neg_integer()],
          cost: non_neg_integer() | nil,
          locale: String.t(),
          sky: %{time: String.t(), weather: String.t()},
          items: [%{id: String.t(), kwh: non_neg_integer(), cost: non_neg_integer() | nil}]
        }

  # The sky of a link with no sky: a link of an older version.
  @day %{time: "day", weather: "sun"}

  @doc "The largest `DATA` of a link."
  def max_data, do: @max_data

  @doc """
  The build with no data of a link to Home Assistant or to a maker. It has
  no state of the app and no plans of the lesson. With `zip: false`, it
  also has no ZIP code.
  """
  @spec strip(Build.t(), keyword()) :: Build.t()
  def strip(%Build{} = build, opts \\ []) do
    build = %{
      build
      | revision: 0,
        stamp: "",
        lesson: 1,
        lesson_plan: nil,
        plans: [],
        hints: [],
        areas: %{},
        devices: %{},
        units: %{}
    }

    if Keyword.get(opts, :zip, true), do: build, else: %{build | zip: nil}
  end

  @doc """
  The summary of the numbers of a house:

  - the kWh of each month (12 numbers, January first);
  - the cost of the year in dollars, or `nil`;
  - a locale of the app;
  - the sky of the picture: a time of day and a weather (`DIY.Sky`). A
    sky that `DIY.Sky` does not know is a day with sun;
  - the items with the most kWh in a year, for the labels of the
    picture. Each item is `{id, kwh, cost}`. The cost is the cost of the
    year in dollars, or `nil`.
    The summary keeps the 6 items with the most kWh, and no item with
    less than 1 kWh.

  The numbers are rounded, and they stay in the range that a link
  accepts.
  """
  @spec summary([number()], number() | nil, String.t(), map(), list()) :: summary()
  def summary(months, cost, locale, sky \\ @day, items \\ []) when length(months) == 12 do
    %{
      months: Enum.map(months, &(&1 |> round() |> max(0) |> min(@max_kwh))),
      cost: cost && amount(cost),
      locale: if(locale in @locales, do: locale, else: "en"),
      sky: if(sky?(sky), do: Map.take(sky, [:time, :weather]), else: @day),
      items:
        for(
          {id, kwh, cost} <- items,
          is_binary(id) and byte_size(id) <= @max_id,
          kwh = kwh |> round() |> min(12 * @max_kwh),
          kwh >= 1,
          do: %{id: id, kwh: kwh, cost: cost && amount(cost)}
        )
        |> Enum.sort_by(&(-&1.kwh))
        |> Enum.take(@max_labels)
    }
  end

  defp amount(dollars), do: dollars |> round() |> max(0) |> min(@max_cost)

  defp sky?(%{time: time, weather: weather}),
    do: time in DIY.Sky.times() and weather in DIY.Sky.weathers()

  defp sky?(_sky), do: false

  @doc "The kWh of the year of a summary."
  def year(%{months: months}), do: Enum.sum(months)

  @doc """
  The `DATA` of the link of a build and its summary. The build is
  stripped (`strip/2`): `opts` goes to it. A house that a link cannot
  carry gives `{:error, :too_large}`: it has too many items or rooms, or
  its link is too long.
  """
  @spec encode(Build.t(), summary(), keyword()) :: {:ok, String.t()} | {:error, :too_large}
  def encode(%Build{} = build, summary, opts \\ []) do
    map =
      build
      |> strip(opts)
      |> Build.to_json()
      |> Jason.decode!()
      |> Map.drop(Map.keys(@forced))

    json =
      Jason.encode!(%{
        "b" => map,
        "s" => %{
          "m" => summary.months,
          "c" => summary.cost,
          "l" => summary.locale,
          "t" => summary.sky.time,
          "w" => summary.sky.weather,
          "i" => Enum.map(summary.items, &[&1.id, &1.kwh, &1.cost])
        }
      })

    data = DIY.Pack.encode(json)

    if small?(map) and byte_size(json) <= @max_json and byte_size(data) < @max_data,
      do: {:ok, @version <> data},
      else: {:error, :too_large}
  end

  # The count of the items and of the rooms of the JSON of a build.
  defp small?(map) do
    count(map["items"]) <= @max_items and count(map["rooms"]) <= @max_rooms
  end

  defp count(list) when is_list(list), do: length(list)
  defp count(_other), do: 0

  @doc """
  Reads the `DATA` of a link. Gives `{:ok, build, summary}`, or
  `{:error, reason}` for a text that is not a shared house.
  """
  @spec decode(term()) :: {:ok, Build.t(), summary()} | {:error, atom()}
  def decode(@version <> data) when byte_size(data) < @max_data do
    with {:ok, json} <- DIY.Pack.decode(data, @max_json),
         {:ok, %{"b" => b, "s" => s}} when is_map(b) <- decode_json(json),
         {:ok, summary} <- read_summary(s),
         {:ok, build} <- read_build(b) do
      {:ok, build, summary}
    else
      {:ok, _other} -> {:error, :not_a_house}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(@version <> _data), do: {:error, :too_long}
  def decode(_data), do: {:error, :version}

  @doc """
  Reads the path of a link: the `DATA` of a long link, or the id of a
  short link (`DIY.Links`). A short link that ended gives
  `{:error, :gone}`.
  """
  @spec resolve(term()) :: {:ok, Build.t(), summary()} | {:error, atom()}
  def resolve(path) do
    if DIY.Links.id?(path) do
      with {:ok, data} <- DIY.Links.fetch(path), do: decode(data)
    else
      decode(path)
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      {:error, _reason} -> {:error, :json}
    end
  end

  defp read_summary(%{"m" => months, "c" => cost, "l" => locale} = s) when length(months) == 12 do
    # A link of an older version has no sky (a day with sun) and no items.
    sky = %{time: Map.get(s, "t", "day"), weather: Map.get(s, "w", "sun")}
    items = Map.get(s, "i", [])

    if Enum.all?(months, &(is_integer(&1) and &1 in 0..@max_kwh)) and cost?(cost) and
         locale in @locales and sky?(sky) and is_list(items) and
         length(items) <= @max_labels and Enum.all?(items, &item?/1) do
      items = for [id, kwh, cost] <- items, do: %{id: id, kwh: kwh, cost: cost}
      {:ok, %{months: months, cost: cost, locale: locale, sky: sky, items: items}}
    else
      {:error, :summary}
    end
  end

  defp read_summary(_summary), do: {:error, :summary}

  defp cost?(cost), do: cost == nil or (is_integer(cost) and cost in 0..@max_cost)

  defp item?([id, kwh, cost]),
    do:
      is_binary(id) and byte_size(id) <= @max_id and is_integer(kwh) and
        kwh in 1..(12 * @max_kwh) and cost?(cost)

  defp item?(_item), do: false

  # A shared house has a house: the page of the link draws it. The count
  # of its items and rooms comes first: it costs nothing. The read gives
  # each van its zones, so the rooms are counted again after the read.
  defp read_build(map) do
    with true <- small?(map) || {:error, :too_large},
         {:ok, %Build{house: %{}} = build} <-
           map |> Map.merge(@forced) |> Jason.encode!() |> Build.from_json(),
         true <- length(build.rooms) <= @max_rooms || {:error, :too_large} do
      {:ok, build}
    else
      {:ok, _build} -> {:error, :no_house}
      {:error, :too_large} -> {:error, :too_large}
      {:error, _reason} -> {:error, :build}
    end
  end
end
