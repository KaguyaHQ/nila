defmodule Nila.Gst.ChaseAsk do
  @moduledoc """
  One chase message actually sent to a client, stored append-only: the ask is
  an *event*, never mutated. The log exists so reminders don't repeat and the
  cockpit can show "asked N days ago". `body` is the drafted text as sent —
  Nila drafts, a human copies and sends; there is no channel integration.

  Kinds:

    * `month_open`    — the opening nudge: the filing month is open, send your
      sales invoices and purchase bills.
    * `missing_bills` — the specific chase: named vendor bills in GSTR-2B the
      client never sent, plus gaps in their own invoice sequence.
  """
  use Nila.Schema

  @kinds ~w(month_open missing_bills)

  def kinds, do: @kinds

  schema "gst_chase_asks" do
    field :period, :string
    field :kind, :string
    field :body, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :sent_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(chase_ask, attrs) do
    chase_ask
    |> cast(attrs, [:kind, :period, :body])
    |> validate_required([:org_id, :client_id, :sent_by_id, :kind, :period, :body])
    |> validate_inclusion(:kind, @kinds)
  end
end
