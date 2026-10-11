defmodule DIYWeb.StageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Catalog
  alias DIYWeb.{Camera, Stage}
  alias DIYWeb.Icon.Shapes

  @types Enum.map(Catalog.kinds(), & &1.type)

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

    # The last camera looks at the panel: at the front, or down at the top
    # of a hub. The side and the top show a little.
    assert {List.last(Stage.cameras("fridge")).yaw, List.last(Stage.cameras("fridge")).pitch} ==
             {84.0, 10.0}

    assert {List.last(Stage.cameras("home_assistant")).yaw,
            List.last(Stage.cameras("home_assistant")).pitch} == {88.0, 58.0}
  end

  test "the face of an item: its screen, or the middle of its front" do
    assert Stage.region("tv") == {:front, {0.015, 0.137, 0.135}, {1.09, 0.57}}
    assert {:top, _corner, _size} = Stage.region("home_assistant")

    # No screen: 3/4 of the width of the front, all its height, in front of
    # the model.
    {{x0, _y0, z0}, {x1, y1, z1}} = Shapes.bounds(Shapes.model("fridge"))
    {:front, {x, y, z}, {w, h}} = Stage.region("fridge")
    assert_in_delta w, (x1 - x0) * 0.75, 1.0e-9
    assert_in_delta x - x0, (x1 - x0 - w) / 2, 1.0e-9
    assert y > y1
    assert z == z0 and h == z1 - z0
  end

  test "the tags: each is a number of its kind, on the face of the item" do
    for type <- @types, spot <- Stage.frames(type).spots do
      param = Enum.find(Catalog.kind(type).params, &(&1.key == spot.key))
      assert param.type in [:int, :float], "#{type} #{spot.key}"
      assert spot.tag != "" and spot.where != ""

      # The point is in the face: its parts along the two sides of the face
      # are from 0 to 1.
      {ax, ay, bx, by, cx, cy} = Stage.frames(type).region
      {x, y} = spot.at
      det = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
      u = ((x - ax) * (cy - ay) - (cx - ax) * (y - ay)) / det
      v = ((bx - ax) * (y - ay) - (x - ax) * (by - ay)) / det
      assert u >= -1.0e-6 and u <= 1 + 1.0e-6 and v >= -1.0e-6 and v <= 1 + 1.0e-6, type
    end

    assert Enum.map(Stage.frames("tv").spots, & &1.key) == ["hours", "watts"]
    assert Stage.frames("ac").spots == []
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
      %{view: {vx, vy, vw, vh}, frames: frames, start: {sx, sy, sw, sh}, region: region} =
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
      # The corners of the panel are on the last frame: in the view. The
      # top left goes to the right to the top right, and down to the bottom
      # left.
      {ax, ay, bx, by, cx, cy} = region

      for {x, y} <- [{ax, ay}, {bx, by}, {cx, cy}] do
        assert x >= vx - 1 and x <= vx + vw + 1 and y >= vy - 1 and y <= vy + vh + 1, type
      end

      assert bx > ax and cy > ay, type
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
