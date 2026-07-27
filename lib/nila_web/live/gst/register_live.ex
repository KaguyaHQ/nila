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

  defp cell_title(%{state: :filed} = cell) do
    [
      cell.r1_arn && "GSTR-1 ARN: #{cell.r1_arn}",
      cell.gstr3b_arn && "GSTR-3B ARN: #{cell.gstr3b_arn}"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      arns -> Enum.join(arns, " · ")
    end
  end

  defp cell_title(_cell), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="register-page" class="mx-auto max-w-6xl space-y-6">
        <.page_header eyebrow="GST" title="GST months">
          The firm's recent client-periods — open, partly filed, or filed.
        </.page_header>

        <.card :if={@grid.periods == []} id="register-empty" class="py-10 text-center">
          <div class="mx-auto max-w-md space-y-4">
            <p class="text-base-content/70 text-body font-light">
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
          class="bg-base-100 border-base-300 rounded-box shadow-moon overflow-x-auto border"
        >
          <table id="register-table" class="text-small min-w-full border-separate border-spacing-0">
            <thead>
              <tr class="bg-base-200/80 text-base-content/60 text-label uppercase">
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
                <th class="bg-base-100 border-base-300 group-hover/register-row:bg-base-200/50 sticky left-0 z-10 border-b p-4 text-left font-medium transition">
                  {row.client_name}
                </th>
                <td
                  :if={@grid.periods == []}
                  id={"register-cell-#{row.client_id}-none"}
                  class="border-base-300 group-hover/register-row:bg-base-200/50 text-base-content/35 border-b p-4 text-center transition"
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
                      class="hover:bg-base-200/70 flex min-h-14 items-center justify-center px-3 py-4 transition"
                    >
                      <.badge :if={cell.state == :filed} variant="success" class="gap-1">
                        <.icon name="hero-check-mini" class="size-3.5" /> filed
                      </.badge>
                      <.badge :if={cell.state == :partial} variant="warning" class="gap-1">
                        <span>{if cell.r1_filed, do: "R1", else: "3B"}</span>
                        <.icon name="hero-check-mini" class="size-3.5" />
                      </.badge>
                      <.badge :if={cell.state == :open} variant="neutral">open</.badge>
                    </.link>
                  <% else %>
                    <span class="text-base-content/35">—</span>
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
