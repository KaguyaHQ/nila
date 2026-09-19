defmodule Nila.Gst.Portal.Statement do
  use Ecto.Schema

  schema "gst_portal_statements" do
    belongs_to :client, Nila.Clients.Client
    field :gstin, :string
    field :period, :string
    field :document, :map
    field :fetched_at, :utc_datetime_usec
    field :status, :string, default: "pending"
    field :last_error, :string
    timestamps(type: :utc_datetime_usec)
  end
end
