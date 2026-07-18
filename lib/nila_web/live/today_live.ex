defmodule NilaWeb.TodayLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.{Arrivals, Calendar, Chase, Today}

  # The front door: one row per client-month the firm should look at today,
  # grouped by who it's waiting on (Nila.Gst.Today). The junior reads
  # "Needs you" top to bottom and that is their day; clients who sent
  # nothing appear under "Waiting on the client" with the chase verbs.
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: subscribe_arrivals(socket)

    {:ok,
     socket
     |> assign(:page_title, "Today")
     |> assign(:draft, nil)
     |> assign(:arrival_group, nil)
     |> assign(:arrival_form, nil)
     |> assign(:arrival_error, nil)
     |> assign(:client_options, client_options(socket))
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
    |> assign(:arrival_groups, arrival_groups(socket))
  end

  defp list_rows(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}),
    do: Today.rows(org_id, Date.utc_today())

  defp list_rows(_socket), do: []

  defp arrival_groups(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    org_id
    |> Arrivals.pending_for_org()
    |> Enum.group_by(&{&1.client_id, &1.source, &1.sender, arrival_batch(&1)})
    |> Enum.map(fn {_key, arrivals} ->
      latest = hd(arrivals)

      %{
        id: latest.id,
        arrivals: arrivals,
        client_id: latest.client_id,
        client_name: latest.client && latest.client.name,
        source: latest.source,
        sender: latest.sender,
        received_at: latest.received_at,
        count: length(arrivals)
      }
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.received_at, :microsecond), :desc)
  end

  defp arrival_groups(_socket), do: []

  defp arrival_batch(%{source_ref: nil, id: id}), do: "arrival:#{id}"

  defp arrival_batch(%{source_ref: source_ref}) do
    source_ref |> String.split(":") |> Enum.take(2) |> Enum.join(":")
  end

  defp client_options(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    org_id |> Clients.list_clients() |> Enum.map(&{&1.name, &1.id})
  end

  defp client_options(_socket), do: []

  defp subscribe_arrivals(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}),
    do: Arrivals.subscribe(org_id)

  defp subscribe_arrivals(_socket), do: :ok

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

  def handle_event("open-arrivals", %{"arrival-id" => arrival_id}, socket) do
    group = Enum.find(socket.assigns.arrival_groups, &(to_string(&1.id) == arrival_id))

    form =
      to_form(
        %{
          "client_id" => group && group.client_id,
          "period" => Calendar.closeable_period(Date.utc_today()),
          "kind" => ""
        },
        as: :arrival
      )

    {:noreply,
     socket
     |> assign(:arrival_group, group)
     |> assign(:arrival_form, form)
     |> assign(:arrival_error, nil)}
  end

  def handle_event("close-arrivals", _params, socket) do
    {:noreply,
     socket
     |> assign(:arrival_group, nil)
     |> assign(:arrival_form, nil)
     |> assign(:arrival_error, nil)}
  end

  def handle_event("validate-arrival", %{"arrival" => params}, socket) do
    {:noreply,
     socket
     |> assign(:arrival_form, to_form(params, as: :arrival))
     |> assign(:arrival_error, nil)}
  end

  def handle_event("route-arrivals", %{"arrival" => params}, socket) do
    group = socket.assigns.arrival_group
    scope = socket.assigns.current_scope

    attrs = Map.put(params, "brought_in_by_id", scope.user.id)

    case group && Arrivals.route_many(group.arrivals, attrs) do
      {:ok, _dump} ->
        {:noreply,
         socket
         |> assign(:arrival_group, nil)
         |> assign(:arrival_form, nil)
         |> assign(:arrival_error, nil)
         |> assign_rows()
         |> put_flash(:info, "Arrival routed — extraction is queued.")}

      _error ->
        {:noreply, assign(socket, :arrival_error, "Pick a client, period, and document kind.")}
    end
  end

  def handle_event("dismiss-arrivals", _params, socket) do
    case socket.assigns.arrival_group do
      nil ->
        {:noreply, socket}

      group ->
        {:ok, _} = Arrivals.dismiss_many(group.arrivals)

        {:noreply,
         socket
         |> assign(:arrival_group, nil)
         |> assign(:arrival_form, nil)
         |> assign(:arrival_error, nil)
         |> assign_rows()
         |> put_flash(:info, "Arrival dismissed.")}
    end
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
        %{kind: draft.kind, period: draft.period, body: draft.body, channel: "manual"}
      )

    {:noreply,
     socket
     |> assign(:draft, nil)
     |> assign_rows()
     |> put_flash(:info, "Ask logged.")}
  end

  @impl true
  def handle_info({:gst_arrivals_changed, _org_id}, socket) do
    socket = assign_rows(socket)

    if socket.assigns.arrival_group &&
         not Enum.any?(
           socket.assigns.arrival_groups,
           &(&1.id == socket.assigns.arrival_group.id)
         ) do
      {:noreply,
       socket
       |> assign(:arrival_group, nil)
       |> assign(:arrival_form, nil)
       |> assign(:arrival_error, nil)
       |> put_flash(:info, "These files were already sorted — refreshed.")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp arrival_label(%{client_name: nil} = group) do
    "Unknown number #{display_sender(group)} sent #{file_phrase(group.count)}"
  end

  defp arrival_label(group) do
    "#{group.client_name} sent #{file_phrase(group.count)} over #{source_label(group.source)}"
  end

  defp source_label("whatsapp"), do: "WhatsApp"
  defp source_label("email"), do: "Email"

  defp display_sender(%{source: "whatsapp", sender: sender}), do: "+#{sender}"
  defp display_sender(%{sender: sender}), do: sender

  defp file_phrase(1), do: "a file"
  defp file_phrase(count), do: "#{count} files"

  defp arrival_age(received_at, now) do
    seconds = max(DateTime.diff(now, received_at, :second), 0)

    cond do
      seconds < 3_600 -> "#{max(div(seconds, 60), 1)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp arrival_kind_options,
    do: [{"Sales bills", "sales"}, {"Purchase bills", "purchase"}, {"GSTR-2B", "gstr2b"}]

  @impl true
  def render(assigns) do
    assigns = assigns |> assign(:today, Date.utc_today()) |> assign(:now, DateTime.utc_now())

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

        <section :if={@arrival_groups != []} id="pending-arrivals" class="space-y-2">
          <h2 class="text-base-content text-small font-semibold">New arrivals</h2>
          <.card class="divide-base-300 divide-y p-0">
            <button
              :for={group <- @arrival_groups}
              type="button"
              id={"arrival-group-#{group.id}"}
              phx-click="open-arrivals"
              phx-value-arrival-id={group.id}
              class="hover:bg-base-200/50 flex w-full items-center gap-3 px-4 py-3 text-left transition"
            >
              <.icon name="hero-inbox-arrow-down" class="text-moon size-5 shrink-0" />
              <span class="text-base-content text-small flex-1 font-medium">
                {arrival_label(group)}
              </span>
              <span class="text-base-content/50 text-fine">
                {arrival_age(group.received_at, @now)}
              </span>
              <.icon name="hero-chevron-right" class="text-base-content/40 size-4" />
            </button>
          </.card>
        </section>

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
              <div :if={r.chase_channel != "none"} class="flex items-center gap-2">
                <span
                  id={"automated-chase-#{r.client_id}-#{r.period}"}
                  class="text-base-content/70 text-fine"
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
              <span :if={r.chase_channel == "none" and !r.draft} class="text-base-content/45">
                —
              </span>
            </:col>
          </.data_table>
        </section>
      </div>

      <.modal
        :if={@arrival_group}
        id="arrival-sort-modal"
        title={"Sort #{file_phrase(@arrival_group.count)}"}
        on_close="close-arrivals"
      >
        <.form
          for={@arrival_form}
          id="arrival-sort-form"
          phx-change="validate-arrival"
          phx-submit="route-arrivals"
        >
          <div class="space-y-4">
            <div class="bg-base-200/40 rounded-box px-3 py-2">
              <p class="text-base-content/60 text-fine">
                From {display_sender(@arrival_group)} over {source_label(@arrival_group.source)}
              </p>
              <p :for={arrival <- @arrival_group.arrivals} class="text-base-content text-small mt-1">
                {arrival.filename}
              </p>
            </div>

            <.input
              field={@arrival_form[:client_id]}
              type="select"
              label="Client"
              prompt="Select a client"
              options={@client_options}
            />
            <.input
              field={@arrival_form[:period]}
              label="Period"
              placeholder="YYYY-MM"
              pattern="[0-9]{4}-[0-9]{2}"
              required
            />
            <.input
              field={@arrival_form[:kind]}
              type="select"
              label="Document kind"
              prompt="Select what arrived"
              options={arrival_kind_options()}
            />

            <p :if={@arrival_error} id="arrival-sort-error" class="text-error text-small">
              {@arrival_error}
            </p>

            <div class="flex items-center justify-between gap-3">
              <.button
                type="button"
                id="arrival-dismiss"
                variant="ghost"
                size="sm"
                phx-click="dismiss-arrivals"
              >
                Dismiss as junk
              </.button>
              <.button type="submit" id="arrival-route" size="sm">Bring into month</.button>
            </div>
          </div>
        </.form>
      </.modal>

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
