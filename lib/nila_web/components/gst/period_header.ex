defmodule NilaWeb.Components.Gst.PeriodHeader do
  use NilaWeb, :html

  @moduledoc "Shared GST filing month header and month picker."

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :section, :string, required: true
  attr :due_label, :string, default: nil
  attr :path_for_period, :any, required: true

  attr :picker_year, :integer, required: true
  slot :inner_block

  def period_header(assigns) do
    assigns =
      assigns
      |> assign(
        :can_go_forward?,
        assigns.period < Elixir.Calendar.strftime(Date.utc_today(), "%Y-%m")
      )
      |> assign(:period_label, full_period_label(assigns.period))
      |> assign(:previous_period, shift_period(assigns.period, -1))
      |> assign(:next_period, shift_period(assigns.period, 1))

    assigns =
      assigns
      |> assign(:current_year, Date.utc_today().year)
      |> assign(
        :months,
        Enum.map(1..12, fn month ->
          date = Date.new!(assigns.picker_year, month, 1)
          period = Elixir.Calendar.strftime(date, "%Y-%m")

          %{
            period: period,
            label: Elixir.Calendar.strftime(date, "%b"),
            full_label: Elixir.Calendar.strftime(date, "%B %Y"),
            available?: Date.compare(date, Date.utc_today()) != :gt
          }
        end)
      )

    ~H"""
    <.page_header eyebrow={@client.name <> " / " <> @section} title={@period_label}>
      <:title_control>
        <span class="block w-62">
          <button
            id="filing-period-trigger"
            type="button"
            popovertarget="filing-period-picker"
            aria-label={"Choose filing month, #{@period_label}"}
            aria-haspopup="dialog"
            class="focus-visible:outline-focus hover:bg-interactive rounded-field flex w-fit items-center gap-2 px-2 py-1 text-left whitespace-nowrap focus-visible:outline-2"
            style="anchor-name: --filing-period-trigger"
          >
            <span>{@period_label}</span> <.icon name="hero-chevron-down-mini" class="size-4" />
          </button>
        </span>
      </:title_control>

      <:title_actions>
        <div
          id="filing-period-picker"
          popover="auto"
          role="dialog"
          aria-label="Choose filing month"
          class="bg-panel-surface border-rule rounded-box shadow-moon text-base-content w-64 border p-4"
          style="position-anchor: --filing-period-trigger; top: anchor(bottom); left: anchor(left); margin: 8px 0 0;"
          phx-hook=".FilingPeriodPicker"
        >
          <div class="space-y-block">
            <div class="flex items-center justify-between">
              <.button
                id="filing-year-previous"
                type="button"
                variant="ghost"
                phx-click="shift-filing-year"
                phx-value-direction="previous"
                disabled={@picker_year <= 1}
                aria-label="Previous year"
              >
                <.icon name="hero-chevron-left-mini" class="size-4" />
              </.button>

              <span id="filing-picker-year" class="text-ui font-medium" aria-live="polite">{@picker_year}</span>
              <.button
                id="filing-year-next"
                type="button"
                variant="ghost"
                phx-click="shift-filing-year"
                phx-value-direction="next"
                disabled={@picker_year >= @current_year}
                aria-label="Next year"
              >
                <.icon name="hero-chevron-right-mini" class="size-4" />
              </.button>
            </div>

            <div class="grid grid-cols-3 gap-1">
              <.button
                :for={month <- @months}
                id={"filing-month-#{String.slice(month.period, -2, 2)}"}
                navigate={if month.available?, do: @path_for_period.(month.period)}
                disabled={not month.available?}
                variant={if month.period == @period, do: "soft", else: "ghost"}
                aria-current={if month.period == @period, do: "date"}
                aria-label={month.full_label}
                title={if not month.available?, do: "Future months are not available"}
              >
                {month.label}
              </.button>
            </div>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".FilingPeriodPicker">
          export default {
            mounted() {
              this.trigger = document.getElementById("filing-period-trigger")
              this.onToggle = event => {
                this.trigger?.setAttribute("aria-expanded", String(event.newState === "open"))
                if (event.newState === "open") (this.el.querySelector('[aria-current="date"]') || this.el.querySelector('a'))?.focus({preventScroll: true})
              }
              this.trigger?.setAttribute("aria-expanded", "false")
              this.onClick = event => {
                if (event.target.closest("a")) {
                  this.el.hidePopover()
                  this.trigger?.focus({preventScroll: true})
                }
              }
              this.el.addEventListener("click", this.onClick)
              this.el.addEventListener("toggle", this.onToggle)
            },
            destroyed() {
              this.el.removeEventListener("toggle", this.onToggle)
              this.el.removeEventListener("click", this.onClick)
            }
          }
        </script>

        <nav aria-label="Filing period" class="flex items-center gap-1">
          <.button
            navigate={@path_for_period.(@previous_period)}
            variant="ghost"
            size="sm"
            id="previous-filing-period"
            title="Previous month ([)"
            aria-label="Previous filing period"
          >
            <.icon name="hero-chevron-left-mini" class="size-4" />
          </.button>

          <.button
            navigate={if @can_go_forward?, do: @path_for_period.(@next_period)}
            disabled={not @can_go_forward?}
            variant="ghost"
            size="sm"
            id="next-filing-period"
            title="Next month (])"
            aria-label="Next filing period"
          >
            <.icon name="hero-chevron-right-mini" class="size-4" />
          </.button>
        </nav>
      </:title_actions>

      <:actions>
        <div class="gap-related flex items-center">
          <span :if={@due_label} class="text-ink-muted text-ui">{@due_label}</span> {render_slot(
            @inner_block
          )}
        </div>
      </:actions>
    </.page_header>
    """
  end

  defp full_period_label(period) do
    case Date.from_iso8601(period <> "-01") do
      {:ok, date} -> Elixir.Calendar.strftime(date, "%B %Y")
      _ -> Nila.Formatters.period_label(period)
    end
  end

  defp shift_period(period, months) do
    [year, month] = period |> String.split("-") |> Enum.map(&String.to_integer/1)
    shifted = year * 12 + month - 1 + months

    "#{div(shifted, 12)}-#{shifted |> rem(12) |> Kernel.+(1) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
