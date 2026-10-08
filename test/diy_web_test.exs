defmodule DIYWebTest do
  use ExUnit.Case, async: true

  # Each kind of DIYWeb runs at compile time. These modules use each kind
  # at the time of the tests, so that the coverage sees them.
  test "each kind of module compiles" do
    for {kind, name} <- [
          router: DIYWebTest.Router,
          live_view: DIYWebTest.Live,
          html: DIYWebTest.HTML,
          verified_routes: DIYWebTest.Routes
        ] do
      Code.compile_quoted(
        quote do
          defmodule unquote(name) do
            use DIYWeb, unquote(kind)
          end
        end
      )

      assert Code.ensure_loaded?(name)
    end
  end
end
