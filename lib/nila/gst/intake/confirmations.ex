defmodule Nila.Gst.Intake.Confirmations do
  @moduledoc """
  Sales collection completeness for one client-period.

  Confirmations are append-only. The latest event is authoritative, except
  that a later active or effective sales dump makes that event stale by
  derivation. Portal snapshots and purchase-side intake do not participate.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Accounts.Policy
  alias Nila.Clients
  alias Nila.Gst.Intake.{Confirmation, Dumps}
  alias Nila.Repo

  @complete_statuses [:complete]

  @doc """
  Records a client yes/no from an already resolved intake scope. The client is
  fetched under `scope.org_id`; org/client ids in `attrs` are ignored. A
  non-nil `(org, channel, source_ref)` is idempotent.
  """
  def record_client(%{org_id: org_id}, client_id, period, attrs) do
    Repo.transact(fn ->
      with {:ok, client} <- Clients.get_client(org_id, client_id),
           {:ok, confirmation} <-
             client
             |> client_confirmation(period, attrs)
             |> insert_idempotently() do
        {:ok, confirmation}
      end
    end)
  end

  @doc """
  Records an attributed senior override. The current scope supplies the org and
  actor; the client is re-fetched under that org. Only `:sign_off` may override,
  and a nonblank reason is required.
  """
  def record_override(scope, client_id, period, attrs) do
    if Policy.can?(scope, :sign_off) do
      Repo.transact(fn ->
        with {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
             {:ok, confirmation} <-
               client
               |> override_confirmation(period, scope.user.id, attrs)
               |> insert_idempotently() do
          {:ok, confirmation}
        end
      end)
    else
      {:error, :not_allowed}
    end
  end

  @doc "The newest confirmation event for an org/client/period."
  def latest(org_id, client_id, period) do
    Repo.fetch_one(
      from c in Confirmation,
        where: c.org_id == ^org_id and c.client_id == ^client_id and c.period == ^period,
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: 1,
        preload: [:actor_user]
    )
  end

  @doc "Returns `:open`, `:client_no`, `:stale`, or `:complete`."
  def status(org_id, client_id, period) do
    case latest(org_id, client_id, period) do
      {:error, :not_found} ->
        :open

      {:ok, confirmation} ->
        cond do
          stale?(confirmation) -> :stale
          confirmation.decision == "client_no" -> :client_no
          true -> :complete
        end
    end
  end

  @doc "Whether signing may proceed for this org/client/period."
  def complete?(org_id, client_id, period),
    do: status(org_id, client_id, period) in @complete_statuses

  @doc """
  A confirmation is stale when a sales dump inserted later is still active or
  effective. Failed, held, discarded, post-filing, purchase, GSTR-2B, and filed
  GSTR-1 dumps are excluded by the existing dump-set semantics.
  """
  def stale?(%Confirmation{} = confirmation) do
    confirmation.org_id
    |> sales_dumps(confirmation.client_id, confirmation.period)
    |> Enum.any?(&(DateTime.compare(&1.inserted_at, confirmation.inserted_at) == :gt))
  end

  defp sales_dumps(org_id, client_id, period) do
    active =
      org_id
      |> Dumps.active(client_id, period)
      |> Enum.filter(&(&1.kind == "sales"))

    active ++ Dumps.effective(org_id, client_id, period, "sales")
  end

  defp client_confirmation(client, period, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("period", period)

    %Confirmation{org_id: client.org_id, client_id: client.id}
    |> Confirmation.client_changeset(attrs)
  end

  defp override_confirmation(client, period, actor_user_id, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("period", period)
      |> Map.put("decision", "senior_override")
      |> Map.put("channel", "manual")

    %Confirmation{
      org_id: client.org_id,
      client_id: client.id,
      actor_user_id: actor_user_id
    }
    |> Confirmation.override_changeset(attrs)
  end

  defp insert_idempotently(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  defp insert_idempotently(changeset) do
    source_ref = Ecto.Changeset.get_field(changeset, :source_ref)

    if source_ref do
      {:ok, confirmation} =
        Repo.insert(changeset,
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment, "(org_id, channel, source_ref) WHERE source_ref IS NOT NULL"},
          returning: true
        )

      if confirmation.id do
        {:ok, confirmation}
      else
        Repo.fetch_by(Confirmation,
          org_id: Ecto.Changeset.get_field(changeset, :org_id),
          channel: Ecto.Changeset.get_field(changeset, :channel),
          source_ref: source_ref
        )
      end
    else
      Repo.insert(changeset)
    end
  end

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
