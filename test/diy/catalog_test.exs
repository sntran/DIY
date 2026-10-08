defmodule DIY.CatalogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Catalog

  test "each kind has its places, features and valid defaults" do
    for kind <- Catalog.kinds() do
      assert kind.places != [] and Enum.all?(kind.places, &(&1 in Catalog.places()))
      assert kind.features != []
      assert {:ok, defaults} = Catalog.params(kind.type, %{})
      assert defaults == Catalog.defaults(kind.type)
      assert Catalog.kind(kind.type) == kind
    end

    assert Enum.sort(Catalog.types()) == Enum.sort(Enum.map(Catalog.kinds(), & &1.type))
    assert Catalog.kind("rocket") == nil
  end

  test "the parameters of the kinds, at compile time" do
    alias DIY.Catalog.Param
    assert %{type: :int, min: 0, max: 2, note: nil} = Param.int("k", "K", nil, 1, 0, 2)
    assert %{type: :float, unit: "kW"} = Param.float("k", "K", "kW", 1.0, 0.0, 2.0, nil)

    assert %{type: {:choice, [{"a", "A"}]}, default: "a"} =
             Param.choice("k", "K", [{"a", "A"}], "a")

    assert %{key: "season", default: "all"} = Param.season("all")
    assert length(Param.seasons()) == 5
  end

  test "the kinds of a place" do
    assert Enum.any?(Catalog.kinds_for(:outdoor), &(&1.type == "ac"))
    refute Enum.any?(Catalog.kinds_for(:indoor), &(&1.type == "ac"))
    assert Enum.any?(Catalog.kinds_for(:roof), &(&1.type == "other"))
  end

  test "the months of a season" do
    assert Catalog.season_months("summer") == [5, 6, 7, 8, 9]
    assert Catalog.season_months("winter") == [12, 1, 2]
    assert Catalog.season_label("all") == "All year"
  end

  test "the name of an item" do
    assert Catalog.name(%{type: "fridge", params: %{}}) == "Fridge"
    assert Catalog.name(%{type: "other", params: %{"name" => "Hot tub"}}) == "Hot tub"
  end

  test "params reads the text of a form, and drops unknown keys" do
    assert {:ok, %{"tons" => 3.5, "seer2" => 14.0, "heat_pump" => true, "hspf2" => 7.5}} =
             Catalog.params("ac", %{
               "tons" => " 3.5 ",
               "seer2" => "14",
               "heat_pump" => "true",
               "x" => 1
             })

    assert {:ok, %{"heat_pump" => false}} = Catalog.params("ac", %{"heat_pump" => "false"})
    assert {:ok, %{"kwh_year" => 600}} = Catalog.params("fridge", %{"kwh_year" => "600"})
    assert {:ok, %{"kwh_year" => 600}} = Catalog.params("fridge", %{"kwh_year" => 600.0})
    assert {:ok, %{"fuel" => "gas"}} = Catalog.params("dryer", %{"fuel" => "gas"})
    assert {:ok, %{"name" => "Hot tub"}} = Catalog.params("other", %{"name" => "  Hot tub "})
  end

  test "params gives the first parameter that is not valid" do
    assert Catalog.params("ac", %{"tons" => "99"}) == {:error, {:param, "tons"}}
    assert Catalog.params("ac", %{"tons" => "three"}) == {:error, {:param, "tons"}}
    assert Catalog.params("ac", %{"heat_pump" => "yes"}) == {:error, {:param, "heat_pump"}}
    assert Catalog.params("fridge", %{"kwh_year" => "6.5"}) == {:error, {:param, "kwh_year"}}
    assert Catalog.params("fridge", %{"kwh_year" => 600.5}) == {:error, {:param, "kwh_year"}}
    assert Catalog.params("dryer", %{"fuel" => "wood"}) == {:error, {:param, "fuel"}}
    assert Catalog.params("dryer", %{"fuel" => 1}) == {:error, {:param, "fuel"}}
    assert Catalog.params("other", %{"name" => "  "}) == {:error, {:param, "name"}}
    assert Catalog.params("fridge", "not a map") == {:error, {:param, nil}}
  end

  property "params gives a valid map, or the error of one parameter, for any values" do
    kinds = Catalog.kinds()

    check all(
            kind <- member_of(kinds),
            pairs <-
              list_of(
                {member_of(Enum.map(kind.params, & &1.key)),
                 one_of([integer(), float(), string(:printable), boolean()])},
                max_length: 4
              )
          ) do
      values = Map.new(pairs)

      case Catalog.params(kind.type, values) do
        {:ok, params} ->
          assert Map.keys(params) |> Enum.sort() ==
                   kind.params |> Enum.map(& &1.key) |> Enum.sort()

          assert Catalog.params(kind.type, params) == {:ok, params}

        {:error, {:param, key}} ->
          assert key in Enum.map(kind.params, & &1.key)
      end
    end
  end
end
