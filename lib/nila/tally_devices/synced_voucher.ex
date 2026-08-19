defmodule Nila.TallyDevices.SyncedVoucher do
  use Nila.Schema

  schema "tally_synced_vouchers" do
    field :identity, :string
    field :master_id, :integer
    field :tally_guid, :string
    field :remote_id, :string
    field :date, :date
    field :voucher_type, :string
    field :voucher_number, :string
    field :narration, :string
    field :data, :map, default: %{}
    belongs_to :org, Nila.Orgs.Org
    belongs_to :company, Nila.TallyDevices.Company
    belongs_to :last_seen_sync, Nila.TallyDevices.SyncRun
    timestamps()
  end
end
