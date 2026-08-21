defmodule NilaWeb.Banking.UploadLive do
  use NilaWeb, :live_view

  alias Nila.Banking
  alias Nila.Banking.StatementWorker
  alias Nila.Clients
  alias Nila.Storage

  @max_pdf_bytes 20_000_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Banking")
      |> assign(:clients, list_clients(socket))
      |> assign(:form, to_form(defaults(), as: :statement))
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

    with {:ok, client} <- fetch_client(org, params["client_id"]),
         {:ok, bank_name} <- fetch_bank(params["bank_code"]),
         {:ok, _entry} <- ready_entry(socket),
         [{key, original_filename}] <- consume_statement(socket),
         {:ok, statement} <-
           record_and_enqueue(
             socket,
             client.id,
             params,
             bank_name,
             bank_name,
             key,
             original_filename
           ) do
      {:noreply, push_navigate(socket, to: ~p"/banking/#{statement.id}")}
    else
      {:error, message} when is_binary(message) -> {:noreply, assign(socket, :error, message)}
      _error -> {:noreply, assign(socket, :error, "Nila could not bring in this statement.")}
    end
  end

  defp record_and_enqueue(socket, client_id, params, bank_name, ledger, key, filename) do
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
                 bank_code: params["bank_code"],
                 bank_name: bank_name,
                 bank_ledger_name: ledger,
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

  defp fetch_bank(code) do
    case Banking.bank_name(code) do
      nil -> {:error, "Pick a supported bank."}
      name -> {:ok, name}
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

  defp defaults do
    %{"client_id" => nil, "bank_code" => "hdfc", "password" => ""}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div id="banking-upload-page" class="space-y-section mx-auto max-w-2xl">
        <.page_header eyebrow="Banking" title="Bring in a bank statement">
          Drop the original bank-generated PDF. Nila reads its text, checks every running balance,
          and prepares Tally vouchers without OCR.
        </.page_header>

        <.card :if={@clients == []} id="banking-upload-empty" padding="roomy" class="text-center">
          <div class="space-y-block">
            <h2 class="text-base-content text-h4 font-semibold">No clients yet</h2>
            <.button navigate={~p"/clients/new"} id="banking-add-first-client">
              <.icon name="hero-plus" class="size-4" /> Add your first client
            </.button>
          </div>
        </.card>

        <.card :if={@clients != []}>
          <.form
            for={@form}
            id="banking-upload-form"
            phx-change="validate"
            phx-submit="submit"
            class="space-y-block"
          >
            <.input
              field={@form[:client_id]}
              type="select"
              label="Client"
              prompt="Select a client"
              options={@clients}
            />
            <.input field={@form[:bank_code]} type="select" label="Bank" options={Banking.banks()} />
            <.input
              field={@form[:password]}
              type="password"
              label="PDF password (optional)"
              hint="Leave blank if the statement opens without one. Nila erases it after extraction."
              autocomplete="off"
            />

            <.file_drop
              id="banking-statement-pdf"
              upload={@uploads.statement}
              label="Bank statement"
              hint="Original text PDF · scans are not accepted · up to 20 MB"
              prompt="Choose PDF"
              on_cancel="cancel-upload"
            />

            <p :if={@error} id="banking-upload-error" class="text-error text-ui">{@error}</p>

            <.button type="submit" id="banking-upload-submit" full_width>
              Read statement
            </.button>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
