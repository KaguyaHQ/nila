defmodule NilaWeb.TodayLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Filing.Calendar
  alias Nila.Gst.Intake.Arrivals, as: IntakeArrivals
  alias NilaWeb.Components.Today.{Arrivals, Modals, WorkQueue}

  # The front door: one row per client-month the firm should look at today,
  # grouped by who it's waiting on (Nila.Gst.WorkQueue). The junior reads
  # "Needs you" top to bottom and that is their day; clients who sent
  # nothing appear under "Waiting on the client" with the chase verbs.
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: subscribe_arrivals(socket)

    {:ok,
     socket
     |> assign(:page_title, "Today")
     |> assign(:draft, nil)
     |> assign(:chase_history, nil)
     |> assign(:arrival_group, nil)
     |> assign(:arrival_form, nil)
     |> assign(:arrival_error, nil)
     |> assign(:client_options, client_options(socket))
     |> assign_rows()}
  end

  defp assign_rows(socket) do
    rows = list_rows(socket)

    sections =
      Nila.Gst.WorkQueue.sections()
      |> Enum.map(fn section -> {section, Enum.filter(rows, &(&1.section == section))} end)
      |> Enum.reject(fn {_section, rows} -> rows == [] end)

    socket
    |> assign(:rows, rows)
    |> assign(:sections, sections)
    |> assign(:arrival_groups, arrival_groups(socket))
  end

  defp list_rows(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}),
    do: Nila.Gst.WorkQueue.rows(org_id, Date.utc_today())

  defp list_rows(_socket), do: []

  defp arrival_groups(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    org_id
    |> IntakeArrivals.pending_for_org()
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
    do: IntakeArrivals.subscribe(org_id)

  defp subscribe_arrivals(_socket), do: :ok

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

  def handle_event(
        "open-chase-history",
        %{"client-id" => client_id, "period" => period},
        socket
      ) do
    row =
      Enum.find(
        socket.assigns.rows,
        &(to_string(&1.client_id) == client_id and &1.period == period)
      )

    {:noreply,
     assign(
       socket,
       :chase_history,
       row &&
         %{
           client_name: row.client_name,
           period_label: period_label(row.period),
           asks: Chase.list_asks(row.org_id, row.client_id, row.period)
         }
     )}
  end

  def handle_event("close-chase-history", _params, socket) do
    {:noreply, assign(socket, :chase_history, nil)}
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

    case group && IntakeArrivals.route_many(group.arrivals, attrs) do
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
        {:ok, _} = IntakeArrivals.dismiss_many(group.arrivals)

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
      <div id="today-page" class="space-y-region mx-auto max-w-6xl">
        <.page_header eyebrow="Today" title="Today">
          Every client's month, led by who it's waiting on.
          <:actions>
            <.button navigate={~p"/gst/upload"} id="add-month">Bring in documents</.button>
          </:actions>
        </.page_header>

        <Arrivals.new_arrivals groups={@arrival_groups} now={@now} />

        <WorkQueue.work_queue sections={@sections} today={@today} />
      </div>

      <Arrivals.arrival_sort_modal
        group={@arrival_group}
        form={@arrival_form}
        client_options={@client_options}
        error={@arrival_error}
      />

      <Modals.modals chase_history={@chase_history} draft={@draft} />
    </Layouts.app>
    """
  end
end
