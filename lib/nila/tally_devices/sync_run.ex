defmodule Nila.TallyDevices.SyncRun do
  use Nila.Schema

  schema "tally_sync_runs" do
    field :status, :string, default: "running"
    field :masters_status, :string, default: "pending"
    field :vouchers_status, :string, default: "pending"
    field :period_start, :date
    field :period_end, :date
    field :masters_count, :integer
    field :vouchers_count, :integer
    field :masters_error, :string
    field :vouchers_error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    belongs_to :org, Nila.Orgs.Org
    belongs_to :device, Nila.TallyDevices.Device
    belongs_to :company, Nila.TallyDevices.Company
    timestamps()
  end
end
