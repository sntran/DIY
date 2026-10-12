defmodule DIY.StationModelsTest do
  @moduledoc "The models of power stations (`DIY.Catalog.station_models/0`)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, Catalog, House, Layout}
  alias DIYWeb.Format

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

  defp model(key), do: List.keyfind(Catalog.station_models(), key, 0)
  defp numbers(key), do: elem(model(key), 2)

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

      # Each number is in the source: the Wh, the watts, and the weight to
      # the nearest pound. The charge from the wall is 1,800 W: the charge
      # from an outlet of 120 V and 15 A.
      assert numbers["charge_w"] == 1800
      assert source =~ "#{Format.int(round(numbers["kwh"] * 1000))} Wh", key

      for watts <- ["output_w", "charge_w", "solar_w"] do
        assert source =~ "#{Format.int(numbers[watts])} W", "#{key}: #{watts}"
      end

      pounds =
        for [lb] <- Regex.scan(~r/([\d.]+) lb/, source, capture: :all_but_first),
            do: lb |> Float.parse() |> elem(0) |> round()

      assert numbers["weight"] in pounds, key
    end

    # The choice of the kind has each model, and another station by default.
    %{params: [model | _]} = Catalog.kind("power_station")
    assert model.key == "model" and model.default == "other"
    assert {:choice, values} = model.type
    assert values == Enum.map(models, &{elem(&1, 0), elem(&1, 1)})
  end

  test "the numbers and the sizes of the makers" do
    # Each model: the battery, the output, the solar input and the weight
    # (the charge from the wall is 1,800 W for each).
    for {key, {kwh, output, solar, weight}} <- [
          {"pecron_f5000lfp", {5.12, 7200, 5800, 124}},
          {"pecron_e3800lfp", {3.84, 4200, 3000, 87}},
          {"ecoflow_delta_pro", {3.6, 3600, 1600, 99}},
          {"ecoflow_delta_pro_3", {4.096, 4000, 2600, 114}},
          {"ecoflow_delta_pro_ultra", {6.144, 7200, 5600, 182}},
          {"anker_solix_f3800", {3.84, 6000, 2400, 132}},
          {"anker_solix_f3800_plus", {3.84, 6000, 3200, 137}}
        ] do
      assert numbers(key) == %{
               "kwh" => kwh,
               "output_w" => output,
               "charge_w" => 1800,
               "solar_w" => solar,
               "weight" => weight
             },
             key
    end

    # The front of a DELTA Pro is its short end; the F3800 stands up.
    assert Catalog.station_size("ecoflow_delta_pro") == {11, 25, 16}
    assert Catalog.station_size("ecoflow_delta_pro_3") == {13, 27, 16}
    assert Catalog.station_size("ecoflow_delta_pro_ultra") == {27, 19, 16}
    assert Catalog.station_size("anker_solix_f3800") == {15, 16, 28}
    assert Catalog.station_size("pecron_e3800lfp") == {18, 12, 15}
    assert Catalog.station_size("pecron_f5000lfp") == Catalog.size("power_station")
    assert Catalog.station_size("other") == Catalog.size("power_station")
    assert Catalog.station_size("no such model") == Catalog.size("power_station")

    # A station of a model has the name of the model.
    station = fn model -> %{type: "power_station", params: %{"model" => model}} end
    assert Catalog.name(station.("ecoflow_delta_pro_ultra")) == "EcoFlow DELTA Pro Ultra"
    assert Catalog.name(station.("other")) == "Power station"

    # In the middle of a sentence, the name of a model stays. A different
    # name starts in lower case, but not a word of capitals.
    assert Catalog.text_name(station.("anker_solix_f3800")) == "Anker SOLIX F3800"
    assert Catalog.text_name(station.("other")) == "power station"
    assert Catalog.text_name(%{type: "tv", params: %{}}) == "TV"
  end

  test "a new model gives its numbers; the numbers and the size of the person stay" do
    {build, id} = station(house())
    assert item(build, id).params["model"] == "other"
    assert Layout.size(item(build, id)) == Catalog.size("power_station")
    refute Build.own_numbers?(item(build, id))

    # A new station has the numbers of a new station: a model gives its
    # numbers, and the station has the size of the model.
    {:ok, build} =
      Build.update_item(build, id, %{"model" => "ecoflow_delta_pro", "cost" => "3000"})

    station = item(build, id)
    assert Map.take(station.params, @numbers) == numbers("ecoflow_delta_pro")
    assert station.params["cost"] == 3000
    refute station.typical
    assert Layout.size(station) == {11, 25, 16}

    # A size of the person stays with a new model. The numbers of the old
    # model are not the numbers of the person: the new model gives its
    # numbers.
    {:ok, build} = Build.size_item(build, id, %{w: 14, d: 28, h: 18})
    {:ok, build} = Build.update_item(build, id, %{"model" => "ecoflow_delta_pro_3"})
    assert Map.take(item(build, id).params, @numbers) == numbers("ecoflow_delta_pro_3")
    assert Layout.size(item(build, id)) == {14, 28, 18}
    {:ok, build} = Build.size_item(build, id, nil)
    assert Layout.size(item(build, id)) == {13, 27, 16}

    # The person changes a number: a pass through the models keeps it, and
    # the model changes.
    {:ok, build} = Build.update_item(build, id, %{"kwh" => "8.2", "extra_kwh" => "4.1"})
    assert Build.own_numbers?(item(build, id))

    {:ok, build} =
      Enum.reduce(["anker_solix_f3800", "other", "ecoflow_delta_pro_ultra"], {:ok, build}, fn
        model, {:ok, build} -> Build.update_item(build, id, %{"model" => model})
      end)

    assert item(build, id).params["model"] == "ecoflow_delta_pro_ultra"
    assert item(build, id).params["kwh"] == 8.2
    assert Layout.size(item(build, id)) == {27, 19, 16}

    # The numbers of the model again. The extra batteries stay.
    {:ok, build} = Build.use_model(build, id)
    assert Map.take(item(build, id).params, @numbers) == numbers("ecoflow_delta_pro_ultra")
    assert item(build, id).params["extra_kwh"] == 4.1

    # Another station keeps the numbers, with the size and the look of the
    # kind. "Use the numbers of the model" changes nothing for it.
    {:ok, build} = Build.update_item(build, id, %{"model" => "other"})
    assert Map.take(item(build, id).params, @numbers) == numbers("ecoflow_delta_pro_ultra")
    assert Layout.size(item(build, id)) == Catalog.size("power_station")
    {:ok, same} = Build.use_model(build, id)
    assert item(same, id).params == item(build, id).params

    # Only a van and a station have a model.
    fridge = Enum.find(build.items, &(&1.type == "fridge")).id
    assert Build.use_model(build, fridge) == {:error, :item}
    assert Build.use_model(build, "no such item") == {:error, :item}
  end

  test "a guess of the app is not the numbers of the person" do
    {build, id} = station(house())
    station = %{item(build, id) | typical: true, params: %{item(build, id).params | "kwh" => 7.0}}
    refute Build.own_numbers?(station)
    assert Build.own_numbers?(%{station | typical: false})
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

  property "a new model gives its numbers when the person has none; a size of the person stays" do
    {build, id} = station(house())
    keys = ["other" | known()]

    check all(
            from <- member_of(keys),
            to <- member_of(keys),
            touch <- boolean(),
            kwh <- float(min: 10.0, max: 100.0),
            solar <- integer(0..20_000),
            size <- one_of([constant(nil), constant(%{w: 30, d: 30, h: 30})])
          ) do
      {:ok, build} = Build.update_item(build, id, %{"model" => from})

      {:ok, build} =
        if touch,
          do: Build.update_item(build, id, %{"kwh" => kwh, "solar_w" => solar}),
          else: {:ok, build}

      {:ok, build} = Build.size_item(build, id, size)
      before = item(build, id)
      {:ok, build} = Build.update_item(build, id, %{"model" => to})
      station = item(build, id)
      assert station.params["model"] == to
      assert station.size == size

      if to in [from, "other"] or touch,
        do: assert(Map.drop(station.params, ["model"]) == Map.drop(before.params, ["model"])),
        else: assert(Map.take(station.params, @numbers) == numbers(to))

      assert Layout.size(station) == if(size, do: {30, 30, 30}, else: Catalog.station_size(to))
    end
  end
end
