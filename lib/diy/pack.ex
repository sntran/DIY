defmodule DIY.Pack do
  @moduledoc """
  The `DATA` of a link (`DIY.Share` and `DIY.PlanLink`): a JSON text,
  compressed with raw DEFLATE, in base64url with no padding.
  """

  @doc "The `DATA` of a JSON text."
  @spec encode(String.t()) :: String.t()
  def encode(json), do: Base.url_encode64(deflate(json), padding: false)

  @doc """
  The JSON text of a `DATA`. The inflate stops at `max` bytes: a small
  link cannot become a large text. It gives `{:error, :base64}`,
  `{:error, :inflate}` or `{:error, :too_large}` for a `DATA` that is not
  a link.
  """
  @spec decode(String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, :base64 | :inflate | :too_large}
  def decode(data, max) do
    case Base.url_decode64(data, padding: false) do
      {:ok, bytes} -> inflate(bytes, max)
      :error -> {:error, :base64}
    end
  end

  defp deflate(data) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 9, :deflated, -15, 9, :default)
    out = :zlib.deflate(z, data, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(out)
  end

  defp inflate(bytes, max) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, -15)

    try do
      z |> :zlib.safeInflate(bytes) |> collect(z, [], 0, max)
    rescue
      ErlangError -> {:error, :inflate}
    after
      :zlib.close(z)
    end
  end

  defp collect(_result, _z, _acc, size, max) when size > max, do: {:error, :too_large}

  # A stream that ends before its end gives no output and asks for more
  # input: it is not a link.
  defp collect({:continue, out}, z, acc, size, max) do
    case IO.iodata_length(out) do
      0 -> {:error, :inflate}
      n -> z |> :zlib.safeInflate([]) |> collect(z, [acc | out], size + n, max)
    end
  end

  defp collect({:finished, out}, _z, acc, size, max) do
    if size + IO.iodata_length(out) > max,
      do: {:error, :too_large},
      else: {:ok, IO.iodata_to_binary([acc | out])}
  end
end
