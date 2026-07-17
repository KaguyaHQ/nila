defmodule NilaWeb.TodayLive do
  use NilaWeb, :live_view

  alias Nila.Gst.{Chase, Today}

  # The front door: one row per client-month the firm should look at today,
  # grouped by who it's waiting on (Nila.Gst.Today). The junior reads
  # "Needs you" top to bottom and that is their day; clients who sent
  # nothing appear under "Waiting on the client" with the chase verbs.
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Today")
     |> assign(:draft, nil)
     |> assign_rows()}
  end

  defp assign_rows(socket) do
    rows = list_rows(socket)

    sections =
      Today.sections()
      |> Enum.map(fn section -> {section, Enum.filter(rows, &(&1.section == section))} end)
      |> Enum.reject(fn {_section, rows} -> rows == [] end)

    socket
    |> assign(:rows, rows)
    |> assign(:sections, sections)
  end

  defp list_rows(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}),
    do: Today.rows(org_id, Date.utc_today())

  defp list_rows(_socket), do: []

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

  defp work_label(row) do
    [
      row.need_decision > 0 && "#{row.need_decision} to decide",
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

  @impl true
  def handle_event("open-draft", %{"client-id" => client_id, "period" => period}, socket) do
    row =
      Enum.find(
        socket.assigns.rows,
        &(to_string(&1.client_id) == client_id and &1.period == period)
      )

    {:noreply,
     assign(
       socket,
       :draft,
       row && row.draft &&
         Map.merge(row.draft, %{
           client_id: row.client_id,
           period: row.period,
           client_name: row.client_name,
           period_label: period_label(row.period)
         })
     )}
  end

  def handle_event("close-draft", _params, socket) do
    {:noreply, assign(socket, :draft, nil)}
  end

  def handle_event("mark-sent", _params, socket) do
    %{draft: draft, current_scope: scope} = socket.assigns

    {:ok, _ask} =
      Chase.record_ask(
        %{
          org_id: scope.current_org.id,
          client_id: draft.client_id,
          sent_by_id: scope.user.id
        },
        %{kind: draft.kind, period: draft.period, body: draft.body}
      )

    {:noreply,
     socket
     |> assign(:draft, nil)
     |> assign_rows()
     |> put_flash(:info, "Ask logged.")}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :today, Date.utc_today())

    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="today-page" class="mx-auto max-w-6xl space-y-8">
        <.page_header eyebrow="Today" title="Today">
          Every client's month, led by who it's waiting on.
          <:actions>
            <.button navigate={~p"/gst/upload"} id="add-month">Bring in documents</.button>
          </:actions>
        </.page_header>

        <.card :if={@sections == []} id="today-empty" class="py-10 text-center">
          <div class="mx-auto max-w-sm space-y-4">
            <h2 class="text-base-content text-h4 font-semibold">No clients yet</h2>
            <.button navigate={~p"/clients/new"} id="today-add-first-client">
              Add your first client
            </.button>
          </div>
        </.card>

        <section :for={{section, rows} <- @sections} id={"today-#{section}"} class="space-y-3">
          <h2 class="flex items-center gap-2.5">
            <span class="text-base-content text-small font-semibold">
              {Today.section_title(section)}
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
              <span :if={!r.deadline} class="text-base-content/45">filed</span>
            </:col>
            <:col :let={r} label="Where it stands">
              <span
                :if={r.processing?}
                id={"today-processing-#{r.client_id}-#{r.period}"}
                class="text-fine text-moon mr-2 inline-flex items-center gap-1.5"
              >
                <span class="loading loading-spinner loading-xs"></span> extracting…
              </span>
              <span :if={section == :waiting_on_client} class="text-base-content/70 text-fine">
                {slots_label(r.slots)}
              </span>
              <span :if={section != :waiting_on_client and work_label(r)} class="text-small">
                {work_label(r)}
              </span>
              <span
                :if={section != :waiting_on_client and !work_label(r)}
                class="text-base-content/45"
              >
                —
              </span>
            </:col>
            <:col :let={r} label="Last ask">
              <span :if={last_ask_label(r.last_ask_at, @today)} class="text-base-content/70 text-fine">
                {last_ask_label(r.last_ask_at, @today)}
              </span>
              <span :if={!last_ask_label(r.last_ask_at, @today)} class="text-base-content/45">
                —
              </span>
            </:col>
            <:col :let={r} label="Chase">
              <.button
                :if={r.draft}
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
              <span :if={!r.draft} class="text-base-content/45">—</span>
            </:col>
          </.data_table>
        </section>
      </div>

      <.modal
        :if={@draft}
        id="chase-draft-modal"
        title={"Ask #{@draft.client_name} · #{@draft.period_label}"}
        on_close="close-draft"
        class="max-w-2xl"
      >
        <div class="space-y-4">
          <pre
            id="chase-draft-body"
            class="bg-base-200/40 border-base-300 rounded-box text-base-content text-small overflow-x-auto border p-4 font-sans whitespace-pre-wrap"
          >{@draft.body}</pre>

          <div class="flex items-center justify-end gap-2">
            <.button
              id="chase-copy-button"
              variant="soft"
              size="sm"
              phx-hook=".CopyDraft"
              type="button"
            >
              <.icon name="hero-clipboard-document" class="size-4" /> Copy
            </.button>
            <.button id="chase-mark-sent" variant="primary" size="sm" phx-click="mark-sent">
              Mark as sent
            </.button>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyDraft">
            export default {
              mounted() {
                this.el.addEventListener("click", () => {
                  const body = document.getElementById("chase-draft-body")
                  if (body) navigator.clipboard.writeText(body.textContent)
                })
              }
            }
          </script>
        </div>
      </.modal>
    </Layouts.app>
    """
  end
end
