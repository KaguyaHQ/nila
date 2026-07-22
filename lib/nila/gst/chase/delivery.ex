defmodule Nila.Gst.Chase.Delivery do
  @moduledoc """
  One chase message actually sent to a client, stored append-only: the ask is
  an *event*, never mutated. The log exists so reminders don't repeat and the
  cockpit can show "asked N days ago". `body` is the drafted text as sent and
  `channel` records whether a human, WhatsApp, or email delivered it.

  Kinds:

    * `month_open`    — the opening nudge: the filing month is open, send your
      sales invoices and purchase bills.
    * `missing_bills` — the specific chase: named vendor bills in GSTR-2B the
      client never sent, plus gaps in their own invoice sequence.
  """
  use Nila.Schema

  @kinds ~w(month_open missing_bills)
  @channels ~w(manual whatsapp email)

  def kinds, do: @kinds
  def channels, do: @channels

  schema "gst_chase_asks" do
    field :period, :string
    field :kind, :string
    field :body, :string
    field :channel, :string, default: "manual"

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :sent_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(chase_ask, attrs) do
    chase_ask
    |> cast(attrs, [:kind, :period, :body, :channel])
    |> validate_required([:org_id, :client_id, :kind, :period, :body, :channel])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:channel, @channels)
    |> validate_manual_sender()
  end

  defp validate_manual_sender(changeset) do
    if get_field(changeset, :channel) == "manual" and is_nil(get_field(changeset, :sent_by_id)) do
      add_error(changeset, :sent_by_id, "is required for manual asks")
    else
      changeset
    end
  end
end
