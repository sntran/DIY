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
    # A space before ";", and a weight in capitals.
    assert Locale.from_header("es ;q=0.9, en;q=0.8") == "es"
    assert Locale.from_header("vi;Q=0, es") == "es"
    # Only the first 20 parts count.
    assert Locale.from_header(String.duplicate("fr, ", 20) <> "vi") == nil
    assert Locale.from_header(String.duplicate("fr, ", 19) <> "vi") == "vi"
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
    assert Locale.live_session(with_cookie) == %{"locale" => "vi"}
    assert html_response(with_cookie, 200) =~ ~r/<html[^>]* lang="vi"/
    # The cookie session does not keep the language: no write at each page.
    assert get_session(with_cookie, "locale") == nil

    # The cookie wins over the header.
    both =
      build_conn()
      |> put_req_cookie("diy_language", "vi")
      |> put_req_header("accept-language", "es")
      |> get(~p"/")

    assert both.assigns.locale == "vi"

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

    # A path of 200 bytes at most. A sign that a redirect does not take
    # gives "/", not an error.
    long = "/" <> String.duplicate("a", 199)
    assert redirected_to(get(build_conn(), ~p"/language/vi?#{[return: long]}")) == long
    assert redirected_to(get(build_conn(), ~p"/language/vi?#{[return: long <> "a"]}")) == "/"

    for return <- ["/a\\b", "/\t/x", "/x\ny", "/x\r", "/x y", "/ä"] do
      assert redirected_to(get(build_conn(), ~p"/language/vi?#{[return: return]}")) == "/"
    end

    assert redirected_to(get(build_conn(), ~p"/language/vi?#{[return: "/van?id=i3&item=i9"]}")) ==
             "/van?id=i3&item=i9"

    # The cookie is Secure on https.
    secure = get(build_conn(), "https://localhost/language/es?return=%2F")
    assert %{secure: true} = secure.resp_cookies["diy_language"]
    refute changed.resp_cookies["diy_language"][:secure]

    assert redirected_to(get(build_conn(), ~p"/language/vi?#{[return: "/inside?item=i1"]}")) ==
             "/inside?item=i1"
  end

  property "the link of a language goes back to a path of the app, or to /" do
    check all(return <- one_of([string(:printable), string(:ascii), string(:utf8)])) do
      conn = get(build_conn(), "/language/vi?" <> URI.encode_query(%{"return" => return}))
      back = redirected_to(conn)
      assert back == "/" or back == return
      assert back =~ ~r/\A\/(?:[A-Za-z0-9_\/-]*)(?:\?[A-Za-z0-9_.~=&%-]*)?\z/
      refute String.starts_with?(back, "//")
    end
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

    # The notices and the button of a notice are in the language of the
    # page. A notice from a script of the page is in English.
    render_hook(view, "usage_error", %{"error" => "The file has no rows."})
    assert has_element?(view, "#flash-error p[lang=en]", "The file has no rows.")
    assert has_element?(view, "#flash-error button[aria-label=Cerrar]")

    view |> element("#door-my-house") |> render_click()
    assert has_element?(view, "h1", "¿Dónde está la casa?")
    view |> form("#zip-form", %{"zip" => "00000"}) |> render_submit()
    assert has_element?(view, "#zip-error", "La app no conoce este código postal.")
    view |> form("#zip-form", %{"zip" => "75070"}) |> render_submit()
    assert has_element?(view, "h1", "Una casa como la mía")
    assert has_element?(view, "label[for=size-medium]", "Mediana · 1,800 pies²")
    assert has_element?(view, "label[for=age-2000s]", "De 2000 a 2009")
    render_submit(view, "preset", %{"preset" => %{"start" => "preset"}})
    assert has_element?(view, "#flash-error", "Elija uno de cada uno: el tamaño, la edad")

    render_submit(view, "preset", %{
      "preset" => %{
        "size" => "medium",
        "age" => "2000s",
        "floors" => "2",
        "heat" => "gas",
        "lot" => "abc"
      }
    })

    assert has_element?(view, "#flash-error", "Indique el terreno en pies cuadrados")
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
    assert has_element?(view, "#start-preset", "Bắt đầu từ nhà mẫu này")
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
    # The weather and the prices of the ZIP code change the build. The
    # status waits for them, also on a busy computer.
    render_async(view, 5_000)
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
    in_vi = fn text -> Gettext.with_locale(DIY.Gettext, "vi", fn -> DIY.Gettext.t(text) end) end
    assert in_vi.(DIY.Prices.price(%{price: 12.0}).source) == "giá do bạn nhập"

    assert in_vi.(DIY.Prices.price(%{price: nil, market: nil, zip: "75070"}).source) =~
             "giá trung bình cho hộ gia đình ở Texas"

    # A value that is a key is translated too.
    assert in_vi.(DIY.Prices.price(%{price: nil, market: nil, zip: "00601"}).source) =~
             "Hoa Kỳ"

    in_es =
      Gettext.with_locale(DIY.Gettext, "es", fn ->
        DIY.Gettext.t(DIY.Prices.gas(%{zip: "10001"}).source)
      end)

    assert in_es =~ "los hogares de EE. UU."

    # In English, for a page that is not translated yet.
    assert Gettext.with_locale(DIY.Gettext, "vi", fn ->
             DIY.Gettext.en(DIY.Prices.price(%{price: 12.0}).source)
           end) == "the price that you gave"
  end

  test "the pages that are not translated yet are in English, with lang=en", %{conn: conn} do
    {house, rooms, items} =
      DIY.House.preset(%{size: 1800, year: 2005, floors: 2, heat: "gas", lot: nil})

    {:ok, build} = Build.choose_door(Build.new(), "my_house")
    {:ok, build} = Build.set_zip(build, "75070")
    build = Build.put_house(build, house, rooms, items)
    es = put_req_cookie(conn, "diy_language", "es")

    for path <- [~p"/", ~p"/inside", ~p"/estimate", ~p"/power", ~p"/plans"] do
      view = open(es, path, build)
      html = render(view)
      assert has_element?(view, "div[lang=en].contents"), path
      # The sources of the prices are in English there.
      refute html =~ "la mediana", path
      refute html =~ "los hogares de", path
    end

    view = open(es, ~p"/", build)

    assert render(view) =~
             "These numbers come from a line through the bills of the homes of Texas"

    # Settings is in Spanish, with the card of Home Assistant in English.
    view = open(es, ~p"/settings", build)
    refute has_element?(view, "div[lang=en].contents")
    assert has_element?(view, "#home-assistant-card[lang=en]")
    render_submit(view, "price", %{"price" => "abc"})
    assert has_element?(view, "#flash-error", "Indique el precio en centavos por un kWh")
    render_submit(view, "house", %{"house" => %{"size" => "1"}})

    assert has_element?(
             view,
             "#flash-error",
             "Indique números dentro de los límites de cada campo."
           )

    # A build of a newer version: the notice of the device is in Spanish.
    {:ok, view, _html} = live(es, ~p"/")
    render_hook(view, "device:restore", %{"text" => ~s({"version": 99}), "stamp" => "s1"})
    assert has_element?(view, "#flash-error", "viene de una versión más nueva de la app")

    # The page of the sign-in of Home Assistant.
    html = es |> get(~p"/ha/sign-in") |> html_response(200)
    assert html =~ ~r/<html[^>]* lang="es"/
    assert html =~ ~r/<section[^>]* id="ha-sign-in" lang="en"/
  end

  test "the page keeps the language of its first render after a reconnect", %{conn: conn} do
    # The language is in the signed session of the LiveView, not in the
    # cookie session: the socket mounts with the language of the HTML.
    first = conn |> put_req_cookie("diy_language", "es") |> get(~p"/")
    {:ok, view, _html} = live(first)
    render_hook(view, "device:restore", %{"stamp" => "s0"})
    assert has_element?(view, "h1", "Encuentre su próximo pequeño paso")
  end

  test "a LiveView with no language in its session is in English" do
    socket = %Phoenix.LiveView.Socket{}
    assert {:cont, %{assigns: %{locale: "en"}}} = Locale.on_mount(:default, %{}, %{}, socket)

    assert {:cont, %{assigns: %{locale: "en"}}} =
             Locale.on_mount(:default, %{}, %{"locale" => "fr"}, socket)

    assert {:cont, %{assigns: %{locale: "vi"}}} =
             Locale.on_mount(:default, %{}, %{"locale" => "vi"}, socket)
  end

  # The messages of a file of translations: {msgid, [msgstr], flags, keys}.
  # The keys of a plural message are the keys of its plural form, and
  # "count".
  defp messages(path) do
    {:ok, po} = Expo.PO.parse_file(path)

    for m <- po.messages do
      case m do
        %Expo.Message.Singular{} ->
          id = IO.iodata_to_binary(m.msgid)
          {id, [IO.iodata_to_binary(m.msgstr)], m.flags, keys(id)}

        %Expo.Message.Plural{} ->
          id = IO.iodata_to_binary(m.msgid)
          plural = IO.iodata_to_binary(m.msgid_plural)
          strs = m.msgstr |> Enum.sort() |> Enum.map(fn {_n, str} -> IO.iodata_to_binary(str) end)
          {id, strs, m.flags, Enum.uniq(keys(plural) ++ ["count"]) |> Enum.sort()}
      end
    end
  end

  # The texts that are the same in each language: names and units.
  @same ~w(Gas Home\ Assistant)

  defp keys(text), do: ~r/%\{(\w+)\}/ |> Regex.scan(text) |> Enum.map(&List.last/1) |> Enum.sort()

  test "each text has its translation in Spanish and in Vietnamese, with the same keys" do
    pot = for {id, _strs, _flags, _keys} <- messages("priv/gettext/default.pot"), do: id
    assert length(pot) > 100

    for locale <- ~w(es vi) do
      po = messages("priv/gettext/#{locale}/LC_MESSAGES/default.po")
      assert Enum.map(po, &elem(&1, 0)) |> Enum.sort() == Enum.sort(pot), locale

      for {id, strs, flags, id_keys} <- po, str <- strs do
        assert str != "", "#{locale}: no translation of #{inspect(id)}"
        # A translation is not the English text, except a name.
        assert str != id or id in @same, "#{locale}: #{inspect(id)} is not translated"
        assert keys(str) -- id_keys == [], "#{locale}: the keys of #{inspect(id)}"
        refute "fuzzy" in List.flatten(flags), "#{locale}: #{inspect(id)} is fuzzy"
      end

      # A singular text has all its keys.
      for {id, [str], _flags, id_keys} <- po, do: assert(keys(str) == id_keys, inspect(id))
    end
  end
end
