defmodule DIYWeb.AboutControllerTest do
  @moduledoc "The page About (`DIYWeb.AboutController`), and the link to it."
  use DIYWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the page About tells who made the app and what it does with the data", %{conn: conn} do
    html = conn |> get(~p"/about") |> html_response(200)
    assert html =~ ~r/<html[^>]* lang="en"/
    assert html =~ ~r/<title[^>]*>About Small Steps Home<\/title>/
    assert html =~ ~r/<h1[^>]*>\s*About Small Steps Home\s*<\/h1>/

    for id <- ~w(about-who about-data about-numbers about-code),
        do: assert(html =~ ~s(id="#{id}" aria-labelledby="#{id}-title"))

    assert html =~ "Sơn Trần-Nguyễn made this app."
    assert html =~ "The server keeps no copy."
    assert html =~ "for one year after the last visit of the link"
    assert html =~ ~s(id="about-code-link" href="https://github.com/sntran/DIY")
    assert html =~ ~s(id="about-issues-link" href="https://github.com/sntran/DIY/issues")
    assert html =~ ~s(id="about-start" href="/")

    # The links of the languages come back to this page. The page has no
    # link to itself.
    assert html =~ ~s(href="/language/es?return=%2Fabout")
    refute html =~ ~s(id="about-link")
    assert redirected_to(get(build_conn(), ~p"/language/es?#{[return: "/about"]}")) == "/about"
  end

  test "the page About in Spanish and in Vietnamese", %{conn: conn} do
    for {lang, title, data} <- [
          {"es", "Acerca de Small Steps Home", "Sus datos"},
          {"vi", "Giới thiệu Small Steps Home", "Dữ liệu của bạn"}
        ] do
      html = conn |> put_req_cookie("diy_language", lang) |> get(~p"/about") |> html_response(200)
      assert html =~ ~r/<html[^>]* lang="#{lang}"/
      assert html =~ ~r/<title[^>]*>#{title}<\/title>/
      assert html =~ data
      assert html =~ ~s(id="language-#{lang}")
    end
  end

  test "each page of the app has the link to the page About", %{conn: conn} do
    assert conn |> get(~p"/") |> html_response(200) =~
             ~s(<a id="about-link" href="/about" class="link">About this app</a>)

    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "device:restore", %{"stamp" => "s0"})
    assert has_element?(view, "footer a#about-link[href='/about']", "About this app")

    es = put_req_cookie(build_conn(), "diy_language", "es")
    assert es |> get(~p"/") |> html_response(200) =~ "Acerca de esta aplicación"
  end
end
