defmodule DIY.Share do
  @moduledoc """
  The link of a shared house (docs/design.md, "A shared house"): the
  path `/s/DATA`. `DATA` is the version of the format (`1`), then the
  shared house as JSON, compressed with raw DEFLATE, in base64url.

  The JSON has the stripped build (`strip/2`) and its summary
  (`summary/3`). The picture and the title of the preview are in the
  language of the summary.

  The server keeps no copy of a shared house: it reads it only to answer
  the request of its link.
  """

  alias DIY.Build

  @version "1"

  # The languages of the app (`DIY.Gettext`).
  @locales Application.compile_env!(:diy, [DIY.Gettext, :allowed_locales])

  # The largest DATA, and the largest JSON after the inflate.
  @max_data 6_000
  @max_json 256 * 1024

  # The largest kWh of a month, and the largest cost of a year.
  @max_kwh 100_000
  @max_cost 10_000_000

  # The fields of the build that a link never has. They are the links to
  # Home Assistant and to the makers, and the state of the app. A decode
  # puts these values back, whatever the link has.
  @forced %{
    "revision" => 0,
    "stamp" => "",
    "lesson" => 1,
    "lesson_plan" => nil,
    "hints" => [],
    "areas" => %{},
    "devices" => %{},
    "units" => %{}
  }

  @type summary :: %{
          months: [non_neg_integer()],
          cost: non_neg_integer() | nil,
          locale: String.t()
        }

  @doc "The largest `DATA` of a link."
  def max_data, do: @max_data

  @doc """
  The build with no data of a link to Home Assistant or to a maker, and
  no state of the app. With `zip: false`, it also has no ZIP code.
  """
  @spec strip(Build.t(), keyword()) :: Build.t()
  def strip(%Build{} = build, opts \\ []) do
    build = %{
      build
      | revision: 0,
        stamp: "",
        lesson: 1,
        lesson_plan: nil,
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
  - a locale of the app.

  The numbers are rounded.
  """
  @spec summary([number()], number() | nil, String.t()) :: summary()
  def summary(months, cost, locale) when length(months) == 12 do
    %{
      months: Enum.map(months, &max(round(&1), 0)),
      cost: cost && max(round(cost), 0),
      locale: if(locale in @locales, do: locale, else: "en")
    }
  end

  @doc "The kWh of the year of a summary."
  def year(%{months: months}), do: Enum.sum(months)

  @doc """
  The `DATA` of the link of a build and its summary. The build is
  stripped (`strip/2`): `opts` goes to it.
  """
  @spec encode(Build.t(), summary(), keyword()) :: String.t()
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
        "s" => %{"m" => summary.months, "c" => summary.cost, "l" => summary.locale}
      })

    @version <> Base.url_encode64(deflate(json), padding: false)
  end

  @doc """
  Reads the `DATA` of a link. Gives `{:ok, build, summary}`, or
  `{:error, reason}` for a text that is not a shared house.
  """
  @spec decode(term()) :: {:ok, Build.t(), summary()} | {:error, atom()}
  def decode(@version <> data) when byte_size(data) < @max_data do
    with {:ok, bytes} <- base64(data),
         {:ok, json} <- inflate(bytes),
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

  defp base64(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :base64}
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      {:error, _reason} -> {:error, :json}
    end
  end

  defp read_summary(%{"m" => months, "c" => cost, "l" => locale}) when length(months) == 12 do
    if Enum.all?(months, &(is_integer(&1) and &1 in 0..@max_kwh)) and
         (cost == nil or (is_integer(cost) and cost in 0..@max_cost)) and
         locale in @locales do
      {:ok, %{months: months, cost: cost, locale: locale}}
    else
      {:error, :summary}
    end
  end

  defp read_summary(_summary), do: {:error, :summary}

  # A shared house has a house: the page of the link draws it.
  defp read_build(map) do
    case map |> Map.merge(@forced) |> Jason.encode!() |> Build.from_json() do
      {:ok, %Build{house: %{}} = build} -> {:ok, build}
      {:ok, _build} -> {:error, :no_house}
      {:error, _reason} -> {:error, :build}
    end
  end

  defp deflate(data) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 9, :deflated, -15, 9, :default)
    out = :zlib.deflate(z, data, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(out)
  end

  # The inflate stops at @max_json bytes: a small link cannot become a
  # large text.
  defp inflate(bytes) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, -15)

    try do
      z |> :zlib.safeInflate(bytes) |> collect(z, [], 0)
    rescue
      ErlangError -> {:error, :inflate}
    after
      :zlib.close(z)
    end
  end

  defp collect(_result, _z, _acc, size) when size > @max_json, do: {:error, :too_large}

  # A stream that ends before its end gives no output and asks for more
  # input: it is not a link.
  defp collect({:continue, out}, z, acc, size) do
    case IO.iodata_length(out) do
      0 -> {:error, :inflate}
      n -> z |> :zlib.safeInflate([]) |> collect(z, [acc | out], size + n)
    end
  end

  defp collect({:finished, out}, _z, acc, size) do
    if size + IO.iodata_length(out) > @max_json,
      do: {:error, :too_large},
      else: {:ok, IO.iodata_to_binary([acc | out])}
  end
end
