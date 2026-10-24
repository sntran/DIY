defmodule DIYWeb.Share do
  @moduledoc """
  A shared house (docs/design.md, "A shared house"): the sheet of the
  share on the page House, and the page of a link (`/s/DATA`).
  """
  use DIYWeb, :html

  alias DIY.Share
  alias DIYWeb.{Format, Inside, Outside}

  attr :build, :map, required: true
  attr :summary, :map, required: true, doc: "the summary of the numbers (`DIY.Share.summary/3`)"
  attr :zip, :boolean, required: true, doc: "the link has the ZIP code"
  attr :url, :string, required: true, doc: "the full link"
  attr :picture, :string, required: true, doc: "the path of the picture of the link"
  attr :title, :string, required: true, doc: "the title of the link"

  @doc """
  The sheet of the share: what the link shows, the box of the ZIP code,
  and the button Share (the hook Share, `assets/js/share.js`).
  """
  def sheet(assigns) do
    ~H"""
    <Inside.sheet id="share-sheet" title={gettext("Share this house")} close={~p"/"}>
      <p class="text-sm">
        {gettext(
          "The link shows your house and its numbers to a different person. The link carries the house: the app keeps no copy of it."
        )}
      </p>
      <img
        src={@picture}
        alt={@title}
        width="1200"
        height="630"
        class="w-full h-auto rounded-box border border-base-300"
      />
      <ul class="text-sm list-disc ps-5 space-y-1">
        <li>{gettext("The house, its rooms and its items.")}</li>
        <li>
          {gettext("%{kwh} a year", kwh: Format.kwh(Share.year(@summary)))}{if @summary.cost,
            do: " · " <> gettext("%{cost} a year", cost: Format.money(@summary.cost))}
        </li>
        <li :if={@zip}>{gettext("ZIP code %{zip}", zip: @build.zip)}</li>
        <li>
          {gettext(
            "Not in the link: your links to Home Assistant and to the makers of your stations."
          )}
        </li>
      </ul>
      <form id="share-zip" phx-change="share_zip">
        <label class="label cursor-pointer gap-2 text-sm whitespace-normal">
          <input type="hidden" name="zip" value="false" />
          <input type="checkbox" name="zip" value="true" checked={@zip} class="checkbox checkbox-sm" />
          {gettext("Put the ZIP code in the link. The weather and the plans need it.")}
        </label>
      </form>
      <label class="text-sm block">
        <span class="block font-semibold">{gettext("The link")}</span>
        <input id="share-link" type="text" readonly value={@url} class="input input-sm w-full" />
      </label>
      <button
        id="share-button"
        type="button"
        phx-hook="Share"
        data-path={@url}
        data-title={@title}
        data-copied={gettext("The link is in the clipboard.")}
        data-failed={gettext("Copy the link from the box.")}
        data-status="share-status"
        class="btn btn-primary w-full"
      >
        <.icon name="hero-share" class="size-5" /> {gettext("Share")}
      </button>
      <%!-- Only the hook Share writes the status: a render of the page keeps it. --%>
      <p id="share-status" role="status" phx-update="ignore" class="text-sm min-h-5"></p>
    </Inside.sheet>
    """
  end

  attr :shared, :any, required: true, doc: "`{:ok, shared}` or `{:error, reason}`"
  attr :build, :map, default: nil, doc: "the build of the device, or nil while it loads"
  attr :adopt, :atom, default: nil, doc: "`:confirm` when the button asks first"

  @doc """
  The page of the link of a shared house. It shows the house, the numbers
  of its year and a bar for each month. It has the button Start from
  this house.
  """
  def page(assigns) do
    ~H"""
    <section id="shared" class="space-y-4">
      <%= case @shared do %>
        <% {:ok, shared} -> %>
          <div>
            <h1 class="text-2xl font-bold">{gettext("A shared house")}</h1>
            <p class="text-sm opacity-70">{shared.title}</p>
          </div>
          <div class="overflow-hidden rounded-box" role="img" aria-label={shared.view.label}>
            <Outside.house view={shared.view} />
          </div>
          <dl class="grid grid-cols-2 gap-3">
            <div class="rounded-box bg-base-200 p-3">
              <dt class="text-sm opacity-70">{gettext("Electricity in a year")}</dt>
              <dd id="shared-kwh" class="text-2xl font-bold">
                {Format.kwh(Share.year(shared.summary))}
              </dd>
            </div>
            <div :if={shared.summary.cost} class="rounded-box bg-base-200 p-3">
              <dt class="text-sm opacity-70">{gettext("Cost in a year")}</dt>
              <dd id="shared-cost" class="text-2xl font-bold">
                {Format.money(shared.summary.cost)}
              </dd>
            </div>
          </dl>
          <.bars months={shared.summary.months} />
          <p>
            {gettext(
              "Small Steps Home shows where the electricity of a house goes, and what a change can save. Start from this house, and then change it to your house."
            )}
          </p>
          <%= if @adopt == :confirm do %>
            <div id="adopt-confirm" role="alert" class="alert alert-warning flex-col items-start">
              <p>
                {gettext("This house takes the place of your house on this device.")}
                <.link navigate={~p"/settings"} class="link">
                  {gettext("Keep a file of your house first.")}
                </.link>
              </p>
              <div class="flex gap-2">
                <button
                  id="adopt-sure"
                  type="button"
                  phx-click="adopt"
                  phx-value-sure="true"
                  class="btn btn-sm btn-primary"
                >
                  {gettext("Start from this house")}
                </button>
                <button id="adopt-cancel" type="button" phx-click="adopt_cancel" class="btn btn-sm">
                  {gettext("Keep my house")}
                </button>
              </div>
            </div>
          <% else %>
            <button
              id="adopt"
              type="button"
              phx-click="adopt"
              disabled={is_nil(@build)}
              class="btn btn-primary btn-lg w-full"
            >
              {gettext("Start from this house")}
            </button>
          <% end %>
        <% {:error, _reason} -> %>
          <h1 class="text-2xl font-bold">{gettext("This link has no house")}</h1>
          <p>
            {gettext(
              "The link is not complete, or it is from a different version of the app. Ask for the link again."
            )}
          </p>
          <.link navigate={~p"/"} id="shared-start" class="btn btn-primary">
            {gettext("Go to Small Steps Home")}
          </.link>
      <% end %>
    </section>
    """
  end

  attr :months, :list, required: true

  # A bar for each month, from January.
  defp bars(assigns) do
    top = assigns.months |> Enum.max() |> max(1)

    assigns =
      assign(assigns,
        bars:
          Enum.zip([
            month_names(),
            DIYWeb.Picture.month_letters(),
            assigns.months,
            Enum.map(assigns.months, &(100 * &1 / top))
          ])
      )

    ~H"""
    <ol
      id="shared-months"
      class="flex h-32 items-end gap-0.5"
      aria-label={gettext("The kWh of each month")}
    >
      <li
        :for={{name, letter, kwh, height} <- @bars}
        class="flex-1 flex flex-col items-center h-full justify-end"
        aria-label={"#{name}: #{Format.kwh(kwh)}"}
      >
        <span class="w-full rounded-t-sm bg-primary/80" style={"height: #{Float.round(height, 1)}%"} />
        <span class="text-xs opacity-70" aria-hidden="true">{letter}</span>
      </li>
    </ol>
    """
  end

  defp month_names do
    [
      gettext("January"),
      gettext("February"),
      gettext("March"),
      gettext("April"),
      gettext("May"),
      gettext("June"),
      gettext("July"),
      gettext("August"),
      gettext("September"),
      gettext("October"),
      gettext("November"),
      gettext("December")
    ]
  end
end
