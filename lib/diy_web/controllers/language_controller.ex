defmodule DIYWeb.LanguageController do
  @moduledoc """
  The links of the languages (on the first screen and on the page
  Settings) come here (`DIYWeb.Locale.update/2`).
  """
  use Phoenix.Controller, formats: [:html]

  def update(conn, params), do: DIYWeb.Locale.update(conn, params)
end
