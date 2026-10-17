defmodule DIY.PecronTest do
  @moduledoc "The cloud of Pecron, through its API for Home Assistant (`DIY.Pecron`)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DIY.Pecron

  # An answer of /api/ha/devices: an E3800LFP with all its parts, and an
  # F5000LFP that is offline, with switches of 1 and 0.
  @devices %{
    "devices" => [
      %{
        "id" => "dev_1",
        "name" => "Garage battery",
        "model" => "E3800LFP",
        "sn" => "AABBCCDDEEFF",
        "online" => true,
        "state" => %{
          "battery_percentage" => 82,
          "total_input_power" => 640,
          "total_output_power" => 1250.5,
          "ac_switch_hm" => true,
          "dc_switch_hm" => false,
          "battery_voltage" => 53.1
        },
        "entities" => []
      },
      %{
        "id" => "dev-2",
        "name" => "Cabin",
        "model" => "F5000LFP",
        "online" => false,
        "state" => %{"ac_switch_hm" => 1, "dc_switch_hm" => 0}
      }
    ]
  }

  test "the stations of an account: the parts that the app reads" do
    Req.Test.stub(Pecron, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/ha/devices"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer phk_test"]
      Req.Test.json(conn, @devices)
    end)

    assert Pecron.stations("phk_test") ==
             {:ok,
              [
                %{
                  "id" => "dev_1",
                  "name" => "Garage battery",
                  "model" => "E3800LFP",
                  "online" => true,
                  "battery" => 82,
                  "input" => 640,
                  "output" => 1250.5,
                  "ac" => "on",
                  "dc" => "off"
                },
                %{
                  "id" => "dev-2",
                  "name" => "Cabin",
                  "model" => "F5000LFP",
                  "online" => false,
                  "battery" => nil,
                  "input" => nil,
                  "output" => nil,
                  "ac" => "on",
                  "dc" => "off"
                }
              ]}
  end

  test "an answer that the app cannot read, a refused token, and no answer" do
    for {answer, result} <- [
          {&Req.Test.json(&1, %{"devices" => "none"}), {:error, :failed}},
          {&Req.Test.json(&1, %{"devices" => List.duplicate(%{}, 101)}), {:error, :failed}},
          {&Plug.Conn.send_resp(&1, 401, "no"), {:error, :token}},
          {&Plug.Conn.send_resp(&1, 403, "no"), {:error, :token}},
          {&Plug.Conn.send_resp(&1, 500, "no"), {:error, :failed}},
          {&Req.Test.transport_error(&1, :econnrefused), {:error, :unreachable}}
        ] do
      Req.Test.stub(Pecron, answer)
      assert Pecron.stations("phk_test") == result
    end
  end

  test "a control of the AC or DC outlets of one station" do
    Req.Test.stub(Pecron, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/ha/command/dev_1"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer phk_test"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:body, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert Pecron.command("phk_test", "dev_1", "ac", false) == :ok
    assert_received {:body, %{"properties" => [%{"code" => "ac_switch_hm", "value" => false}]}}
    assert Pecron.command("phk_test", "dev_1", "dc", true) == :ok
    assert_received {:body, %{"properties" => [%{"code" => "dc_switch_hm", "value" => true}]}}

    Req.Test.stub(Pecron, &Plug.Conn.send_resp(&1, 401, "no"))
    assert Pecron.command("phk_test", "dev_1", "ac", true) == {:error, :token}
    assert Pecron.switches() == ["ac", "dc"]
  end

  test "the ids and the parts that the app takes" do
    assert Pecron.id?("dev_1-A")
    refute Pecron.id?("dev/1")
    refute Pecron.id?("")
    refute Pecron.id?(String.duplicate("a", 65))
    refute Pecron.id?(5)

    [station] =
      Pecron.read_stations(%{
        "devices" => [
          %{
            "id" => "a",
            "name" => String.duplicate("x", 201),
            "model" => 5,
            "online" => "yes",
            "state" => %{
              "battery_percentage" => 101,
              "total_input_power" => -5,
              "total_output_power" => "9",
              "ac_switch_hm" => "on"
            }
          },
          %{"id" => "a"},
          %{"id" => "b/c"},
          %{"name" => "no id"},
          "device"
        ]
      })

    assert station == %{
             "id" => "a",
             "name" => nil,
             "model" => nil,
             "online" => false,
             "battery" => nil,
             "input" => nil,
             "output" => nil,
             "ac" => nil,
             "dc" => nil
           }

    assert Pecron.read_stations(%{"devices" => [%{"id" => "a", "state" => "none"}]})
           |> hd()
           |> Map.get("battery") == nil

    assert Pecron.read_stations("none") == nil
  end

  property "each station of an answer has the parts that the app reads, in their ranges" do
    value =
      one_of([
        constant(nil),
        boolean(),
        integer(-5..110),
        integer(999_990..1_000_010),
        float(min: -5.0, max: 2.0e6),
        string(:ascii)
      ])

    code =
      member_of(
        ~w(battery_percentage total_input_power total_output_power ac_switch_hm dc_switch_hm other)
      )

    check all(
            devices <-
              list_of(
                fixed_map(%{
                  "id" =>
                    one_of([string(:alphanumeric, min_length: 1, max_length: 8), constant("x y")]),
                  "state" => map(list_of(tuple({code, value}), max_length: 8), &Map.new/1)
                }),
                max_length: 6
              )
          ) do
      stations = Pecron.read_stations(%{"devices" => devices})
      assert length(stations) <= length(devices)
      assert stations == Enum.uniq_by(stations, & &1["id"])

      for station <- stations do
        assert Pecron.id?(station["id"])

        assert is_nil(station["battery"]) or station["battery"] in 0..100 or
                 (is_float(station["battery"]) and station["battery"] >= 0 and
                    station["battery"] <= 100)

        for part <- ~w(input output),
            do:
              assert(is_nil(station[part]) or (station[part] >= 0 and station[part] <= 1_000_000))

        for part <- ~w(ac dc), do: assert(station[part] in [nil, "on", "off"])
      end
    end
  end
end
