defmodule DIY.CatalogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Catalog

  test "each kind has its places, features and valid defaults" do
    zones = Keyword.keys(Catalog.zones())

    for kind <- Catalog.kinds() do
      assert kind.places != [] and
               Enum.all?(kind.places, &(&1 in Catalog.places() or &1 in zones))

      # An item of a van has its weight.
      if Enum.any?(kind.places, &(&1 in zones)),
        do: assert(Enum.any?(kind.params, &(&1.key == "weight")), kind.type)

      # A pool has no feature: it uses no power, and its pump and its
      # heater are items. Furniture has no feature and no parameter.
      assert kind.features != [] or kind.type == "pool" or kind.type in Catalog.furniture()
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
    assert %{key: "weight", unit: "lb", default: 10} = Param.weight(10)
    assert %{key: "weight", note: "A note."} = Param.weight(10, "A note.")
    assert %{key: "minutes", default: 5} = Param.minutes(5)
    assert length(Param.seasons()) == 5
  end

  test "the zones and the models of a camper van" do
    assert [{:cab, "Cab"}, {:engine, "Engine bay"} | _] = Catalog.zones()
    assert length(Catalog.zones()) == 8
    assert Enum.any?(Catalog.kinds_for(:bay), &(&1.type == "power_station"))
    refute Enum.any?(DIY.Kinds.house(), &(&1.type == "van_fridge"))
    assert Enum.any?(DIY.Kinds.house(), &(&1.type == "camper_van"))

    # The numbers of each model are valid numbers of a van.
    for {key, _name, numbers, _source} <- Catalog.van_models() do
      assert {:ok, params} = Catalog.params("camper_van", Map.put(numbers, "model", key))
      assert params["model"] == key
    end

    assert {:ok, %{"model" => "promaster_159", "gvwr" => 8900}} =
             Catalog.params("camper_van", %{})
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
    # A very large integer has no float: it is out of the range.
    assert Catalog.params("ac", %{"tons" => 10 ** 400}) == {:error, {:param, "tons"}}
    assert {:ok, %{"tons" => 3.0}} = Catalog.params("ac", %{"tons" => 3})
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
    kinds = Enum.filter(Catalog.kinds(), &(&1.params != []))

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

  test "each kind has a typical size, and some are on a wall or a ceiling" do
    for type <- Catalog.types() do
      {w, d, h} = Catalog.size(type)
      assert Enum.all?([w, d, h], &(is_integer(&1) and &1 > 0))
    end

    assert Catalog.lift("ceiling_fan") == 84
    assert Catalog.lift("fridge") == 0
  end

  # The number parameters of all the kinds.
  @numbers for kind <- Catalog.kinds(),
               param <- kind.params,
               param.type in [:int, :float],
               do: {kind.type, param}

  test "the steps of − and +: round steps, half an hour for hours" do
    param = fn type, key -> Enum.find(Catalog.kind(type).params, &(&1.key == key)) end

    assert Catalog.step(param.("fridge", "kwh_year"), 500) == 20
    assert Catalog.stepped(param.("fridge", "kwh_year"), 500, 1) == 520
    assert Catalog.stepped(param.("fridge", "kwh_year"), 503, -1) == 500
    assert Catalog.stepped(param.("tv", "watts"), 100, 1) == 105
    assert Catalog.stepped(param.("tv", "hours"), 5.3, 1) == 5.5
    assert Catalog.stepped(param.("tv", "hours"), 24.0, 1) == 24.0
    assert Catalog.stepped(param.("power_station", "cost"), 1500, 1) == 1600
    # Near 0, the step comes from the range.
    assert Catalog.stepped(param.("power_station", "solar_w"), 0, 1) == 5
    assert Catalog.stepped(param.("dishwasher", "loads"), 0, -1) == 0
    assert Catalog.stepped(param.("power_station", "kwh"), 0.1, -1) == 0.1
    # Hours that are whole numbers have the steps of a number.
    hours = %{param.("tv", "hours") | type: :int, min: 0, max: 24}
    assert Catalog.stepped(hours, 5, -1) == 4
  end

  property "− and + give a valid value in the range, in the right direction" do
    check all(
            {type, param} <- member_of(@numbers),
            part <- float(min: 0.0, max: 1.0),
            by <- member_of([-1, 1])
          ) do
      value =
        case param.type do
          :int -> round(param.min + part * (param.max - param.min))
          :float -> Float.round(param.min + part * (param.max - param.min), 2)
        end

      next = Catalog.stepped(param, value, by)
      step = Catalog.step(param, value)
      assert {:ok, _params} = Catalog.params(type, %{param.key => next})
      assert next >= param.min and next <= param.max

      # Up is more, and down is less, unless the value is at the end of the
      # range. The new value is a multiple of the step, or an end.
      if by > 0, do: assert(next > value or next == param.max)
      if by < 0, do: assert(next < value or next == param.min)
      ratio = next / step

      assert abs(ratio - round(ratio)) < 1.0e-6 or next in [param.min, param.max],
             "#{type} #{param.key}: #{value} #{by} gives #{next} (step #{step})"

      # One tap goes one step at most (a float has a round of 0.01).
      assert abs(next - value) <= step + 0.01,
             "#{type} #{param.key}: #{value} #{by} gives #{next} (step #{step})"

      # A step is 1, 2 or 5 times a power of ten (or half an hour).
      digits = step |> abs() |> :math.log10() |> Float.floor()
      lead = step / :math.pow(10, digits)
      assert Enum.any?([1, 2, 5], &(abs(lead - &1) < 1.0e-6))

      # A step is near 5% of the value (or of 1/200 of the range): from 3%
      # to 8% of it, or the smallest step.
      base = max(abs(value), (param.max - param.min) / 200)
      least = if param.type == :int, do: 1, else: 0.1

      unless param.unit == "h" do
        assert step >= 0.03 * base or step == least
        assert step <= 0.08 * base or step == least
      end
    end
  end
end
