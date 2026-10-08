defmodule DIY.ZipTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Zip

  test "a ZIP code gives its state and its center" do
    assert {:ok, %{zip: "75070", state: "TX", lat: lat, lon: lon}} = Zip.lookup("75070")
    assert_in_delta lat, 33.15, 0.01
    assert_in_delta lon, -96.7, 0.01
    assert {:ok, %{state: "NY"}} = Zip.lookup("10001")
    assert {:ok, %{state: "PR"}} = Zip.lookup("00601")
  end

  test "a ZIP code that is not in the data, or is not 5 digits, is an error" do
    for zip <- ["00000", "99999", "7507", "750700", "7507a", "-7507", "+7507", nil, 75070] do
      assert Zip.lookup(zip) == :error, inspect(zip)
    end
  end

  test "each state has a name" do
    for state <- Zip.states(), do: assert(is_binary(Zip.state_name(state)))
    assert Zip.state_name("TX") == "Texas"
  end

  test "the records of the file are in order, and each one has a known state" do
    data = File.read!(Application.app_dir(:diy, "priv/data/zips.bin"))
    assert rem(byte_size(data), 8) == 0
    zips = for <<zip::24, state::8, _lat::16, _lon::16 <- data>>, do: {zip, state}
    assert zips == Enum.sort(zips)
    assert Enum.all?(zips, fn {_zip, state} -> state < length(Zip.states()) end)
    assert length(zips) > 33_000
  end

  property "each ZIP code of the file is found, with a place in the US" do
    data = File.read!(Application.app_dir(:diy, "priv/data/zips.bin"))
    count = div(byte_size(data), 8)

    check all(index <- integer(0..(count - 1))) do
      <<zip::24, _rest::binary>> = binary_part(data, index * 8, 8)
      code = zip |> Integer.to_string() |> String.pad_leading(5, "0")
      assert {:ok, %{zip: ^code, lat: lat, lon: lon}} = Zip.lookup(code)
      assert lat > -20 and lat < 72
      assert lon > -180 and lon < 180
    end
  end

  property "lookup never raises" do
    check all(text <- one_of([string(:printable, max_length: 7), string(?0..?9, length: 5)])) do
      assert Zip.lookup(text) == :error or match?({:ok, %{}}, Zip.lookup(text))
    end
  end
end
