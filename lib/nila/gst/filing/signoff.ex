defmodule Nila.Gst.Filing.Signoff do
  @moduledoc "An audited GSTR-3B approval snapshot and its revocation record."
  use Nila.Schema

  @artifacts ~w(gstr3b)

  def artifacts, do: @artifacts

  schema "gst_signoffs" do
    field :artifact, :string, default: "gstr3b"
    field :snapshot, :map
    field :revoked_at, :utc_datetime_usec

    belongs_to :client_month, Nila.Gst.Purchase.Month
    belongs_to :org, Nila.Orgs.Org
    belongs_to :signed_by, Nila.Accounts.User
    belongs_to :revoked_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(signoff, attrs) do
    signoff
    |> cast(attrs, [:artifact, :snapshot])
    |> validate_required([:artifact, :org_id, :signed_by_id, :snapshot])
    |> validate_inclusion(:artifact, @artifacts)
    |> validate_required([:client_month_id])
  end
end
