defmodule Nila.TallyJobs.Job do
  use Nila.Schema

  @statuses ~w(pending running succeeded failed indeterminate)

  schema "tally_jobs" do
    field :job_key, Ecto.UUID
    field :source_key, :string
    field :kind, :string
    field :payload, :map
    field :payload_hash, :binary
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :result, :map
    field :error, :map

    belongs_to :org, Nila.Orgs.Org
    belongs_to :device, Nila.TallyDevices.Device
    belongs_to :company, Nila.TallyDevices.Company
    belongs_to :sales_batch, Nila.Gst.Sales.Batch

    timestamps()
  end

  def create_changeset(job, attrs) do
    job
    |> cast(attrs, [:job_key, :source_key, :kind, :payload, :payload_hash])
    |> validate_required([:org_id, :device_id, :job_key, :kind, :payload])
    |> validate_inclusion(:kind, ["create_voucher", "import_vouchers"])
    |> validate_length(:source_key, max: 240)
    |> unique_constraint([:org_id, :job_key])
    |> unique_constraint([:org_id, :source_key])
  end

  def transition_changeset(job, attrs) do
    job
    |> cast(attrs, [:status, :attempts, :started_at, :completed_at, :result, :error])
    |> validate_inclusion(:status, @statuses)
  end
end
