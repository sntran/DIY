defmodule DIYWeb.Settings do
  @moduledoc """
  The settings of a build: the place, the utility area, the price of one
  kWh and the numbers of the house. The page also has the link to Home
  Assistant, and the file of the build (to keep it or to move it).
  """
  use DIYWeb, :html

  alias DIY.{Build, House, Zip}
  alias DIYWeb.{Format, HomeAssistant}

  attr :build, :map, required: true
  attr :price, :map, required: true
  attr :market, :map, required: true
  attr :uploads, :map, required: true
  attr :ha, :map, required: true, doc: "the link to Home Assistant (`DIYWeb.HomeAssistant`)"

  def settings(assigns) do
    {:ok, place} = Zip.lookup(assigns.build.zip)
    assigns = assign(assigns, :place, place)

    ~H"""
    <section id="settings" class="space-y-6">
      <h1 class="text-2xl font-bold">Settings</h1>

      <div class="space-y-2">
        <h2 class="text-lg font-bold">The place</h2>
        <form id="settings-zip" phx-submit="zip" class="flex gap-2 items-end">
          <label>
            <span class="text-sm">ZIP code</span>
            <input
              name="zip"
              value={@build.zip}
              inputmode="numeric"
              maxlength="5"
              class="input input-sm w-28 block"
            />
          </label>
          <button class="btn btn-sm">Change</button>
        </form>
        <p class="text-sm opacity-80">{Zip.state_name(@place.state)}</p>

        <div :if={@place.state == "TX"} id="utility" class="space-y-1 text-sm">
          <p :if={@build.market && @build.market.choice}>
            Retail choice{if @build.market.utility,
              do: ": #{@build.market.utility} delivers the power"}.
          </p>
          <p :if={@build.market && not @build.market.choice}>
            No retail choice: a city utility or a co-op sells the power.
          </p>
          <div class="flex flex-wrap gap-2">
            <button type="button" phx-click="utility" phx-value-choice="false" class="btn btn-xs">
              My utility is a city utility or a co-op
            </button>
            <button type="button" phx-click="utility" phx-value-choice="true" class="btn btn-xs">
              I choose my retail plan
            </button>
          </div>
        </div>
      </div>

      <div class="space-y-2">
        <h2 class="text-lg font-bold">The price of power</h2>
        <p class="text-sm">Now: {Format.cents(@price.cents)} for each kWh, {@price.source}.</p>
        <form id="settings-price" phx-submit="price" class="flex gap-2 items-end">
          <label>
            <span class="text-sm">Your price, in cents for one kWh (the total of the bill ÷ the kWh of the bill)</span>
            <input
              name="price"
              value={@build.price && Format.value(Float.round(@build.price, 2))}
              inputmode="decimal"
              placeholder="14.5"
              class="input input-sm w-28 block"
            />
          </label>
          <button class="btn btn-sm">Save</button>
        </form>
        <p class="text-xs opacity-70">
          Leave it empty to use the typical price. Then the app also forgets the kWh of your bill.
        </p>
        <form id="settings-night" phx-submit="power" class="space-y-2">
          <p class="text-sm">
            A plan with a different price at night (for example, free nights): the price and the hours of the night.
          </p>
          <div class="flex flex-wrap gap-2 items-end">
            <label>
              <span class="text-sm">At night (cents)</span>
              <input
                name="night_cents"
                value={@build.power.night_cents && Format.value(@build.power.night_cents)}
                inputmode="decimal"
                placeholder="none"
                class="input input-sm w-24 block"
              />
            </label>
            <label>
              <span class="text-sm">From (hour)</span>
              <input
                name="night_from"
                value={@build.power.night_from}
                inputmode="numeric"
                class="input input-sm w-20 block"
              />
            </label>
            <label>
              <span class="text-sm">To (hour)</span>
              <input
                name="night_to"
                value={@build.power.night_to}
                inputmode="numeric"
                class="input input-sm w-20 block"
              />
            </label>
            <button class="btn btn-sm">Save</button>
          </div>
          <p class="text-xs opacity-70">Leave the price empty for one price at all hours.</p>
        </form>
      </div>

      <div class="space-y-2">
        <h2 class="text-lg font-bold">The house</h2>
        <form id="settings-house" phx-submit="house" class="grid grid-cols-2 gap-2">
          <label>
            <span class="text-sm">Size (sq ft)</span>
            <input
              name="house[size]"
              value={@build.house.size}
              inputmode="numeric"
              class="input input-sm w-full"
            />
          </label>
          <label>
            <span class="text-sm">Year built</span>
            <input
              name="house[year]"
              value={@build.house.year}
              inputmode="numeric"
              class="input input-sm w-full"
            />
          </label>
          <label>
            <span class="text-sm">Floors</span>
            <select name="house[floors]" class="select select-sm w-full">
              <option :for={floors <- 1..3} value={floors} selected={floors == @build.house.floors}>
                {floors}
              </option>
            </select>
          </label>
          <label>
            <span class="text-sm">Heat</span>
            <select name="house[heat]" class="select select-sm w-full">
              <option
                :for={{key, label, _text} <- House.heats()}
                value={key}
                selected={key == @build.house.heat}
              >
                {label}
              </option>
            </select>
          </label>
          <button class="btn btn-sm col-span-2">Save the house</button>
        </form>
        <p class="text-xs opacity-70">
          The heat here is for the preset only. The items of the rooms give the estimate.
        </p>
      </div>

      <.home_assistant ha={@ha} />

      <div class="space-y-2">
        <h2 class="text-lg font-bold">The file of your build</h2>
        <p class="text-sm">
          Your build stays on this device. Keep a file of it, or open it on a different device.
        </p>
        <a
          id="export"
          href={"data:application/json;charset=utf-8," <> URI.encode(Build.export(@build), &URI.char_unreserved?/1)}
          download="small-steps-home.json"
          class="btn btn-sm"
        >
          Keep a file of the build
        </a>
        <form id="import" phx-change="upload" phx-submit="upload">
          <label class="text-sm">
            Open a file of a build
            <.live_file_input upload={@uploads.build_file} class="file-input file-input-sm block" />
          </label>
        </form>
      </div>

      <div class="space-y-2">
        <h2 class="text-lg font-bold">Start again</h2>
        <button
          type="button"
          id="restart"
          phx-click="restart"
          data-confirm="Remove this build from this device and start again?"
          class="btn btn-sm btn-error btn-outline"
        >
          Start again
        </button>
      </div>
    </section>
    """
  end

  attr :ha, :map, required: true

  # The link to Home Assistant: the address and the sign-in, or the state
  # of the link and a disconnect.
  defp home_assistant(assigns) do
    assigns =
      assign(assigns,
        status: HomeAssistant.status(assigns.ha),
        linked: assigns.ha.state in ~w(signing_in connecting connected offline)
      )

    ~H"""
    <div id="home-assistant-card" class="space-y-2">
      <h2 class="text-lg font-bold">Home Assistant</h2>
      <p class="text-sm">
        Connect your Home Assistant to bring its rooms and devices into the app.
        The sign-in stays on this device: the server of the app does not see it.
      </p>
      <p id="ha-status" role="status" class="text-sm font-medium">{@status}</p>
      <p :if={@ha.error} id="ha-error" role="alert" class="text-sm text-error">
        {HomeAssistant.message(@ha.error)}
      </p>
      <form
        :if={not @linked}
        id="ha-form"
        phx-submit="ha_connect"
        class="flex flex-wrap gap-2 items-end"
      >
        <label>
          <span class="text-sm">The address of your Home Assistant</span>
          <input
            name="url"
            value={@ha.url}
            type="url"
            inputmode="url"
            autocomplete="url"
            placeholder="https://home.example.com"
            class="input input-sm w-72 max-w-full block"
          />
        </label>
        <button class="btn btn-sm">Connect</button>
      </form>
      <p :if={not @linked} class="text-xs opacity-70">
        The browser goes to the sign-in page of your Home Assistant, and then comes back here.
        Use the HTTPS address (for example, from Home Assistant Cloud): this page blocks an http address.
      </p>
      <button
        :if={@linked}
        type="button"
        id="ha-disconnect"
        phx-click="ha_disconnect"
        class="btn btn-sm"
      >
        Disconnect
      </button>
    </div>
    """
  end
end
