defmodule Nila.Gst.Intake.Message do
  @moduledoc "An append-only inbound client message preserved as collection evidence."

  use Nila.Schema

  schema "gst_intake_messages" do
    field :period, :string
    field :channel, :string
    field :source_ref, :string
    field :provider_context_ref, :string
    field :sender, :string
    field :body, :string
    field :received_at, :utc_datetime_usec

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :chase_ask, Nila.Gst.Chase.Delivery

    timestamps(updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :period,
      :channel,
      :source_ref,
      :provider_context_ref,
      :sender,
      :body,
      :received_at
    ])
    |> update_change(:sender, &Nila.Clients.Client.normalize_phone/1)
    |> update_change(:body, &String.trim/1)
    |> validate_required([:org_id, :channel, :source_ref, :sender, :body, :received_at])
    |> validate_inclusion(:channel, ["whatsapp"])
    |> validate_format(:period, ~r/\A\d{4}-\d{2}\z/, allow_nil: true)
    |> unique_constraint(:source_ref, name: :gst_intake_messages_source_ref_index)
  end
end
