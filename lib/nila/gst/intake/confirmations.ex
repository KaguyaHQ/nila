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
  alias Nila.Clients.Client
  alias Nila.Gst.Intake.{Confirmation, Dumps}
  alias Nila.Repo

  @complete_statuses [:complete]

  @doc """
  Records a client yes/no from an already resolved intake scope. The client is
  fetched under `scope.org_id`; org/client ids in `attrs` are ignored. A
  non-nil `(org, channel, source_ref)` is idempotent.
  """
  def record_client(%{org_id: org_id}, client_id, period, attrs) do
    attrs = stringify_keys(attrs)

    Repo.transact(fn ->
      with {:ok, client} <- Clients.get_client(org_id, client_id),
           :ok <- verify_client_actor(client, attrs),
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
  A confirmation is stale while any supplied sales packet is unresolved or
  failed, or when an effective sales packet arrived after the confirmation.
  Discarded and post-filing packets do not alter the live draft, and neither
  does a failed packet a later clean extraction has already superseded.
  """
  def stale?(%Confirmation{} = confirmation) do
    dumps = Dumps.list(confirmation.org_id, confirmation.client_id, confirmation.period)
    superseded = superseded_failures(dumps)

    Enum.any?(dumps, fn dump ->
      dump.kind == "sales" and dump.id not in superseded and
        (dump.status in ~w(received extracting failed held needs_confirmation) or
           (dump.status == "extracted" and
              DateTime.compare(dump.inserted_at, confirmation.inserted_at) == :gt))
    end)
  end

  # A failed packet is a dead end rather than a queue item: extraction produced
  # nothing, so there is no work inside it for anyone to pick up. The human's
  # answer to a failure is to bring the original in again, and when that
  # re-upload extracts cleanly the failure has been answered — asking the senior
  # to *also* dismiss the corpse is bookkeeping the month should not need. The
  # other blocking statuses are not superseded this way: `held`,
  # `needs_confirmation` and the in-flight ones each carry an unanswered
  # question about their own contents, which a different packet does not answer.
  #
  # This does not slip a month past its reviewer. The packet doing the
  # superseding is itself an effective dump, so if it landed after the
  # confirmation, the `extracted`-after clause above re-opens the month for a
  # fresh answer on its own terms.
  #
  # Arrival order comes from `Dumps.list/3` (inserted_at, then id), so index
  # comparison is a total order even for packets recorded in the same tick.
  defp superseded_failures(dumps) do
    indexed = Enum.with_index(dumps)

    last_extracted =
      for {dump, index} <- indexed,
          dump.status == "extracted",
          into: %{},
          do: {dump.kind, index}

    for {dump, index} <- indexed,
        dump.status == "failed",
        index < Map.get(last_extracted, dump.kind, -1),
        into: MapSet.new(),
        do: dump.id
  end

  defp verify_client_actor(client, %{"channel" => "whatsapp", "actor_phone" => phone}) do
    if Client.normalize_phone(phone) == Client.normalize_phone(client.phone) and
         not is_nil(client.phone),
       do: :ok,
       else: {:error, :sender_mismatch}
  end

  defp verify_client_actor(_client, _attrs), do: {:error, :unsupported_client_channel}

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
