defmodule DIYWeb.HomeLiveTest do
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DIY.Build

  test "the page waits for the build of the device", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "The page reads your build"
    assert render(view) =~ "The page reads your build"
  end

  test "a new build starts at the two doors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render_hook(view, "device:restore", %{"text" => nil, "stamp" => ""})
    assert html =~ "My house"
    assert html =~ "A house I&#39;m planning"
    assert has_element?(view, "#door-my-house")
    assert has_element?(view, "#door-planning")
  end

  test "a door goes to the device", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "device:restore", %{"text" => nil, "stamp" => ""})

    view |> element("#door-planning") |> render_click()
    assert_push_event view, "device:save", %{text: text, base: "", epoch: 0}
    assert {:ok, %Build{door: "planning", revision: 1, stamp: stamp}} = Build.from_json(text)
    assert render(view) =~ "The device does not have the last change yet"

    assert render_hook(view, "device:saved", %{"stamp" => stamp}) =~ "Saved on this device"
  end

  test "a door that is not a door changes nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "device:restore", %{"text" => nil, "stamp" => ""})
    render_click(view, "door", %{"door" => "garage"})
    refute_push_event view, "device:save", _payload
  end

  test "start again clears the build", %{conn: conn} do
    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    assert render(view) =~ "Saved on this device"

    view |> element("#restart") |> render_click()
    assert_push_event view, "device:save", %{text: text, base: base}
    assert base == build.stamp
    assert {:ok, %Build{door: nil, revision: 2}} = Build.from_json(text)
    assert has_element?(view, "#door-my-house")
  end
end
