defmodule DIY.BuildTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Build

  test "a new build has no revision, no stamp and no door" do
    assert %Build{version: 1, revision: 0, stamp: "", door: nil} = Build.new()
    assert Build.version() == 1
    assert Build.doors() == ["my_house", "planning"]
  end

  test "each change adds 1 to the revision and makes a new stamp" do
    {:ok, one} = Build.choose_door(Build.new(), "my_house")
    {:ok, two} = Build.choose_door(one, "planning")
    assert {one.revision, two.revision} == {1, 2}
    assert one.stamp != "" and two.stamp != one.stamp
    assert two.door == "planning"
  end

  test "a door that is not a door is an error" do
    assert Build.choose_door(Build.new(), "garage") == {:error, :door}
  end

  test "a restart keeps the revision and clears the build" do
    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    restarted = Build.restart(build)
    assert restarted.revision == 2
    assert restarted.door == nil
    assert restarted.stamp not in ["", build.stamp]
  end

  test "from_json gives the reason for a text that is not a build" do
    assert Build.from_json(nil) == {:error, :not_json}
    assert Build.from_json("{") == {:error, :not_json}
    assert Build.from_json("[1]") == {:error, :not_a_build}
    assert Build.from_json("{}") == {:error, :not_a_build}
    assert Build.from_json(~s({"version": 2})) == {:error, {:version, 2}}
    assert Build.from_json(~s({"version": 1, "revision": -1, "stamp": ""})) == {:error, :revision}
    assert Build.from_json(~s({"version": 1, "revision": 1, "stamp": 5})) == {:error, :stamp}

    assert Build.from_json(~s({"version": 1, "revision": 1, "stamp": "a", "door": "attic"})) ==
             {:error, :door}
  end

  defp build do
    gen all(
          revision <- non_negative_integer(),
          stamp <- string(:alphanumeric),
          door <- member_of([nil | Build.doors()])
        ) do
      %Build{revision: revision, stamp: stamp, door: door}
    end
  end

  property "to_json and from_json give the same build" do
    check all(build <- build()) do
      assert Build.from_json(Build.to_json(build)) == {:ok, build}
    end
  end

  property "from_json never raises" do
    check all(text <- one_of([string(:printable), json()])) do
      assert {status, _} = Build.from_json(text)
      assert status in [:ok, :error]
    end
  end

  # A JSON text of a map with some of the keys of a build, and random values.
  defp json do
    value = one_of([integer(), string(:printable), boolean(), constant(nil)])
    keys = member_of(["version", "revision", "stamp", "door", "other"])
    likely = member_of([1, "my_house", "planning"])

    gen all(pairs <- list_of({keys, one_of([value, likely])}, max_length: 6)) do
      pairs |> Map.new() |> Jason.encode!()
    end
  end
end
