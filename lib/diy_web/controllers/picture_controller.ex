defmodule DIYWeb.PictureController do
  @moduledoc """
  The picture of a shared house (`DIYWeb.Picture`), for the preview of
  its link: `/s/DATA/picture.png`, or `/s/ID/picture.png` for a short
  link (`DIY.Links`). The picture is in the language of the link. The
  server keeps no copy of the house of a long link (docs/design.md, "The
  link").
  """
  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias DIY.Share
  alias DIYWeb.Picture

  def show(conn, %{"data" => data}) do
    with {:ok, build, summary} <- Share.resolve(data),
         {:ok, png} <-
           Gettext.with_locale(DIY.Gettext, summary.locale, fn -> Picture.png(build, summary) end) do
      conn
      # The picture of a long link never changes. A short link ends, so
      # its picture stays in a cache for one day only.
      |> put_resp_header("cache-control", cache(data))
      |> put_resp_content_type("image/png", nil)
      |> send_resp(200, png)
    else
      {:error, _reason} -> send_resp(conn, 404, "")
    end
  end

  defp cache(data) do
    if DIY.Links.id?(data),
      do: "public, max-age=86400",
      else: "public, max-age=31536000, immutable"
  end
end
