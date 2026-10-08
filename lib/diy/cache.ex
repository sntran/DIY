defmodule DIY.Cache do
  @moduledoc """
  A cache in the memory of the VM for the data of the public services: the
  weather of a place (`DIY.Weather`) and the utility area of a ZIP code
  (`DIY.Market`). The data has no person in it. The cache goes away when
  the VM stops, and that is not a problem: the next request gets the data
  again.

  The cache keeps at most 1,000 values (the memory of a Durable Object is
  small). When it is full, it starts again with no values.
  """
  use GenServer

  @max 1_000

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
  """
  def fetch(key, fun) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, value}] ->
        {:ok, value}

      [] ->
        with {:ok, value} <- fun.() do
          if :ets.info(__MODULE__, :size) >= max(), do: :ets.delete_all_objects(__MODULE__)
          :ets.insert(__MODULE__, {key, value})
          {:ok, value}
        end
    end
  end

  defp max, do: Application.get_env(:diy, __MODULE__, [])[:max] || @max
end
