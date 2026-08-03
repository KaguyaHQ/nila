defmodule Nila.Gst.Intake.Messages do
  @moduledoc "Persistence for inbound collection messages that are evidence, not accounting decisions."

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Chase.Delivery
  alias Nila.Gst.Intake.Message
  alias Nila.Repo

  def record_whatsapp(%{org_id: org_id} = scope, attrs) do
    attrs = string_keyed(attrs)
    ask = linked_ask(org_id, scope[:client_id], attrs["provider_context_ref"])

    record(scope, "whatsapp", attrs, chase_ask_id: ask && ask.id, period: ask && ask.period)
  end

  @doc """
  Records an inbound email as evidence.

  The period is not inferred here — it came from the address the client replied
  to, which is the whole reason the reply is attributable at all.
  """
  def record_email(%{org_id: _org_id} = scope, period, attrs) do
    record(scope, "email", string_keyed(attrs), chase_ask_id: nil, period: period)
  end

  defp record(%{org_id: org_id} = scope, channel, attrs, fields) do
    changeset =
      %Message{
        org_id: org_id,
        client_id: scope[:client_id],
        chase_ask_id: fields[:chase_ask_id],
        period: fields[:period]
      }
      |> Message.changeset(Map.put(attrs, "channel", channel))

    {:ok, message} =
      Repo.insert(changeset,
        on_conflict: :nothing,
        conflict_target: [:org_id, :channel, :source_ref],
        returning: true
      )

    if message.id do
      {:ok, message}
    else
      Repo.fetch_by(Message, org_id: org_id, channel: channel, source_ref: attrs["source_ref"])
    end
  end

  defp string_keyed(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  def list(org_id, client_id, period) do
    Repo.all(
      from m in Message,
        where: m.org_id == ^org_id and m.client_id == ^client_id and m.period == ^period,
        order_by: [desc: m.inserted_at, desc: m.id]
    )
  end

  defp linked_ask(_org_id, _client_id, nil), do: nil

  defp linked_ask(org_id, client_id, provider_context_ref) do
    Repo.one(
      from a in Delivery,
        where:
          a.org_id == ^org_id and a.client_id == ^client_id and
            a.provider_ref == ^provider_context_ref,
        limit: 1
    )
  end
end
