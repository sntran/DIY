defmodule DIY.Pecron do
  @moduledoc """
  The cloud of Pecron, through the API that Pecron made for Home Assistant
  (`https://app.pecron.com/api/ha/`). The integration of Pecron for Home
  Assistant uses the same API. The relay of the app
  (`DIYWeb.RelayController`) calls it for a person with no Home
  Assistant. It uses the token of the person: a token of the portal of
  Pecron (`phk_…`). The module keeps no token, and writes no token to a
  log.

  - `GET /api/ha/devices` gives each device of the account, with its state:
    `%{"devices" => [%{"id", "name", "model", "online", "state"}]}`. The
    state has the code of each property of the device.
  - `POST /api/ha/command/{id}` writes properties:
    `%{"properties" => [%{"code" => code, "value" => value}]}`.

  The app reads five properties (`stations/1`): the battery (%), the power
  in and out (W), and the switches of the AC and DC outlets. It writes only
  the two switches (`command/4`).
  """

  @url "https://app.pecron.com"

  # The codes of the properties of a station, and the part of each.
  @numbers [
    {"battery_percentage", "battery"},
    {"total_input_power", "input"},
    {"total_output_power", "output"}
  ]
  @switches [{"ac_switch_hm", "ac"}, {"dc_switch_hm", "dc"}]
  @switch_parts Enum.map(@switches, &elem(&1, 1))

  # The most devices of one account, and the longest id, name or model,
  # that the app takes.
  @max_devices 100
  @max_text 200

  @type station :: %{String.t() => String.t() | number() | boolean() | nil}

  @doc "The parts of a station that the app turns on and off."
  def switches, do: @switch_parts

  @doc """
  The stations of the account of a token, or an error: `:token` (Pecron
  refuses the token), `:unreachable` (no answer) or `:failed` (any other
  answer).
  """
  @spec stations(String.t()) :: {:ok, [station()]} | {:error, :token | :unreachable | :failed}
  def stations(token) do
    with {:ok, body} <- request(:get, "/api/ha/devices", token, nil),
         list when is_list(list) <- read_stations(body) do
      {:ok, list}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :failed}
    end
  end

  @doc """
  Turns a switch of a station on or off: the AC outlets (`"ac"`) or the
  DC outlets (`"dc"`).
  """
  @spec command(String.t(), String.t(), String.t(), boolean()) ::
          :ok | {:error, :token | :unreachable | :failed}
  def command(token, id, part, on) when part in @switch_parts and is_boolean(on) do
    {code, _part} = List.keyfind(@switches, part, 1)
    body = %{"properties" => [%{"code" => code, "value" => on}]}

    case request(
           :post,
           "/api/ha/command/" <> URI.encode(id, &URI.char_unreserved?/1),
           token,
           body
         ) do
      {:ok, _body} -> :ok
      error -> error
    end
  end

  defp request(method, path, token, body) do
    options =
      [
        method: method,
        url: @url <> path,
        headers: [{"authorization", "Bearer " <> token}],
        receive_timeout: 15_000,
        retry: false
      ]
      |> then(&if body, do: Keyword.put(&1, :json, body), else: &1)
      |> Keyword.merge(Application.get_env(:diy, __MODULE__, [])[:req] || [])

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, :token}
      {:ok, _response} -> {:error, :failed}
      {:error, _error} -> {:error, :unreachable}
    end
  end

  @doc """
  The stations of an answer of `/api/ha/devices`, or `nil`. Each station
  has its id, name, model, `online`, and its parts. A part is a number or
  `nil` for the battery and the power, and `"on"`, `"off"` or `nil` for a
  switch. A
  device that the app cannot read does not count. A battery is from 0 to
  100 %, and a power from 0 to 1,000,000 W: else the number is `nil`.
  """
  def read_stations(%{"devices" => devices}) when is_list(devices) do
    if length(devices) <= @max_devices,
      do:
        devices |> Enum.map(&read_station/1) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1["id"])
  end

  def read_stations(_body), do: nil

  defp read_station(%{"id" => id} = device) do
    state = if is_map(device["state"]), do: device["state"], else: %{}

    with id when is_binary(id) <- id(id) do
      parts =
        Enum.map(@numbers, fn {code, part} -> {part, number(part, state[code])} end) ++
          Enum.map(@switches, fn {code, part} -> {part, switch(state[code])} end)

      Map.new(parts)
      |> Map.merge(%{
        "id" => id,
        "name" => text(device["name"]),
        "model" => text(device["model"]),
        "online" => device["online"] == true
      })
    end
  end

  defp read_station(_device), do: nil

  @doc "True for an id of a device of Pecron: letters, digits, `-` and `_`."
  def id?(id), do: is_binary(id) and id =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/

  defp id(id), do: if(id?(id), do: id)

  defp text(value) when is_binary(value) and byte_size(value) <= @max_text, do: value
  defp text(_value), do: nil

  defp number("battery", value) when is_number(value) and value >= 0 and value <= 100, do: value
  defp number("battery", _value), do: nil
  defp number(_part, value) when is_number(value) and value >= 0 and value <= 1_000_000, do: value
  defp number(_part, _value), do: nil

  # The cloud gives a switch as true or false, or as 1 or 0.
  defp switch(value) when value in [true, 1], do: "on"
  defp switch(value) when value in [false, 0], do: "off"
  defp switch(_value), do: nil
end
