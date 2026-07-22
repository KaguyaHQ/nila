defmodule Nila.Gst.Intake.Arrival do
  use Nila.Schema

  @sources ~w(whatsapp email)
  @statuses ~w(pending routed dismissed)

  schema "gst_arrivals" do
    field :source, :string
    field :source_ref, :string
    field :sender, :string
    field :storage_key, :string
    field :filename, :string
    field :content_type, :string
    field :received_at, :utc_datetime_usec
    field :status, :string, default: "pending"

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :routed_dump, Nila.Gst.Intake.Dump

    timestamps()
  end

  def changeset(arrival, attrs) do
    arrival
    |> cast(attrs, [
      :source,
      :source_ref,
      :sender,
      :storage_key,
      :filename,
      :content_type,
      :received_at,
      :status
    ])
    |> validate_required([
      :org_id,
      :source,
      :sender,
      :storage_key,
      :filename,
      :content_type,
      :received_at,
      :status
    ])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:org_id, :source, :source_ref])
  end
end
