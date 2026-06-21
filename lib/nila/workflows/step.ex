defmodule Nila.Workflows.Step do
  use Nila.Schema
  import Ecto.Changeset

  @statuses ~w(queued running blocked waiting_for_review completed failed skipped)

  schema "workflow_steps" do
    field :name, :string
    field :position, :integer
    field :status, :string, default: "queued"
    field :input, :map, default: %{}
    field :result, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :run, Nila.Workflows.Run, foreign_key: :workflow_run_id
    belongs_to :assigned_to, Nila.Accounts.User

    timestamps()
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :workflow_run_id,
      :assigned_to_id,
      :name,
      :position,
      :status,
      :input,
      :result,
      :started_at,
      :completed_at
    ])
    |> validate_required([:workflow_run_id, :name, :position, :status, :input, :result])
    |> validate_number(:position, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
  end
end
