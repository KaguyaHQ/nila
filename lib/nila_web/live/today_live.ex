defmodule NilaWeb.TodayLive do
  use NilaWeb, :live_view

  alias Nila.Gst.ClientMonths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Today")
     |> assign(:months, list_months(socket))}
  end

  defp list_months(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    org_id
    |> ClientMonths.list_for_org()
    |> Enum.map(&month_view/1)
  end

  defp list_months(_socket), do: []

  defp month_view(client_month) do
    buckets = client_month.summary["buckets"] || %{}
    total = buckets |> Map.values() |> Enum.sum()
    matched = buckets["matched"] || 0

    %{
      client_id: client_month.client_id,
      period: client_month.period,
      client_name: client_month.client.name,
      state: client_month.state,
      period_label: period_label(client_month.period),
      invoices: total,
      need_decision: total - matched
    }
  end

  defp period_label(period) do
    case String.split(period, "-") do
      [year, month] ->
        name =
          Enum.at(
            ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec),
            String.to_integer(month) - 1
          )

        "#{name} #{year}"

      _ ->
        period
    end
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
      <div id="today-page" class="mx-auto max-w-4xl space-y-6">
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
        >
          <:col :let={m} label="Client">{m.client_name}</:col>
          <:col :let={m} label="Period">{m.period_label}</:col>
          <:col :let={m} label="Invoices" align="right">{m.invoices}</:col>
          <:col :let={m} label="Need a decision" align="right">
            <.badge :if={m.need_decision > 0} variant="warning">{m.need_decision}</.badge>
            <span :if={m.need_decision == 0} class="text-base-content/45">—</span>
          </:col>
          <:col :let={m} label="State">{m.state}</:col>
          <:empty>No worked months yet.</:empty>
        </.data_table>
      </div>
    </Layouts.app>
    """
  end
end
