defmodule DIY.Stubs do
  @moduledoc """
  The answers of the public services for the tests (`Req.Test`). NASA
  POWER gives a real answer for Plano, Texas (2016 to 2025). Power to
  Choose gives a real answer for the ZIP code 75070 (October 2026).
  Open-Meteo gives the sky of a point near Plano (`open_meteo/1`). The
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
  An answer of Open-Meteo for a point near Plano, Texas (UTC − 5 hours).
  Its sunrise and its sunset make `time` at the moment `at`. `time` is
  `"day"`, `"sunset"`, `"dawn"` (near the sunrise) or `"night"`. It can
  also be `"polar"` or `"polar_day"`. In a polar night, the sunrise and
  the sunset are the same time. In a polar day, the sunset is 24 hours
  after the sunrise. `code` is the code of the weather.
  """
  def open_meteo(opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())
    local = at |> DateTime.to_naive() |> NaiveDateTime.add(-18_000)

    hm =
      &(local
        |> NaiveDateTime.add(&1, :minute)
        |> NaiveDateTime.to_iso8601()
        |> binary_part(0, 16))

    {rise, set} =
      case Keyword.get(opts, :time, "day") do
        "day" ->
          {hm.(-240), hm.(240)}

        "sunset" ->
          {hm.(-600), hm.(10)}

        "dawn" ->
          {hm.(10), hm.(600)}

        "night" ->
          {hm.(180), hm.(780)}

        "polar" ->
          {binary_part(hm.(0), 0, 10) <> "T00:00", binary_part(hm.(0), 0, 10) <> "T00:00"}

        "polar_day" ->
          {binary_part(hm.(0), 0, 10) <> "T00:00", binary_part(hm.(1440), 0, 10) <> "T00:00"}
      end

    %{
      "latitude" => 33.241005,
      "longitude" => -96.735214,
      "utc_offset_seconds" => -18_000,
      "timezone" => "America/Chicago",
      "current" => %{
        "time" => hm.(0),
        "interval" => 900,
        "weather_code" => Keyword.get(opts, :code, 0),
        "temperature_2m" => 59.1,
        "is_day" => if(Keyword.get(opts, :time, "day") in ~w(night polar), do: 0, else: 1)
      },
      "daily" => %{"time" => [binary_part(hm.(0), 0, 10)], "sunrise" => [rise], "sunset" => [set]}
    }
  end

  @doc "Open-Meteo answers with the sky of Plano: a clear day."
  def sky(answer \\ :ok)

  def sky(:ok), do: Req.Test.stub(DIY.Sky, &Req.Test.json(&1, open_meteo()))

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
