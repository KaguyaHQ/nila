defmodule Nila.Integrations.ResendInboundWorker do
  @moduledoc """
  Turns a received email into arrivals and evidence.

  Attribution comes from the address the client replied to, not from the
  sender: the reply-to Nila issued already names the org, client, and month,
  and is signed. A partner forwarding from a personal address still lands in
  the right month, which is the thing reading a mailbox never got right.
  """

  use Oban.Worker, queue: :documents, max_attempts: 3

  require Logger

  alias Nila.Clients
  alias Nila.Clients.Client
  alias Nila.Gst.Intake.{Arrivals, InboundAddress, Messages}

  @supported_types ~w(application/pdf image/jpeg image/png image/heic image/webp)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email_id" => email_id} = args}) do
    case route(args) do
      {:ok, scope, period} ->
        sender = sender_email(args["from"])
        :ok = record_message(scope, period, email_id, sender, args)
        ingest_attachments(scope, email_id, sender)

      {:error, reason} ->
        # A stranger mailing the inbound domain, or an address we never issued.
        # Nothing to retry — dropping it is the correct end state.
        Logger.info("Resend inbound email not routed",
          email_id: email_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp route(args) do
    with {:ok, routing} <- InboundAddress.find(List.wrap(args["to"])),
         {:ok, client} <- Clients.get_client(routing.org_id, routing.client_id) do
      {:ok, %{org_id: routing.org_id, client_id: client.id}, routing.period}
    end
  end

  defp ingest_attachments(scope, email_id, sender) do
    with {:ok, attachments} <- resend().list_attachments(email_id) do
      attachments
      |> Enum.filter(&supported?/1)
      |> Enum.reduce_while(:ok, fn attachment, :ok ->
        case ingest_attachment(scope, email_id, sender, attachment) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp ingest_attachment(scope, email_id, sender, attachment) do
    # The download URL expires about an hour after the webhook, so a failure
    # here is worth a retry rather than losing the document.
    with {:ok, bytes} <- resend().download(attachment.download_url) do
      {:ok, _arrival} =
        Arrivals.ingest(scope, %{
          source: "email",
          source_ref: "resend:#{email_id}:#{attachment.id}",
          sender: sender,
          filename: attachment.filename,
          content_type: attachment.content_type,
          bytes: bytes
        })

      :ok
    end
  end

  defp record_message(scope, period, email_id, sender, args) do
    body = args["text"] |> to_string() |> String.trim()

    if body != "" and is_binary(sender) do
      {:ok, _message} =
        Messages.record_email(scope, period, %{
          source_ref: "resend:#{email_id}",
          sender: sender,
          body: body,
          received_at: DateTime.utc_now()
        })
    end

    :ok
  end

  defp supported?(%{content_type: content_type}), do: content_type in @supported_types

  defp sender_email(nil), do: nil

  defp sender_email(value) do
    case Regex.run(~r/<([^>]+)>/, value) do
      [_full, email] -> Client.normalize_email(email)
      nil -> Client.normalize_email(value)
    end
  end

  defp resend, do: Application.get_env(:nila, :resend_adapter, Nila.Integrations.Resend)
end
