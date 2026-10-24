defmodule DIYWeb.Picture.Labels do
  @moduledoc """
  The places of the labels in the picture of a shared house
  (`DIYWeb.Picture`, docs/design.md, "The preview of a link"). A label is
  a box above the top of its item, with a line down to the item.

  The labels come in their order: the first label has the best place.
  Each label goes to the nearest free place above its item, in the box of
  the picture. A place is just above the item, or just above a label that
  is already in its place. At each height, the label is at the center of
  the item, or at its left, or at its right. The nearest place is the
  place with the smallest move up, plus half of its move to the side.
  When no place is free, the picture has no label for that item. So two
  labels never overlap, and each label is in the box
  (`specs/Labels.tla`).
  """

  # The space between a label and its item, and between two labels. Then
  # the part of a label at the side of an item that is over the item.
  @gap 4
  @side 14

  @type label :: %{
          required(:x) => number(),
          required(:y) => number(),
          required(:w) => number(),
          required(:h) => number(),
          optional(atom()) => term()
        }

  @doc """
  The places of the labels in a box `{x, y, w, h}`. A label has the top
  center of its item (`x`, `y`), and its size (`w`, `h`). Each label that
  has a place gets its top left corner (`left`, `top`). A label that is
  wider or higher than the box has no place.
  """
  @spec place([label()], {number(), number(), number(), number()}) :: [label()]
  def place(labels, {bx, by, bw, bh}) do
    labels
    |> Enum.reduce([], fn label, placed ->
      inside = fn left -> left |> min(bx + bw - label.w) |> max(bx) end
      center = inside.(label.x - label.w / 2)
      start = (label.y - label.h - @gap) |> min(by + bh - label.h) |> max(by)
      tops = [start | Enum.map(placed, &(&1.top - label.h - @gap))]
      # The label at the center, at the left (its right end over the
      # item), and at the right (its left end over the item).
      sides = Enum.map([center, label.x - label.w + @side, label.x - @side], inside)

      place =
        for(
          top <- tops,
          top >= by and top <= start,
          left <- sides,
          box = %{left: left, top: top, w: label.w, h: label.h},
          free?(box, placed),
          do: box
        )
        |> Enum.min_by(&(start - &1.top + abs(&1.left - center) / 2), fn -> nil end)

      if place && label.w <= bw && label.h <= bh,
        do: [Map.merge(label, Map.take(place, [:left, :top])) | placed],
        else: placed
    end)
    |> Enum.reverse()
  end

  @doc "True when two placed labels overlap."
  def overlap?(a, b),
    do:
      a.left < b.left + b.w and b.left < a.left + a.w and a.top < b.top + b.h and
        b.top < a.top + a.h

  defp free?(box, placed), do: not Enum.any?(placed, &overlap?(box, &1))
end
