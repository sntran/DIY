defmodule DIY.CacheTest do
  # Not async: the test fills the cache of all the tests.
  use ExUnit.Case, async: false

  alias DIY.Cache

  setup do
    Application.put_env(:diy, Cache, max: 2)
    on_exit(fn -> Application.delete_env(:diy, Cache) end)
  end

  test "a full cache starts again with no values" do
    assert Cache.fetch({__MODULE__, 1}, fn -> {:ok, 1} end) == {:ok, 1}
    assert Cache.fetch({__MODULE__, 1}, fn -> {:ok, :new} end) == {:ok, 1}
    assert Cache.fetch({__MODULE__, 2}, fn -> {:ok, 2} end) == {:ok, 2}
    assert Cache.fetch({__MODULE__, 3}, fn -> {:ok, 3} end) == {:ok, 3}
    assert Cache.fetch({__MODULE__, 1}, fn -> {:ok, :new} end) == {:ok, :new}
    assert Cache.fetch({__MODULE__, 4}, fn -> {:error, "no"} end) == {:error, "no"}
  end
end
