defmodule NilaWeb.ClientsLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.Purchase.{Months, Register}
  alias Nila.Gst.Sales.Months, as: SalesMonths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Clients")
     |> assign(:clients, list_clients(socket))}
  end

  defp list_clients(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    purchase = Months.latest_by_client(org_id)
    sales = SalesMonths.latest_by_client(org_id)

    org_id
    |> Clients.list_clients()
    |> Enum.map(&client_view(&1, purchase[&1.id], sales[&1.id]))
  end

  defp list_clients(_socket), do: []

  # A client's latest month spans both returns, so the row reads both. The
  # status is the *least* advanced of the two sides: a filed purchase month
  # sitting over an unworked GSTR-1 is not a client anyone is done with, and
  # this column used to say "Ready for review" about exactly that. A side with
  # no month for the period hasn't started — that is `collecting`.
  defp client_view(client, purchase, sales) do
    period = latest_period(purchase, sales)
    purchase = month_in(purchase, period)
    sales = month_in(sales, period)

    %{
      id: client.id,
      name: client.name,
      type: type_label(client.type),
      gstin: client.gstin,
      period: period,
      state: period && least_advanced(purchase, sales),
      need_decision: purchase && Register.need_decision(purchase.summary)
    }
  end

  defp latest_period(nil, nil), do: nil
  defp latest_period(nil, sales), do: sales.period
  defp latest_period(purchase, nil), do: purchase.period
  defp latest_period(purchase, sales), do: max(purchase.period, sales.period)

  # The two sides' latest periods can differ — a month is only this client's
  # if it is *for* the period being shown.
  defp month_in(%{period: period} = month, period), do: month
  defp month_in(_month, _period), do: nil

  @state_rank %{"collecting" => 0, "worked" => 1, "reviewed" => 2, "filed" => 3}

  # An unrecognised state ranks lowest rather than raising: the roster stays up,
  # and the error leans towards claiming less progress than we can prove.
  defp least_advanced(purchase, sales) do
    Enum.min_by([state(purchase), state(sales)], &Map.get(@state_rank, &1, 0))
  end

  defp state(nil), do: "collecting"
  defp state(%{state: state}), do: state

  defp type_label(type), do: type |> to_string() |> String.capitalize()

  defp state_variant("reviewed"), do: "success"
  defp state_variant("filed"), do: "success"
  defp state_variant("worked"), do: "warning"
  defp state_variant(_state), do: "neutral"

  # Click follows the work: latest month when one exists, else start one —
  # intake pre-scoped to this client.
  defp row_path(%{period: period, id: id}) when is_binary(period), do: ~p"/gst/#{id}/#{period}"
  defp row_path(%{id: id}), do: ~p"/gst/upload?client_id=#{id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="clients-page" class="space-y-section mx-auto max-w-5xl">
        <.page_header eyebrow="Clients" title="Clients">
          Every business the firm files for, with where their GST work stands.
          <:actions>
            <.button navigate={~p"/clients/new"} id="clients-add">Add client</.button>
          </:actions>
        </.page_header>

        <.data_table
          id="clients-table"
          rows={@clients}
          row_id={fn client -> "client-#{client.id}" end}
          row_navigate={&row_path/1}
          row_label={fn client -> "Open #{client.name}" end}
          empty?={@clients == []}
        >
          <:col :let={client} label="Name">
            <div class="flex items-center gap-2">
              <span class="font-medium">{client.name}</span>
              <.badge :if={!client.gstin} variant="warning">no GSTIN</.badge>
            </div>
          </:col>
          <:col :let={client} label="Type">{client.type}</:col>
          <:col :let={client} label="Latest month">
            <span :if={client.period}>{period_label(client.period)}</span>
            <span :if={!client.period} class="text-ink-subtle">no months yet</span>
          </:col>
          <:col :let={client} label="Status">
            <.badge :if={client.state} variant={state_variant(client.state)}>
              {month_state_label(client.state)}
            </.badge>
            <span :if={!client.state} class="text-ink-faint">—</span>
          </:col>
          <:col :let={client} label="Needs a decision" align="right">
            <%!-- The badge lands on the working paper; the reviewer opens the
                  purchase surface from the month after seeing its context. --%>
            <.link
              :if={client.need_decision && client.need_decision > 0}
              navigate={~p"/gst/#{client.id}/#{client.period}"}
              id={"client-decisions-#{client.id}"}
              class="relative z-10"
            >
              <.badge variant="warning">{client.need_decision}</.badge>
            </.link>
            <span
              :if={!client.need_decision || client.need_decision == 0}
              class="text-ink-faint"
            >
              —
            </span>
          </:col>
          <:col :let={client} label="" class="whitespace-nowrap">
            <div class="flex items-center justify-end gap-3">
              <span class="relative z-10">
                <.button
                  navigate={~p"/clients/#{client.id}/edit"}
                  id={"client-edit-#{client.id}"}
                  variant="ghost"
                  size="xs"
                  aria-label={"Edit #{client.name}"}
                >
                  <.icon name="hero-pencil-square" class="size-4" /> Edit
                </.button>
              </span>
              <%!-- Not a control — the standing mark that the row itself opens.
                    The hover and the pointer only say so once you're already
                    on the row. --%>
              <.icon name="hero-arrow-right" class="text-ink-faint size-4" />
            </div>
          </:col>
          <:empty>
            <div id="clients-empty" class="space-y-block">
              <p>No clients yet.</p>
              <.button navigate={~p"/clients/new"} id="clients-add-first">
                Add your first client
              </.button>
            </div>
          </:empty>
        </.data_table>
      </div>
    </Layouts.app>
    """
  end
end
