defmodule DIYWeb.Address do
  @moduledoc """
  The key of the address of a person, for the limit of the short links
  (`DIY.Links.allow/2`). The key is an HMAC of the IP address with the
  secret key base: the app does not keep the address. On Cloudflare,
  beam.com gives the connection the address of the client
  (`cf-connecting-ip`), so `conn.remote_ip` is that address.
  """

  @doc "The key of the address of the request."
  @spec key(Plug.Conn.t()) :: String.t()
  def key(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    :crypto.mac(:hmac, :sha256, DIYWeb.Endpoint.config(:secret_key_base), ip)
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  The signed session of a LiveView of the build: the language of its
  first render (`DIYWeb.Locale.live_session/1`) and the key of the
  address.
  """
  def live_session(conn), do: Map.put(DIYWeb.Locale.live_session(conn), "address", key(conn))
end
