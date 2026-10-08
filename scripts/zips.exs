# Writes priv/data/zips.bin: the center and the state of each ZIP Code
# Tabulation Area (ZCTA) of the US Census Bureau.
#
#   mix.com run --no-start scripts/zips.exs
#
# The sources:
# - The 2024 Gazetteer file of the ZCTAs: the center (the internal point) of
#   each ZCTA.
# - The 2020 relationship file of the ZCTAs and the counties: the state of
#   each ZCTA is the state of the county with the most land of the ZCTA.
#
# The file is a list of records of 8 bytes, in the order of the ZIP code:
# the ZIP code (24 bits), the state (8 bits, an index of DIY.Zip.states/0),
# the latitude and the longitude (16 bits each, signed, in 1/100 degree).
# DIY.Zip reads it.

defmodule Zips do
  @gazetteer "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2024_Gazetteer/2024_Gaz_zcta_national.zip"
  @relationship "https://www2.census.gov/geo/docs/maps-data/data/rel2020/zcta520/tab20_zcta520_county20_natl.txt"

  # The FIPS code of each state, and its postal code.
  @fips %{
    "01" => "AL", "02" => "AK", "04" => "AZ", "05" => "AR", "06" => "CA", "08" => "CO",
    "09" => "CT", "10" => "DE", "11" => "DC", "12" => "FL", "13" => "GA", "15" => "HI",
    "16" => "ID", "17" => "IL", "18" => "IN", "19" => "IA", "20" => "KS", "21" => "KY",
    "22" => "LA", "23" => "ME", "24" => "MD", "25" => "MA", "26" => "MI", "27" => "MN",
    "28" => "MS", "29" => "MO", "30" => "MT", "31" => "NE", "32" => "NV", "33" => "NH",
    "34" => "NJ", "35" => "NM", "36" => "NY", "37" => "NC", "38" => "ND", "39" => "OH",
    "40" => "OK", "41" => "OR", "42" => "PA", "44" => "RI", "45" => "SC", "46" => "SD",
    "47" => "TN", "48" => "TX", "49" => "UT", "50" => "VT", "51" => "VA", "53" => "WA",
    "54" => "WV", "55" => "WI", "56" => "WY", "60" => "AS", "66" => "GU", "69" => "MP",
    "72" => "PR", "78" => "VI"
  }

  def run(out) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    states = DIY.Zip.states()
    state_of = state_of(get(@relationship))

    records =
      zip_text(get(@gazetteer))
      |> String.split("\n", trim: true)
      |> tl()
      |> Enum.map(fn line ->
        [zip, _, _, _, _, lat, lon] = line |> String.split("\t") |> Enum.map(&String.trim/1)
        state = Map.fetch!(state_of, zip)
        index = Enum.find_index(states, &(&1 == state))
        lat = round(String.to_float(lat) * 100)
        lon = round(String.to_float(lon) * 100)
        {String.to_integer(zip), <<String.to_integer(zip)::24, index::8, lat::signed-16, lon::signed-16>>}
      end)
      |> Enum.sort()

    File.write!(out, Enum.map(records, &elem(&1, 1)))
    IO.puts("#{out}: #{length(records)} ZIP codes")
  end

  defp get(url) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {String.to_charlist(url), []},
        [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]], body_format: :binary)

    body
  end

  defp zip_text(zip) do
    {:ok, [{_name, text}]} = :zip.unzip(zip, [:memory])
    text
  end

  # The state of the county with the most land of each ZCTA.
  defp state_of(text) do
    text
    |> String.replace_prefix("﻿", "")
    |> String.split(["\r\n", "\n"], trim: true)
    |> tl()
    |> Enum.map(&String.split(&1, "|"))
    |> Enum.filter(fn row -> Enum.at(row, 1) != "" end)
    |> Enum.group_by(&Enum.at(&1, 1))
    |> Map.new(fn {zip, rows} ->
      row = Enum.max_by(rows, &String.to_integer(Enum.at(&1, 16)))
      {zip, Map.fetch!(@fips, String.slice(Enum.at(row, 9), 0, 2))}
    end)
  end
end

Zips.run(Path.expand("../priv/data/zips.bin", __DIR__))
