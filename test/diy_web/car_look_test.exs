defmodule DIYWeb.CarLookTest do
  @moduledoc "The body and the color of an electric car (the kind \"ev\")."
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, Catalog, House, Layout}
  alias DIYWeb.Scene
  alias DIYWeb.Icon.Shapes

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    Build.put_house(build, house, rooms, items)
  end

  defp car(params) do
    {:ok, params} = Catalog.params("ev", params)
    %{type: "ev", at: %{x: 0, y: 0}, size: nil, turn: 0, params: params}
  end

  test "a car has a body and a color: the crossover in red, or the Bolt of 2027" do
    # The first car of the app is a red crossover. A file of an older
    # version gets the same.
    default = car(%{})
    assert %{"body" => "crossover", "color" => "red"} = default.params
    assert Shapes.look(default) == {"ev", "crossover", "red"}
    assert Shapes.model(Shapes.look(default)) == Shapes.model("ev")
    assert Layout.size(default) == {73, 186, 57}

    # The Bolt: 169.6 in long, 69.7 in wide, 63.9 in high. The size of its
    # model is its size.
    bolt = car(%{"body" => "bolt", "color" => "blue"})
    assert Layout.size(bolt) == {70, 170, 64}
    assert Catalog.car_size("other") == Catalog.size("ev")

    for {body, _name} <- Catalog.car_bodies(), color <- ~w(red blue white gray black) do
      look = Shapes.look(car(%{"body" => body, "color" => color}))
      {{x0, y0, z0}, {x1, y1, z1}} = Shapes.bounds(Shapes.model(look))
      {w, d, h} = Catalog.car_size(body)

      for {size, extent} <- [{w, x1 - x0}, {d, y1 - y0}, {h, z1 - z0}],
          do: assert(abs(size - extent / 0.0254) < 1, body)

      # The body has the color. Black is the dark material.
      paint = if color == "black", do: "dark", else: color
      assert [{:group, [{:prism, :x, _profile, _, _, ^paint} | _]}] = Shapes.model(look)
    end

    # A size that the person gives stays.
    assert Layout.size(%{bolt | size: %{w: 72, d: 175, h: 65}}) == {72, 175, 65}

    # A body or a color that the app does not know is not valid.
    assert {:error, _} = Catalog.params("ev", %{"body" => "truck"})
    assert {:error, _} = Catalog.params("ev", %{"color" => "pink"})
  end

  test "the picture of Power draws the first car with its body and its color" do
    build = house()
    garage = Enum.find(build.rooms, &(&1.name == "Garage")).id
    {:ok, build, id} = Build.add_item(build, garage, "ev")
    {:ok, build} = Build.update_item(build, id, %{"body" => "bolt", "color" => "blue"})

    parts = Scene.parts(build)
    assert parts.car and parts.car_look == {"ev", "bolt", "blue"}
    html = render_component(&Scene.house/1, id: "t", parts: parts)
    refute html =~ ~s(class="i-red-)
    assert html =~ ~s(class="i-blue-)

    # With no car, the look is the first car of the app.
    assert Scene.parts(house()).car_look == "ev"
  end
end
