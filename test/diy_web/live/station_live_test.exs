defmodule DIYWeb.StationLiveTest do
  @moduledoc "The model of a power station in its panel."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.{Build, House, Stubs}

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  defp preset do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    view
  end

  defp build_of(view), do: :sys.get_state(view.pid).socket.assigns.build

  defp station(view, id) do
    {:ok, item} = Build.item(build_of(view), id)
    item
  end

  defp choose(view, id, model) do
    view
    |> form("#item-form", %{"item_id" => id, "item" => %{"model" => model}})
    |> render_change()
  end

  test "the person chooses the model of a station: its numbers, its size and its look",
       %{conn: conn} do
    build = preset()
    garage = Enum.find(build.rooms, &(&1.name == "Garage")).id
    {:ok, build, id} = Build.add_item(build, garage, "power_station")
    view = open(conn, ~p"/inside?#{[item: id]}", build)

    # A new station is another station: the typical numbers, the typical
    # size, and the look of the F5000LFP. Only the caps of the E3800LFP
    # have the orange of a top (i-orange-t).
    assert has_element?(view, "#param-model-field legend", "Model")
    assert has_element?(view, ~s(#param-model-field input[value="other"][checked]))
    assert has_element?(view, "#param-model-field", "EcoFlow DELTA Pro Ultra")
    assert has_element?(view, "#param-model-help", "Another station keeps the numbers")
    refute has_element?(view, "#use-model")
    refute has_element?(view, "#station-source")
    assert has_element?(view, "#item-place", "These are the typical sizes of this kind of item.")
    refute render(view) =~ "i-orange-t"

    # The E3800LFP of Pecron: its numbers, its source, its size, its name
    # and its orange caps on the stage and on the plan. A status tells the
    # new numbers.
    choose(view, id, "pecron_e3800lfp")
    assert station(view, id).params["kwh"] == 3.84
    assert has_element?(view, "#param-kwh[value='3.84']")
    assert has_element?(view, "#item-stage-title", "Pecron E3800LFP")

    assert has_element?(
             view,
             "#item-said",
             "Pecron E3800LFP: 3.84 kWh, 4,200 W, a charge of 1,800 W, 3,000 W of solar input, 87 lb. Its size: 18 by 12 by 15 in."
           )

    assert has_element?(
             view,
             "#station-source",
             "The numbers of the model: Pecron, the page of the E3800LFP"
           )

    assert has_element?(view, "#use-model", "Use the numbers of the model")
    assert has_element?(view, "#item-place", "These are the sizes of the model.")
    assert has_element?(view, "#size-w[value='18']")
    assert render(view) =~ "i-orange-t"

    # The person changes a number. A pass through the models keeps it, and
    # the status tells it.
    view
    |> form("#item-form", %{"item_id" => id, "item" => %{"kwh" => "5"}})
    |> render_change()

    assert station(view, id).params["kwh"] == 5.0
    choose(view, id, "anker_solix_f3800")
    assert station(view, id).params["kwh"] == 5.0
    assert has_element?(view, "#item-said", "Anker SOLIX F3800. Your numbers stay.")
    choose(view, id, "other")
    assert has_element?(view, "#item-said", "Another station. The numbers stay.")
    choose(view, id, "pecron_e3800lfp")
    assert station(view, id).params["kwh"] == 5.0

    # The numbers of the model again, with the status.
    view |> element("#use-model") |> render_click()
    assert station(view, id).params["kwh"] == 3.84
    assert has_element?(view, "#item-said", "Pecron E3800LFP: 3.84 kWh")

    # A size of the person stays with a new model. The key gives the size
    # of the model again, and the focus goes to the first side.
    view
    |> form("#size-form", %{"item_id" => id, "w" => "20", "d" => "12", "h" => "15"})
    |> render_submit()

    choose(view, id, "anker_solix_f3800")
    assert station(view, id).size == %{w: 20, d: 12, h: 15}
    assert has_element?(view, "#item-said", "Anker SOLIX F3800: 3.84 kWh, 6,000 W")
    refute has_element?(view, "#item-said", "Its size")
    assert has_element?(view, "#item-place", "You gave this size.")
    assert has_element?(view, ~s(#typical-size[phx-click*="size-w"]), "The size of the model")
    view |> element("#typical-size") |> render_click()
    assert station(view, id).size == nil

    # The F3800 of Anker has its own look: the warm gray.
    assert render(view) =~ "i-titanium-"
    refute render(view) =~ "i-orange-t"

    # An item with no model: nothing changes.
    before = build_of(view)
    render_click(view, "use_model", %{"id" => "no such item"})
    assert build_of(view) == before
  end

  test "a new model of a van gets a status too", %{conn: conn} do
    build = preset()
    driveway = Enum.find(build.rooms, &(&1.name == "Driveway")).id
    {:ok, build, van} = Build.add_item(build, driveway, "camper_van")
    view = open(conn, ~p"/inside?#{[item: van]}", build)

    choose(view, van, "transit_148")

    assert has_element?(
             view,
             "#item-said",
             "Ford Transit 250, 148 in, high roof: the numbers of the model are in the fields."
           )

    choose(view, van, "other")
    assert has_element?(view, "#item-said", "Another van. The numbers stay.")
  end
end
