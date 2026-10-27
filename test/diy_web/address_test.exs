defmodule DIYWeb.AddressTest do
  use ExUnit.Case, async: true

  alias DIYWeb.Address

  test "the key of an IPv4 address: the same for one address, and different for two" do
    a = Address.key({203, 0, 113, 7})
    assert a == Address.key({203, 0, 113, 7})
    refute a == Address.key({203, 0, 113, 8})
    # 16 bytes of the HMAC, in base64url.
    assert byte_size(a) == 22
  end

  test "an IPv6 address counts as its /64, and IPv4 in IPv6 counts as the IPv4 address" do
    one = Address.key({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1})
    assert one == Address.key({0x2001, 0xDB8, 1, 2, 0xFFFF, 0xABCD, 7, 9})
    refute one == Address.key({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1})

    assert Address.key({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}) == Address.key({203, 0, 113, 7})
    refute Address.key({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7108}) == Address.key({203, 0, 113, 7})
  end
end
