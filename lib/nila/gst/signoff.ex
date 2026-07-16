defmodule Nila.Gst.Signoff do
  @moduledoc """
  A senior's certification of a worked month, stored append-only with a frozen
  `snapshot` of the numbers as they stood at signature time (summary, ITC,
  GSTR-3B, register rows). The snapshot is the point: once signed, the month
  renders from these persisted figures, not from a live re-derivation — so a
  later engine improvement can never silently change what was approved under
  the signature. This is the BlackLine/FloQast certification-lock pattern.
  """
  use Nila.Schema

  schema "gst_signoffs" do
    field :snapshot, :map

    belongs_to :client_month, Nila.Gst.ClientMonth
    belongs_to :org, Nila.Orgs.Org
    belongs_to :signed_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(signoff, attrs) do
    signoff
    |> cast(attrs, [:snapshot])
    |> validate_required([:client_month_id, :org_id, :signed_by_id, :snapshot])
  end
end
