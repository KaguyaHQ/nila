defmodule Nila.Gst.Dump do
  @moduledoc """
  One arrival of client documents for a month — a WhatsApp forward, a photo
  batch, a 2B download. Intake is accretive: a month is the union of its
  dumps, so each arrival is a first-class record of what came in, when, from
  whom, and whether extraction survived it.

  `kind` is human-declared at intake (`sales` | `purchase` | `gstr2b`) — the
  accountant knows what they're holding, and a mis-classified dump would
  quietly poison two returns. `source` records the channel that carried the
  arrival (`whatsapp` | `email`) when the dump was routed from one; direct
  uploads leave it nil. `invoices` holds the dump's own normalized
  extraction output (invoice ids and image paths namespaced by dump, so
  unions never collide) — the month is derived from the union across dumps,
  and a straggler dump never forces re-reading the main pile. For a 2B dump
  `invoices` holds the parsed 2B entries. `status`:
  `received → extracting → extracted | failed | held | after_filing` (`held`:
  arrived while the artifact was signed — stored, not derived, until a senior
  reopens; `after_filing`: arrived after filing — terminal and never derived
  into that filed month).
  """
  use Nila.Schema

  @kinds ~w(sales purchase gstr2b)
  @statuses ~w(received extracting extracted failed held after_filing)

  def kinds, do: @kinds

  schema "gst_dumps" do
    field :period, :string
    field :kind, :string
    field :status, :string, default: "received"
    field :source, :string
    field :file_keys, {:array, :string}, default: []
    field :invoices, {:array, :map}, default: []
    field :meta, :map, default: %{}
    field :error, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :brought_in_by, Nila.Accounts.User

    has_many :extraction_attempts, Nila.Gst.ExtractionAttempt, foreign_key: :gst_dump_id

    timestamps()
  end

  def changeset(dump, attrs) do
    dump
    |> cast(attrs, [:period, :kind, :status, :source, :file_keys, :invoices, :meta, :error])
    |> validate_inclusion(:source, ~w(whatsapp email))
    |> validate_required([:org_id, :client_id, :period, :kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:period, ~r/\A\d{4}-\d{2}\z/)
  end
end
