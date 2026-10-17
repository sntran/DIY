defmodule DIYWeb.RelayController do
  @moduledoc """
  The relay of the app to the cloud of the maker of a power station, for a
  person with no Home Assistant (`DIY.Pecron`). A page of the app cannot
  call the cloud of Pecron: its answers have no CORS headers. So the hook
  of the page (`assets/js/maker_link.js`) calls the relay, and the relay
  calls the cloud. The TLA+ model `specs/MakerLink.tla` checks the rules of
  the hook.

  The rules of the relay:

  - It takes a request of a page of the app only (`sec-fetch-site:
    same-origin`). A page of a different site cannot use it.
  - The token of the person comes in each request (`authorization:
    Bearer …`). The relay keeps no token and writes no token to a log.
    This is a decision of the owner (October 2026): the server sees the
    token for each call, and keeps it for no call.
  - It sends to the cloud only two requests of the app. These are the list
    of the stations, and a control of the AC or DC outlets of one station.
  - It gives back only the parts that the app reads, and no answer goes to
    a cache (`cache-control: no-store`).
  """
  use Phoenix.Controller, formats: [:json]

  alias DIY.Pecron

  # The longest token that the relay takes.
  @max_token 512

  def pecron_stations(conn, _params) do
    with {:ok, token} <- token(conn) do
      case Pecron.stations(token) do
        {:ok, stations} -> answer(conn, 200, %{"stations" => stations})
        {:error, reason} -> error(conn, reason)
      end
    else
      {:error, status, reason} -> answer(conn, status, %{"error" => reason})
    end
  end

  def pecron_command(conn, %{"id" => id, "part" => part, "on" => on})
      when is_boolean(on) do
    with {:ok, token} <- token(conn),
         true <- (Pecron.id?(id) and part in Pecron.switches()) || {:error, 400, "request"} do
      case Pecron.command(token, id, part, on) do
        :ok -> answer(conn, 200, %{"ok" => true})
        {:error, reason} -> error(conn, reason)
      end
    else
      {:error, status, reason} -> answer(conn, status, %{"error" => reason})
    end
  end

  def pecron_command(conn, _params), do: answer(conn, 400, %{"error" => "request"})

  # The token of a request of a page of the app: printable, with no space.
  defp token(conn) do
    with {:site, ["same-origin"]} <- {:site, get_req_header(conn, "sec-fetch-site")},
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- byte_size(token) <= @max_token and token =~ ~r/\A[\x21-\x7e]+\z/ do
      {:ok, token}
    else
      {:site, _site} -> {:error, 403, "origin"}
      _no_token -> {:error, 401, "token"}
    end
  end

  defp error(conn, :token), do: answer(conn, 401, %{"error" => "token"})
  defp error(conn, reason), do: answer(conn, 502, %{"error" => Atom.to_string(reason)})

  defp answer(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(body)
  end
end
