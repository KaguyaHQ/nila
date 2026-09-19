defmodule Nila.Notices do
  @moduledoc "Notices fetched through Whitebooks, retained independently of its list window."
  import Ecto.Query
  alias Nila.{Clients, Repo}
  alias Nila.Accounts.Policy
  alias Nila.Gst.Portal
  alias Nila.Notices.{Check, Notice, SyncWorker}

  def list(org_id) do
    Repo.all(
      from n in Notice,
        join: c in assoc(n, :client),
        where: c.org_id == ^org_id,
        order_by: [desc: n.issued_on, desc: n.id],
        preload: [client: c]
    )
  end

  def checks(org_id) do
    Repo.all(
      from n in Check,
        join: c in assoc(n, :client),
        where: c.org_id == ^org_id and c.gstin == n.gstin
    )
    |> Map.new(&{&1.client_id, &1})
  end

  def client_checks(org_id) do
    connections = Portal.connections(org_id)
    checks = checks(org_id)

    checking_ids =
      Repo.all(
        from j in Oban.Job,
          where:
            j.worker == "Nila.Notices.SyncWorker" and
              j.state in ["available", "scheduled", "executing", "retryable", "suspended"] and
              fragment("? @> ?", j.args, ^%{"org_id" => org_id}),
          select: j.args
      )
      |> MapSet.new(& &1["client_id"])

    now = DateTime.utc_now()

    Enum.map(Clients.list_clients(org_id), fn client ->
      saved = connections[client.id]
      connection = if saved && saved.gstin == client.gstin, do: saved
      check = checks[client.id]

      state =
        cond do
          is_nil(client.gstin) -> :missing_gstin
          is_nil(connection) -> :not_connected
          MapSet.member?(checking_ids, client.id) -> :checking
          Portal.session_expired?(connection, now) -> :expired
          check && not is_nil(check.last_error) -> :failed
          is_nil(check) or is_nil(check.last_checked_at) -> :not_checked
          true -> :checked
        end

      %{
        id: client.id,
        client: client,
        connection: connection,
        state: state,
        last_checked_at: check && check.last_checked_at,
        last_error: check && check.last_error
      }
    end)
  end

  def fetch(org_id, id) do
    Repo.fetch_one(
      from n in Notice,
        join: c in assoc(n, :client),
        where: c.org_id == ^org_id and n.id == ^id,
        preload: [client: c]
    )
  end

  @doc "Fetches and saves one known reference without marking the client's notice list as checked."
  def fetch_by_reference(scope, client_id, reference) do
    with :ok <- authorize(scope, :edit_records),
         {:ok, reference} <- reference(reference),
         {:ok, connection} <- Portal.connection(scope.current_org.id, client_id),
         {:ok, %{"data" => detail}} <-
           Portal.notice_details(scope.current_org.id, client_id, reference),
         {:ok, attrs} <- parse_detail(reference, nil, detail) do
      Repo.transact(fn ->
        existing =
          Repo.get_by(Notice,
            client_id: client_id,
            gstin: connection.gstin,
            reference: reference
          )

        # A direct lookup must not discard evidence from an earlier list response.
        attrs =
          if existing,
            do: put_in(attrs, [:payload, "list"], existing.payload["list"]),
            else: attrs

        {:ok, save_notice!(client_id, connection.gstin, attrs)}
      end)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unexpected_response}
    end
  end

  defp reference(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 100,
      do: {:ok, value},
      else: {:error, :invalid_reference}
  end

  defp reference(_), do: {:error, :invalid_reference}

  def enqueue(scope, client_id) do
    with :ok <- authorize(scope, :edit_records),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, connection} <- Portal.connection(scope.current_org.id, client.id),
         {:ok, _} <- Portal.account(connection) do
      %{org_id: scope.current_org.id, client_id: client.id}
      |> SyncWorker.new()
      |> Oban.insert()
    end
  end

  def checking?(org_id, client_id) do
    Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == "Nila.Notices.SyncWorker" and
            j.state in ["available", "scheduled", "executing", "retryable", "suspended"] and
            fragment("? @> ?", j.args, ^%{"org_id" => org_id, "client_id" => client_id})
    )
  end

  # Network calls finish before the transaction. Failed checks keep all saved
  # notices and the last successful check time intact.
  def sync(org_id, client_id) do
    result =
      with {:ok, connection} <- Portal.connection(org_id, client_id),
           {:ok, account} <- Portal.account(connection),
           {:ok, entries} <- notice_list(org_id, client_id),
           {:ok, notices} <- fetch_details(org_id, client_id, entries) do
        Repo.transact(fn ->
          for attrs <- notices do
            save_notice!(client_id, account.gstin, attrs)
          end

          save_check(client_id, account.gstin,
            last_checked_at: DateTime.utc_now(),
            last_error: nil
          )

          {:ok, length(notices)}
        end)
      end

    case result do
      {:ok, count} ->
        {:ok, count}

      {:error, reason} ->
        record_failure(org_id, client_id, reason)
        {:error, reason}
    end
  end

  defp save_notice!(client_id, gstin, attrs) do
    %Notice{client_id: client_id, gstin: gstin}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!(
      on_conflict:
        {:replace, [:notice_type, :issued_on, :reply_due_on, :payload, :fetched_at, :updated_at]},
      conflict_target: [:client_id, :gstin, :reference],
      returning: true
    )
  end

  @doc false
  def record_failure(org_id, client_id, reason) do
    case Portal.connection(org_id, client_id) do
      {:ok, c} -> save_check(client_id, c.gstin, last_error: error_message(reason))
      _ -> :ok
    end
  end

  defp save_check(client_id, gstin, attrs) do
    %Check{client_id: client_id, gstin: gstin}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, Keyword.keys(attrs) ++ [:updated_at]},
      conflict_target: [:client_id, :gstin]
    )
  end

  def documents(%Notice{payload: %{"detail" => detail}}),
    do: Enum.map(detail["maindocs"] ++ detail["suppdocs"], & &1["dcupdtls"])

  def download(org_id, notice_id, index) when is_integer(index) and index >= 0 do
    with {:ok, notice} <- fetch(org_id, notice_id),
         %{"id" => id, "ct" => "application/pdf"} <- Enum.at(documents(notice), index),
         {:ok, %{"data" => %{"ct" => "application/pdf", "data" => encoded}}}
         when is_binary(encoded) <-
           Portal.download_document(org_id, notice.client_id, notice.gstin, id, notice.issued_on),
         true <- byte_size(encoded) <= 35_000_000,
         {:ok, <<"%PDF-", _::binary>> = bytes} <- Base.decode64(encoded) do
      {:ok, bytes}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :document_unavailable}
    end
  end

  def error_message(:session_expired),
    do: "GST login expired. Connect the client again with an OTP."

  def error_message(:not_configured),
    do: "The GST connection is not set up. Ask the workspace owner to finish setup."

  def error_message(:invalid_connection),
    do: "Check the GST username, GSTIN and OTP. The OTP request may have expired."

  def error_message(:invalid_account), do: "This client needs a valid GSTIN and GST connection."
  def error_message(:invalid_reference), do: "Enter a notice reference of up to 100 characters."
  def error_message(:not_found), do: "Connect this client's GST account first."
  def error_message(:forbidden), do: "Your role cannot perform this action."

  def error_message(:unexpected_response),
    do: "The notice details received are incomplete. Saved notices have not changed."

  def error_message({:provider, _code}),
    do: "Could not complete the GST request. Try reconnecting the GST account."

  def error_message(_),
    do: "Could not complete the GST request. Try again; saved notices have not changed."

  defp notice_list(org_id, client_id) do
    case Portal.list_notices(org_id, client_id, Date.add(Date.utc_today(), -59)) do
      {:ok, %{"data" => %{"notices" => entries}}} when is_list(entries) -> {:ok, entries}
      {:error, {:provider, "NOTC_010"}} -> {:ok, []}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unexpected_response}
    end
  end

  defp fetch_details(org_id, client_id, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with %{"refId" => ref} when is_binary(ref) and ref != "" <- entry,
           {:ok, %{"data" => detail}} <- Portal.notice_details(org_id, client_id, ref),
           {:ok, attrs} <- parse_detail(ref, entry, detail) do
        {:cont, {:ok, [attrs | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :unexpected_response}}
      end
    end)
  end

  defp parse_detail(
         ref,
         entry,
         %{
           "noticeType" => type,
           "dateOfIssue" => issued,
           "maindocs" => main,
           "suppdocs" => supplementary
         } = detail
       )
       when is_binary(type) and type != "" and is_list(main) and is_list(supplementary) do
    with {:ok, issued_on} <- date(issued),
         true <- not is_nil(issued_on),
         {:ok, due_on} <- date(detail["dueDateOfReply"]),
         true <- Enum.all?(main ++ supplementary, &valid_document?/1) do
      {:ok,
       %{
         reference: ref,
         notice_type: type,
         issued_on: issued_on,
         reply_due_on: due_on,
         payload: %{"list" => entry, "detail" => detail},
         fetched_at: DateTime.utc_now()
       }}
    else
      _ -> {:error, :unexpected_response}
    end
  end

  defp parse_detail(_, _, _), do: {:error, :unexpected_response}

  defp valid_document?(%{"dcupdtls" => %{"id" => id, "docName" => name, "ct" => ct}}),
    do: Enum.all?([id, name, ct], &(is_binary(&1) and &1 != ""))

  defp valid_document?(_), do: false

  defp date(value) when value in [nil, "", "NA"], do: {:ok, nil}

  defp date(<<day::binary-size(2), "/", month::binary-size(2), "/", year::binary-size(4)>>),
    do: Date.from_iso8601("#{year}-#{month}-#{day}")

  defp date(_), do: {:error, :invalid_date}

  defp authorize(scope, capability),
    do: if(Policy.can?(scope, capability), do: :ok, else: {:error, :forbidden})
end
