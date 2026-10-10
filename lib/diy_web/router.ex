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

    live_session :build, on_mount: [DIYWeb.Device, DIYWeb.HomeAssistant] do
      live "/", HomeLive, :front
      live "/inside", HomeLive, :inside
      live "/estimate", HomeLive, :estimate
      live "/power", HomeLive, :power
      live "/plans", HomeLive, :plans
      live "/van", HomeLive, :van
      live "/settings", HomeLive, :settings
    end
  end
end
