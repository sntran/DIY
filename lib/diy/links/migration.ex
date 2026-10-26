defmodule DIY.Links.Migration do
  @moduledoc """
  The table of the short links (`DIY.Links.Link`). It is a module, not a
  file of `priv/repo/migrations`: the boot runs it with no compile of an
  `.exs` file (`DIY.Links.migrate/0`). Each statement commits alone in
  the storage of a Durable Object. Thus the migration can run again
  after a boot that stopped in it: it makes only what is not there.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:links, primary_key: false) do
      add(:key, :binary, primary_key: true)
      add(:box, :binary, null: false)
      add(:used_on, :date, null: false)
    end

    create_if_not_exists(index(:links, [:used_on]))
  end
end
