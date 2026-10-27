defmodule DIY.Links.Guard do
  @moduledoc """
  The state of the short links in the memory of the VM (`DIY.Links`). One
  VM serves all the requests, so one table is enough:

  - The state of the table of the links: ready, or not ready since a
    time. At the start, it runs the migration of the table.
  - The count of the new links of today: for all the persons, and for
    each address. The key of an address is a hash (`DIYWeb.Address`),
    not the address.

  The state goes away when the VM stops. Then the counts start again, and
  the start runs the migration again.
  """
  use GenServer

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public])
    DIY.Links.boot()
    {:ok, nil}
  end
end
