defmodule DIYWeb.Address do
  @moduledoc """
  The key of the address of a person, for the limit of the short links
  (`DIY.Links.allow/2`). A LiveView reads the address of its WebSocket
  (`peer_data`). On Cloudflare, beam.com gives the connection the address
  of the client (`cf-connecting-ip`).

  - An IPv6 address counts as its network of 64 bits. A person usually
    has a full /64, and can change the other 64 bits.
  - An IPv4 address in IPv6 (`::ffff:a.b.c.d`) counts as the IPv4
    address.
  - The key is an HMAC of the address. Its key comes from the secret key
    base. The app does not keep the address, and the key is only in the
    memory of the VM.
  """
  import Bitwise

  @doc "The key of an IP address."
  @spec key(:inet.ip_address()) :: String.t()
  def key({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: key({hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255})

  def key({a, b, c, d, _e, _f, _g, _h}), do: hash("#{:inet.ntoa({a, b, c, d, 0, 0, 0, 0})}/64")

  def key(ip), do: hash(to_string(:inet.ntoa(ip)))

  defp hash(text) do
    secret = :crypto.mac(:hmac, :sha256, DIYWeb.Endpoint.config(:secret_key_base), "diy address")

    :crypto.mac(:hmac, :sha256, secret, text)
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
