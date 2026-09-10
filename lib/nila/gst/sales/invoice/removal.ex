defmodule Nila.Gst.Sales.Invoice.Removal do
  @moduledoc "An internal tombstone for one invoice removed from active Nila work."

  use Nila.Schema

  schema "sales_invoice_removals" do
    field :batch_ref, :string
    field :source_id, :string
    field :removed_at, :utc_datetime_usec

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :removed_by, Nila.Accounts.User
  end

  def changeset(removal, attrs) do
    removal
    |> cast(attrs, [:batch_ref, :source_id, :removed_at])
    |> validate_required([:org_id, :client_id, :batch_ref, :source_id, :removed_at])
    |> validate_length(:batch_ref, max: 500)
    |> validate_length(:source_id, max: 500)
    |> unique_constraint([:org_id, :client_id, :batch_ref, :source_id])
  end
end
