defmodule DIYWeb.PlanLinkPage do
  @moduledoc """
  A link of plans to compare (docs/design.md, "A link of plans"). This
  module has the chart of the price for each kWh (`DIYWeb.PlanChart`)
  and the page of a link (`/p/DATA`). It also has the button that
  shares the plans of the worksheet. The pages of the plans are in English, as the plan lesson.

  The pages do not pick a plan, and they do not rank plans (honesty rule
  4): the plans are in the order of the link.
  """
  use DIYWeb, :html

  alias DIY.{Plan, PlanLink}
  alias DIYWeb.{Format, LessonPage, PlanChart}

  attr :id, :string, required: true
  attr :plans, :list, required: true
  attr :months, :list, default: [], doc: "the months of the house, for a dot on the axis of each"

  @doc """
  The chart of the price for each kWh of plans. It has the plot, and a
  key with the dashes and the name of each plan. It also has a table of
  its numbers, for a person who does not see the chart.
  """
  def chart(assigns) do
    assigns =
      assign(assigns,
        svg: PlanChart.svg(assigns.plans, assigns.months, assigns.id),
        kwhs: PlanChart.table_kwh(assigns.plans)
      )

    ~H"""
    <figure id={@id} class="pc-chart space-y-2">
      <figcaption class="text-sm">
        <span class="font-semibold">The price for each kWh, at each use of a month.</span>
        The bill of a month divided by its kWh, with the delivery charges. A credit makes the price drop at its kWh.
      </figcaption>
      {raw(@svg)}
      <ul class="flex flex-wrap gap-x-4 gap-y-1 text-sm" aria-label="The key of the chart">
        <li :for={{plan, n} <- Enum.with_index(@plans, 1)} class="flex items-center gap-2">
          <svg viewBox="0 0 32 8" class="w-8 h-2" aria-hidden="true">
            <line
              x1="0"
              y1="4"
              x2="32"
              y2="4"
              class={"pc-key pc-#{n}"}
              stroke-dasharray={PlanChart.dashes(n)}
            />
          </svg>
          {plan.name}
        </li>
        <li :if={@months != []} class="flex items-center gap-2">
          <svg viewBox="0 0 10 10" class="size-2.5" aria-hidden="true">
            <circle cx="5" cy="5" r="4" class="pc-month" />
          </svg>
          Your months
        </li>
      </ul>
      <details class="text-sm">
        <summary class="cursor-pointer">The numbers of the chart</summary>
        <div class="overflow-x-auto" tabindex="0" role="region" aria-label="The numbers of the chart">
          <table class="table table-xs" id={"#{@id}-table"}>
            <thead>
              <tr>
                <th>Plan</th>
                <th :for={kwh <- @kwhs} class="text-right">{Format.kwh(kwh)}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={plan <- @plans}>
                <th class="font-normal">{plan.name}</th>
                <td :for={kwh <- @kwhs} class="text-right">
                  {Format.cents(Plan.bill(plan, kwh).cents)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
    </figure>
    """
  end

  attr :compared, :any, required: true, doc: "`{:ok, plans}` or `{:error, reason}`"
  attr :build, :map, default: nil, doc: "the build of the device, or nil while it loads"

  @doc """
  The page of a link of plans: the chart, and the numbers of each plan.
  The button puts the plans in the worksheet of the device, with the
  months of its house.
  """
  def page(assigns) do
    ~H"""
    <section id="plan-link" lang="en" class="space-y-4">
      <%= case @compared do %>
        <% {:ok, plans} -> %>
          <h1 class="text-2xl font-bold">
            {if length(plans) == 1, do: "A plan to compare", else: "#{length(plans)} plans to compare"}
          </h1>
          <p>
            The price of a plan is not the same at each use. A bill credit can make a plan cheap at 1,000 kWh and expensive at 999 kWh. The cost of your year comes from your own months.
          </p>
          <.chart id="link-chart" plans={plans} />
          <div :for={{plan, n} <- Enum.with_index(plans, 1)} class="space-y-1">
            <h2 class="font-semibold">{plan.name}</h2>
            <LessonPage.plan_numbers plan={plan} id={"link-plan-#{n}"} />
          </div>
          <p class="text-sm opacity-80">
            The delivery charges are the charges in the link. The plans of a link are for the area of its utility. Small Steps Home does not pick a plan, and it does not rank plans.
          </p>
          <button
            id="plan-link-add"
            type="button"
            phx-click="plan_link_add"
            disabled={is_nil(@build)}
            class="btn btn-primary btn-lg w-full"
          >
            See these plans with my months
          </button>
          <p class="text-sm opacity-80">
            The plans go into the worksheet on this device. A new person first tells a few facts of the house: the app makes the months from them. You can also open the file of your meter.
          </p>
        <% {:error, _reason} -> %>
          <h1 class="text-2xl font-bold">This link has no plans</h1>
          <p id="plan-link-error">
            The link is not complete, or it is from a different version of the app. Ask for the link again.
          </p>
          <.link navigate={~p"/"} id="plan-link-start" class="btn btn-primary">
            Go to Small Steps Home
          </.link>
      <% end %>
    </section>
    """
  end

  attr :plans, :list, required: true
  attr :origin, :string, default: "", doc: "the scheme and the host of the page"

  @doc """
  The button that shares the plans of the worksheet (the hook Share,
  `assets/js/share.js`). The link has the first 6 plans.
  """
  def share(assigns) do
    shared = Enum.take(assigns.plans, PlanLink.max_plans())

    path =
      case PlanLink.encode(shared) do
        {:ok, data} -> ~p"/p/#{data}"
        {:error, :too_large} -> nil
      end

    assigns =
      assign(assigns,
        path: path,
        more: length(assigns.plans) > PlanLink.max_plans(),
        shared: shared
      )

    ~H"""
    <p :if={is_nil(@path)} id="plan-share-too-large" class="text-sm">
      The names of these plans are too long for a link.
    </p>
    <div :if={@path} id="plan-share" class="space-y-2">
      <button
        id="plan-share-button"
        type="button"
        phx-hook="Share"
        data-path={@path}
        data-title={PlanChart.title(@shared)}
        data-copied="The link is in the clipboard."
        data-failed="Copy the link from the box."
        data-status="plan-share-status"
        class="btn btn-sm"
      >
        <.icon name="hero-share" class="size-4" /> Share these plans
      </button>
      <p class="text-xs opacity-80">
        The link has the numbers of the plans{if @more, do: " (the first 6)"}: not your house, your months or your ZIP code. A different person sees the plans with the months of their own house.
      </p>
      <input
        id="plan-share-link"
        type="text"
        readonly
        value={@origin <> @path}
        aria-label="The link of the plans"
        class="input input-sm w-full"
      />
      <%!-- Only the hook Share writes the status: a render of the page keeps it. --%>
      <p id="plan-share-status" role="status" phx-update="ignore" class="text-sm min-h-5"></p>
    </div>
    """
  end
end
