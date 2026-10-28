defmodule DIYWeb.RoofShapesTest do
  @moduledoc """
  The roofs of a house with their shapes (`DIY.Roof`): in the build, on
  the plan (`DIYWeb.Cutaway`), on the house from outside (`DIYWeb.Outside`)
  and in the sheet of a roof. Also the order of the paint of a tall item in
  a yard (`DIYWeb.Camera.order/2`).
  """
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Roof}
  alias DIYWeb.{Camera, Cutaway, Outside}

  @m 0.0254

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  defp shape(slope, pitch \\ 5, base \\ nil),
    do: %{"slope" => slope, "pitch" => pitch, "base" => base}

  test "a roof gets a shape, a file keeps it, and a bad shape does not go" do
    build = house()
    roof = room(build, "Roof")
    assert Roof.shape(roof) == %{slope: "x", pitch: 5, base: nil}

    {:ok, build} = Build.set_roof(build, roof.id, shape("front", 7, "f1"))
    assert room(build, "Roof").roof == %{slope: "front", pitch: 7, base: "f1"}

    # The file keeps the shape.
    {:ok, loaded} = build |> Build.to_json() |> Build.from_json()
    assert room(loaded, "Roof").roof == %{slope: "front", pitch: 7, base: "f1"}

    # Only a roof has a shape. A shape must be valid, on a floor of the house.
    assert Build.set_roof(build, room(build, "Kitchen").id, shape("x")) == {:error, :roof}
    assert Build.set_roof(build, roof.id, shape("up")) == {:error, :roof}
    assert Build.set_roof(build, roof.id, shape("x", 5, "f3")) == {:error, :roof}
    assert Build.set_roof(build, "nothing", shape("x")) == {:error, :room}

    # A file with a shape that the app cannot read: the roof gets the first
    # shape. A room that is not a roof keeps no shape.
    map = build |> Build.to_json() |> Jason.decode!()

    rooms =
      for room <- map["rooms"] do
        cond do
          room["place"] == "roof" -> Map.put(room, "roof", %{"slope" => "up", "pitch" => 5})
          room["name"] == "Kitchen" -> Map.put(room, "roof", %{"slope" => "x", "pitch" => 5})
          true -> room
        end
      end

    {:ok, read} = %{map | "rooms" => rooms} |> Jason.encode!() |> Build.from_json()
    refute Map.has_key?(room(read, "Roof"), :roof)
    refute Map.has_key?(room(read, "Kitchen"), :roof)
  end

  test "the plan of a roof: its slopes, its ends, its rise and its slope for the hook" do
    build = house()
    roof = room(build, "Roof")
    {:ok, build} = Build.set_roof(build, roof.id, shape("y", 6))
    html = render_component(&Cutaway.cutaway/1, view: Cutaway.view(build), selected: nil)

    # The rise of two slopes along y: half the width, 6 in 12.
    rise = round(roof.plan.w / 2 * 6 / 12)
    assert html =~ ~r/data-room="#{roof.id}"[^>]*data-rise="#{rise}"[^>]*data-slope="y"/

    # Its gable end at the front, and no end at the right (the eaves).
    shaped = room(build, "Roof")
    front = (roof.plan.y + roof.plan.d) * @m
    assert [{corners, "p-gable"}] = Cutaway.roof_ends(shaped, roof.plan, 0.0)
    assert Enum.all?(corners, fn {_x, y, _z} -> abs(y - front) < 1.0e-9 end)
    assert Enum.any?(corners, fn {_x, _y, z} -> abs(z - rise * @m) < 0.02 end)

    # One slope with its low side at the front: the end at the right.
    {:ok, shed} = Build.set_roof(build, roof.id, shape("front", 4))
    right = (roof.plan.x + roof.plan.w) * @m
    assert [{corners, "p-gable"}] = Cutaway.roof_ends(room(shed, "Roof"), roof.plan, 0.0)
    assert Enum.all?(corners, fn {x, _y, _z} -> abs(x - right) < 1.0e-9 end)
  end

  test "panels on a roof with the ridge along y go over the ridge in two parts" do
    build = house()
    roof = room(build, "Roof")
    {:ok, build} = Build.set_roof(build, roof.id, shape("y"))
    {:ok, build, panels} = Build.add_item(build, roof.id, "solar_panels")
    {:ok, build} = Build.update_item(build, panels, %{"watts" => "8000"})
    ridge = div(roof.plan.w, 2)
    {:ok, build} = Build.place_item(build, panels, roof.id, %{x: ridge - 100, y: 20})

    [layer] = for level <- Cutaway.view(build).levels, level.id == "roof", do: level
    object = Enum.find(layer.objects, &(&1.id == panels))
    %{cols: cols, rows: rows} = DIY.Layout.array(DIY.Build.item(build, panels) |> elem(1))
    pv = for {_points, "i-pv"} <- object.polys, do: 1
    # 20 panels in 7 columns and 3 rows: the ridge crosses one column.
    assert {cols, rows} == {7, 3}
    assert length(pv) == 20 + 3

    # An AC on the slope of the roof stands on it, over the eaves.
    {:ok, build, ac} = Build.add_item(build, roof.id, "ac")
    {:ok, build} = Build.place_item(build, ac, roof.id, %{x: ridge + 60, y: 200})
    [layer] = for level <- Cutaway.view(build).levels, level.id == "roof", do: level
    {_x, _y, low, _x1, _y1, _high} = Enum.find(layer.objects, &(&1.id == ac)).box
    assert low > layer.z
  end

  test "the house from outside: a roof on its floor, with its ends" do
    build = house()
    roof = room(build, "Roof")

    top = fn build ->
      view = Outside.view(build)
      Enum.find(view.level.objects, &(&1.id == "roof-" <> roof.id))
    end

    # On the top floor (floor 2): the eaves are over two floors.
    %{box: {_, _, z2, _, _, _}} = top.(build)
    assert_in_delta z2, 0.3 + 2.4 + 0.3 + 2.4, 1.0e-9

    # On floor 1: the eaves are over one floor. The roof has its slope, its
    # shingles and its end at the right.
    {:ok, low} = Build.set_roof(build, roof.id, shape("front", 6, "f1"))
    %{box: {_, _, z1, _, _, z1top}, polys: polys} = top.(low)
    assert_in_delta z1, 0.3 + 2.4, 1.0e-9
    assert_in_delta z1top - z1, Roof.rise(room(low, "Roof")) * @m, 1.0e-9
    classes = Enum.map(polys, &elem(&1, 1))
    assert Enum.count(classes, &(&1 == "p-gable")) == 1
    assert "p-floor p-roof-f" in classes

    # A roof that looks to the back: its slope paints first.
    {:ok, back} = Build.set_roof(build, roof.id, shape("back"))
    assert [{_corners, "p-floor p-roof-b"} | _] = top.(back).polys
  end

  test "a tall item in a yard paints after a box all behind it, and before a box all in front" do
    camera = Camera.house()
    square = fn x, y -> [{{x, y, 0.0}, "a"}, {{x + 1, y, 0.0}, "a"}, {{x, y + 1, 3.0}, "a"}] end

    object = fn id, box, polys, extra ->
      Map.merge(
        %{
          id: id,
          box: box,
          key: 0,
          loose: false,
          polys: Enum.map(polys, fn {p, c} -> {[p], c} end)
        },
        extra
      )
    end

    # The roof is behind the tree along y, and they cover the same part of
    # the screen. The tree has a smaller key: by its key only, it paints
    # first.
    roof = object.("roof", {0.0, 0.0, 2.0, 4.0, 2.0, 4.0}, square.(0.0, 0.0), %{key: 5})

    tree =
      object.("tree", {0.5, 2.5, 0.0, 1.5, 3.5, 6.0}, square.(0.2, 0.3), %{key: 1, loose: true})

    order = fn objects -> Enum.map(Camera.order(objects, camera), & &1.id) end
    assert order.([roof, tree]) == ["tree", "roof"]
    assert order.([roof, Map.put(tree, :tall, true)]) == ["roof", "tree"]

    # A tall item behind the roof paints first.
    behind =
      object.("tree", {0.5, -3.0, 0.0, 1.5, -2.0, 6.0}, square.(0.2, 0.3), %{
        key: 9,
        loose: true,
        tall: true
      })

    assert order.([roof, behind]) == ["tree", "roof"]

    # The camera of a van looks most along x.
    van = Camera.van()

    near =
      object.("near", {2.0, 0.0, 0.0, 3.0, 1.0, 6.0}, square.(0.0, 0.0), %{
        key: 1,
        loose: true,
        tall: true
      })

    far = object.("far", {0.0, 0.0, 0.0, 1.0, 1.0, 3.0}, square.(0.0, 0.0), %{key: 5})
    assert Enum.map(Camera.order([near, far], van), & &1.id) == ["far", "near"]
  end

  test "the sheet of a roof gives it a shape", %{conn: conn} do
    build = house()
    roof = room(build, "Roof")
    kitchen = room(build, "Kitchen")
    {:ok, view, _html} = live(conn, ~p"/inside")
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    settle(view)

    render_patch(view, ~p"/inside?#{[room: kitchen.id, sheet: "room"]}")
    refute has_element?(view, "#roof-#{kitchen.id}")

    render_patch(view, ~p"/inside?#{[room: roof.id, sheet: "room"]}")
    assert has_element?(view, "#roof-#{roof.id} legend", "Shape of the roof")
    assert has_element?(view, "#roof-#{roof.id}-x[checked]")
    assert has_element?(view, "#roof-base-#{roof.id} option[value='f2']")

    view
    |> form("#roof-#{roof.id}", %{"slope" => "front", "pitch" => "7", "base" => "f1"})
    |> render_change()

    build = :sys.get_state(view.pid).socket.assigns.build
    assert room(build, "Roof").roof == %{slope: "front", pitch: 7, base: "f1"}
    assert has_element?(view, "#roof-#{roof.id}-front[checked]")

    # The top floor is no base. A bad change does nothing.
    render_change(view, "room_roof", %{
      "room_id" => roof.id,
      "slope" => "y",
      "pitch" => "5",
      "base" => ""
    })

    assert room(:sys.get_state(view.pid).socket.assigns.build, "Roof").roof.base == nil
    render_change(view, "room_roof", %{"room_id" => roof.id, "slope" => "y", "pitch" => "x"})
    assert room(:sys.get_state(view.pid).socket.assigns.build, "Roof").roof.slope == "y"
  end
end
