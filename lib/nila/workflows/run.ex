defmodule Nila.Workflows.Run do
  use Nila.Schema
  import Ecto.Changeset

  @statuses ~w(queued running waiting_for_review completed failed cancelled)

  schema "workflow_runs" do
    field :name, :string
    field :status, :string, default: "queued"
    field :input, :map, default: %{}
    field :result, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :org, Nila.Orgs.Org
    belongs_to :document, Nila.Documents.Document
    has_many :steps, Nila.Workflows.Step, foreign_key: :workflow_run_id

    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :org_id,
      :document_id,
      :name,
      :status,
      :input,
      :result,
      :started_at,
      :completed_at
    ])
    |> validate_required([:org_id, :name, :status, :input, :result])
    |> validate_inclusion(:status, @statuses)
  end
end
