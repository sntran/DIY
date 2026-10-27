defmodule DIYWeb.Router do
  use DIYWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug DIYWeb.Locale
    plug :fetch_live_flash
    plug :put_root_layout, html: {DIYWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # The relay to the cloud of the maker of a power station
  # (DIYWeb.RelayController): no session, no cookie.
  pipeline :relay do
    plug :accepts, ["json"]
  end

  scope "/relay", DIYWeb do
    pipe_through :relay

    get "/pecron/stations", RelayController, :pecron_stations
    post "/pecron/command/:id", RelayController, :pecron_command
  end

  # The picture of a shared house, for the preview of its link
  # (DIYWeb.PictureController): no session, no cookie. A site that reads
  # the picture can send any Accept field, so the scope has no pipeline.
  scope "/s", DIYWeb do
    get "/:data/picture.png", PictureController, :show
  end

  # The picture of a link of plans (DIY.PlanLink), in the same way.
  scope "/p", DIYWeb do
    get "/:data/picture.png", PictureController, :plans
  end

  scope "/", DIYWeb do
    pipe_through :browser

    # The language that the person chooses (DIYWeb.Locale). It is a link:
    # it needs no script.
    get "/language/:locale", LanguageController, :update

    # The signed session keeps the language of the first render
    # (DIYWeb.Locale.live_session/1).
    live_session :build,
      session: {DIYWeb.Locale, :live_session, []},
      on_mount: [DIYWeb.Locale, DIYWeb.Device, DIYWeb.HomeAssistant, DIYWeb.MakerLink] do
      live "/", HomeLive, :front
      live "/inside", HomeLive, :inside
      live "/estimate", HomeLive, :estimate
      live "/power", HomeLive, :power
      live "/plans", HomeLive, :plans
      live "/van", HomeLive, :van
      live "/settings", HomeLive, :settings
      # The page of the link of a shared house (DIY.Share).
      live "/s/:data", HomeLive, :shared
      # The page of a link of plans to compare (DIY.PlanLink).
      live "/p/:data", HomeLive, :plan_link
    end

    # The sign-in page of Home Assistant, in its own tab: it needs no build.
    live_session :sign_in,
      session: {DIYWeb.Locale, :live_session, []},
      on_mount: [DIYWeb.Locale, {DIYWeb.HomeAssistant, :sign_in}] do
      live "/ha/sign-in", SignInLive
    end
  end
end
