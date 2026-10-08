defmodule DIYWeb.HomeLive do
  @moduledoc """
  The first page. The build comes from the device (`DIYWeb.Device`). A new
  build starts at the two doors: "My house" for a person who lives in the
  house now, and "A house I'm planning" for a lot or a new build.
  """
  use DIYWeb, :live_view

  alias DIY.Build
  alias DIYWeb.Device

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Small Steps Home")}
  end

  @impl true
  def handle_info({Device, :build}, socket), do: {:noreply, socket}

  @impl true
  # No change before the page has the build of the device.
  def handle_event(_event, _params, %{assigns: %{build: nil}} = socket), do: {:noreply, socket}

  def handle_event("door", %{"door" => door}, socket) do
    case Build.choose_door(socket.assigns.build, door) do
      {:ok, build} -> {:noreply, Device.put_build(socket, build)}
      {:error, :door} -> {:noreply, socket}
    end
  end

  def handle_event("restart", _params, socket) do
    {:noreply, Device.put_build(socket, Build.restart(socket.assigns.build))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="device" phx-hook="Device" class="hidden"></div>
      <noscript>
        <p class="alert alert-warning">
          This app needs JavaScript. Turn on JavaScript in the browser.
        </p>
      </noscript>

      <p :if={is_nil(@build)} class="py-16 text-center opacity-70">
        The page reads your build from this device.
      </p>

      <section :if={@build && is_nil(@build.door)} class="space-y-4">
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

      <section :if={@build && @build.door} class="space-y-4">
        <h1 class="text-2xl font-bold">
          {if @build.door == "my_house", do: "My house", else: "A house I'm planning"}
        </h1>
        <p id="device-status" class="text-sm opacity-80">
          {if Device.saved?(assigns),
            do: "Saved on this device.",
            else: "The device does not have the last change yet."}
        </p>
        <button id="restart" type="button" phx-click="restart" class="btn btn-ghost btn-sm">
          Start again
        </button>
      </section>
    </Layouts.app>
    """
  end
end
