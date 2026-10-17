defmodule DIYWeb.BrowserTest do
  @moduledoc """
  The browser test: `test/browser/house.mjs` builds a house in Chromium,
  with the checks of axe-core on each screen. The weather, Power to Choose
  and the cloud of Pecron are the stubs of the tests, for all the
  processes of the server.

  It needs the server of the tests, Node.js with the packages of
  `package.json`, a Chromium (`CHROMIUM`), and the assets:

      MIX_ENV=test mix.com assets.build
      DIY_BROWSER=1 mix.com test --only browser
  """
  use ExUnit.Case, async: false

  @moduletag :browser
  # The walk takes about 15 minutes: it opens and closes many items on their
  # stage, in four sizes and colors. On a busy computer, it takes more.
  @moduletag timeout: 1_800_000

  setup do
    Req.Test.set_req_test_to_shared()
    DIY.Stubs.weather()
    DIY.Stubs.market()
    DIY.Stubs.pecron()
    on_exit(&Req.Test.set_req_test_to_private/0)
    :ok
  end

  test "a person builds a house in a browser" do
    assert DIYWeb.Endpoint.config(:server), "Start the tests with DIY_BROWSER=1."

    {output, status} =
      System.cmd("node", ["test/browser/house.mjs", DIYWeb.Endpoint.url()],
        stderr_to_stdout: true,
        env: [{"DIY_STUBS", "1"}]
      )

    assert status == 0, output
  end
end
