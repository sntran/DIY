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

    # The data of a person: what goes to the server, and what stays.
    for fact <- [
          "The server uses it while the page is open, but it does not save it.",
          "the link holds the house and the months of your meter",
          "Only the sums of each month, and the text of the plan, go to the server.",
          "The server keeps it for one year after the last visit of the link.",
          "a point near your ZIP code to NASA POWER and to Open-Meteo",
          "the server sends the ZIP code to Power to Choose",
          "For Pecron, each request goes through the server, which does not keep the key.",
          "The app runs on Cloudflare."
        ],
        do: assert(html =~ fact)

    assert html =~ ~s(id="about-code-link" href="https://github.com/sntran/DIY")

    assert html =~
             ~r/id="about-issues-link" href="https:\/\/github.com\/sntran\/DIY\/issues"[^>]*>\s*Open an issue on GitHub/

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

    # The foot is after the main part: a landmark of its own.
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "device:restore", %{"stamp" => "s0"})
    assert has_element?(view, "main + footer a#about-link[href='/about']", "About this app")

    for {lang, text} <- [{"es", "Acerca de esta aplicación"}, {"vi", "Giới thiệu ứng dụng này"}] do
      html =
        build_conn() |> put_req_cookie("diy_language", lang) |> get(~p"/") |> html_response(200)

      assert html =~ text
    end

    # The tab of the sign-in of Home Assistant has no link: a click there
    # loses the sign-in.
    refute build_conn() |> get(~p"/ha/sign-in") |> html_response(200) =~ "about-link"
  end
end
