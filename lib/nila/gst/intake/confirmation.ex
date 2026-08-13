defmodule Nila.Gst.Intake.Confirmation do
  @moduledoc """
  Historical records from the retired sales-completeness confirmation workflow.

  The table and schema remain so prior audit evidence stays readable. No live
  filing or intake path creates or consults these records.
  """
  use Nila.Schema

  schema "gst_intake_confirmations" do
    field :period, :string
    field :decision, :string
    field :channel, :string
    field :source_ref, :string
    field :actor_phone, :string
    field :reason, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :actor_user, Nila.Accounts.User

    timestamps(updated_at: false)
  end
end
