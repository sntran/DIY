defmodule DIYWeb.BrowserTest do
  @moduledoc """
  The browser test: `test/browser/house.mjs` builds a house in Chromium,
  with the checks of axe-core on each screen. The weather and Power to
  Choose are the stubs of the tests, for all the processes of the server.

  It needs the server of the tests, Node.js with the packages of
  `package.json`, a Chromium (`CHROMIUM`), and the assets:

      MIX_ENV=test mix.com assets.build
      DIY_BROWSER=1 mix.com test --only browser
  """
  use ExUnit.Case, async: false

  @moduletag :browser
  @moduletag timeout: 600_000

  setup do
    Req.Test.set_req_test_to_shared()
    DIY.Stubs.weather()
    DIY.Stubs.market()
    on_exit(&Req.Test.set_req_test_to_private/0)
    :ok
  end

  test "a person builds a house in a browser" do
    assert DIYWeb.Endpoint.config(:server), "Start the tests with DIY_BROWSER=1."

    {output, status} =
      System.cmd("node", ["test/browser/house.mjs", DIYWeb.Endpoint.url()],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
