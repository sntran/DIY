defmodule DIY.Links.Link do
  @moduledoc """
  A row of the table `links` (`DIY.Links`):

  - `key`: a hash of the id of the link. The table does not keep the id.
  - `box`: the `DATA` of the long link, encrypted with a key that comes
    from the id.
  - `used_on`: the day of the last visit of the link (UTC).
  """
  use Ecto.Schema

  @primary_key {:key, :binary, autogenerate: false}
  schema "links" do
    field(:box, :binary)
    field(:used_on, :date)
  end
end
