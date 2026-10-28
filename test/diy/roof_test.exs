defmodule DIY.RoofTest do
  @moduledoc "The shape of a roof (`DIY.Roof`): its slope, its pitch and its base."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Roof

  # A roof of 240 by 120 inches at x = 100, y = 50.
  defp roof(slope, pitch \\ 6),
    do: %{plan: %{x: 100, y: 50, w: 240, d: 120}, roof: %{slope: slope, pitch: pitch, base: nil}}

  test "a roof with no shape has the first shape" do
    assert Roof.shape(%{plan: %{x: 0, y: 0, w: 10, d: 10}}) == %{slope: "x", pitch: 5, base: nil}
    assert Roof.shape(roof("left", 9)) == %{slope: "left", pitch: 9, base: nil}
    assert Roof.slopes() == ~w(x y front back left right)
  end

  test "the shape from a file or a form: a slope, a pitch from 1 to 12, and a floor" do
    assert Roof.read(%{"slope" => "y", "pitch" => 7}, 2) ==
             {:ok, %{slope: "y", pitch: 7, base: nil}}

    assert Roof.read(%{"slope" => "front", "pitch" => 12, "base" => "f2"}, 2) ==
             {:ok, %{slope: "front", pitch: 12, base: "f2"}}

    assert Roof.read(%{"slope" => "x", "pitch" => 1, "base" => nil}, 1) ==
             {:ok, %{slope: "x", pitch: 1, base: nil}}

    for bad <- [
          %{"slope" => "up", "pitch" => 5},
          %{"slope" => "x", "pitch" => 0},
          %{"slope" => "x", "pitch" => 13},
          %{"slope" => "x", "pitch" => "5"},
          %{"slope" => "x", "pitch" => 5, "base" => "f3"},
          %{"slope" => "x", "pitch" => 5, "base" => "roof"},
          %{"slope" => "x", "pitch" => 5, "base" => 2},
          %{"pitch" => 5},
          nil
        ],
        do: assert(Roof.read(bad, 2) == :error, inspect(bad))
  end

  test "the rise and the height of each shape, with the ridge" do
    # 6 in 12: half an inch of rise for each inch of run.
    assert Roof.rise(roof("x")) == 30.0
    assert Roof.rise(roof("y")) == 60.0
    assert Roof.rise(roof("front")) == 60.0
    assert Roof.rise(roof("back")) == 60.0
    assert Roof.rise(roof("left")) == 120.0
    assert Roof.rise(roof("right")) == 120.0

    # Two slopes: 0 at the eaves, the rise at the ridge.
    assert Roof.height(roof("x"), {150, 50}) == 0.0
    assert Roof.height(roof("x"), {150, 110}) == 30.0
    assert Roof.height(roof("x"), {150, 170}) == 0.0
    assert Roof.ridge(roof("x")) == {:y, 110.0}
    assert Roof.height(roof("y"), {220, 60}) == 60.0
    assert Roof.ridge(roof("y")) == {:x, 220.0}

    # One slope: 0 at its low side. Past the walls, the slope goes on.
    assert Roof.height(roof("front"), {150, 170}) == 0.0
    assert Roof.height(roof("front"), {150, 50}) == 60.0
    assert Roof.height(roof("front"), {150, 180}) == -5.0
    assert Roof.height(roof("back"), {150, 50}) == 0.0
    assert Roof.height(roof("left"), {100, 60}) == 0.0
    assert Roof.height(roof("left"), {340, 60}) == 120.0
    assert Roof.height(roof("right"), {340, 60}) == 0.0
    assert Roof.ridge(roof("front")) == nil
  end

  test "the planes of each shape, and the side that each looks to" do
    box = %{x: 100, y: 50, w: 240, d: 120}

    assert Roof.planes(roof("x"), box) == [
             {[{100, 50}, {340, 50}, {340, 110.0}, {100, 110.0}], :back},
             {[{100, 110.0}, {340, 110.0}, {340, 170}, {100, 170}], :front}
           ]

    assert Roof.planes(roof("y"), box) == [
             {[{100, 50}, {220.0, 50}, {220.0, 170}, {100, 170}], :left},
             {[{220.0, 50}, {340, 50}, {340, 170}, {220.0, 170}], :right}
           ]

    for side <- ~w(front back left right) do
      assert [{[{100, 50}, {340, 50}, {340, 170}, {100, 170}], looks}] =
               Roof.planes(roof(side), box)

      assert looks == String.to_atom(side)
    end
  end

  test "the plane at a point, and its normal" do
    assert Roof.side(roof("x"), {150, 60}) == :back
    assert Roof.side(roof("x"), {150, 110}) == :front
    assert Roof.side(roof("y"), {150, 60}) == :left
    assert Roof.side(roof("y"), {300, 60}) == :right
    assert Roof.side(roof("left"), {300, 60}) == :left

    # 6 in 12: the plane goes up half an inch for each inch to its high side.
    assert Roof.normal(roof("x"), :front) == {0.0, 0.5, 1.0}
    assert Roof.normal(roof("x"), :back) == {0.0, -0.5, 1.0}
    assert Roof.normal(roof("y"), :left) == {-0.5, 0.0, 1.0}
    assert Roof.normal(roof("y"), :right) == {0.5, 0.0, 1.0}
  end

  test "the top of a wall under a roof, at each side" do
    box = %{x: 100, y: 50, w: 240, d: 120}

    # The gable end at the right of two slopes along x has the ridge.
    assert Roof.profile(roof("x"), :right, box) == [
             {{340, 50}, 0.0},
             {{340, 110.0}, 30.0},
             {{340, 170}, 0.0}
           ]

    # Two slopes along y: the gable at the front.
    assert Roof.profile(roof("y"), :front, box) == [
             {{100, 170}, 0.0},
             {{220.0, 170}, 60.0},
             {{340, 170}, 0.0}
           ]

    # The eaves are on the front: no height there.
    assert Roof.profile(roof("y"), :right, box) == [{{340, 50}, 0.0}, {{340, 170}, 0.0}]
    # One slope with its low side at the front: the right wall rises to the back.
    assert Roof.profile(roof("front"), :right, box) == [{{340, 50}, 60.0}, {{340, 170}, 0.0}]
    assert Roof.profile(roof("front"), :back, box) == [{{100, 50}, 60.0}, {{340, 50}, 60.0}]
    assert Roof.profile(roof("right"), :left, box) == [{{100, 50}, 120.0}, {{100, 170}, 120.0}]

    # Past the walls (a larger box), the eaves go lower: the wall has no
    # height there.
    wide = %{x: 90, y: 40, w: 260, d: 140}

    assert [{{350, 40}, 0}, {{350, 110.0}, 30.0}, {{350, 180}, 0}] =
             Roof.profile(roof("x"), :right, wide)
  end

  property "each plane has the height of the roof at its corners, and the profile is on the planes" do
    check all(
            slope <- member_of(Roof.slopes()),
            pitch <- integer(1..12),
            w <- integer(24..1200),
            d <- integer(24..1200)
          ) do
      room = %{plan: %{x: 0, y: 0, w: w, d: d}, roof: %{slope: slope, pitch: pitch, base: nil}}

      # The roof is 0 at the eaves (a corner of the plan with no gable), and
      # the rise at its top.
      heights =
        for {corners, _side} <- Roof.planes(room, room.plan),
            point <- corners,
            do: Roof.height(room, point)

      assert_in_delta Enum.max(heights), Roof.rise(room), 1.0e-6
      assert_in_delta Enum.min(heights), 0, 1.0e-6

      # The normal of each plane is at a right angle to it, and goes up the
      # slope: each plane goes down to the side that it looks to.
      for {corners, side} <- Roof.planes(room, room.plan),
          {x, y} = a <- corners,
          {u, v} = b <- corners do
        {nx, ny, 1.0} = Roof.normal(room, side)

        assert_in_delta Roof.height(room, b) - Roof.height(room, a),
                        -(nx * (u - x) + ny * (v - y)),
                        1.0e-6

        assert Roof.side(room, {(x + u) / 2, (y + v) / 2}) in [side, :front, :right]
      end

      for side <- [:front, :back, :left, :right],
          {point, h} <- Roof.profile(room, side, room.plan),
          do: assert_in_delta(h, max(Roof.height(room, point), 0), 1.0e-9)
    end
  end
end
