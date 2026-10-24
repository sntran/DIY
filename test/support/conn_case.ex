defmodule DIYWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DIYWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DIYWeb.Endpoint

      use DIYWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import DIYWeb.ConnCase
    end
  end

  # The sky of the house is a clear day at noon (DIY.Stubs.sky/1). A test
  # can stub a different sky.
  setup _tags do
    DIY.Stubs.sky()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Waits until the page has the answers of the weather, of the sky and of
  the market: no request is open. It waits for 10 seconds at most. A
  fixed sleep fails when the computer is slow.
  """
  def settle(view, tries \\ 500) do
    assigns = :sys.get_state(view.pid).socket.assigns

    if tries > 0 and
         :loading in [assigns.weather.status, assigns.sky.status, assigns.market.status] do
      Process.sleep(20)
      settle(view, tries - 1)
    else
      Process.sleep(5)
      Phoenix.LiveViewTest.render(view)
    end
  end
end
