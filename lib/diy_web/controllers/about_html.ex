defmodule DIYWeb.AboutHTML do
  @moduledoc """
  The page About (`DIYWeb.AboutController`). A neighbor can read it before
  the neighbor tries the app. It tells what the app does, who made it,
  and what it does with the data of a person. A change to the data of the
  app must change this page too.
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
              {gettext(
                "You need no account. The app asks for no name, no email, no password and no street address."
              )}
            </li>
            <li>
              {gettext(
                "Your house is saved only in the browser of this device. The server uses it while the page is open, but it does not save it."
              )}
            </li>
            <li>
              {gettext(
                "When you share a house, the link holds the house and the months of your meter. It holds the ZIP code too, if you keep it."
              )}
              {gettext("Anyone with the link can see them.")}
            </li>
            <li>
              {gettext(
                "Only a short link makes the server save a copy of the house. The server keeps it for one year after the last visit of the link."
              )}
              {gettext("The copy is locked with a key that only the link has.")}
            </li>
            <li>
              {gettext(
                "The app reads the file of your smart meter and the PDF of a plan on this device. Only the sums of each month, and the text of the plan, go to the server."
              )}
            </li>
            <li>
              {gettext(
                "For the weather, the server sends a point near your ZIP code to NASA POWER and to Open-Meteo."
              )}
            </li>
            <li>
              {gettext(
                "For a ZIP code in Texas, the server sends the ZIP code to Power to Choose, for the prices of the plans."
              )}
            </li>
            <li>
              {gettext(
                "The app saves your keys for Home Assistant and for the maker of a power station only on this device."
              )}
              {gettext(
                "For Pecron, each request goes through the server, which does not keep the key."
              )}
            </li>
            <li>
              {gettext(
                "The app runs on Cloudflare. It sets a cookie for the safety of its forms, and a cookie for the language that you choose."
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
              "The price is the price that you give. Else, in Texas, it is the median of the plans on Power to Choose."
            )}
            {gettext(
              "Else it is the average of your state from the US Energy Information Administration."
            )}
          </p>
          <p>
            {gettext(
              "The worksheet of the plans reads the Electricity Facts Label (EFL) of each plan."
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
            {gettext("Do you have a question, or did you find a problem?")}
            <a id="about-issues-link" href={@code <> "/issues"} class="link">{gettext("Open an issue on GitHub")}</a>. {gettext(
              "An issue is public, and it needs a GitHub account."
            )}
          </p>
        </section>

        <a id="about-start" href={~p"/"} class="btn btn-primary">{gettext("Go to the app")}</a>
      </article>
    </Layouts.app>
    """
  end
end
