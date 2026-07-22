defmodule NilaWeb.Gst.UploadLive do
  use NilaWeb, :live_view

  @moduledoc """
  Bring in documents — the intake action. One arrival at a time, the way
  documents actually reach a firm: sales bills early in the month, 2B when
  the portal generates it (~14th), purchase bills whenever the client gets
  around to it, stragglers after the chase. Drop whatever came; each pile
  becomes a `Nila.Gst.Intake.Dump` and a `DumpWorker` job, and the month re-derives
  from the union of everything that has arrived.

  Accepts `?client_id=&period=` so Today rows and the workbench can open it
  pre-scoped to the client-month the documents belong to.
  """

  alias Nila.Clients
  alias Nila.Gst.Filing.Calendar
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Storage

  @kinds [
    %{
      name: :sales,
      kind: "sales",
      label: "Sales bills (PDF)",
      hint: "The client's own invoices — needed for GSTR-1, due the 11th"
    },
    %{
      name: :purchase,
      kind: "purchase",
      label: "Purchase bills (PDF)",
      hint: "The shoebox — reconciled against 2B for ITC"
    },
    %{
      name: :gstr2b,
      kind: "gstr2b",
      label: "GSTR-2B (JSON)",
      hint: "From the portal, available ~the 14th. A new one replaces the old"
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: subscribe(socket)

    socket =
      socket
      |> assign(:page_title, "Bring in documents")
      |> assign(:clients, list_clients(socket))
      |> assign(:kinds, @kinds)
      |> assign(:form, to_form(prefill(socket, params), as: :intake))
      |> assign(:jobs, %{})
      |> assign(:pending, nil)
      |> allow_upload(:sales, accept: ~w(.pdf), max_entries: 1, max_file_size: 50_000_000)
      |> allow_upload(:purchase, accept: ~w(.pdf), max_entries: 1, max_file_size: 50_000_000)
      |> allow_upload(:gstr2b, accept: ~w(.json), max_entries: 1, max_file_size: 20_000_000)

    {:ok, assign(socket, :error, nil)}
  end

  defp prefill(socket, params) do
    period =
      if Enum.any?(period_options(), &(elem(&1, 1) == params["period"])),
        do: params["period"],
        else: Calendar.closeable_period(Date.utc_today())

    %{
      "client_id" => permitted_client(socket, params["client_id"]),
      "period" => period
    }
  end

  defp permitted_client(socket, client_id) do
    if Enum.any?(socket.assigns[:clients] || list_clients(socket), fn {_name, id} ->
         to_string(id) == to_string(client_id)
       end),
       do: client_id,
       else: nil
  end

  @impl true
  def handle_event("validate", %{"intake" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :intake))}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    name = Enum.find([:sales, :purchase, :gstr2b], :sales, &entry_in?(socket, &1, ref))
    {:noreply, cancel_upload(socket, name, ref)}
  end

  def handle_event("submit", %{"intake" => params}, socket) do
    org = socket.assigns.current_scope.current_org

    with {:ok, client_id} <- fetch_client(org, params["client_id"]),
         {:ok, period} <- fetch_period(params["period"]),
         {:ok, piles} <- attached_piles(socket) do
      jobs =
        Map.new(piles, fn name ->
          dump = create_dump(socket, org.id, client_id, period, name)
          {dump.id, %{kind: dump.kind, status: :queued, client_id: client_id, period: period}}
        end)

      {:noreply,
       socket
       |> assign(:jobs, jobs)
       |> assign(:error, nil)
       |> assign(:pending, %{client_id: client_id, period: period})}
    else
      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("open-month", _params, socket) do
    %{client_id: client_id, period: period} = socket.assigns.pending
    {:noreply, push_navigate(socket, to: ~p"/gst/#{client_id}/#{period}")}
  end

  def handle_event("try-again", _params, socket) do
    %{client_id: client_id, period: period} = socket.assigns.pending

    {:noreply,
     socket
     |> assign(:jobs, %{})
     |> assign(
       :form,
       to_form(%{"client_id" => to_string(client_id), "period" => period}, as: :intake)
     )}
  end

  defp attached_piles(socket) do
    case Enum.filter([:sales, :purchase, :gstr2b], &(entries(socket, &1) != [])) do
      [] -> {:error, "Drop at least one pile — sales bills, purchase bills, or the 2B."}
      piles -> {:ok, piles}
    end
  end

  defp entries(socket, name), do: socket.assigns.uploads[name].entries

  defp create_dump(socket, org_id, client_id, period, name) do
    kind = Enum.find(@kinds, &(&1.name == name)).kind
    scope = socket.assigns.current_scope

    [key] =
      consume_uploaded_entries(socket, name, fn %{path: path}, entry ->
        bytes = File.read!(path)
        ext = entry.client_name |> Path.extname() |> String.downcase()

        key =
          "orgs/#{org_id}/clients/#{client_id}/#{period}/dumps/#{Ecto.UUID.generate()}/original#{ext}"

        {:ok, _} = Storage.put(key, bytes, content_type: upload_content_type(kind))
        {:ok, key}
      end)

    {:ok, dump} =
      Dumps.record(
        %{org_id: org_id, client_id: client_id, brought_in_by_id: scope.user.id},
        %{period: period, kind: kind, file_keys: [key]}
      )

    {:ok, _job} = Oban.insert(DumpWorker.new(%{dump_id: dump.id}))
    dump
  end

  @impl true
  def handle_info({:gst_dump_progress, dump_id, _client_id, _period, _kind, message}, socket) do
    case socket.assigns.jobs do
      %{^dump_id => job} = jobs ->
        {:noreply, assign(socket, :jobs, Map.put(jobs, dump_id, apply_progress(job, message)))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp apply_progress(job, {:done, _client_id, _period}), do: %{job | status: :done}
  defp apply_progress(job, {:failed, _reason}), do: %{job | status: :failed}
  defp apply_progress(job, :held), do: %{job | status: :held}
  defp apply_progress(job, stage) when is_atom(stage), do: %{job | status: stage}

  defp entry_in?(socket, name, ref) do
    Enum.any?(socket.assigns.uploads[name].entries, &(&1.ref == ref))
  end

  defp fetch_client(org, client_id) do
    case org && client_id && client_id != "" && Clients.get_client(org.id, client_id) do
      {:ok, client} -> {:ok, client.id}
      _ -> {:error, "Pick a client."}
    end
  end

  defp fetch_period(period) when is_binary(period) do
    if Enum.any?(period_options(), &(elem(&1, 1) == period)),
      do: {:ok, period},
      else: {:error, "Pick a period."}
  end

  defp fetch_period(_period), do: {:error, "Pick a period."}

  defp period_options do
    <<year::binary-size(4), "-", month::binary-size(2)>> =
      Calendar.closeable_period(Date.utc_today())

    first_month = String.to_integer(year) * 12 + String.to_integer(month) - 1

    for offset <- 0..35 do
      month_index = first_month - offset
      option_year = div(month_index, 12)
      option_month = rem(month_index, 12) + 1
      period = "#{option_year}-#{String.pad_leading(to_string(option_month), 2, "0")}"

      {period_label(period), period}
    end
  end

  defp subscribe(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}),
    do: ClientMonths.subscribe(org_id)

  defp subscribe(_socket), do: :ok

  defp list_clients(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    org_id
    |> Clients.list_clients()
    |> Enum.map(&{&1.name, &1.id})
  end

  defp list_clients(_socket), do: []

  defp upload_content_type("gstr2b"), do: "application/json"
  defp upload_content_type(_kind), do: "application/pdf"

  defp kind_title("sales"), do: "Sales bills"
  defp kind_title("purchase"), do: "Purchase bills"
  defp kind_title("gstr2b"), do: "GSTR-2B"

  defp job_label(:queued), do: "Queued"
  defp job_label(:extracting), do: "Extracting invoices — this takes a few minutes"
  defp job_label(:deriving), do: "Deriving the GSTR-1"
  defp job_label(:reconciling), do: "Reconciling against 2B"
  defp job_label(:done), do: "Done"

  defp job_label(:held),
    do: "Held — this month's return is already signed. Open the month to have a senior reopen it."

  defp job_label(:after_filing),
    do: "This month is already filed — bring this into the current month instead"

  defp job_label(:failed), do: "Failed — check the file and bring it in again"
  defp job_label(_stage), do: "Working"

  defp job_variant(:done), do: "success"
  defp job_variant(:failed), do: "error"
  defp job_variant(:held), do: "warning"
  defp job_variant(:after_filing), do: "info"
  defp job_variant(_status), do: "neutral"

  defp working?(jobs) do
    Enum.any?(jobs, fn {_id, job} ->
      job.status not in [:done, :failed, :held, :after_filing]
    end)
  end

  defp any_done?(jobs) do
    Enum.any?(jobs, fn {_id, job} -> job.status == :done end)
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
      <div id="gst-upload-page" class="mx-auto max-w-2xl space-y-6">
        <.page_header eyebrow="Intake" title="Bring in documents">
          Drop whatever arrived — sales bills, purchase bills, the 2B, or any mix.
          Nila extracts it, adds it to the month's pile, and reworks the month.
        </.page_header>

        <.card :if={@clients == [] and @jobs == %{}} id="gst-upload-empty" class="py-10 text-center">
          <div class="space-y-4">
            <h2 class="text-base-content text-h4 font-semibold">No clients yet</h2>
            <.button navigate={~p"/clients/new"} id="gst-upload-add-first-client">
              Add your first client
            </.button>
          </div>
        </.card>

        <.card :if={@clients != [] and @jobs == %{}}>
          <.form for={@form} id="gst-upload-form" phx-change="validate" phx-submit="submit">
            <div class="space-y-5">
              <div>
                <.input
                  field={@form[:client_id]}
                  type="select"
                  label="Client"
                  prompt="Select a client"
                  options={@clients}
                />
                <p class="text-base-content/60 text-fine mt-1">
                  Client not listed?
                  <.link
                    navigate={~p"/clients/new"}
                    id="gst-upload-add-client"
                    class="text-moon font-semibold"
                  >
                    Add one
                  </.link>
                </p>
              </div>

              <.input
                field={@form[:period]}
                type="select"
                label="Period"
                options={period_options()}
              />

              <.file_drop
                :for={kind <- @kinds}
                id={"gst-upload-#{kind.name}"}
                upload={@uploads[kind.name]}
                label={kind.label}
                hint={kind.hint}
                on_cancel="cancel-upload"
              />

              <p :if={@error} id="gst-upload-error" class="text-error text-small">
                {@error}
              </p>

              <.button type="submit" id="gst-upload-submit" class="w-full">
                Bring it in
              </.button>
            </div>
          </.form>
        </.card>

        <.card :if={@jobs != %{}} id="gst-upload-progress" class="space-y-4">
          <div
            :for={{dump_id, job} <- Enum.sort(@jobs)}
            id={"gst-dump-#{dump_id}"}
            class="flex items-center gap-3"
          >
            <span
              :if={job.status not in [:done, :failed, :held, :after_filing]}
              class="loading loading-sm loading-spinner text-moon"
            ></span>
            <.icon
              :if={job.status == :done}
              name="hero-check-circle"
              class="text-success size-5 shrink-0"
            />
            <.icon
              :if={job.status == :failed}
              name="hero-exclamation-circle"
              class="text-error size-5 shrink-0"
            />
            <.icon
              :if={job.status == :held}
              name="hero-pause-circle"
              class="text-warning size-5 shrink-0"
            />
            <.icon
              :if={job.status == :after_filing}
              name="hero-information-circle"
              class="text-info size-5 shrink-0"
            />
            <div class="min-w-0 flex-1">
              <p class="text-base-content text-small font-medium">{kind_title(job.kind)}</p>
              <p class={["text-fine", "text-#{job_variant(job.status)}"]}>
                {job_label(job.status)}
              </p>
              <.link
                :if={job.status == :held}
                navigate={~p"/gst/#{job.client_id}/#{job.period}"}
                id={"gst-dump-open-month-#{dump_id}"}
                class="text-fine text-moon font-semibold"
              >
                Open the month
              </.link>
              <.link
                :if={job.status == :after_filing}
                navigate={
                  ~p"/gst/upload?client_id=#{job.client_id}&period=#{Calendar.closeable_period(Date.utc_today())}"
                }
                id={"gst-dump-open-period-#{dump_id}"}
                class="text-fine text-moon font-semibold"
              >
                Bring it into the open month →
              </.link>
              <.button
                :if={job.status == :failed}
                id={"gst-dump-try-again-#{dump_id}"}
                phx-click="try-again"
                variant="soft"
                size="xs"
                class="mt-2"
              >
                Try again
              </.button>
            </div>
          </div>

          <p :if={working?(@jobs)} class="text-base-content/60 text-small">
            You can leave this open — each pile lands on the month as it finishes.
          </p>

          <.button
            :if={not working?(@jobs) and any_done?(@jobs)}
            id="gst-upload-open-month"
            phx-click="open-month"
            variant="primary"
            class="w-full"
            autofocus
          >
            Open the month
          </.button>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
