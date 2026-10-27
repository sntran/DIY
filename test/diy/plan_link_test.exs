defmodule DIY.PlanLinkTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Pack, Plan, PlanLink}

  # A plan with a credit at 1,000 kWh and a minimum usage fee, as the EFL
  # of Just Energy (test/fixtures/efl).
  defp credit_plan do
    %{
      Plan.new("8.9¢ with a $125 credit")
      | energy: [{0, 14.4}],
        tdu_base: 4.9,
        tdu_cents: 6.5333,
        credits: [%{dollars: 125.0, min_kwh: 1000, months: nil}],
        min_fee: %{dollars: 4.99, below_kwh: 400}
    }
  end

  defp flat_plan,
    do: %{
      Plan.new("14.9¢ with no credit")
      | energy: [{0, 7.88}],
        tdu_base: 4.9,
        tdu_cents: 6.5333
    }

  # The DATA of a JSON text.
  defp data(json), do: "1" <> Pack.encode(json)

  test "a link carries the numbers of the plans, with no id and no averages" do
    plans = [
      %{credit_plan() | id: "p7", averages: %{500 => 22.9, 1000 => 8.9, 2000 => 15.4}},
      %{
        flat_plan()
        | id: "p9",
          energy: [{0, 9.0}, {1000, 8.0}],
          night: %{cents: 1.5, from: 23, to: 6, share: 0.35},
          credits: [%{dollars: 25.0, min_kwh: 1000, months: [7, 8]}]
      }
    ]

    {:ok, data} = PlanLink.encode(plans)
    assert "1" <> _ = data
    # Two plans give a short link.
    assert byte_size(data) < 400

    assert {:ok, [a, b]} = PlanLink.decode(data)
    assert a == %{hd(plans) | id: "p1", averages: nil}
    assert b == %{List.last(plans) | id: "p2"}
    {:ok, json} = Pack.decode(String.slice(data, 1..-1//1), 8192)
    refute json =~ "p7"
    refute json =~ "averages"
  end

  test "a link has 1 to 6 plans, and plans that a link cannot carry give an error" do
    assert PlanLink.encode([]) == {:error, :plans}
    assert PlanLink.encode(List.duplicate(flat_plan(), 7)) == {:error, :plans}
    assert {:ok, _data} = PlanLink.encode(List.duplicate(flat_plan(), 6))
    assert PlanLink.max_plans() == 6

    # A name is 60 letters at most, but a letter can have many marks: a
    # name can be long in bytes.
    large = %{flat_plan() | name: "a" <> String.duplicate("\u0301", 3000)}
    assert String.length(large.name) == 1
    assert {:ok, data} = PlanLink.encode([large])
    assert {:ok, [_plan]} = PlanLink.decode(data)
    assert PlanLink.encode(List.duplicate(large, 3)) == {:error, :too_large}
  end

  test "a text that is not a link of plans gives an error" do
    {:ok, good} = PlanLink.encode([flat_plan()])
    plan = flat_plan() |> Plan.to_map() |> Map.delete("id")

    assert PlanLink.decode(nil) == {:error, :version}
    assert PlanLink.decode("2" <> String.slice(good, 1..-1//1)) == {:error, :version}
    assert PlanLink.decode("1" <> String.duplicate("A", 6000)) == {:error, :too_long}
    assert PlanLink.decode("1!!") == {:error, :base64}

    assert PlanLink.decode("1" <> Base.url_encode64("no deflate", padding: false)) ==
             {:error, :inflate}

    assert PlanLink.decode(data(String.duplicate(" ", 17_000))) == {:error, :too_large}
    assert PlanLink.decode(data("{")) == {:error, :json}
    assert PlanLink.decode(data("[1]")) == {:error, :not_plans}
    assert PlanLink.decode(data(~s({"p":[]}))) == {:error, :not_plans}

    assert PlanLink.decode(data(Jason.encode!(%{"p" => List.duplicate(plan, 7)}))) ==
             {:error, :not_plans}

    assert PlanLink.decode(data(~s({"p":[1]}))) == {:error, :plan}

    assert PlanLink.decode(data(Jason.encode!(%{"p" => [plan, %{plan | "name" => ""}]}))) ==
             {:error, :plan}

    assert PlanLink.decode(data(Jason.encode!(%{"p" => [%{plan | "base" => -1}]}))) ==
             {:error, :plan}
  end

  property "the plans of a link are the plans that went in" do
    check all(
            plans <-
              list_of(
                gen all(
                      name <- string(:printable, min_length: 1, max_length: 60),
                      base <- float(min: 0.0, max: 50.0),
                      cents <- float(min: 0.0, max: 50.0),
                      dollars <- float(min: 0.0, max: 200.0),
                      min_kwh <- integer(0..2500)
                    ) do
                  %{
                    flat_plan()
                    | name: name,
                      base: base,
                      energy: [{0, cents}],
                      credits: [%{dollars: dollars, min_kwh: min_kwh, months: nil}]
                  }
                end,
                min_length: 1,
                max_length: 6
              )
          ) do
      {:ok, data} = PlanLink.encode(plans)
      {:ok, back} = PlanLink.decode(data)
      assert back == Enum.with_index(plans, 1) |> Enum.map(fn {p, n} -> %{p | id: "p#{n}"} end)
    end
  end
end
