defmodule Nila.Workflows do
  import Ecto.Query

  alias Nila.Repo
  alias Nila.Workflows.{Run, Step}

  def list_runs(org_id) do
    Repo.all(
      from run in Run,
        where: run.org_id == ^org_id,
        order_by: [desc: run.inserted_at],
        preload: [:document, :steps]
    )
  end

  def get_run!(id) do
    Run
    |> Repo.get!(id)
    |> Repo.preload([:document, :steps])
  end

  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  def create_step(attrs) do
    %Step{}
    |> Step.changeset(attrs)
    |> Repo.insert()
  end

  def change_run(%Run{} = run, attrs \\ %{}) do
    Run.changeset(run, attrs)
  end
end
