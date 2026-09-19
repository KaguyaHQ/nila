defmodule Nila.Notices.Run do
  use Nila.Schema

  schema "notice_check_runs" do
    belongs_to :org, Nila.Orgs.Org
    field :results, :map, default: %{}
    field :baseline_notice_id, :integer, default: 0
    field :notice_ids, {:array, :integer}, default: []
    timestamps()
  end
end
