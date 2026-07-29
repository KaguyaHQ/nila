defmodule Nila.Integrations.MicrosoftGrantWorker do
  @moduledoc """
  Confirms a tenant-wide admin grant has propagated.

  Microsoft records the grant before it is usable, so the first mint after
  consent often fails. Retry rather than telling an admin their approval
  failed when it did not.
  """

  use Oban.Worker, queue: :documents, max_attempts: 6

  alias Nila.Integrations

  # Roughly 15s, 30s, 60s, 2m, 4m: a grant is usually live inside the first
  # minute, and an admin should not wait half an hour to learn it is not.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt - 1) * 15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => connection_id}} = job) do
    connection = Integrations.get_connection!(connection_id)

    case Integrations.ensure_token(connection) do
      {:ok, _connection} ->
        {:ok, _connection} = Integrations.mark_synced(connection)
        :ok

      {:error, reason} = error ->
        # Intermediate failures are the grant still propagating, not a bad
        # grant, so only a exhausted job is worth reporting as broken.
        if job.attempt >= job.max_attempts do
          {:ok, _connection} = Integrations.mark_error(connection, reason)
        end

        error
    end
  end
end
