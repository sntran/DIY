defmodule DIYWeb.AboutController do
  @moduledoc """
  The page About (`/about`): who made the app, what it costs, what it does
  with the data of a person, and where its numbers come from. It is a
  plain page: it needs no build and no script.
  """
  use Phoenix.Controller, formats: [:html]
  use Gettext, backend: DIY.Gettext

  def show(conn, _params) do
    # The plug of the language gives the language of the page
    # (`DIYWeb.Locale`). A page of a controller sets it for Gettext.
    Gettext.put_locale(DIY.Gettext, conn.assigns.locale)
    render(conn, :show, page_title: gettext("About Small Steps Home"))
  end
end
