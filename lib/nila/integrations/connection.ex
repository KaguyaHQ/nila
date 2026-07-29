defmodule Nila.Integrations.Connection do
  use Nila.Schema
  import Ecto.Changeset

  @providers ~w(gmail microsoft whatsapp)
  @email_providers ~w(gmail microsoft)
  @statuses ~w(active error disconnected)
  @last_statuses ~w(connected expired revoked error)

  schema "integration_connections" do
    field :provider, :string
    field :status, :string, default: "active"
    field :external_account_id, :string
    field :label, :string
    field :credentials, Nila.EncryptedMap
    field :settings, :map, default: %{}
    field :last_synced_at, :utc_datetime_usec
    field :last_status, :string, default: "connected"
    field :last_status_at, :utc_datetime_usec
    field :last_error, :string
    field :disconnected_at, :utc_datetime_usec

    belongs_to :org, Nila.Orgs.Org

    timestamps()
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :org_id,
      :provider,
      :status,
      :external_account_id,
      :label,
      :credentials,
      :settings,
      :last_synced_at,
      :last_status,
      :last_status_at,
      :last_error,
      :disconnected_at
    ])
    |> validate_required([:org_id, :provider, :status, :external_account_id])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:last_status, @last_statuses)
    |> update_change(:label, &normalize_blank/1)
    |> unique_constraint([:org_id, :provider, :external_account_id])
  end

  @doc """
  Changeset for the fields a person may edit.

  `settings` carries the send-as mailbox, tenant, and cc list, and `credentials`
  carries the grant. Neither is user data, so neither is castable from a form.
  """
  def settings_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:label])
    |> update_change(:label, &normalize_blank/1)
  end

  def providers, do: @providers
  def email_providers, do: @email_providers
  def statuses, do: @statuses
  def last_statuses, do: @last_statuses

  def display_label(%__MODULE__{label: label}) when label not in [nil, ""], do: label

  def display_label(%__MODULE__{external_account_id: external_account_id}),
    do: external_account_id

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
end
