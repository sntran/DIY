defmodule DIYWeb.Start do
  @moduledoc """
  The first steps of a new build: the two doors, the ZIP code, and "a house
  like mine" (a preset). After the preset, the user is in front of the
  house, with a bill estimate (`DIYWeb.Front`).
  """
  use DIYWeb, :html

  alias DIY.{Build, House}

  @doc "The two doors of the first screen."
  def doors(assigns) do
    ~H"""
    <section class="space-y-4">
      <h1 class="text-2xl font-bold">Find your next small step</h1>
      <p>
        Build a model of your house. See your power bill at once, and then see what each change does.
      </p>
      <div class="grid gap-4 sm:grid-cols-2">
        <button
          id="door-my-house"
          type="button"
          phx-click="door"
          phx-value-door="my_house"
          class="card card-border bg-base-200 p-6 text-left hover:bg-base-300"
        >
          <span class="text-4xl" aria-hidden="true">🏠</span>
          <span class="text-lg font-semibold">My house</span>
          <span class="text-sm opacity-80">I live in the house now.</span>
        </button>
        <button
          id="door-planning"
          type="button"
          phx-click="door"
          phx-value-door="planning"
          class="card card-border bg-base-200 p-6 text-left hover:bg-base-300"
        >
          <span class="text-4xl" aria-hidden="true">📐</span>
          <span class="text-lg font-semibold">A house I'm planning</span>
          <span class="text-sm opacity-80">I look at a lot or a new build.</span>
        </button>
      </div>
      <p class="text-sm opacity-80">Your build stays on this device. The server keeps no copy.</p>
    </section>
    """
  end

  @doc "The ZIP code of the house."
  attr :build, Build, required: true
  attr :error, :string, default: nil

  def zip(assigns) do
    ~H"""
    <section class="space-y-4">
      <p class="text-sm opacity-70">Step 1 of 2</p>
      <h1 class="text-2xl font-bold">Where is the house?</h1>
      <p>
        The ZIP code gives the weather history of the place and the price of power. It stays on this device.
      </p>
      <form id="zip-form" phx-submit="zip" class="flex gap-2">
        <label for="zip" class="sr-only">ZIP code</label>
        <input
          id="zip"
          name="zip"
          type="text"
          inputmode="numeric"
          autocomplete="postal-code"
          maxlength="5"
          placeholder="75070"
          class={["input input-lg w-40", @error && "input-error"]}
          aria-describedby={@error && "zip-error"}
          required
        />
        <button type="submit" class="btn btn-primary btn-lg">Next</button>
      </form>
      <p :if={@error} id="zip-error" class="text-error">{@error}</p>
      <button type="button" phx-click="restart" class="btn btn-ghost btn-sm">Back to the doors</button>
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
      <p class="text-sm opacity-70">Step 2 of 2</p>
      <%= if @build.door == "planning" do %>
        <h1 class="text-2xl font-bold">The lot and the house</h1>
        <p>
          Give the size of the lot, if you know it. Then start from a house like the one that you plan, or from nothing.
        </p>
      <% else %>
        <h1 class="text-2xl font-bold">A house like mine</h1>
        <p>Choose the house that is most like yours. You can change each number later.</p>
      <% end %>

      <form id="preset-form" phx-submit="preset" class="space-y-5">
        <div :if={@build.door == "planning"}>
          <label for="lot" class="font-semibold">The size of the lot (square feet)</label>
          <input
            id="lot"
            name="preset[lot]"
            type="text"
            inputmode="numeric"
            placeholder="8000"
            class="input w-40 block mt-1"
          />
          <p class="text-sm opacity-70">One acre is 43,560 square feet.</p>
        </div>

        <fieldset>
          <legend class="font-semibold mb-2">The size of the house</legend>
          <div class="flex flex-wrap gap-2">
            <label
              :for={{key, label, sqft} <- House.sizes()}
              for={"size-#{key}"}
              class="btn btn-outline has-[:checked]:btn-primary has-[:checked]:text-primary-content"
            >
              <input
                id={"size-#{key}"}
                type="radio"
                name="preset[size]"
                value={key}
                class="sr-only"
                required
              />
              {label} · {DIYWeb.Format.int(sqft)} sq ft
            </label>
          </div>
        </fieldset>

        <fieldset :if={@build.door == "my_house"}>
          <legend class="font-semibold mb-2">The year that the house was built</legend>
          <div class="flex flex-wrap gap-2">
            <label
              :for={{key, label, _year} <- House.ages()}
              for={"age-#{key}"}
              class="btn btn-outline has-[:checked]:btn-primary has-[:checked]:text-primary-content"
            >
              <input
                id={"age-#{key}"}
                type="radio"
                name="preset[age]"
                value={key}
                class="sr-only"
                required
              />
              {label}
            </label>
          </div>
        </fieldset>

        <fieldset>
          <legend class="font-semibold mb-2">Floors</legend>
          <div class="flex flex-wrap gap-2">
            <label
              :for={floors <- 1..3}
              for={"floors-#{floors}"}
              class="btn btn-outline has-[:checked]:btn-primary has-[:checked]:text-primary-content"
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
          <legend class="font-semibold mb-2">Heat</legend>
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
                <span class="font-semibold">{label}</span>
              </span>
              <span class="text-sm opacity-80">{text}</span>
            </label>
          </div>
        </fieldset>

        <div class="flex flex-wrap gap-2">
          <button
            id="start-preset"
            type="submit"
            name="preset[start]"
            value="preset"
            class="btn btn-primary btn-lg"
          >
            {if @build.door == "planning", do: "Start from a house like this", else: "See my house"}
          </button>
          <button
            :if={@build.door == "planning"}
            id="start-scratch"
            type="submit"
            name="preset[start]"
            value="scratch"
            class="btn btn-lg"
          >
            Start from nothing
          </button>
        </div>
      </form>
    </section>
    """
  end
end
