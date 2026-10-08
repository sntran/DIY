defmodule DIYWeb.Layouts do
  @moduledoc """
  The layouts of the pages: `root.html.heex` (the HTML document) and
  `app/1` (the frame of each page).
  """
  use DIYWeb, :html

  embed_templates "layouts/*"

  @doc """
  The frame of a page: the name of the app, the content, and the notices.
  """
  attr :flash, :map, required: true, doc: "the flash notices"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar min-h-12 px-4">
      <a href="/" class="font-semibold">Small Steps Home</a>
    </header>

    <main class="px-4 pb-16">
      <div class="mx-auto max-w-xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <div id="flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
