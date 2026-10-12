defmodule DIY.Gettext do
  @moduledoc """
  The texts of the pages in English, Spanish and Vietnamese. The English
  text is the key (`msgid`): it is in ASD-STE100 Simplified Technical
  English. The files of the translations are in `priv/gettext`
  (`mix gettext.extract --merge`).

  A module of the pages uses the macros of Gettext (`gettext/1`,
  `ngettext/3`) with `use Gettext, backend: DIY.Gettext`
  (`DIYWeb.html/0`). A text of the core (for example a label of a kind of
  house) is a key with `gettext_noop/1`. The page translates it when it
  shows it (`t/1`). The locale of a page comes from `DIYWeb.Locale`.
  """
  use Gettext.Backend, otp_app: :diy

  @doc "A text of the core (a key of `gettext_noop/1`) in the language of the page."
  def t(text), do: Gettext.gettext(__MODULE__, text)
end
