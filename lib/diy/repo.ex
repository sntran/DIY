defmodule DIY.Repo do
  @moduledoc """
  The database of the app: only the short links of shared houses
  (`DIY.Links`). It is SQLite. On Cloudflare, beam.com sends each
  statement to the SQLite storage of the Durable Object of the VM. That
  storage does not let SQL control a transaction: each statement commits
  alone (docs/WORKERS.md of BEAM.com).
  """
  use Ecto.Repo, otp_app: :diy, adapter: Ecto.Adapters.SQLite3
end
