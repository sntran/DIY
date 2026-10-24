defmodule DIYWeb.Picture.LabelsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIYWeb.Picture.Labels

  @box {38, 38, 656, 554}

  # A label at a random item in the box, or near it.
  defp label do
    gen all(
          x <- integer(0..740),
          y <- integer(0..640),
          w <- integer(40..240),
          h <- integer(20..50)
        ) do
      %{x: x / 1, y: y / 1, w: w / 1, h: h / 1}
    end
  end

  property "two labels never overlap, and each label is in the box" do
    check all(labels <- list_of(label(), max_length: 12)) do
      placed = Labels.place(labels, @box)
      {bx, by, bw, bh} = @box

      for {a, i} <- Enum.with_index(placed), {b, j} <- Enum.with_index(placed), i < j do
        refute Labels.overlap?(a, b), "#{inspect(a)} and #{inspect(b)} overlap"
      end

      for l <- placed do
        assert l.left >= bx and l.left + l.w <= bx + bw
        assert l.top >= by and l.top + l.h <= by + bh
      end
    end
  end

  property "the labels keep their order, and the first label always has a place" do
    check all(labels <- list_of(label(), min_length: 1, max_length: 12)) do
      placed = Labels.place(labels, @box)
      # Each placed label is a label of the list, in the order of the list.
      plain = Enum.map(placed, &Map.drop(&1, [:left, :top]))
      assert subsequence?(plain, labels)
      assert hd(plain) == hd(labels)
    end
  end

  property "a label is above its item, or at the top of the box" do
    check all(labels <- list_of(label(), max_length: 12)) do
      {_bx, by, _bw, bh} = @box

      for l <- Labels.place(labels, @box) do
        start = (l.y - l.h - 4) |> min(by + bh - l.h) |> max(by)
        assert l.top <= start
      end
    end
  end

  test "a label goes up over a label that is in its place, or to the side" do
    a = %{x: 300.0, y: 300.0, w: 100.0, h: 30.0}
    assert [%{left: 250.0, top: 266.0}] = Labels.place([a], @box)

    # The same item: the places at the sides overlap the first label too.
    # The second label goes up over the first label.
    [_a, b] = Labels.place([a, a], @box)
    assert {b.left, b.top} == {250.0, 232.0}

    # An item near the first item: the place at its right is free, and it
    # is nearer than the place up. The move is 36 to the side (18), not 34
    # up.
    [_a, c] = Labels.place([a, %{a | x: 380.0}], @box)
    assert {c.left, c.top} == {366.0, 266.0}

    # A label at the right end of the box stays in the box.
    [d] = Labels.place([%{a | x: 690.0}], @box)
    assert d.left == 594.0
  end

  test "a label that does not fit in the box has no place" do
    wide = %{x: 300.0, y: 300.0, w: 700.0, h: 30.0}
    assert Labels.place([wide], @box) == []
    high = %{wide | w: 100.0, h: 600.0}
    assert Labels.place([high], @box) == []
  end

  test "with no free place, a label has no place" do
    # Labels as wide as the box, and as high as half of it: only two fit,
    # one over the other.
    {_bx, _by, bw, bh} = @box
    big = %{x: 360.0, y: 600.0, w: bw / 1, h: (bh - 4) / 2}
    assert length(Labels.place([big, big, big], @box)) == 2
  end

  defp subsequence?([], _list), do: true
  defp subsequence?(_sub, []), do: false
  defp subsequence?([x | sub], [x | rest]), do: subsequence?(sub, rest)
  defp subsequence?(sub, [_ | rest]), do: subsequence?(sub, rest)
end
