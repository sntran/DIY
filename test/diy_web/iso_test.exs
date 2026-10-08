defmodule DIYWeb.IsoTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIYWeb.Iso

  defp number, do: float(min: -50.0, max: 50.0)
  defp point, do: tuple({number(), number(), number()})

  property "a step of the same size on x, y and z goes to the same point (the eye looks along it)" do
    check all(p <- point(), t <- number()) do
      {x1, y1} = Iso.at({0, 0}, p)
      {x2, y2} = Iso.at({0, 0}, Iso.add(p, {t, t, t}))
      assert_in_delta x1, x2, 1.0e-9
      assert_in_delta y1, y2, 1.0e-9
    end
  end

  property "the points of the world go to the SVG with a sum (a linear map)" do
    check all(a <- point(), b <- point(), {ox, oy} <- tuple({number(), number()})) do
      {ax, ay} = Iso.at({0, 0}, a)
      {bx, by} = Iso.at({0, 0}, b)
      {sx, sy} = Iso.at({ox, oy}, Iso.add(a, b))
      assert_in_delta sx, ax + bx + ox, 1.0e-6
      assert_in_delta sy, ay + by + oy, 1.0e-6
    end
  end

  test "up is up, and x and y go to the two sides" do
    assert Iso.at({0, 0}, {0, 0, 1}) == {0.0, -10.0}
    assert Iso.at({0, 0}, {1, 0, 0}) == {8.66, 5.0}
    assert Iso.at({0, 0}, {0, 1, 0}) == {-8.66, 5.0}
  end

  test "the three faces of a box that show" do
    box = Iso.box({1, 2, 3}, {4, 5, 6})
    assert {1, 2, 9} in box.top and {5, 7, 9} in box.top
    assert Enum.all?(box.left, fn {_x, y, _z} -> y == 7 end)
    assert Enum.all?(box.right, fn {x, _y, _z} -> x == 5 end)
  end

  property "a rectangle and a circle stay on their plane" do
    check all(a <- point(), s <- number(), t <- number(), r <- float(min: 0.1, max: 9.0)) do
      for {_x, _y, z} <- Iso.on_plane(a, {1, 0, 0}, {0, 1, 0}, {s, t}, {1.0, 2.0}),
          do: assert_in_delta(z, elem(a, 2), 1.0e-9)

      for p <- Iso.circle(a, {1, 0, 0}, {0, 0, 1}, r) do
        {dx, dy, dz} = Iso.add(p, Iso.scale(a, -1))
        assert_in_delta dy, 0, 1.0e-9
        assert_in_delta :math.sqrt(dx * dx + dz * dz), r, 1.0e-6
      end
    end
  end

  test "the numbers of the SVG have one decimal" do
    assert Iso.round1(2.0) == "2"
    assert Iso.round1(2.25) == "2.3"
    assert Iso.round1(-0.04) == "0"
    assert Iso.points({0, 0}, [{0, 0, 0}, {1, 0, 0}]) == "0,0 8.7,5"
  end
end
