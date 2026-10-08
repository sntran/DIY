defmodule DIY.Zip do
  @moduledoc """
  The place of a ZIP code: its state, and its center (latitude and
  longitude). The data comes from the US Census Bureau: the 2024 Gazetteer
  file of the ZIP Code Tabulation Areas, and the 2020 file of the ZCTAs and
  the counties (`scripts/zips.exs`).

  The file `priv/data/zips.bin` has one record of 8 bytes for each ZIP
  code, in order. A lookup is a binary search: no copy of the data.
  """

  # The order is the index of the state in the file. Do not change it
  # without `scripts/zips.exs`.
  @states ~w(AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS
             MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI
             WY PR AS GU MP VI)

  @names %{
    "AL" => "Alabama",
    "AK" => "Alaska",
    "AZ" => "Arizona",
    "AR" => "Arkansas",
    "CA" => "California",
    "CO" => "Colorado",
    "CT" => "Connecticut",
    "DE" => "Delaware",
    "DC" => "District of Columbia",
    "FL" => "Florida",
    "GA" => "Georgia",
    "HI" => "Hawaii",
    "ID" => "Idaho",
    "IL" => "Illinois",
    "IN" => "Indiana",
    "IA" => "Iowa",
    "KS" => "Kansas",
    "KY" => "Kentucky",
    "LA" => "Louisiana",
    "ME" => "Maine",
    "MD" => "Maryland",
    "MA" => "Massachusetts",
    "MI" => "Michigan",
    "MN" => "Minnesota",
    "MS" => "Mississippi",
    "MO" => "Missouri",
    "MT" => "Montana",
    "NE" => "Nebraska",
    "NV" => "Nevada",
    "NH" => "New Hampshire",
    "NJ" => "New Jersey",
    "NM" => "New Mexico",
    "NY" => "New York",
    "NC" => "North Carolina",
    "ND" => "North Dakota",
    "OH" => "Ohio",
    "OK" => "Oklahoma",
    "OR" => "Oregon",
    "PA" => "Pennsylvania",
    "RI" => "Rhode Island",
    "SC" => "South Carolina",
    "SD" => "South Dakota",
    "TN" => "Tennessee",
    "TX" => "Texas",
    "UT" => "Utah",
    "VT" => "Vermont",
    "VA" => "Virginia",
    "WA" => "Washington",
    "WV" => "West Virginia",
    "WI" => "Wisconsin",
    "WY" => "Wyoming",
    "PR" => "Puerto Rico",
    "AS" => "American Samoa",
    "GU" => "Guam",
    "MP" => "Northern Mariana Islands",
    "VI" => "U.S. Virgin Islands"
  }

  @record 8

  @type place :: %{zip: String.t(), state: String.t(), lat: float(), lon: float()}

  @doc "The postal codes of the states, in the order of the file."
  def states, do: @states

  @doc "The name of a state, from its postal code."
  def state_name(state), do: Map.fetch!(@names, state)

  @doc """
  The place of a ZIP code of 5 digits, or `:error` for a ZIP code that is
  not in the data (for example a ZIP code of a post office box only).
  """
  @spec lookup(term()) :: {:ok, place()} | :error
  def lookup(<<_::binary-size(5)>> = zip) do
    case Integer.parse(zip) do
      {number, ""} when number >= 0 -> search(data(), number, zip)
      _ -> :error
    end
  end

  def lookup(_zip), do: :error

  defp search(data, number, zip) do
    count = div(byte_size(data), @record)
    search(data, number, zip, 0, count - 1)
  end

  defp search(_data, _number, _zip, low, high) when low > high, do: :error

  defp search(data, number, zip, low, high) do
    middle = div(low + high, 2)

    <<found::24, state::8, lat::signed-16, lon::signed-16>> =
      binary_part(data, middle * @record, @record)

    cond do
      found == number ->
        {:ok, %{zip: zip, state: Enum.at(@states, state), lat: lat / 100, lon: lon / 100}}

      found < number ->
        search(data, number, zip, middle + 1, high)

      true ->
        search(data, number, zip, low, middle - 1)
    end
  end

  # The file, read one time and kept for all the processes.
  defp data do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        data = File.read!(Application.app_dir(:diy, "priv/data/zips.bin"))
        :persistent_term.put(__MODULE__, data)
        data

      data ->
        data
    end
  end
end
