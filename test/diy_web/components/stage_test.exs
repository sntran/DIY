defmodule DIYWeb.StageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Catalog
  alias DIYWeb.{Camera, Stage}
  alias DIYWeb.Icon.Shapes

  @types Enum.map(Catalog.kinds(), & &1.type)

  test "the style of a panel" do
    assert Stage.style("home_assistant") == :led
    assert Stage.style("tv") == :screen
    assert Stage.style("computer") == :screen
    assert Stage.style("fridge") == :label
    assert Stage.style("water_heater") == :label
  end

  test "the cameras go from the camera of the house to the front, or over a hub" do
    house = Camera.house()

    for type <- ["fridge", "home_assistant"] do
      cameras = Stage.cameras(type)
      assert length(cameras) == Stage.frame_count()
      first = hd(cameras)
      assert {first.yaw, first.pitch} == {house.yaw, house.pitch}
      # Each camera turns more to the front than the camera before it.
      yaws = Enum.map(cameras, & &1.yaw)
      assert yaws == Enum.sort(yaws)
    end

    # A view of three quarters: the side shows a little, and the top of a
    # hub shows more.
    assert {List.last(Stage.cameras("fridge")).yaw, List.last(Stage.cameras("fridge")).pitch} ==
             {80.0, 15.0}

    assert {List.last(Stage.cameras("home_assistant")).yaw,
            List.last(Stage.cameras("home_assistant")).pitch} == {72.0, 42.0}
  end

  # The x and y of the points of a frame.
  defp points(frame) do
    for {points, _class} <- frame,
        pair <- String.split(points),
        [x, y] = String.split(pair, ","),
        do: {number(x), number(y)}
  end

  defp number(text), do: text |> Float.parse() |> elem(0)

  test "the frames of each kind: the first is the drawing of the plan, all in the view" do
    for type <- @types do
      %{view: {vx, vy, vw, vh}, frames: frames, start: {sx, sy, sw, sh}, anchor: {ax, ay}} =
        Stage.frames(type)

      assert length(frames) == Stage.frame_count(), type
      assert Enum.all?(frames, &(&1 != [])), type

      # The first frame has the polygons of the plan, with the same colors.
      plan = Shapes.shapes(type, Camera.house())

      assert Enum.map(hd(frames), &elem(&1, 1)) ==
               Enum.map(plan, fn {:poly, _, class} -> class end)

      # The largest side is 100 units, with 2 units of margin.
      assert_in_delta max(vw, vh), 104, 1.0e-6

      for frame <- frames, {x, y} <- points(frame) do
        assert x >= vx and x <= vx + vw and y >= vy and y <= vy + vh, type
      end

      assert sx >= vx and sy >= vy and sx + sw <= vx + vw + 1.0e-6 and sy + sh <= vy + vh + 1.0e-6
      assert ax >= 0 and ax <= 100 and ay >= 0 and ay <= 100, type
    end
  end

  property "the center of the model stays at 0, 0 in each frame" do
    check all(type <- member_of(@types)) do
      %{frames: frames} = Stage.frames(type)

      for frame <- frames do
        {xs, ys} = Enum.unzip(points(frame))
        # The model is around its center: the center is in the box.
        assert Enum.min(xs) <= 0.01 and Enum.max(xs) >= -0.01
        assert Enum.min(ys) <= 0.01 and Enum.max(ys) >= -0.01
      end
    end
  end
end
