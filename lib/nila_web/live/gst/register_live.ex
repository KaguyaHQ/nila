defmodule NilaWeb.Gst.RegisterLive do
  use NilaWeb, :live_view

  alias Nila.Gst.Filing.History

  @impl true
  def mount(_params, _session, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    {:ok,
     socket
     |> assign(:page_title, "GST months")
     |> assign(:grid, History.grid(org_id))}
  end

  defp cell_title(cell) do
    [filing_arn("GSTR-1", cell.gstr1), filing_arn("GSTR-3B", cell.gstr3b)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      arns -> Enum.join(arns, " · ")
    end
  end

  defp filing_arn(return, {:filed, _filed_at, arn}) when is_binary(arn),
    do: "#{return} ARN: #{arn}"

  defp filing_arn(_return, _state), do: nil

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :return, :string, required: true
  attr :state, :any, required: true

  defp filing_line(assigns) do
    ~H"""
    <div id={@id} class="flex min-h-5 items-center gap-2 text-left whitespace-nowrap tabular-nums">
      <span class="sr-only">{filing_description(@return, @state)}</span>
      <span aria-hidden="true" class="contents">
        <span class="text-ink-subtle w-6 shrink-0 font-semibold">{@label}</span>
        <%= case @state do %>
          <% :absent -> %>
            <span class="text-ink-faint">—</span>
          <% :not_filed -> %>
            <span class="text-ink-muted">Not filed</span>
          <% {:filed, filed_at, _arn} -> %>
            <span class="text-base-content flex items-center gap-1 font-medium">
              <.icon name="hero-check-mini" class="text-success size-3.5" />
              <span>{Calendar.strftime(filed_at, "%d %b")}</span>
            </span>
        <% end %>
      </span>
    </div>
    """
  end

  defp filing_description(return, :absent), do: "#{return} does not exist in Nila"
  defp filing_description(return, :not_filed), do: "#{return} not filed"

  defp filing_description(return, {:filed, filed_at, nil}),
    do: "#{return} filed on #{Calendar.strftime(filed_at, "%d %B %Y")}"

  defp filing_description(return, {:filed, filed_at, arn}),
    do: "#{return} filed on #{Calendar.strftime(filed_at, "%d %B %Y")}, ARN #{arn}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="register-page" class="space-y-section mx-auto max-w-6xl">
        <.page_header eyebrow="GST" title="GST months">
          Recent client periods and their GSTR-1 and GSTR-3B filing status.
        </.page_header>

        <.card
          :if={@grid.periods == []}
          id="register-empty"
          padding="roomy"
          class="text-center"
        >
          <div class="space-y-block mx-auto max-w-md">
            <p class="text-body text-ink-muted font-light">
              No GST months yet — bring in a client's documents and this view fills itself.
            </p>
            <.button navigate={~p"/gst/upload"} id="register-bring-documents">
              Bring in documents
            </.button>
          </div>
        </.card>

        <%!-- Bespoke client×period matrix: sticky Client column + per-cell links.
             data_table (a record list, one row_click per row) deliberately can't
             express this — don't fold it in. --%>
        <div
          :if={@grid.rows != []}
          id="register-table-wrap"
          class="bg-base-100 border-base-300 rounded-box overflow-x-auto border"
        >
          <table id="register-table" class="text-ui min-w-full border-separate border-spacing-0">
            <thead>
              <tr class="bg-base-200/80 text-ink-subtle text-label uppercase">
                <th class="bg-base-200 border-base-300 sticky left-0 z-20 min-w-52 border-b px-4 py-3 text-left font-semibold">
                  Client
                </th>
                <th
                  :if={@grid.periods == []}
                  class="border-base-300 min-w-36 border-b px-4 py-3 text-center font-semibold"
                >
                  Period
                </th>
                <th
                  :for={period <- @grid.periods}
                  id={"register-period-#{period}"}
                  class="border-base-300 min-w-36 border-b px-4 py-3 text-center font-semibold"
                >
                  {period_label(period)}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @grid.rows}
                id={"register-row-#{row.client_id}"}
                class="group/register-row last:[&>td]:border-b-0 last:[&>th]:border-b-0"
              >
                <th class="bg-base-100 border-base-300 group-hover/register-row:bg-base-200/50 sticky left-0 z-10 border-b px-4 py-3 text-left font-medium wrap-break-word transition">
                  {row.client_name}
                </th>
                <td
                  :if={@grid.periods == []}
                  id={"register-cell-#{row.client_id}-none"}
                  class="border-base-300 group-hover/register-row:bg-base-200/50 text-ink-faint border-b px-4 py-3 text-center transition"
                >
                  —
                </td>
                <td
                  :for={period <- @grid.periods}
                  id={"register-cell-#{row.client_id}-#{period}"}
                  class="border-base-300 group-hover/register-row:bg-base-200/50 border-b p-0 text-center transition"
                >
                  <%= if cell = row.cells[period] do %>
                    <.link
                      navigate={~p"/gst/#{row.client_id}/#{period}"}
                      id={"register-link-#{row.client_id}-#{period}"}
                      title={cell_title(cell)}
                      class="hover:bg-base-200/70 text-ui flex min-h-14 flex-col justify-center px-4 py-3 transition"
                    >
                      <.filing_line
                        id={"register-r1-#{row.client_id}-#{period}"}
                        label="R1"
                        return="GSTR-1"
                        state={cell.gstr1}
                      />
                      <.filing_line
                        id={"register-3b-#{row.client_id}-#{period}"}
                        label="3B"
                        return="GSTR-3B"
                        state={cell.gstr3b}
                      />
                    </.link>
                  <% else %>
                    <span class="text-ink-faint">—</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
