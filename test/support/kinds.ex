defmodule DIY.Kinds do
  @moduledoc "The kinds of items for the tests."

  alias DIY.Catalog

  @doc "The kinds of items of a house: each kind with a place in a house."
  def house do
    Enum.filter(
      Catalog.kinds(),
      &Enum.any?(&1.places, fn p -> p in [:indoor, :outdoor, :roof] end)
    )
  end
end
