defmodule NilaWeb.Banking.UploadLive do
  use NilaWeb, :live_view

  alias Nila.Banking
  alias Nila.Banking.StatementWorker
  alias Nila.Clients
  alias Nila.Storage

  @max_pdf_bytes 20_000_000

  @impl true
  def mount(_params, _session, socket) do
    org = socket.assigns.current_scope.current_org
    if connected?(socket), do: Banking.subscribe(org.id)

    socket =
      socket
      |> assign(:page_title, "Banking")
      |> assign(:clients, list_clients(socket))
      |> assign(:statements, Banking.recent_statements(org.id, active_client_id(socket)))
      |> assign(:form, to_form(defaults(socket), as: :statement))
      |> assign(:entry_keys, %{})
      |> assign(:error, nil)
      |> allow_upload(:statement,
        accept: ~w(.pdf),
        max_entries: 1,
        max_file_size: @max_pdf_bytes,
        auto_upload: true,
        external: &presign_upload/2
      )

    {:ok, socket}
  end

  @impl true
  def handle_info({:bank_statement_progress, _statement_id, _state}, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    {:noreply,
     assign(socket, :statements, Banking.recent_statements(org_id, active_client_id(socket)))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"statement" => params}, socket) do
    {:noreply, socket |> assign(:form, to_form(params, as: :statement)) |> assign(:error, nil)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {key, entry_keys} = Map.pop(socket.assigns.entry_keys, ref)
    if key, do: Storage.delete(key)

    {:noreply,
     socket
     |> cancel_upload(:statement, ref)
     |> assign(:entry_keys, entry_keys)}
  end

  def handle_event("submit", %{"statement" => params}, socket) do
    org = socket.assigns.current_scope.current_org

    with {:ok, client} <- fetch_client(org, active_client_id(socket)),
         {:ok, _entry} <- ready_entry(socket),
         [{key, original_filename}] <- consume_statement(socket),
         {:ok, statement} <-
           record_and_enqueue(socket, client.id, params, key, original_filename) do
      {:noreply, push_navigate(socket, to: ~p"/banking/#{statement.id}")}
    else
      {:error, message} when is_binary(message) -> {:noreply, assign(socket, :error, message)}
      _error -> {:noreply, assign(socket, :error, "Nila could not bring in this statement.")}
    end
  end

  defp record_and_enqueue(socket, client_id, params, key, filename) do
    scope = socket.assigns.current_scope

    Nila.Repo.transact(fn ->
      with {:ok, statement} <-
             Banking.record_statement(
               %{
                 org_id: scope.current_org.id,
                 client_id: client_id,
                 brought_in_by_id: scope.user.id
               },
               %{
                 source_key: key,
                 original_filename: filename,
                 source_credentials: credentials(params["password"])
               }
             ),
           {:ok, _job} <- Oban.insert(StatementWorker.new(%{statement_id: statement.id})) do
        {:ok, statement}
      end
    end)
  end

  defp ready_entry(socket) do
    upload = socket.assigns.uploads.statement

    cond do
      upload.entries == [] ->
        {:error, "Choose a bank statement PDF."}

      upload_errors(upload) != [] ->
        {:error, "Remove the file with errors and try again."}

      Enum.any?(upload.entries, &(upload_errors(upload, &1) != [])) ->
        {:error, "Remove the file with errors and try again."}

      Enum.any?(upload.entries, &(not &1.done?)) ->
        {:error, "Wait for the PDF to finish uploading."}

      true ->
        {:ok, hd(upload.entries)}
    end
  end

  defp consume_statement(socket) do
    consume_uploaded_entries(socket, :statement, fn %{key: key}, entry ->
      {:ok, {key, entry.client_name}}
    end)
  end

  defp presign_upload(entry, socket) do
    case socket.assigns.current_scope.current_org do
      %{id: org_id} ->
        key = "orgs/#{org_id}/bank-statements/#{Ecto.UUID.generate()}/original.pdf"

        case Storage.presign_put(key) do
          {:ok, url} ->
            meta = %{uploader: "Put", key: key, url: url}

            {:ok, meta,
             assign(socket, :entry_keys, Map.put(socket.assigns.entry_keys, entry.ref, key))}

          {:error, _reason} ->
            {:error, %{reason: :storage_unavailable},
             assign(socket, :error, "Nila could not reach storage. Try that file again.")}
        end

      _no_org ->
        {:error, %{reason: :storage_unavailable}, socket}
    end
  end

  defp fetch_client(org, client_id) do
    case org && client_id not in [nil, ""] && Clients.get_client(org.id, client_id) do
      {:ok, client} -> {:ok, client}
      _not_found -> {:error, "Pick a client."}
    end
  end

  defp credentials(password) when is_binary(password) do
    case String.trim(password) do
      "" -> nil
      password -> %{"password" => password}
    end
  end

  defp credentials(_password), do: nil

  defp list_clients(%{assigns: %{current_scope: %{current_org: %{id: org_id}}}}) do
    org_id |> Clients.list_clients() |> Enum.map(&{&1.name, &1.id})
  end

  defp list_clients(_socket), do: []

  defp defaults(_socket), do: %{"password" => ""}

  defp active_client_id(%{assigns: %{current_scope: %{current_client: %{id: id}}}}), do: id
  defp active_client_id(_socket), do: nil

  defp banking_intake_intro(%{current_client: %{name: name}}) do
    "Upload the original bank-generated PDF for #{name}. Nila verifies the balances and prepares the Tally vouchers."
  end

  defp banking_intake_intro(_scope) do
    "Upload the original bank-generated PDF. Nila verifies the balances and prepares the Tally vouchers."
  end

  defp statement_path(statement), do: "/banking/#{statement.id}"

  defp statement_bank(statement) do
    bank_name = Banking.bank_name(statement.bank_code) || pending_bank_name(statement.status)

    if statement.account_number_masked,
      do: "#{bank_name} · #{statement.account_number_masked}",
      else: bank_name
  end

  defp pending_bank_name("failed"), do: "Bank not recognised"
  defp pending_bank_name(_status), do: "Reading statement"

  defp statement_period(%{statement_from: %Date{} = from, statement_to: %Date{} = to}),
    do: "#{format_display_date(from)}–#{format_display_date(to)}"

  defp statement_period(_statement), do: "—"

  defp transaction_count_label(1), do: "1 transaction"
  defp transaction_count_label(count), do: "#{count} transactions"

  defp review_label(1), do: "1 needs review"
  defp review_label(count), do: "#{count} need review"

  defp statement_outcome(%{status: status}) when status in ["received", "extracting"],
    do: "Reading statement"

  defp statement_outcome(%{status: "failed"}), do: "Needs review"

  defp statement_outcome(%{status: "ready", bank_transactions: transactions}) do
    counts = Enum.frequencies_by(transactions, & &1.status)
    review = Enum.sum(Enum.map(~w(unassigned failed verifying), &Map.get(counts, &1, 0)))
    ready = Map.get(counts, "ready", 0)
    queued = Map.get(counts, "queued", 0)
    posted = Map.get(counts, "posted", 0)
    ignored = Map.get(counts, "ignored", 0)

    cond do
      review > 0 and posted > 0 -> "#{posted} added · #{review_label(review)}"
      review > 0 -> review_label(review)
      queued > 0 -> "Sending to Tally"
      ready > 0 -> "#{ready} ready"
      posted > 0 and ignored > 0 -> "#{posted} added · #{ignored} left out"
      posted > 0 -> "Added to Tally"
      ignored > 0 -> "#{ignored} left out"
      true -> "Ready"
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :banking_workspace?,
        assigns.live_action == :index and assigns.statements != []
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active_client={@current_scope.current_client}
    >
      <div id="banking-page" class="space-y-region mx-auto max-w-6xl">
        <div :if={@banking_workspace?} class="space-y-region max-w-5xl">
          <.page_header eyebrow="Banking" title="Bank statements">
            Statements prepared for Tally, with anything that still needs your review.
            <:actions>
              <.button navigate={~p"/banking/new"} id="banking-bring-statement">
                <.icon name="hero-plus" class="size-4" /> Bring in statement
              </.button>
            </:actions>
          </.page_header>

          <section id="banking-statements" class="space-y-block">
            <h2 class="text-base-content text-h4 font-semibold">Statements</h2>
            <.data_table
              id="banking-statements-table"
              rows={@statements}
              row_id={&"banking-statement-#{&1.id}"}
              row_navigate={&statement_path/1}
              row_label={&"Open #{&1.original_filename} for #{&1.client.name}"}
              mode="worklist"
            >
              <:col :let={statement} label="Statement" row_header>
                {statement.original_filename}
              </:col>
              <:col :let={statement} label="Bank">
                {statement_bank(statement)}
              </:col>
              <:col :let={statement} label="Period">
                <span class="whitespace-nowrap tabular-nums">{statement_period(statement)}</span>
              </:col>
              <:col :let={statement} label="Transactions" align="right">
                {transaction_count_label(statement.transaction_count)}
              </:col>
              <:col :let={statement} label="Outcome">
                {statement_outcome(statement)}
              </:col>
            </.data_table>
          </section>
        </div>

        <.importer
          :if={!@banking_workspace?}
          id="banking-importer"
          eyebrow="Banking"
          eyebrow_path={if(@live_action == :new, do: ~p"/banking")}
          title="Bring in a bank statement"
          form={@form}
          form_id="banking-upload-form"
          show_form={@clients != []}
          upload={@uploads.statement}
          upload_id="banking-statement-pdf"
          upload_label="Bank statement"
          upload_hint="Original text PDF · scans are not accepted · up to 20 MB"
          upload_prompt="Choose PDF"
          error={@error}
          error_id="banking-upload-error"
          submit_id="banking-upload-submit"
          submit_label="Read statement"
          loading_label="Reading statement…"
        >
          <:intro>
            {banking_intake_intro(@current_scope)}
          </:intro>
          <:state :if={@clients == []}>
            <.card id="banking-upload-empty" padding="roomy" class="text-center">
              <div class="space-y-block">
                <h2 class="text-base-content text-h4 font-semibold">No clients yet</h2>
                <.button navigate={~p"/clients/new"} id="banking-add-first-client">
                  <.icon name="hero-plus" class="size-4" /> Add your first client
                </.button>
              </div>
            </.card>
          </:state>
          <:fields>
            <.input
              field={@form[:password]}
              type="password"
              label="PDF password (optional)"
              hint="Leave blank if the statement opens without one. Nila erases it after extraction."
              autocomplete="off"
            />
          </:fields>
        </.importer>
      </div>
    </Layouts.app>
    """
  end
end
