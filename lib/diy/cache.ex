defmodule DIY.Cache do
  @moduledoc """
  A cache in the memory of the VM for the data of the public services. It
  keeps the weather of a place (`DIY.Weather`) and the sky of now at a
  place (`DIY.Sky`, for 30 minutes). It also keeps the utility area of a
  ZIP code (`DIY.Market`). The data has no person in it. The cache goes away when
  the VM stops, and that is not a problem: the next request gets the data
  again.

  The cache keeps at most 200 values. The weather of one place is near 28
  KB, and the memory of a Durable Object is 128 MB. When it is full, it
  starts again with no values. With a maximum of 0 (the tests), it keeps
  nothing.
  """
  use GenServer

  @max 200

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  The value of a key, or the value of `fun` when the cache does not have
  it. Only `{:ok, value}` goes into the cache: an error does not stay.
  With `max_age` (in milliseconds), an older value is not good. Then the
  cache asks `fun` again, and keeps the new value under the same key.
  """
  def fetch(key, fun, opts \\ []) do
    if max() == 0, do: fun.(), else: cached(key, fun, Keyword.get(opts, :max_age))
  end

  defp cached(key, fun, max_age) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, key) do
      [{^key, value, at}] when max_age == nil or now - at < max_age ->
        {:ok, value}

      found ->
        with {:ok, value} <- fun.() do
          if found == [] and :ets.info(__MODULE__, :size) >= max(),
            do: :ets.delete_all_objects(__MODULE__)

          :ets.insert(__MODULE__, {key, value, now})
          {:ok, value}
        end
    end
  end

  defp max, do: Application.get_env(:diy, __MODULE__, [])[:max] || @max
end
