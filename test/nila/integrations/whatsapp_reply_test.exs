defmodule Nila.Integrations.WhatsAppReplyTest do
  use ExUnit.Case, async: true

  alias Nila.Integrations.WhatsAppReply

  test "signs a period ask response and rejects tampering" do
    ask_ref = Ecto.UUID.generate()

    assert {:ok, payload} = WhatsAppReply.sign(ask_ref, "client_yes")
    assert {:ok, %{ask_ref: ^ask_ref, decision: "client_yes"}} = WhatsAppReply.verify(payload)

    tampered = String.replace(payload, "client_yes", "client_no")
    assert {:error, :invalid_reply} = WhatsAppReply.verify(tampered)
  end

  test "rejects unknown decisions and malformed references" do
    assert {:error, :invalid_decision} = WhatsAppReply.sign(Ecto.UUID.generate(), "maybe")
    assert {:error, :invalid_ask_ref} = WhatsAppReply.sign("not-a-uuid", "client_yes")
    assert {:error, :invalid_reply} = WhatsAppReply.verify("garbage")
  end
end
