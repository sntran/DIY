defmodule DIY.BuildDevicesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.{Build, House}

  defp preset do
    {house, rooms, items} =
      House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    Build.put_house(build, house, rooms, items)
  end

  defp room_named(build, name), do: Enum.find(build.rooms, &(&1.name == name))

  test "an item for a device of Home Assistant: one device, one item" do
    build = preset()
    kitchen = room_named(build, "Kitchen")
    {:ok, build1, id} = Build.add_device(build, kitchen.id, "lights", "dev-1")
    assert build1.revision == build.revision + 1
    assert build1.devices == %{id => "dev-1"}
    assert Build.device_item(build1, "dev-1") == id
    assert Build.device_item(build1, "dev-2") == nil
    {:ok, item} = Build.item(build1, id)
    # The numbers of one device: one bulb, not the lights of a house.
    assert item.params["bulbs"] == 1
    assert item.room == kitchen.id
    assert item.at != nil

    {:ok, build2, fan} = Build.add_device(build1, kitchen.id, "ceiling_fan", "dev-2")
    {:ok, item} = Build.item(build2, fan)
    assert item.params["count"] == 1
    {:ok, build3, tv} = Build.add_device(build2, kitchen.id, "tv", "dev-3")

    # At the place of its ghost, in its room. A place out of the limits is
    # no place: the item goes to a free place.
    {:ok, at_build, at_id} =
      Build.add_device(build3, kitchen.id, "microwave", "dev-4", %{x: 60, y: 120})

    assert {:ok, %{at: %{x: 60, y: 120}}} = Build.item(at_build, at_id)

    {:ok, far, far_id} =
      Build.add_device(build3, kitchen.id, "microwave", "dev-4", %{x: 99_999, y: 0})

    assert {:ok, %{at: %{x: _, y: _}}} = Build.item(far, far_id)

    {:ok, bad, bad_id} =
      Build.add_device(build3, kitchen.id, "microwave", "dev-4", %{x: "a", y: 0})

    assert {:ok, %{at: %{x: _, y: _}}} = Build.item(bad, bad_id)
    {:ok, item} = Build.item(build3, tv)
    assert item.params == DIY.Catalog.defaults("tv")

    # The errors: a device with an item, and a bad id. A room that cannot
    # have an area, a kind that cannot go in the room, and no room.
    roof = room_named(build, "Roof")
    assert Build.add_device(build1, kitchen.id, "tv", "dev-1") == {:error, :taken}
    assert Build.add_device(build1, kitchen.id, "tv", "") == {:error, :device}

    assert Build.add_device(build1, kitchen.id, "tv", String.duplicate("d", 256)) ==
             {:error, :device}

    assert Build.add_device(build1, kitchen.id, "tv", 5) == {:error, :device}
    assert Build.add_device(build1, roof.id, "solar_panels", "dev-9") == {:error, :room}
    assert Build.add_device(build1, kitchen.id, "pool_pump", "dev-9") == {:error, :place}
    assert Build.add_device(build1, "r999", "tv", "dev-9") == {:error, :room}
    assert Build.add_device(build1, kitchen.id, "nothing", "dev-9") == {:error, :type}

    # The item goes away: its link too. A new house has no links.
    {:ok, build4} = Build.delete_item(build3, id)
    assert build4.devices == %{fan => "dev-2", tv => "dev-3"}
    assert Build.device_item(build4, "dev-1") == nil

    {house, rooms, items} =
      House.preset(%{size: 1200, year: 1990, floors: 1, heat: "gas", lot: nil})

    assert Build.put_house(build4, house, rooms, items).devices == %{}

    # The links are in the text of the build.
    {:ok, read} = Build.from_json(Build.to_json(build4))
    assert read.devices == build4.devices
  end

  test "the text of a build: only the links of the items of the house, one item for each device" do
    build = preset()
    kitchen = room_named(build, "Kitchen")
    {:ok, build, a} = Build.add_device(build, kitchen.id, "tv", "dev-a")
    {:ok, build, b} = Build.add_item(build, kitchen.id, "microwave")
    {:ok, build, van} = Build.add_item(build, room_named(build, "Driveway").id, "camper_van")
    galley = Enum.find(Build.zones(build, van), &(&1.place == :galley))
    {:ok, build, c} = Build.add_item(build, galley.id, "van_fridge")
    map = Jason.decode!(Build.to_json(build))

    # An older build has no links.
    {:ok, read} = Build.from_json(Jason.encode!(Map.delete(map, "devices")))
    assert read.devices == %{}

    # A second item for one device, an item of a van, and an item that is
    # not there. The first item of the house keeps the device.
    devices = %{a => "dev-a", b => "dev-a", c => "dev-c", "i999" => "dev-z"}
    {:ok, read} = Build.from_json(Jason.encode!(%{map | "devices" => devices}))
    assert read.devices == %{a => "dev-a"}

    for bad <- [[1], %{a => 5}, %{a => ""}, %{a => String.duplicate("x", 256)}, "x"] do
      assert Build.from_json(Jason.encode!(%{map | "devices" => bad})) == {:error, :devices}
    end
  end

  property "the links of a text: each device has one item of the house at most" do
    build = preset()
    ids = Enum.map(build.items, & &1.id) ++ ["i999", "r1"]
    map = Jason.decode!(Build.to_json(build))

    check all(links <- map_of(member_of(ids), member_of(~w(d1 d2 d3 d4)), max_length: 8)) do
      {:ok, read} = Build.from_json(Jason.encode!(%{map | "devices" => links}))
      items = MapSet.new(read.items, & &1.id)
      assert Enum.all?(Map.keys(read.devices), &MapSet.member?(items, &1))
      assert read.devices |> Map.values() |> Enum.uniq() |> length() == map_size(read.devices)
      assert Map.to_list(read.devices) -- Map.to_list(links) == []
      # A device of the text with an item of the house keeps one item.
      for {item, device} <- links, MapSet.member?(items, item) do
        assert device in Map.values(read.devices)
      end
    end
  end
end
