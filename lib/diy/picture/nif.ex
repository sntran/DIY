defmodule DIY.Picture.NIF do
  @moduledoc """
  The NIF of `DIY.Picture`: resvg 0.48.1 in WebAssembly, `priv/resvg.wasm`
  (`native/resvg`, `scripts/nif.sh`). beam.com loads it (docs/NIFS.md of
  BEAM.com).

  `mix test --cover` does not count this module: the NIF replaces its
  function, thus the line of the function never runs.
  """

  @on_load :load

  @doc false
  def load do
    :diy
    |> :code.priv_dir()
    |> Path.join("resvg")
    |> String.to_charlist()
    |> :erlang.load_nif(0)
  end

  @doc "Draws an SVG to a PNG of the width. Gives `{:ok, png}` or `{:error, message}`."
  @spec render(binary(), pos_integer()) :: {:ok, binary()} | {:error, String.t()}
  def render(_svg, _width), do: :erlang.nif_error(:not_loaded)
end
