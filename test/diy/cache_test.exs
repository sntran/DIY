defmodule DIY.CacheTest do
  # Not async: the test turns on the cache, and all the tests share it.
  use ExUnit.Case, async: false

  alias DIY.{Cache, Market, Stubs, Weather}

  # Each test starts with no values, and puts the maximum back at the end.
  setup do
    before = Application.get_env(:diy, Cache)
    Application.put_env(:diy, Cache, max: 2)
    :ets.delete_all_objects(Cache)

    on_exit(fn ->
      :ets.delete_all_objects(Cache)
      Application.put_env(:diy, Cache, before)
    end)
  end

  test "a full cache starts again with no values" do
    assert Cache.fetch({__MODULE__, 1}, fn -> {:ok, 1} end) == {:ok, 1}
    assert Cache.fetch({__MODULE__, 1}, fn -> {:ok, :new} end) == {:ok, 1}
    assert Cache.fetch({__MODULE__, 2}, fn -> {:ok, 2} end) == {:ok, 2}
    assert Cache.fetch({__MODULE__, 3}, fn -> {:ok, 3} end) == {:ok, 3}
    assert Cache.fetch({__MODULE__, 1}, fn -> {:ok, :new} end) == {:ok, :new}
    assert Cache.fetch({__MODULE__, 4}, fn -> {:error, "no"} end) == {:error, "no"}
  end

  test "the cache answers the second time for the weather and for a market" do
    Stubs.weather()
    assert {:ok, climate} = Weather.climate(11.0, -11.0, ~D[2026-10-08])
    Stubs.weather(500)
    assert Weather.climate(11.0, -11.0, ~D[2026-10-08]) == {:ok, climate}

    Stubs.market()
    assert {:ok, market} = Market.fetch("75023", ~D[2026-10-08])
    Stubs.market(500)
    assert Market.fetch("75023", ~D[2026-10-08]) == {:ok, market}
  end

  test "a value older than its maximum age comes again, under the same key" do
    assert Cache.fetch({__MODULE__, 6}, fn -> {:ok, 1} end, max_age: 50) == {:ok, 1}
    assert Cache.fetch({__MODULE__, 6}, fn -> {:ok, 2} end, max_age: 50) == {:ok, 1}
    Process.sleep(60)
    assert Cache.fetch({__MODULE__, 6}, fn -> {:error, "no"} end, max_age: 50) == {:error, "no"}
    assert Cache.fetch({__MODULE__, 6}, fn -> {:ok, 3} end, max_age: 50) == {:ok, 3}
    assert :ets.info(Cache, :size) == 1

    # A full cache does not start again for a new value of the same key.
    assert Cache.fetch({__MODULE__, 7}, fn -> {:ok, 7} end) == {:ok, 7}
    Process.sleep(60)
    assert Cache.fetch({__MODULE__, 6}, fn -> {:ok, 4} end, max_age: 50) == {:ok, 4}
    assert Cache.fetch({__MODULE__, 7}, fn -> {:ok, :new} end) == {:ok, 7}
  end

  test "the cache keeps the sky of a point for 30 minutes" do
    at = DateTime.utc_now()
    Stubs.sky()
    assert {:ok, sky} = DIY.Sky.now(11.0, -11.0, at)
    Stubs.sky(500)
    # The same point of the grid of 0.25°.
    assert {:ok, ^sky} = DIY.Sky.now(11.1, -11.1, at)
  end

  test "with a maximum of 0, the cache keeps nothing" do
    Application.put_env(:diy, Cache, max: 0)
    assert Cache.fetch({__MODULE__, 5}, fn -> {:ok, 5} end) == {:ok, 5}
    assert Cache.fetch({__MODULE__, 5}, fn -> {:ok, :new} end) == {:ok, :new}
    assert :ets.lookup(Cache, {__MODULE__, 5}) == []
  end
end
