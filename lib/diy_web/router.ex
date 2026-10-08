defmodule DIYWeb.Router do
  use DIYWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DIYWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", DIYWeb do
    pipe_through :browser

    live_session :build, on_mount: DIYWeb.Device do
      live "/", HomeLive
    end
  end
end
