defmodule Nila.Gst.Intake.MessagesTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Intake.{Message, Messages}
  alias Nila.Repo

  test "preserves inbound text and links only an explicit provider context to its period" do
    org = org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        phone: "9876543210"
      })

    {:ok, ask} =
      Chase.record_ask(%{org_id: org.id, client_id: client.id}, %{
        kind: "missing_bills",
        period: "2026-02",
        body: "Were invoices 137 and 142 cancelled?",
        channel: "whatsapp",
        provider_ref: "wamid.question"
      })

    attrs = %{
      source_ref: "whatsapp:wamid.answer",
      provider_context_ref: "wamid.question",
      sender: client.phone,
      body: "  Two invoices are cancelled  ",
      received_at: DateTime.utc_now()
    }

    assert {:ok, message} =
             Messages.record_whatsapp(%{org_id: org.id, client_id: client.id}, attrs)

    assert message.period == "2026-02"
    assert message.chase_ask_id == ask.id
    assert message.body == "Two invoices are cancelled"

    assert {:ok, replay} =
             Messages.record_whatsapp(%{org_id: org.id, client_id: client.id}, attrs)

    assert replay.id == message.id
    assert Repo.aggregate(Message, :count) == 1
  end

  test "preserves unsolicited text without guessing a GST period" do
    org = org_fixture()

    assert {:ok, message} =
             Messages.record_whatsapp(%{org_id: org.id, client_id: nil}, %{
               source_ref: "whatsapp:wamid.unsolicited",
               provider_context_ref: nil,
               sender: "919999999999",
               body: "Don't take the Ayyanar bill",
               received_at: DateTime.utc_now()
             })

    assert message.client_id == nil
    assert message.period == nil
    assert message.chase_ask_id == nil
  end
end
