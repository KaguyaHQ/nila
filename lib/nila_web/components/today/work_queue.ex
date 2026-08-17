defmodule NilaWeb.Components.Today.WorkQueue do
  use NilaWeb, :html

  alias Nila.Gst.WorkQueue

  @moduledoc "Work-queue presentation for Today."

  attr :sections, :list, required: true
  attr :today, :any, required: true

  def work_queue(assigns) do
    ~H"""
    <.card :if={@sections == []} id="today-empty" class="py-12 text-center">
      <div class="space-y-block mx-auto max-w-sm">
        <h2 class="text-base-content text-h4 font-semibold">No clients yet</h2>
        <.button navigate={~p"/clients/new"} id="today-add-first-client">
          Add your first client
        </.button>
      </div>
    </.card>

    <section :for={{section, rows} <- @sections} id={"today-#{section}"} class="space-y-related">
      <h2 class="flex items-center gap-2">
        <span class="text-base-content text-ui font-semibold">
          {WorkQueue.section_title(section)}
        </span>
        <.badge variant={section_variant(section)}>{length(rows)}</.badge>
      </h2>

      <.data_table
        id={"today-#{section}-table"}
        rows={rows}
        row_id={fn r -> "today-row-#{r.client_id}-#{r.period}" end}
        row_click={fn r -> JS.navigate(r.path) end}
        min_width="min-w-[840px]"
      >
        <:col :let={r} label="Client">{r.client_name}</:col>
        <:col :let={r} label="Period">{period_label(r.period)}</:col>
        <:col :let={r} label="Due">
          <.badge :if={r.deadline} variant={days_left_variant(r.deadline.days_left)}>
            {r.deadline.return} · {days_left_label(r.deadline.days_left)}
          </.badge>
          <span :if={!r.deadline} class="text-ink-subtle">filed</span>
        </:col>
        <:col :let={r} label="Where it stands">
          <span
            :if={r.processing?}
            id={"today-processing-#{r.client_id}-#{r.period}"}
            class="text-moon text-ui mr-2 inline-flex items-center gap-1.5"
          >
            <span class="loading loading-spinner loading-xs"></span> extracting…
          </span>
          <span :if={section == :waiting_on_client} class="text-ink-muted text-ui">
            {slots_label(r.slots)}
          </span>
          <span :if={section != :waiting_on_client and work_label(r)} class="text-ui">
            {work_label(r)}
          </span>
          <span
            :if={section != :waiting_on_client and !work_label(r)}
            class="text-ink-faint"
          >
            —
          </span>
        </:col>
        <:col :let={r} label="Last ask">
          <button
            :if={last_ask_label(r.last_ask_at, @today)}
            type="button"
            id={"last-ask-#{r.client_id}-#{r.period}"}
            class="hover:text-moon text-ink-muted text-ui cursor-pointer underline decoration-dotted underline-offset-2"
            phx-click={
              JS.push("open-chase-history",
                value: %{"client-id" => to_string(r.client_id), "period" => r.period}
              )
            }
          >
            {last_ask_label(r.last_ask_at, @today)}
          </button>
          <span :if={!last_ask_label(r.last_ask_at, @today)} class="text-ink-faint">
            —
          </span>
        </:col>
        <:col :let={r} label="Chase">
          <div :if={r.chase_channel != "none"} class="flex items-center gap-2">
            <button
              :if={r.ask_count > 0}
              type="button"
              id={"automated-chase-#{r.client_id}-#{r.period}"}
              class="hover:text-moon text-ink-muted text-ui cursor-pointer underline decoration-dotted underline-offset-2"
              phx-click={
                JS.push("open-chase-history",
                  value: %{"client-id" => to_string(r.client_id), "period" => r.period}
                )
              }
            >
              {automated_ask_label(r, @today)}
            </button>
            <span
              :if={r.ask_count == 0}
              id={"automated-chase-#{r.client_id}-#{r.period}"}
              class="text-ink-muted text-ui"
            >
              {automated_ask_label(r, @today)}
            </span>
            <.button
              :if={r.draft}
              id={"manual-chase-#{r.client_id}-#{r.period}"}
              variant="ghost"
              size="xs"
              phx-click={
                JS.push("open-draft",
                  value: %{"client-id" => to_string(r.client_id), "period" => r.period}
                )
              }
            >
              Manual
            </.button>
          </div>
          <.button
            :if={r.chase_channel == "none" and r.draft}
            id={"draft-ask-#{r.client_id}-#{r.period}"}
            variant="soft"
            size="xs"
            phx-click={
              JS.push("open-draft",
                value: %{"client-id" => to_string(r.client_id), "period" => r.period}
              )
            }
          >
            Draft ask
          </.button>
          <span :if={r.chase_channel == "none" and !r.draft} class="text-ink-faint">
            —
          </span>
        </:col>
      </.data_table>
    </section>
    """
  end

  defp days_left_label(days) when days < 0, do: "#{-days}d overdue"
  defp days_left_label(0), do: "due today"
  defp days_left_label(days), do: "#{days}d left"

  defp days_left_variant(days) when days < 0, do: "error"
  defp days_left_variant(days) when days <= 5, do: "warning"
  defp days_left_variant(_days), do: "neutral"

  defp section_variant(:to_file), do: "error"
  defp section_variant(:needs_you), do: "warning"
  defp section_variant(_section), do: "neutral"

  defp last_ask_label(nil, _today), do: nil

  defp last_ask_label(asked_at, today) do
    case asked_at |> DateTime.to_date() |> then(&Date.diff(today, &1)) do
      0 -> "asked today"
      days -> "asked #{days}d ago"
    end
  end

  defp automated_ask_label(row, today) do
    timing = last_ask_label(row.last_ask_at, today) || "not asked yet"
    "Nila asks — #{timing} · #{row.ask_count}×"
  end

  defp work_label(row) do
    [
      row.need_decision > 0 && "#{row.need_decision} to decide",
      row.awaiting_bills > 0 && "#{row.awaiting_bills} bills to collect",
      row.sales_open > 0 && "#{row.sales_open} sales issues"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp slots_label(%{purchase: purchase, sales: sales}) do
    [{"purchase", purchase}, {"sales", sales}]
    |> Enum.map_join(" · ", fn
      {name, true} -> "#{name} ✓"
      {name, false} -> "#{name} not in"
    end)
  end
end
