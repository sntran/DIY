defmodule DIYWeb.CoreComponents do
  @moduledoc """
  The small parts of the pages: notices and icons. The styles are Tailwind
  CSS with daisyUI. The icons are Heroicons (`icon/1`).
  """
  use Phoenix.Component
  use Gettext, backend: DIY.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Shows a flash notice. A click closes it. A notice is a text in the
  language of the page. A text in a different language is
  `{lang, text}`: for example, an English error of a script of the page.
  """
  attr :id, :string, doc: "the id of the notice"
  attr :flash, :map, default: %{}, doc: "the flash notices"
  attr :kind, :atom, values: [:info, :error], doc: "the kind of the notice"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "##{@id}")}
      role="alert"
      class="toast toast-top toast-center z-50"
    >
      <div class={[
        "alert w-80 sm:w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <p :if={is_binary(msg)}>{msg}</p>
        <p :if={is_tuple(msg)} lang={elem(msg, 0)}>{elem(msg, 1)}</p>
        <button type="button" class="self-start cursor-pointer" aria-label={gettext("Close")}>
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Shows a Heroicon, from the class `hero-NAME` of the Tailwind plugin
  (`assets/vendor/heroicons.js`).
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end
end
