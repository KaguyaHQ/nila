defmodule Nila.Gst.Filing.Signoff do
  @moduledoc """
  A recorded return snapshot. Legacy `"gstr1"` records belong to a sales month;
  `"gstr3b"` records belong to a purchase month. Normal sales preparation does
  not create approvals or become locked by legacy GSTR-1 records.

  Snapshots retain the figures recorded at the time. Revocation preserves the
  row, whether it comes from an explicit reopen or changed sales inputs to an
  unfiled GSTR-3B. Actually filed returns remain history.
  """
  use Nila.Schema

  @artifacts ~w(gstr1 gstr3b)

  def artifacts, do: @artifacts

  schema "gst_signoffs" do
    field :artifact, :string, default: "gstr3b"
    field :snapshot, :map
    field :revoked_at, :utc_datetime_usec

    belongs_to :client_month, Nila.Gst.Purchase.Month
    belongs_to :sales_month, Nila.Gst.Sales.Month
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
    |> validate_parent()
  end

  # Exactly one parent, matching the artifact — mirrors the DB check
  # constraint (signoff_artifact_parent).
  defp validate_parent(changeset) do
    case get_field(changeset, :artifact) do
      "gstr1" ->
        changeset
        |> validate_required([:sales_month_id])
        |> refute_field(:client_month_id)

      "gstr3b" ->
        changeset
        |> validate_required([:client_month_id])
        |> refute_field(:sales_month_id)

      _ ->
        changeset
    end
  end

  defp refute_field(changeset, field) do
    if get_field(changeset, field) do
      add_error(changeset, field, "must be empty for this artifact")
    else
      changeset
    end
  end
end
