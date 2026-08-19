defmodule Nila.TallyDevices.SyncedMaster do
  use Nila.Schema

  schema "tally_synced_masters" do
    field :kind, :string
    field :identity, :string
    field :name, :string
    field :tally_guid, :string
    field :alter_id, :string
    field :data, :map, default: %{}
    belongs_to :org, Nila.Orgs.Org
    belongs_to :company, Nila.TallyDevices.Company
    belongs_to :last_seen_sync, Nila.TallyDevices.SyncRun
    timestamps()
  end
end
