defmodule DIYWeb.RelayControllerTest do
  @moduledoc "The relay of the app to the cloud of Pecron (`DIYWeb.RelayController`)."
  use DIYWeb.ConnCase, async: true

  alias DIY.Pecron

  # A request of a page of the app, with a token.
  defp page(conn, token \\ "phk_test") do
    conn
    |> put_req_header("sec-fetch-site", "same-origin")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  test "the stations of the account of the token, with no cache", %{conn: conn} do
    Req.Test.stub(Pecron, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer phk_test"]

      Req.Test.json(conn, %{
        "devices" => [%{"id" => "dev_1", "state" => %{"battery_percentage" => 50}}]
      })
    end)

    conn = conn |> page() |> get("/relay/pecron/stations")
    assert %{"stations" => [%{"id" => "dev_1", "battery" => 50}]} = json_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute get_resp_header(conn, "set-cookie") != []
  end

  test "the errors of the cloud", %{conn: conn} do
    for {answer, status, error} <- [
          {&Plug.Conn.send_resp(&1, 401, "no"), 401, "token"},
          {&Plug.Conn.send_resp(&1, 500, "no"), 502, "failed"},
          {&Req.Test.transport_error(&1, :timeout), 502, "unreachable"}
        ] do
      Req.Test.stub(Pecron, answer)
      conn = conn |> page() |> get("/relay/pecron/stations")
      assert json_response(conn, status) == %{"error" => error}
    end
  end

  test "a control of the outlets of a station", %{conn: conn} do
    Req.Test.stub(Pecron, fn conn ->
      assert conn.request_path == "/api/ha/command/dev_1"
      Req.Test.json(conn, %{})
    end)

    conn = conn |> page() |> post("/relay/pecron/command/dev_1", %{"part" => "dc", "on" => true})
    assert json_response(conn, 200) == %{"ok" => true}

    Req.Test.stub(Pecron, &Plug.Conn.send_resp(&1, 401, "no"))

    conn =
      build_conn()
      |> page()
      |> post("/relay/pecron/command/dev_1", %{"part" => "ac", "on" => false})

    assert json_response(conn, 401) == %{"error" => "token"}
  end

  test "a whole round with the fake cloud of the walk: the stations, a control, the new state",
       %{conn: conn} do
    DIY.Stubs.pecron()
    stations = fn token -> build_conn() |> page(token) |> get("/relay/pecron/stations") end

    assert %{"stations" => [%{"id" => "dev_1", "ac" => "on", "battery" => 82}]} =
             json_response(stations.("phk_walk"), 200)

    conn =
      conn
      |> page("phk_walk")
      |> post("/relay/pecron/command/dev_1", %{"part" => "ac", "on" => false})

    assert json_response(conn, 200) == %{"ok" => true}
    assert %{"stations" => [%{"ac" => "off"}]} = json_response(stations.("phk_walk"), 200)
    assert json_response(stations.("phk_other"), 401) == %{"error" => "token"}
  end

  test "the relay sends no request that is not a request of the app", %{conn: conn} do
    # No call goes to the cloud.
    Req.Test.stub(Pecron, fn _conn -> flunk("a call to the cloud") end)

    # A request of a different site, or with no site.
    for site <- [["cross-site"], ["same-site"], []] do
      conn =
        Enum.reduce(site, conn, &put_req_header(&2, "sec-fetch-site", &1))
        |> put_req_header("authorization", "Bearer phk_test")
        |> get("/relay/pecron/stations")

      assert json_response(conn, 403) == %{"error" => "origin"}
    end

    # No token, a token with a space, and a token that is too long. Also a
    # token that is not a token of the portal of Pecron (no "phk_").
    no_token =
      build_conn()
      |> put_req_header("sec-fetch-site", "same-origin")
      |> get("/relay/pecron/stations")

    assert json_response(no_token, 401) == %{"error" => "token"}

    for token <- ["phk test", "phk_" <> String.duplicate("a", 509), "", "x", "phk_"] do
      conn = build_conn() |> page(token) |> get("/relay/pecron/stations")
      assert json_response(conn, 401) == %{"error" => "token"}
    end

    # A part that is not a switch, a value that is not true or false, and an
    # id that is not an id.
    for {id, body} <- [
          {"dev_1", %{"part" => "battery", "on" => true}},
          {"dev_1", %{"part" => "ac", "on" => "yes"}},
          {"dev_1", %{"part" => "ac"}},
          {"dev%2F1", %{"part" => "ac", "on" => true}}
        ] do
      conn = build_conn() |> page() |> post("/relay/pecron/command/" <> id, body)
      assert json_response(conn, 400) == %{"error" => "request"}
    end
  end
end
