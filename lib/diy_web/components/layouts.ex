defmodule DIYWeb.Layouts do
  @moduledoc """
  The layouts of the pages: `root.html.heex` (the HTML document) and
  `app/1` (the frame of each page).
  """
  use DIYWeb, :html

  embed_templates "layouts/*"

  @doc """
  The frame of a page: the name of the app, the state of the save, the
  content, the bar of the parts of a build, and the notices.
  """
  attr :flash, :map, required: true, doc: "the flash notices"
  attr :nav, :boolean, default: false, doc: "show the bar of the parts of a build"
  attr :action, :atom, default: nil, doc: "the part that shows"
  attr :power, :boolean, default: false, doc: "show the part Power (DIYWeb.PowerPage)"
  attr :plans, :boolean, default: false, doc: "show the part Plans (DIYWeb.LessonPage)"
  attr :saved, :boolean, default: true, doc: "the device has the last change"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar min-h-12 px-4">
      <a href="/" class="flex-1 font-semibold">Small Steps Home</a>
      <span :if={@nav} id="device-status" class="text-xs opacity-70">
        {if @saved, do: "Saved on this device", else: "Not saved yet"}
      </span>
    </header>

    <main class={["px-4", if(@nav, do: "pb-24", else: "pb-16")]}>
      <div class="mx-auto max-w-xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <nav
      :if={@nav}
      class="dock dock-sm z-40 border-t border-base-300 bg-base-100"
      aria-label="The parts of your build"
    >
      <.link
        patch={~p"/"}
        class={[@action == :front && "dock-active"]}
        aria-current={@action == :front && "page"}
      >
        <.icon name="hero-home" class="size-5" /><span class="dock-label">House</span>
      </.link>
      <.link
        patch={~p"/inside"}
        class={[@action in [:inside, :van] && "dock-active"]}
        aria-current={rooms_current(@action)}
      >
        <.icon name="hero-squares-2x2" class="size-5" /><span class="dock-label">Rooms</span>
      </.link>
      <.link
        patch={~p"/estimate"}
        class={[@action == :estimate && "dock-active"]}
        aria-current={@action == :estimate && "page"}
      >
        <.icon name="hero-chart-bar" class="size-5" /><span class="dock-label">Bill</span>
      </.link>
      <.link
        :if={@power}
        patch={~p"/power"}
        class={[@action == :power && "dock-active"]}
        aria-current={@action == :power && "page"}
      >
        <.icon name="hero-bolt" class="size-5" /><span class="dock-label">Power</span>
      </.link>
      <.link
        :if={@plans}
        patch={~p"/plans"}
        class={[@action == :plans && "dock-active"]}
        aria-current={@action == :plans && "page"}
      >
        <.icon name="hero-document-text" class="size-5" /><span class="dock-label">Plans</span>
      </.link>
      <.link
        patch={~p"/settings"}
        class={[@action == :settings && "dock-active"]}
        aria-current={@action == :settings && "page"}
      >
        <.icon name="hero-cog-6-tooth" class="size-5" /><span class="dock-label">Settings</span>
      </.link>
    </nav>

    <div id="flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  # A van is a part of the house: its page is in the part Rooms. The page of
  # a van is not the page of the rooms, so it is the current part only.
  defp rooms_current(:inside), do: "page"
  defp rooms_current(:van), do: "true"
  defp rooms_current(_action), do: nil
end
