defmodule DIYWeb.ErrorHTML do
  @moduledoc """
  The pages of the errors (see `render_errors` in `config/config.exs`): a
  short text from the status, for example "Not Found" for 404.
  """
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
