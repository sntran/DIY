defmodule DIYWeb.Start do
  @moduledoc """
  The first steps of a new build: the two doors, the ZIP code, and "a house
  like mine" (a preset). After the preset, the user is in front of the
  house, with a bill estimate (`DIYWeb.Front`).
  """
  use DIYWeb, :html

  alias DIY.{Build, House}
  alias DIYWeb.Scene

  @doc "The two doors of the first screen, and the links of the languages."
  attr :locale, :string, default: "en", doc: "the language of the page"

  def doors(assigns) do
    ~H"""
    <section class="space-y-4">
      <.languages locale={@locale} return="/" />
      <h1 class="text-2xl font-bold">{gettext("Find your next small step")}</h1>
      <p>
        {gettext(
          "Build a model of your house. See your power bill at once, and then see what each change does."
        )}
      </p>
      <div class="grid gap-4 sm:grid-cols-2">
        <button
          id="door-my-house"
          type="button"
          phx-click="door"
          phx-value-door="my_house"
          class="card card-border bg-base-200 overflow-hidden text-left hover:bg-base-300"
        >
          <Scene.sample id="door-house" />
          <span class="px-6 pt-4 text-lg font-semibold">{gettext("My house")}</span>
          <span class="px-6 pb-5 text-sm opacity-80">{gettext("I live in the house now.")}</span>
        </button>
        <button
          id="door-planning"
          type="button"
          phx-click="door"
          phx-value-door="planning"
          class="card card-border bg-base-200 overflow-hidden text-left hover:bg-base-300"
        >
          <Scene.sample id="door-plan" plan />
          <span class="px-6 pt-4 text-lg font-semibold">{gettext("A house I'm planning")}</span>
          <span class="px-6 pb-5 text-sm opacity-80">
            {gettext("I look at a lot or a new build.")}
          </span>
        </button>
      </div>
      <p class="text-sm opacity-80">
        {gettext("Your build stays on this device. The server keeps no copy.")}
      </p>
    </section>
    """
  end

  attr :locale, :string, required: true, doc: "the language of the page"
  attr :return, :string, required: true, doc: "the page after the change"
  attr :title, :boolean, default: false, doc: "show the title Language"

  @doc """
  The links of the languages. Each name is in its own language (`lang`),
  so a screen reader reads it well. The language of the page is the
  current one.
  """
  def languages(assigns) do
    ~H"""
    <nav id="languages" aria-label={gettext("Language")}>
      <h2 :if={@title} class="text-lg font-bold mb-2">{gettext("Language")}</h2>
      <ul class="flex flex-wrap gap-2">
        <li :for={{key, name} <- DIYWeb.Locale.names()}>
          <a
            id={"language-#{key}"}
            href={~p"/language/#{key}?#{[return: @return]}"}
            lang={key}
            hreflang={key}
            aria-current={key == @locale && "true"}
            class={["btn btn-sm", if(key == @locale, do: "btn-primary", else: "btn-ghost")]}
          >
            {name}
          </a>
        </li>
      </ul>
    </nav>
    """
  end

  @doc "The ZIP code of the house."
  attr :build, Build, required: true
  attr :error, :string, default: nil
  attr :typed, :string, default: nil, doc: "the text that the person typed, after an error"

  def zip(assigns) do
    ~H"""
    <section class="space-y-4">
      <p class="text-sm opacity-70">{gettext("Step 1 of 2")}</p>
      <h1 class="text-2xl font-bold">{gettext("Where is the house?")}</h1>
      <p>
        {gettext(
          "The ZIP code gives the weather history of the place and the price of power. It stays on this device."
        )}
      </p>
      <form id="zip-form" phx-submit="zip" class="flex gap-2">
        <label for="zip" class="sr-only">{gettext("ZIP code")}</label>
        <input
          id="zip"
          name="zip"
          type="text"
          inputmode="numeric"
          autocomplete="postal-code"
          maxlength="5"
          placeholder="75070"
          value={@typed}
          class={["input input-lg w-40", @error && "input-error"]}
          aria-invalid={@error && "true"}
          aria-describedby={@error && "zip-error"}
          required
        />
        <button type="submit" class="btn btn-primary btn-lg">{gettext("Next")}</button>
      </form>
      <p :if={@error} id="zip-error" role="alert" class="text-error">{@error}</p>
      <button type="button" phx-click="restart" class="btn btn-ghost btn-sm">
        {gettext("Back")}
      </button>
    </section>
    """
  end

  @doc """
  The preset of the house: "a house like mine" for my house, or the lot and
  a preset (or nothing) for a house I'm planning.
  """
  attr :build, Build, required: true

  def preset(assigns) do
    ~H"""
    <section class="space-y-4">
      <p class="text-sm opacity-70">{gettext("Step 2 of 2")}</p>
      <%= if @build.door == "planning" do %>
        <h1 class="text-2xl font-bold">{gettext("The lot and the house")}</h1>
        <p>
          {gettext(
            "Give the size of the lot, if you know it. Then start from a house like the one that you plan, or from nothing."
          )}
        </p>
      <% else %>
        <h1 class="text-2xl font-bold">{gettext("A house like mine")}</h1>
        <p>
          {gettext("Choose the house that is most like yours. You can change each number later.")}
        </p>
      <% end %>

      <form id="preset-form" phx-submit="preset" class="space-y-5">
        <div :if={@build.door == "planning"}>
          <label for="lot" class="font-semibold">
            {gettext("The size of the lot (square feet)")}
          </label>
          <input
            id="lot"
            name="preset[lot]"
            type="text"
            inputmode="numeric"
            placeholder="8000"
            class="input w-40 block mt-1"
          />
          <p class="text-sm opacity-70">{gettext("One acre is 43,560 square feet.")}</p>
        </div>

        <fieldset>
          <legend class="font-semibold mb-2">{gettext("The size of the house")}</legend>
          <div class="flex flex-wrap gap-2">
            <label
              :for={{key, label, sqft} <- House.sizes()}
              for={"size-#{key}"}
              class="btn btn-outline has-[:checked]:bg-primary has-[:checked]:border-primary has-[:checked]:text-primary-content"
            >
              <input
                id={"size-#{key}"}
                type="radio"
                name="preset[size]"
                value={key}
                class="sr-only"
                required
              />
              {gettext("%{size} · %{area} sq ft",
                size: DIY.Gettext.t(label),
                area: DIYWeb.Format.int(sqft)
              )}
            </label>
          </div>
        </fieldset>

        <fieldset :if={@build.door == "my_house"}>
          <legend class="font-semibold mb-2">{gettext("The year that the house was built")}</legend>
          <div class="flex flex-wrap gap-2">
            <label
              :for={{key, label, _year} <- House.ages()}
              for={"age-#{key}"}
              class="btn btn-outline has-[:checked]:bg-primary has-[:checked]:border-primary has-[:checked]:text-primary-content"
            >
              <input
                id={"age-#{key}"}
                type="radio"
                name="preset[age]"
                value={key}
                class="sr-only"
                required
              />
              {DIY.Gettext.t(label)}
            </label>
          </div>
        </fieldset>

        <fieldset>
          <legend class="font-semibold mb-2">{gettext("Floors")}</legend>
          <div class="flex flex-wrap gap-2">
            <label
              :for={floors <- 1..3}
              for={"floors-#{floors}"}
              class="btn btn-outline has-[:checked]:bg-primary has-[:checked]:border-primary has-[:checked]:text-primary-content"
            >
              <input
                id={"floors-#{floors}"}
                type="radio"
                name="preset[floors]"
                value={floors}
                class="sr-only"
                required
              />
              {floors}
            </label>
          </div>
        </fieldset>

        <fieldset>
          <legend class="font-semibold mb-2">{gettext("Heat")}</legend>
          <div class="grid gap-2">
            <label
              :for={{key, label, text} <- House.heats()}
              for={"heat-#{key}"}
              class="card card-border p-3 cursor-pointer has-[:checked]:border-primary has-[:checked]:bg-base-200"
            >
              <span class="flex items-center gap-2">
                <input
                  id={"heat-#{key}"}
                  type="radio"
                  name="preset[heat]"
                  value={key}
                  class="radio radio-sm"
                  required
                />
                <span class="font-semibold">{DIY.Gettext.t(label)}</span>
              </span>
              <span class="text-sm opacity-80">{DIY.Gettext.t(text)}</span>
            </label>
          </div>
        </fieldset>

        <div class="flex flex-wrap gap-2">
          <button
            id="start-preset"
            type="submit"
            name="preset[start]"
            value="preset"
            class="btn btn-primary btn-lg h-auto min-h-12 whitespace-normal"
          >
            {if @build.door == "planning",
              do: gettext("Start from a house like this"),
              else: gettext("See my house")}
          </button>
          <button
            :if={@build.door == "planning"}
            id="start-scratch"
            type="submit"
            name="preset[start]"
            value="scratch"
            class="btn btn-lg h-auto min-h-12 whitespace-normal"
          >
            {gettext("Start from nothing")}
          </button>
        </div>
      </form>
    </section>
    """
  end
end
