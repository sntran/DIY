defmodule DIYWeb.PictureController do
  @moduledoc """
  The picture of a shared house (`DIYWeb.Picture`), for the preview of
  its link: `/s/DATA/picture.png`. The picture is in the language of the
  link. The server keeps no copy of the house (docs/design.md, "The
  link").
  """
  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias DIY.Share
  alias DIYWeb.Picture

  def show(conn, %{"data" => data}) do
    with {:ok, build, summary} <- Share.decode(data),
         {:ok, png} <-
           Gettext.with_locale(DIY.Gettext, summary.locale, fn -> Picture.png(build, summary) end) do
      conn
      # The picture of a link never changes.
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_content_type("image/png", nil)
      |> send_resp(200, png)
    else
      {:error, _reason} -> send_resp(conn, 404, "")
    end
  end
end
