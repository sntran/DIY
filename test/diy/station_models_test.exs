defmodule DIY.StationModelsTest do
  @moduledoc "The models of power stations (`DIY.Catalog.station_models/0`)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, House, Layout}

  @numbers ~w(kwh output_w charge_w solar_w weight)

  defp house do
    {house, rooms, items} =
      House.preset(%{size: 2000, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp garage(build), do: Enum.find(build.rooms, &(&1.name == "Garage")).id

  defp station(build) do
    {:ok, build, id} = Build.add_item(build, garage(build), "power_station")
    {build, id}
  end

  defp item(build, id) do
    {:ok, item} = Build.item(build, id)
    item
  end

  defp known, do: for({key, _, _, size, _} <- Catalog.station_models(), size != nil, do: key)

  test "each model has the numbers of its maker, a size and a source" do
    models = Catalog.station_models()
    assert length(models) == 8
    assert {"other", "Another station", %{}, nil, nil} = List.last(models)

    for {key, name, numbers, {w, d, h}, source} <- Enum.drop(models, -1) do
      assert key =~ ~r/^[a-z0-9_]+$/ and name != ""
      assert Enum.sort(Map.keys(numbers)) == Enum.sort(@numbers)
      # The numbers are in the ranges of the kind.
      assert {:ok, params} = Catalog.params("power_station", Map.put(numbers, "model", key))
      assert Map.take(params, @numbers) == numbers
      assert Enum.all?([w, d, h], &(is_integer(&1) and &1 > 0))
      assert source =~ ~r/^(Pecron|EcoFlow|Anker), the page of the /
    end

    # The choice of the kind has each model, and another station by default.
    %{params: [model | _]} = Catalog.kind("power_station")
    assert model.key == "model" and model.default == "other"
    assert {:choice, values} = model.type
    assert values == Enum.map(models, &{elem(&1, 0), elem(&1, 1)})
  end

  test "the numbers and the sizes of the makers" do
    numbers = Map.new(Catalog.station_models(), &{elem(&1, 0), elem(&1, 2)})

    assert numbers["pecron_f5000lfp"] == %{
             "kwh" => 5.12,
             "output_w" => 7200,
             "charge_w" => 3600,
             "solar_w" => 5800,
             "weight" => 124
           }

    assert numbers["pecron_e3800lfp"]["kwh"] == 3.84 and
             numbers["pecron_e3800lfp"]["weight"] == 87

    assert numbers["ecoflow_delta_pro"]["output_w"] == 3600
    assert numbers["ecoflow_delta_pro_3"]["kwh"] == 4.096
    assert numbers["ecoflow_delta_pro_ultra"]["solar_w"] == 5600
    assert numbers["anker_solix_f3800"]["solar_w"] == 2400
    assert numbers["anker_solix_f3800_plus"]["solar_w"] == 3200

    # The front of a DELTA Pro is its short end; the F3800 stands up.
    assert Catalog.station_size("ecoflow_delta_pro") == {11, 25, 16}
    assert Catalog.station_size("ecoflow_delta_pro_3") == {13, 27, 16}
    assert Catalog.station_size("ecoflow_delta_pro_ultra") == {27, 19, 16}
    assert Catalog.station_size("anker_solix_f3800") == {15, 16, 28}
    assert Catalog.station_size("pecron_e3800lfp") == {18, 12, 15}
    assert Catalog.station_size("pecron_f5000lfp") == Catalog.size("power_station")
    assert Catalog.station_size("other") == Catalog.size("power_station")
    assert Catalog.station_size("no such model") == Catalog.size("power_station")
  end

  test "a new model gives its numbers and its size; another station keeps them" do
    {build, id} = station(house())
    assert item(build, id).params["model"] == "other"
    assert Layout.size(item(build, id)) == Catalog.size("power_station")

    # The person gives a size, and then chooses a model.
    {:ok, build} = Build.size_item(build, id, %{w: 20, d: 20, h: 20})

    {:ok, build} =
      Build.update_item(build, id, %{"model" => "ecoflow_delta_pro", "cost" => "3000"})

    station = item(build, id)
    assert station.params["kwh"] == 3.6 and station.params["output_w"] == 3600
    assert station.params["cost"] == 3000
    refute station.typical
    assert station.size == nil
    assert Layout.size(station) == {11, 25, 16}

    # A number changes: the model stays.
    {:ok, build} = Build.update_item(build, id, %{"kwh" => "7.2", "extra_kwh" => "3.6"})
    assert item(build, id).params["model"] == "ecoflow_delta_pro"
    assert item(build, id).params["kwh"] == 7.2

    # The numbers of the model again.
    {:ok, build} = Build.use_model(build, id)
    assert item(build, id).params["kwh"] == 3.6
    assert item(build, id).params["extra_kwh"] == 3.6

    # The size that the person gives wins over the size of the model.
    {:ok, build} = Build.size_item(build, id, %{w: 12, d: 26, h: 17})
    assert Layout.size(item(build, id)) == {12, 26, 17}

    # Another station keeps the numbers and the size.
    {:ok, build} = Build.update_item(build, id, %{"model" => "other"})
    assert item(build, id).params["kwh"] == 3.6
    assert Layout.size(item(build, id)) == {12, 26, 17}
    {:ok, same} = Build.use_model(build, id)
    assert item(same, id).params == item(build, id).params

    # Only a van and a station have a model.
    fridge = Enum.find(build.items, &(&1.type == "fridge")).id
    assert Build.use_model(build, fridge) == {:error, :item}
    assert Build.use_model(build, "no such item") == {:error, :item}
  end

  test "a stored station keeps its model, and an old station is another station" do
    {build, id} = station(house())
    {:ok, build} = Build.update_item(build, id, %{"model" => "anker_solix_f3800_plus"})
    {:ok, loaded} = build |> Build.to_json() |> Build.from_json()
    assert item(loaded, id).params["model"] == "anker_solix_f3800_plus"
    assert Layout.size(item(loaded, id)) == {15, 16, 28}

    # A build from before the models: its station has no model.
    json =
      build
      |> Build.to_json()
      |> Jason.decode!()
      |> update_in(["items"], fn items ->
        Enum.map(items, fn item ->
          if item["id"] == id, do: update_in(item["params"], &Map.delete(&1, "model")), else: item
        end)
      end)
      |> Jason.encode!()

    {:ok, old} = Build.from_json(json)
    assert item(old, id).params["model"] == "other"
    assert item(old, id).params["kwh"] == 3.84
    assert Layout.size(item(old, id)) == Catalog.size("power_station")
  end

  property "a new model gives its numbers and its size; the same model or another station keeps them" do
    {build, id} = station(house())
    keys = ["other" | known()]

    check all(
            from <- member_of(keys),
            to <- member_of(keys),
            kwh <- float(min: 0.1, max: 100.0),
            solar <- integer(0..20_000),
            size <- one_of([constant(nil), constant(%{w: 30, d: 30, h: 30})])
          ) do
      {:ok, build} = Build.update_item(build, id, %{"model" => from})
      {:ok, build} = Build.update_item(build, id, %{"kwh" => kwh, "solar_w" => solar})
      {:ok, build} = Build.size_item(build, id, size)
      before = item(build, id)
      {:ok, build} = Build.update_item(build, id, %{"model" => to})
      station = item(build, id)
      assert station.params["model"] == to

      if to in [from, "other"] do
        assert Map.drop(station.params, ["model"]) == Map.drop(before.params, ["model"])
        assert station.size == size
      else
        {^to, _name, numbers, model_size, _source} = List.keyfind(Catalog.station_models(), to, 0)
        assert Map.take(station.params, @numbers) == numbers
        assert Layout.size(station) == model_size
      end
    end
  end
end
