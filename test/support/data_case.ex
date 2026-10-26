defmodule DIY.DataCase do
  @moduledoc """
  The case of a test that uses the database of the short links
  (`DIY.Links`). Each test checks out a connection of the sandbox, so its
  rows go away at its end.
  """
  use ExUnit.CaseTemplate

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(DIY.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
