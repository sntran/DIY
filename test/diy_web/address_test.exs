defmodule DIYWeb.AddressTest do
  use DIYWeb.ConnCase, async: true

  alias DIYWeb.Address

  test "the key of an address: the same for one address, and different for two", %{conn: conn} do
    a = %{conn | remote_ip: {203, 0, 113, 7}}
    b = %{conn | remote_ip: {203, 0, 113, 8}}
    v6 = %{conn | remote_ip: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}}

    assert Address.key(a) == Address.key(%{conn | remote_ip: {203, 0, 113, 7}})
    assert length(Enum.uniq([Address.key(a), Address.key(b), Address.key(v6)])) == 3
    # 16 bytes of the HMAC, in base64url.
    assert byte_size(Address.key(a)) == 22
  end

  test "the session of a LiveView of the build has the language and the key", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert Address.live_session(conn) == %{"locale" => "en", "address" => Address.key(conn)}
  end
end
