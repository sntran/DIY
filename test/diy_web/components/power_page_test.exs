defmodule DIYWeb.PowerPageTest do
  use ExUnit.Case, async: true

  alias DIYWeb.PowerPage

  defp part(type, fields),
    do: Map.merge(%{items: [%{type: type, params: %{}}], price: 1000, savings: 100.0}, fields)

  test "the line of an item of the planned equipment: its payback in its own life" do
    assert PowerPage.part_text(part("solar_panels", %{payback: 10.0, life: 25})) ==
             "Solar panels ($1,000): it adds $100 of savings in one year. It pays back in 10.0 years, in a life of near 25 years."

    assert PowerPage.part_text(part("power_station", %{payback: 10.0, life: 8})) =~
             "It pays back in 10.0 years: after a life of near 8 years."

    # A part of two items.
    two = %{
      part("power_station", %{payback: 20.0, life: 8})
      | items: [%{type: "power_station", params: %{}}, %{type: "solar_panels", params: %{}}]
    }

    assert PowerPage.part_text(two) ==
             "Power station and solar panels ($1,000): they add $100 of savings in one year. They pay back in 20.0 years: after a life of near 8 years."

    assert PowerPage.part_text(%{two | payback: nil}) =~
             "they add no savings. On savings alone, they do not pay back. The reason is the backup in an outage."

    # Panels with no savings: no reason.
    assert PowerPage.part_text(part("solar_panels", %{payback: nil, life: 25})) ==
             "Solar panels ($1,000): it adds no savings. On savings alone, it does not pay back."

    # An item with no known life (a transfer switch): only its payback.
    assert PowerPage.part_text(part("transfer_switch", %{payback: 10.0, life: nil})) =~
             "It pays back in 10.0 years."

    assert PowerPage.part_text(part("transfer_switch", %{payback: nil, life: nil})) =~
             "it adds no savings. On savings alone, it does not pay back. The reason is a safe backup"
  end

  test "the hours of backup for the sheet of an item: none with no power" do
    assert PowerPage.outage_text(nil, nil) == nil
  end
end
