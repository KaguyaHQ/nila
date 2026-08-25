defmodule Nila.Gst.Sales.InvoiceCorrection do
  @moduledoc "One append-only accountant correction to a sales invoice field."

  use Nila.Schema

  schema "sales_invoice_corrections" do
    field :batch_ref, :string
    field :source_id, :string
    field :field_path, :string
    field :payload, :map

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :corrected_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(correction, attrs) do
    correction
    |> cast(attrs, [:batch_ref, :source_id, :field_path, :payload])
    |> validate_required([:org_id, :client_id, :batch_ref, :source_id, :field_path, :payload])
    |> validate_length(:batch_ref, max: 500)
    |> validate_length(:source_id, max: 500)
    |> validate_length(:field_path, max: 200)
    |> validate_payload()
  end

  defp validate_payload(changeset) do
    case get_field(changeset, :payload) do
      %{"from" => _from, "to" => _to} -> changeset
      _invalid -> add_error(changeset, :payload, "must record the previous and corrected values")
    end
  end
end
