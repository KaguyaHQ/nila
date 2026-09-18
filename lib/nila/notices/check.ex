defmodule Nila.Notices.Check do
  use Nila.Schema

  schema "gst_notice_checks" do
    belongs_to :client, Nila.Clients.Client
    field :gstin, :string
    field :last_checked_at, :utc_datetime_usec
    field :last_error, :string
    timestamps()
  end
end
