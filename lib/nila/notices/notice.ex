defmodule Nila.Notices.Notice do
  use Nila.Schema

  schema "gst_notices" do
    belongs_to :client, Nila.Clients.Client
    field :gstin, :string
    field :reference, :string
    field :notice_type, :string
    field :issued_on, :date
    field :reply_due_on, :date
    field :payload, :map
    field :fetched_at, :utc_datetime_usec
    timestamps()
  end
end
