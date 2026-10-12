defmodule DIYWeb.LocaleTest do
  @moduledoc "The language of the pages (`DIYWeb.Locale`) and the files of the translations."
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.{Build, Stubs}
  alias DIYWeb.Locale

  setup do
    Stubs.weather()
    Stubs.market()
    :ok
  end

  test "the language of a header Accept-Language" do
    assert Locale.from_header("es-MX,es;q=0.9,en;q=0.8") == "es"
    assert Locale.from_header("fr-FR, vi;q=0.5, en;q=0.4") == "vi"
    assert Locale.from_header("en-US") == "en"
    assert Locale.from_header("VI-vn") == "vi"
    # A larger weight comes first. With the same weight, the first one.
    assert Locale.from_header("en;q=0.2, es;q=0.7") == "es"
    assert Locale.from_header("vi, es") == "vi"
    # A weight of zero refuses the language. A weight that is not a number
    # counts as 1.
    assert Locale.from_header("vi;q=0, es;q=0.1") == "es"
    assert Locale.from_header("es;q=x") == "es"
    # A language that the app does not have, or no header.
    assert Locale.from_header("fr, de") == nil
    assert Locale.from_header("") == nil
    assert Locale.from_header(nil) == nil
    assert Locale.locales() == ~w(en es vi)
  end

  property "the language of a header is the best language of the app in it" do
    tag = member_of(~w(en es vi fr de en-US es-419 vi-VN zh *))
    q = one_of([constant(nil), member_of([0, 0.1, 0.5, 0.9, 1])])

    check all(parts <- list_of(tuple({tag, q}), max_length: 6), noise <- string(:printable)) do
      header =
        parts
        |> Enum.map(fn
          {tag, nil} -> tag
          {tag, q} -> "#{tag};q=#{q}"
        end)
        |> Enum.join(", ")

      # The model: the largest weight first, else the first one.
      expected =
        parts
        |> Enum.with_index()
        |> Enum.map(fn {{tag, q}, i} -> {tag |> String.split("-") |> hd(), q || 1, i} end)
        |> Enum.filter(fn {base, q, _i} -> base in Locale.locales() and q > 0 end)
        |> Enum.sort_by(fn {_base, q, i} -> {-q, i} end)
        |> Enum.map(&elem(&1, 0))
        |> List.first()

      assert Locale.from_header(header) == expected
      # Any text gives a language of the app, or nil.
      assert Locale.from_header(noise) in [nil | Locale.locales()]
    end
  end

  test "the plug: the cookie first, then the header, then English", %{conn: conn} do
    with_cookie = conn |> put_req_cookie("diy_language", "vi") |> get(~p"/")
    assert with_cookie.assigns.locale == "vi"
    assert get_session(with_cookie, "locale") == "vi"
    assert html_response(with_cookie, 200) =~ ~r/<html[^>]* lang="vi"/

    header =
      build_conn()
      |> put_req_cookie("diy_language", "fr")
      |> put_req_header("accept-language", "es-MX,es;q=0.9")
      |> get(~p"/")

    assert header.assigns.locale == "es"
    assert build_conn() |> get(~p"/") |> Map.get(:assigns) |> Map.get(:locale) == "en"
  end

  test "a link of a language keeps it in a cookie, and goes back to a page of the app", %{
    conn: conn
  } do
    changed = get(conn, ~p"/language/es?#{[return: "/settings"]}")
    assert redirected_to(changed) == "/settings"

    assert %{value: "es", max_age: 31_536_000, same_site: "Lax"} =
             changed.resp_cookies["diy_language"]

    # A language that the app does not have changes nothing.
    unknown = get(build_conn(), ~p"/language/fr?#{[return: "/settings"]}")
    assert redirected_to(unknown) == "/settings"
    refute Map.has_key?(unknown.resp_cookies, "diy_language")

    # Only a path of the app: not a different site.
    for return <- ["//evil.example", "/\\evil.example", "https://evil.example", "", nil] do
      params = if return, do: [return: return], else: []
      assert redirected_to(get(build_conn(), ~p"/language/vi?#{params}")) == "/"
    end

    long = "/" <> String.duplicate("a", 200)
    assert redirected_to(get(build_conn(), ~p"/language/vi?#{[return: long]}")) == "/"

    assert redirected_to(get(build_conn(), ~p"/language/vi?#{[return: "/inside?item=i1"]}")) ==
             "/inside?item=i1"
  end

  defp open(conn, path, build) do
    {:ok, view, _html} = live(conn, path)
    render_hook(view, "device:restore", %{"text" => Build.to_json(build), "stamp" => build.stamp})
    view
  end

  test "the first screens in Spanish and in Vietnamese", %{conn: conn} do
    es = put_req_cookie(conn, "diy_language", "es")
    assert es |> get(~p"/") |> html_response(200) =~ ~r/<html[^>]* lang="es"/
    {:ok, view, _html} = live(es, ~p"/")
    render_hook(view, "device:restore", %{"stamp" => "s0"})
    assert has_element?(view, "h1", "Encuentre su próximo pequeño paso")
    assert has_element?(view, "#door-my-house", "Mi casa")
    assert has_element?(view, "nav[aria-label=Idioma] a#language-es[aria-current=true][lang=es]")
    assert has_element?(view, "a#language-vi[lang=vi][hreflang=vi]", "Tiếng Việt")
    refute has_element?(view, "a#language-vi[aria-current]")

    view |> element("#door-my-house") |> render_click()
    assert has_element?(view, "h1", "¿Dónde está la casa?")
    view |> form("#zip-form", %{"zip" => "00000"}) |> render_submit()
    assert has_element?(view, "#zip-error", "La app no conoce este código postal.")
    view |> form("#zip-form", %{"zip" => "75070"}) |> render_submit()
    assert has_element?(view, "h1", "Una casa como la mía")
    assert has_element?(view, "label[for=size-medium]", "Mediana · 1,800 pies²")
    assert has_element?(view, "label[for=heat-heat_pump]", "Bomba de calor")

    assert has_element?(
             view,
             "label[for=heat-heat_pump]",
             "el aire acondicionado también calienta"
           )

    vi = put_req_cookie(build_conn(), "diy_language", "vi")
    {:ok, build} = Build.choose_door(Build.new(), "planning")
    {:ok, build} = Build.set_zip(build, "75070")
    view = open(vi, ~p"/", build)
    assert has_element?(view, "h1", "Lô đất và ngôi nhà")
    assert has_element?(view, "#start-preset", "Bắt đầu từ ngôi nhà như thế này")
    assert has_element?(view, "#start-scratch", "Bắt đầu từ đầu")
  end

  test "the frame and the page Settings in Vietnamese", %{conn: conn} do
    {house, rooms, items} =
      DIY.House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    build = Build.put_house(build, house, rooms, items)

    view = open(put_req_cookie(conn, "diy_language", "vi"), ~p"/settings", build)
    assert has_element?(view, "nav[aria-label='Các phần của mô hình'] .dock-label", "Cài đặt")
    assert has_element?(view, "#device-status", "Chưa lưu")
    assert has_element?(view, "#settings h1", "Cài đặt")
    assert has_element?(view, "#languages h2", "Ngôn ngữ")
    assert has_element?(view, "a#language-vi[aria-current=true]")
    assert has_element?(view, ~s(a#language-es[href="/language/es?return=%2Fsettings"]))
    assert has_element?(view, "#settings-house option[selected]", "Gas")
    assert has_element?(view, "#settings p", "Hiện tại:")
    assert render(view) =~ ~s(data-confirm="Xóa mô hình này khỏi thiết bị và bắt đầu lại?")
  end

  test "the sources of the prices in the language of the page" do
    in_vi = fn fun -> Gettext.with_locale(DIY.Gettext, "vi", fun) end
    assert in_vi.(fn -> DIY.Prices.price(%{price: 12.0}).source end) == "giá do bạn nhập"

    assert in_vi.(fn -> DIY.Prices.price(%{price: nil, market: nil, zip: "75070"}).source end) =~
             "giá trung bình cho hộ gia đình ở Texas"

    assert Gettext.with_locale(DIY.Gettext, "es", fn -> DIY.Prices.gas(%{zip: "10001"}).source end) =~
             "los hogares de EE. UU."
  end

  test "a LiveView with no language in its session is in English" do
    socket = %Phoenix.LiveView.Socket{}
    assert {:cont, %{assigns: %{locale: "en"}}} = Locale.on_mount(:default, %{}, %{}, socket)

    assert {:cont, %{assigns: %{locale: "vi"}}} =
             Locale.on_mount(:default, %{}, %{"locale" => "vi"}, socket)
  end

  # The messages of a file of translations: {msgid, msgstr, flags}.
  defp messages(path) do
    {:ok, po} = Expo.PO.parse_file(path)

    for %Expo.Message.Singular{} = m <- po.messages,
        do: {IO.iodata_to_binary(m.msgid), IO.iodata_to_binary(m.msgstr), m.flags}
  end

  defp keys(text), do: ~r/%\{(\w+)\}/ |> Regex.scan(text) |> Enum.map(&List.last/1) |> Enum.sort()

  test "each text has its translation in Spanish and in Vietnamese, with the same keys" do
    pot = for {id, _str, _flags} <- messages("priv/gettext/default.pot"), do: id
    assert length(pot) > 50

    for locale <- ~w(es vi) do
      po = messages("priv/gettext/#{locale}/LC_MESSAGES/default.po")
      assert Enum.map(po, &elem(&1, 0)) |> Enum.sort() == Enum.sort(pot), locale

      for {id, str, flags} <- po do
        assert str != "", "#{locale}: no translation of #{inspect(id)}"
        assert keys(str) == keys(id), "#{locale}: the keys of #{inspect(id)}"
        refute "fuzzy" in List.flatten(flags), "#{locale}: #{inspect(id)} is fuzzy"
      end
    end
  end
end
