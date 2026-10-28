defmodule DIYWeb.AboutController do
  @moduledoc """
  The page About (`/about`). It tells who made the app, what it costs,
  what it does with the data of a person, and where its numbers come
  from. It is a plain page: it needs no build and no script.
  """
  use Phoenix.Controller, formats: [:html]
  use Gettext, backend: DIY.Gettext

  def show(conn, _params) do
    # The plug of the language set the language of the texts
    # (`DIYWeb.Locale`).
    render(conn, :show, page_title: gettext("About Small Steps Home"))
  end
end
