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
    # size, and the look of the F5000LFP.
    assert has_element?(view, "#param-model-field legend", "Model")
    assert has_element?(view, ~s(#param-model-field input[value="other"][checked]))
    assert has_element?(view, "#param-model-field", "EcoFlow DELTA Pro Ultra")
    assert has_element?(view, "#param-model-help", "Another station keeps the numbers")
    refute has_element?(view, "#use-model")
    refute has_element?(view, "#station-source")
    assert has_element?(view, "#item-place", "These are the typical sizes of this kind of item.")
    refute render(view) =~ "i-orange-"

    # The E3800LFP of Pecron: its numbers, its source, its size and its
    # orange caps on the stage and on the plan.
    choose(view, id, "pecron_e3800lfp")
    assert station(view, id).params["kwh"] == 3.84
    assert has_element?(view, "#param-kwh[value='3.84']")

    assert has_element?(
             view,
             "#station-source",
             "The numbers of the model: Pecron, the page of the E3800LFP"
           )

    assert has_element?(view, "#use-model", "Use the numbers of the model")
    assert has_element?(view, "#item-place", "These are the sizes of the model.")
    assert has_element?(view, "#size-w[value='18']")
    assert render(view) =~ "i-orange-"

    # The person changes a number, and then uses the numbers of the model
    # again.
    view
    |> form("#item-form", %{"item_id" => id, "item" => %{"kwh" => "5"}})
    |> render_change()

    assert station(view, id).params["kwh"] == 5.0
    view |> element("#use-model") |> render_click()
    assert station(view, id).params["kwh"] == 3.84

    # A size of the person, and then the size of the model again.
    view
    |> form("#size-form", %{"item_id" => id, "w" => "20", "d" => "12", "h" => "15"})
    |> render_submit()

    assert has_element?(view, "#item-place", "You gave this size.")
    assert has_element?(view, "#typical-size", "The size of the model")
    view |> element("#typical-size") |> render_click()
    assert station(view, id).size == nil

    # The F3800 of Anker has its own look: the warm gray.
    choose(view, id, "anker_solix_f3800")
    assert render(view) =~ "i-titanium-"
    refute render(view) =~ "i-orange-"
  end
end
