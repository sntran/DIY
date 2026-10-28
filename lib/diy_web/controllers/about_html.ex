defmodule DIYWeb.AboutHTML do
  @moduledoc """
  The page About (`DIYWeb.AboutController`). A neighbor can read it before
  the neighbor tries the app: what the app does, who made it, and what
  it does with the data of a person. A change to the data of the app
  must change this page too.
  """
  use DIYWeb, :html

  # The person who made the app, and the place of its code.
  @maker "Sơn Trần-Nguyễn"
  @code "https://github.com/sntran/DIY"

  @doc "The page About."
  attr :flash, :map, required: true, doc: "the flash notices"
  attr :locale, :string, required: true, doc: "the language of the page"

  def show(assigns) do
    # A page of a controller: its assigns are a plain map.
    assigns = Map.merge(assigns, %{maker: @maker, code: @code})

    ~H"""
    <Layouts.app flash={@flash} about={false}>
      <article id="about" class="space-y-6">
        <DIYWeb.Start.languages locale={@locale} return="/about" />
        <h1 class="text-2xl font-bold">{gettext("About Small Steps Home")}</h1>
        <p>
          {gettext(
            "Small Steps Home shows where the power of a house goes. Then it helps you find your next small step."
          )}
        </p>
        <p>
          {gettext(
            "A small step can be a better plan for your electricity, a change to an item, or a power station for an outage."
          )}
        </p>

        <section id="about-who" aria-labelledby="about-who-title" class="space-y-2">
          <h2 id="about-who-title" class="text-lg font-bold">{gettext("Who made it")}</h2>
          <p>{gettext("%{name} made this app.", name: @maker)}</p>
          <p>{gettext("The app is free. It has no ads, and it sells nothing.")}</p>
        </section>

        <section id="about-data" aria-labelledby="about-data-title" class="space-y-2">
          <h2 id="about-data-title" class="text-lg font-bold">{gettext("Your data")}</h2>
          <ul class="list-disc space-y-1 pl-5">
            <li>
              {gettext("You need no account. The app asks for no name, no email and no password.")}
            </li>
            <li>
              {gettext("Your house stays in the browser of this device. The server keeps no copy.")}
            </li>
            <li>
              {gettext(
                "A short link to share a house is the one exception. The server keeps a copy of the house for one year after the last visit of the link."
              )}
              {gettext("The copy is locked with a key that only the link has.")}
            </li>
            <li>
              {gettext(
                "For the weather, the server sends a point near your ZIP code to NASA POWER and to Open-Meteo. It does not send your address."
              )}
            </li>
            <li>
              {gettext(
                "The keys of your links to Home Assistant and to the maker of a power station stay on this device. The server does not keep them."
              )}
            </li>
          </ul>
        </section>

        <section id="about-numbers" aria-labelledby="about-numbers-title" class="space-y-2">
          <h2 id="about-numbers-title" class="text-lg font-bold">
            {gettext("Where the numbers come from")}
          </h2>
          <p>
            {gettext(
              "The bill is an estimate from the weather of your place and the items of your house. It is a range, not one number."
            )}
          </p>
          <p>
            {gettext(
              "The prices come from public data: the US Energy Information Administration, and the Electricity Facts Labels of the plans in Texas."
            )}
          </p>
        </section>

        <section id="about-code" aria-labelledby="about-code-title" class="space-y-2">
          <h2 id="about-code-title" class="text-lg font-bold">{gettext("The code")}</h2>
          <p>
            {gettext("The code of the app is public. Anyone can read how it works.")}
            <a id="about-code-link" href={@code} class="link">github.com/sntran/DIY</a>
          </p>
          <p>
            {gettext("To ask a question or to tell about a problem, open an issue on GitHub.")}
            <a id="about-issues-link" href={@code <> "/issues"} class="link">
              {gettext("The issues of the app")}
            </a>
          </p>
        </section>

        <a id="about-start" href={~p"/"} class="btn btn-primary">{gettext("Go to the app")}</a>
      </article>
    </Layouts.app>
    """
  end
end
