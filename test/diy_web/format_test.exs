defmodule DIYWeb.FormatTest do
  use ExUnit.Case, async: true

  alias DIYWeb.Format

  test "a price with cents, and therms of gas" do
    assert Format.dollars(19.42 / 10.37) == "$1.87"
    assert Format.dollars(2) == "$2.00"
    assert Format.therms(1.2) == "1 therm"
    assert Format.therms(0.3) == "0 therms"
    assert Format.therms(1_234.6) == "1,235 therms"
  end
end
