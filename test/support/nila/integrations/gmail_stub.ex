defmodule Nila.Integrations.GmailStub do
  @behaviour Nila.Integrations.GmailAdapter
  @behaviour Nila.Integrations.MailAdapter

  @impl true
  def authorize_url(opts), do: "https://gmail.test/oauth?" <> URI.encode_query(opts)

  @impl true
  def exchange_code(_code) do
    {:ok, %{"access_token" => "token", "refresh_token" => "refresh"}}
  end

  @impl true
  def profile_email(_access_token), do: {:ok, "firm@example.com"}

  @impl true
  def refresh_token(_refresh_token), do: {:error, :unexpected_refresh}

  @impl true
  def ensure_token(connection), do: {:ok, connection}

  @impl true
  def sync(_connection), do: {:ok, Process.get(:gmail_attachments, [])}

  @impl true
  def send_message(_connection, recipient, message) do
    message = Map.put(message, :to, recipient)
    send(self(), {:gmail_send_message, message})
    {:ok, %{message_id: "msg-123", thread_id: Map.get(message, :thread_id) || "thread-123"}}
  end
end
