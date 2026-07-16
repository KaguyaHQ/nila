defmodule NilaWeb.TodayLive do
  use NilaWeb, :live_view

  alias Nila.Gst.{Calendar, Chase, ClientMonths}

  # The cockpit lists months that already exist (a purchase dump arrived and
  # was worked). A client with no months yet has nothing to chase from this
  # list — the "all clients × current period" matrix is a later slice.
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Today")
     |> assign(:draft, nil)
     |> assign_months()}
  end

  defp assign_months(socket) do
    assign(socket, :months, list_months(socket))
  end

  defp list_months(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    today = Date.utc_today()

    org_id
    |> ClientMonths.list_for_org()
    |> Enum.map(&month_view(&1, today))
  end

  defp list_months(_socket), do: []

  defp month_view(client_month, today) do
    buckets = client_month.summary["buckets"] || %{}
    total = buckets |> Map.values() |> Enum.sum()
    matched = buckets["matched"] || 0
    slots = Chase.slots(client_month.org_id, client_month.client_id, client_month.period)

    %{
      client_id: client_month.client_id,
      period: client_month.period,
      client_name: client_month.client.name,
      state: client_month.state,
      period_label: period_label(client_month.period),
      invoices: total,
      need_decision: total - matched,
      gstr3b_days_left: Calendar.status(client_month.period, today).gstr3b_days_left,
      slots: slots,
      last_ask_label: last_ask_label(client_month, today),
      draft: build_draft(client_month, slots)
    }
  end

  defp last_ask_label(client_month, today) do
    case Chase.last_ask(client_month.org_id, client_month.client_id, client_month.period) do
      {:ok, ask} ->
        case ask.inserted_at |> DateTime.to_date() |> then(&Date.diff(today, &1)) do
          0 -> "asked today"
          days -> "asked #{days}d ago"
        end

      {:error, :not_found} ->
        nil
    end
  end

  # The right ask for where the month stands: dumps still missing -> the
  # opening nudge; dumps in but the engine found gaps -> the specific chase;
  # everything in and nothing missing -> nothing to ask.
  defp build_draft(client_month, slots) do
    cond do
      not (slots.purchase and slots.sales) ->
        %{
          kind: "month_open",
          body: Chase.draft(:month_open, client_month.client, client_month.period)
        }

      true ->
        case Chase.gaps(client_month) do
          %{in_2b_not_books: [], sequence_issues: []} ->
            nil

          gaps ->
            %{
              kind: "missing_bills",
              body: Chase.draft(:missing_bills, client_month.client, client_month.period, gaps)
            }
        end
    end
  end

  defp slots_label(%{purchase: purchase, sales: sales}) do
    [{"purchase", purchase}, {"sales", sales}]
    |> Enum.map_join(" · ", fn
      {name, true} -> "#{name} ✓"
      {name, false} -> "#{name} missing"
    end)
  end

  defp days_left_label(days) when days < 0, do: "#{-days}d overdue"
  defp days_left_label(0), do: "due today"
  defp days_left_label(days), do: "#{days}d left"

  defp state_variant("reviewed"), do: "success"
  defp state_variant("filed"), do: "success"
  defp state_variant("worked"), do: "warning"
  defp state_variant(_state), do: "neutral"

  defp days_left_variant(days) when days < 0, do: "error"
  defp days_left_variant(days) when days <= 5, do: "warning"
  defp days_left_variant(_days), do: "neutral"

  @impl true
  def handle_event("open-draft", %{"client-id" => client_id, "period" => period}, socket) do
    month =
      Enum.find(
        socket.assigns.months,
        &(to_string(&1.client_id) == client_id and &1.period == period)
      )

    {:noreply,
     assign(
       socket,
       :draft,
       month && month.draft &&
         Map.merge(month.draft, %{
           client_id: month.client_id,
           period: month.period,
           client_name: month.client_name,
           period_label: month.period_label
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
     |> assign_months()
     |> put_flash(:info, "Ask logged.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="today-page" class="mx-auto max-w-6xl space-y-6">
        <.page_header eyebrow="Cockpit" title="Client months">
          Every worked GST month for your firm. Open one to review it — each row is one
          tap from its scanned bill.
          <:actions>
            <.button navigate={~p"/gst/upload"} id="add-month">Add a month</.button>
          </:actions>
        </.page_header>

        <.data_table
          id="client-months"
          rows={@months}
          row_id={fn m -> "client-month-#{m.client_id}-#{m.period}" end}
          row_click={fn m -> JS.navigate(~p"/gst/#{m.client_id}/#{m.period}") end}
          empty?={@months == []}
          min_width="min-w-[880px]"
        >
          <:col :let={m} label="Client">{m.client_name}</:col>
          <:col :let={m} label="Period">{m.period_label}</:col>
          <:col :let={m} label="Status">
            <.badge variant={state_variant(m.state)}>{month_state_label(m.state)}</.badge>
          </:col>
          <:col :let={m} label="GSTR-3B">
            <.badge variant={days_left_variant(m.gstr3b_days_left)}>
              {days_left_label(m.gstr3b_days_left)}
            </.badge>
          </:col>
          <:col :let={m} label="Slots">
            <span class="text-base-content/70 text-fine">{slots_label(m.slots)}</span>
          </:col>
          <:col :let={m} label="Last ask">
            <span :if={m.last_ask_label} class="text-base-content/70 text-fine">
              {m.last_ask_label}
            </span>
            <span :if={!m.last_ask_label} class="text-base-content/45">—</span>
          </:col>
          <:col :let={m} label="Invoices" align="right">{m.invoices}</:col>
          <:col :let={m} label="Need a decision" align="right">
            <.badge :if={m.need_decision > 0} variant="warning">{m.need_decision}</.badge>
            <span :if={m.need_decision == 0} class="text-base-content/45">—</span>
          </:col>
          <:col :let={m} label="Chase">
            <.button
              :if={m.draft}
              id={"draft-ask-#{m.client_id}-#{m.period}"}
              variant="soft"
              size="xs"
              phx-click={
                JS.push("open-draft",
                  value: %{"client-id" => to_string(m.client_id), "period" => m.period}
                )
              }
            >
              Draft ask
            </.button>
            <span :if={!m.draft} class="text-base-content/45">—</span>
          </:col>
          <:empty>No worked months yet.</:empty>
        </.data_table>
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
