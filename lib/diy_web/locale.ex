defmodule DIYWeb.Locale do
  @moduledoc """
  The language of the pages: English (`"en"`), Spanish (`"es"`) or
  Vietnamese (`"vi"`).

  The choice of the person is a cookie of the browser (`diy_language`),
  for one year: it stays on the device, as the build does. With no choice,
  the language comes from the header Accept-Language of the browser, else
  it is English.

  - As a plug, it puts the language in the session, and in the assigns of
    the connection for the attribute `lang` of the page. It also sets it
    for the texts of the first render.
  - As a hook of a LiveView (`on_mount/4`), it sets the language of the
    process from the session, and puts it in the assigns.
  - `update/2` keeps the choice of the person (a link on the first screen
    or on the page Settings), and goes back to the page. A change of a
    language does no harm, so the link needs no token of the session.
  """
  import Plug.Conn

  @locales ~w(en es vi)
  @cookie "diy_language"
  @year 365 * 24 * 60 * 60

  @doc "The languages, with their names in their own language."
  def names, do: [{"en", "English"}, {"es", "Español"}, {"vi", "Tiếng Việt"}]

  @doc "The languages of the app."
  def locales, do: @locales

  @doc """
  The best language of the app for a header Accept-Language, or nil. A
  language with a larger weight (`q`) comes first. A region (for example
  `es-MX`) counts as its language.
  """
  @spec from_header(String.t() | nil) :: String.t() | nil
  def from_header(nil), do: nil

  def from_header(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.take(20)
    |> Enum.with_index()
    |> Enum.flat_map(&weighted/1)
    |> Enum.sort_by(fn {_tag, q, index} -> {-q, index} end)
    |> Enum.find_value(fn {tag, _q, _index} -> if tag in @locales, do: tag end)
  end

  defp weighted({part, index}) do
    [tag | params] = part |> String.trim() |> String.split(";")
    base = tag |> String.split("-") |> hd() |> String.downcase()

    case weight(params) do
      q when q > 0 -> [{base, q, index}]
      _zero -> []
    end
  end

  defp weight(params) do
    Enum.find_value(params, 1.0, fn param ->
      with "q=" <> value <- String.trim(param),
           {q, ""} <- Float.parse(value) do
        q
      else
        _other -> nil
      end
    end)
  end

  @doc "The language of a connection: the cookie, else the header, else English."
  def of_conn(conn) do
    cookie = conn.cookies[@cookie]

    cond do
      cookie in @locales -> cookie
      lang = conn |> get_req_header("accept-language") |> List.first() |> from_header() -> lang
      true -> "en"
    end
  end

  ## The plug

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    locale = of_conn(conn)
    Gettext.put_locale(DIY.Gettext, locale)

    conn
    |> put_session("locale", locale)
    |> assign(:locale, locale)
  end

  ## The hook of a LiveView

  def on_mount(:default, _params, session, socket) do
    locale = if session["locale"] in @locales, do: session["locale"], else: "en"
    Gettext.put_locale(DIY.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  ## The choice of the person

  @doc """
  Keeps the language that the person chooses (`locale`) in a cookie, and
  goes back to the page (`return`, a path of the app). A language that the
  app does not have changes nothing.
  """
  def update(conn, params) do
    locale = params["locale"]
    back = back(params["return"])

    conn =
      if locale in @locales,
        do: put_resp_cookie(conn, @cookie, locale, max_age: @year, same_site: "Lax"),
        else: conn

    conn
    |> Phoenix.Controller.redirect(to: back)
  end

  # Only a path of the app: it starts with one "/", and it is not a
  # different site ("//" or "/\\").
  defp back("/" <> rest = path) when byte_size(path) <= 200 do
    if String.starts_with?(rest, ["/", "\\"]), do: "/", else: path
  end

  defp back(_return), do: "/"
end
