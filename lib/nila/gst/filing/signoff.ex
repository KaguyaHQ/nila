defmodule Nila.Gst.Filing.Signoff do
  @moduledoc """
  A senior's certification of one return artifact, stored append-only with a
  frozen `snapshot` of the numbers as they stood at signature time. Two
  artifacts exist because the month has two submissions with different
  evidence and different timing: `"gstr1"` (the outward return, signed before
  the 11th, parented on the sales month) and `"gstr3b"` (ITC + cash payable,
  signed before the 20th, parented on the purchase month). The snapshot is
  the point: once signed, the artifact renders from these persisted figures,
  not from a live re-derivation — so a later engine improvement can never
  silently change what was approved under the signature. This is the
  BlackLine/FloQast certification-lock pattern.

  A signature never dies as a side effect: `revoked_at`/`revoked_by` record a
  deliberate senior reopen, and the row stays for audit.
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
