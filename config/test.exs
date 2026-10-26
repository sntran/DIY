import Config

# The database of the short links (DIY.Links). Each test that uses it
# checks out a connection of the sandbox (DIY.DataCase).
config :diy, DIY.Repo,
  database: Path.expand("../diy_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :diy, DIYWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "87Q+NNHggy2vn71bDKJtpe1xSijscHHNViKNM5GQ6gSIPYGA8eI/5ceRiQywcets",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The HTTP of the weather, of Power to Choose and of Pecron goes to the
# stubs of the tests (Req.Test).
config :diy, DIY.Weather, req: [plug: {Req.Test, DIY.Weather}, retry: false]
config :diy, DIY.Market, req: [plug: {Req.Test, DIY.Market}, retry: false]
config :diy, DIY.Sky, req: [plug: {Req.Test, DIY.Sky}, retry: false]
config :diy, DIY.Pecron, req: [plug: {Req.Test, DIY.Pecron}], call_wait: 2_000

# The tests keep nothing in the cache of the weather and of the markets.
# So a test gets the answer of its own stub, not a value of a different
# test.
config :diy, DIY.Cache, max: 0

# The browser tests (mix test --only browser) need a server: DIY_BROWSER=1
# starts it on the port 4002.
if System.get_env("DIY_BROWSER") do
  config :diy, DIYWeb.Endpoint, server: true
end
