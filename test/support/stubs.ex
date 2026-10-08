defmodule DIY.Stubs do
  @moduledoc """
  The answers of the public services for the tests (`Req.Test`): a real
  answer of NASA POWER for Plano, Texas (2016 to 2025), and a real answer
  of Power to Choose for the ZIP code 75070 (October 2026).
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
end
