defmodule Nila.Gst.Portal.Connection do
  use Nila.Schema

  schema "gst_portal_connections" do
    belongs_to :client, Nila.Clients.Client
    field :gstin, :string
    field :username, :string
    field :credentials, Nila.EncryptedMap, redact: true
    field :authorized_at, :utc_datetime_usec
    timestamps()
  end
end
