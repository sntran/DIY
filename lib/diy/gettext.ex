defmodule DIY.Gettext do
  @moduledoc """
  The texts of the pages in English, Spanish and Vietnamese. The English
  text is the key (`msgid`): it is in ASD-STE100 Simplified Technical
  English. The files of the translations are in `priv/gettext`
  (`mix gettext.extract --merge`).

  A module of the pages uses the macros of Gettext (`gettext/1`,
  `ngettext/3`) with `use Gettext, backend: DIY.Gettext`
  (`DIYWeb.html/0`). A text of the core is a key with `gettext_noop/1`,
  or a key and its values (`{key, values}`). An example is a label of a
  kind of house. The page translates it when it shows it (`t/1`). A
  page that is not translated yet shows it in English (`en/1`). The
  locale of a page comes from `DIYWeb.Locale`.
  """
  use Gettext.Backend, otp_app: :diy

  @typedoc "A text of the core: a key, or a key and its values."
  @type text :: String.t() | {String.t(), keyword()}

  @doc """
  A text of the core in the language of the page. A value that is a text
  of the core is translated too.
  """
  @spec t(text()) :: String.t()
  def t({key, values}), do: Gettext.gettext(__MODULE__, key, Map.new(values, &value/1))
  def t(key) when is_binary(key), do: Gettext.gettext(__MODULE__, key)

  defp value({name, {key, _values} = text}) when is_binary(key), do: {name, t(text)}
  defp value(pair), do: pair

  @doc "A text of the core in English, for a page that is not translated yet."
  @spec en(text()) :: String.t()
  def en(text), do: Gettext.with_locale(__MODULE__, "en", fn -> t(text) end)
end
