defmodule DIYWeb.SignInLive do
  @moduledoc """
  The sign-in page of Home Assistant, in its own tab (`/ha/sign-in`). The
  key Connect of a hub, or of Settings, opens it with the address of Home
  Assistant. Its hook `HomeAssistantSignIn` (`SignIn` in
  `assets/js/home_assistant.js`) goes to the sign-in page of Home
  Assistant, and Home Assistant sends the tab back here with a code. The
  hook gets the tokens, and keeps them on the device. Then it tells the
  first tab, and closes this tab. The page shows the state of the
  sign-in (the assign `:ha` of `DIYWeb.HomeAssistant`), and an error.
  """
  use DIYWeb, :live_view

  alias DIYWeb.{HomeAssistant, Layouts}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, :page_title, "Sign in to Home Assistant")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="ha-sign-in" phx-hook="HomeAssistantSignIn" class="space-y-3">
        <h1 class="text-xl font-bold">Sign in to Home Assistant</h1>
        <p id="ha-status" role="status" class="text-sm font-medium">
          {HomeAssistant.tab_status(@ha)}
        </p>
        <p :if={@ha.error} id="ha-error" role="alert" class="text-sm text-error">
          {HomeAssistant.tab_message(@ha.error)}
        </p>
        <p :if={@ha.state in ~w(none done)} id="ha-close" class="text-sm">
          You can close this tab. The page of the app shows the link to Home Assistant.
        </p>
      </section>
    </Layouts.app>
    """
  end
end
