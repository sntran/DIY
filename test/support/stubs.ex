defmodule DIY.Stubs do
  @moduledoc """
  The answers of the public services for the tests (`Req.Test`). NASA
  POWER gives a real answer for Plano, Texas (2016 to 2025). Power to
  Choose gives a real answer for the ZIP code 75070 (October 2026).
  Open-Meteo gives the sky of a point near Plano (`open_meteo/2`). The
  cloud of Pecron is a fake with one station (`pecron/0`).
  """

  @fixtures Path.expand("../fixtures", __DIR__)

  def power, do: @fixtures |> Path.join("power_plano.json") |> File.read!() |> Jason.decode!()
  def ptc, do: @fixtures |> Path.join("ptc_75070.json") |> File.read!() |> Jason.decode!()

  @doc "The weather service answers with the weather of Plano."
  def weather(answer \\ :ok)

  def weather(:ok), do: Req.Test.stub(DIY.Weather, &Req.Test.json(&1, power()))

  def weather(status) when is_integer(status),
    do: Req.Test.stub(DIY.Weather, &Plug.Conn.send_resp(&1, status, ""))

  def weather(:down), do: Req.Test.stub(DIY.Weather, &Req.Test.transport_error(&1, :econnrefused))
  def weather(body), do: Req.Test.stub(DIY.Weather, &Req.Test.json(&1, body))

  @doc "Power to Choose answers with the plans of 75070."
  def market(answer \\ :ok)

  def market(:ok), do: Req.Test.stub(DIY.Market, &Req.Test.json(&1, ptc()))

  def market(status) when is_integer(status),
    do: Req.Test.stub(DIY.Market, &Plug.Conn.send_resp(&1, status, ""))

  def market(:down), do: Req.Test.stub(DIY.Market, &Req.Test.transport_error(&1, :econnrefused))
  def market(body), do: Req.Test.stub(DIY.Market, &Req.Test.json(&1, body))

  @doc """
  An answer of Open-Meteo for a point near Plano, Texas. It has the time
  of the place, its weather code, its temperature (°F), and the sunrise
  and the sunset of the day.
  """
  def open_meteo(time \\ "2026-10-24T21:30", code \\ 0) do
    %{
      "latitude" => 33.241005,
      "longitude" => -96.735214,
      "utc_offset_seconds" => -18_000,
      "timezone" => "America/Chicago",
      "current" => %{
        "time" => time,
        "interval" => 900,
        "weather_code" => code,
        "temperature_2m" => 59.1
      },
      "daily" => %{
        "time" => ["2026-10-24"],
        "sunrise" => ["2026-10-24T07:38"],
        "sunset" => ["2026-10-24T18:43"]
      }
    }
  end

  @doc "Open-Meteo answers with the sky of Plano: a clear day at noon."
  def sky(answer \\ :ok)

  def sky(:ok), do: Req.Test.stub(DIY.Sky, &Req.Test.json(&1, open_meteo("2026-10-24T12:00")))

  def sky(status) when is_integer(status),
    do: Req.Test.stub(DIY.Sky, &Plug.Conn.send_resp(&1, status, ""))

  def sky(:down), do: Req.Test.stub(DIY.Sky, &Req.Test.transport_error(&1, :econnrefused))
  def sky(body), do: Req.Test.stub(DIY.Sky, &Req.Test.json(&1, body))

  @doc """
  The cloud of Pecron: an E3800LFP in the account of the token
  `phk_walk`. A control changes its outlets. A different token gets 401.
  """
  def pecron do
    {:ok, outlets} =
      Agent.start_link(fn -> %{"ac_switch_hm" => true, "dc_switch_hm" => false} end)

    Req.Test.stub(DIY.Pecron, fn conn ->
      case {conn.method, Plug.Conn.get_req_header(conn, "authorization")} do
        {"GET", ["Bearer phk_walk"]} ->
          state =
            Map.merge(Agent.get(outlets, & &1), %{
              "battery_percentage" => 82,
              "total_input_power" => 0,
              "total_output_power" => 350
            })

          station = %{
            "id" => "dev_1",
            "name" => "Backup battery",
            "model" => "E3800LFP",
            "online" => true,
            "state" => state
          }

          Req.Test.json(conn, %{"devices" => [station]})

        {"POST", ["Bearer phk_walk"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"properties" => [%{"code" => code, "value" => value}]} = Jason.decode!(body)
          Agent.update(outlets, &Map.put(&1, code, value))
          Req.Test.json(conn, %{"ok" => true})

        _request ->
          Plug.Conn.send_resp(conn, 401, "")
      end
    end)
  end
end
