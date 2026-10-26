# The browser test needs a server and a browser: mix test --only browser.
ExUnit.start(exclude: [:browser])
Ecto.Adapters.SQL.Sandbox.mode(DIY.Repo, :manual)
