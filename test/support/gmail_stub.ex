defmodule Nila.GmailStub do
  def send_message(_connection, message) do
    send(self(), {:gmail_send_message, message})
    {:ok, %{message_id: "msg-123", thread_id: Map.get(message, :thread_id) || "thread-123"}}
  end

  def fetch_thread_replies(_connection, thread_refs) do
    replies =
      Enum.map(thread_refs, fn thread_ref ->
        %{
          thread_ref: thread_ref,
          message_id: "reply-#{thread_ref}",
          from: "approver@example.com",
          text: "Approved",
          attachments: []
        }
      end)

    {:ok, replies}
  end
end
