defmodule Nila.Gst.Intake.Messages do
  @moduledoc "Persistence for inbound collection messages that are evidence, not accounting decisions."

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Chase.Delivery
  alias Nila.Gst.Intake.Message
  alias Nila.Repo

  def record_whatsapp(%{org_id: org_id} = scope, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    ask = linked_ask(org_id, scope[:client_id], attrs["provider_context_ref"])

    changeset =
      %Message{
        org_id: org_id,
        client_id: scope[:client_id],
        chase_ask_id: ask && ask.id,
        period: ask && ask.period
      }
      |> Message.changeset(Map.put(attrs, "channel", "whatsapp"))

    {:ok, message} =
      Repo.insert(changeset,
        on_conflict: :nothing,
        conflict_target: [:org_id, :channel, :source_ref],
        returning: true
      )

    if message.id do
      {:ok, message}
    else
      Repo.fetch_by(Message,
        org_id: org_id,
        channel: "whatsapp",
        source_ref: attrs["source_ref"]
      )
    end
  end

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
