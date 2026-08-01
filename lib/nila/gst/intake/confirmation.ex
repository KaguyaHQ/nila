defmodule Nila.Gst.Intake.Confirmation do
  @moduledoc """
  An append-only statement about whether the client has finished sending the
  sales-side source documents for one GST period.
  """
  use Nila.Schema

  alias Nila.Clients.Client

  @client_decisions ~w(client_yes client_no)
  @decisions @client_decisions ++ ~w(senior_override)
  @channels ~w(manual whatsapp email)

  def decisions, do: @decisions
  def channels, do: @channels

  schema "gst_intake_confirmations" do
    field :period, :string
    field :decision, :string
    field :channel, :string
    field :source_ref, :string
    field :actor_phone, :string
    field :reason, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Client
    belongs_to :actor_user, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def client_changeset(confirmation, attrs) do
    confirmation
    |> base_changeset(attrs)
    |> validate_inclusion(:decision, @client_decisions)
  end

  def override_changeset(confirmation, attrs) do
    confirmation
    |> base_changeset(attrs)
    |> validate_inclusion(:decision, ["senior_override"])
    |> validate_required([:actor_user_id, :reason])
  end

  defp base_changeset(confirmation, attrs) do
    confirmation
    |> cast(attrs, [:period, :decision, :channel, :source_ref, :actor_phone, :reason])
    |> update_change(:source_ref, &blank_to_nil/1)
    |> update_change(:actor_phone, &Client.normalize_phone/1)
    |> update_change(:reason, &normalize_reason/1)
    |> validate_required([:org_id, :client_id, :period, :decision, :channel])
    |> validate_inclusion(:decision, @decisions)
    |> validate_inclusion(:channel, @channels)
    |> validate_format(:period, ~r/\A\d{4}-\d{2}\z/)
    |> validate_format(:actor_phone, ~r/^\d{11,15}$/, allow_nil: true)
    |> unique_constraint(:source_ref, name: :gst_intake_confirmations_source_ref_index)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp normalize_reason(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp normalize_reason(value), do: value
end
