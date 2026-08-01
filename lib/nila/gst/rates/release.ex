defmodule Nila.Gst.Rates.Release do
  use Nila.Schema

  @statuses ~w(staged active superseded)

  schema "gst_rate_releases" do
    field :notification_number, :string
    field :tax_type, :string
    field :source_name, :string
    field :source_url, :string
    field :file_sha256, :string
    field :published_on, :date
    field :effective_from, :date
    field :status, :string, default: "staged"
    field :observed_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec

    has_many :rules, Nila.Gst.Rates.Rule

    timestamps(updated_at: false)
  end

  def changeset(release, attrs) do
    release
    |> cast(attrs, [
      :notification_number,
      :tax_type,
      :source_name,
      :source_url,
      :file_sha256,
      :published_on,
      :effective_from,
      :status,
      :observed_at,
      :activated_at
    ])
    |> validate_required([
      :notification_number,
      :tax_type,
      :source_name,
      :file_sha256,
      :published_on,
      :effective_from,
      :status,
      :observed_at
    ])
    |> validate_inclusion(:tax_type, ["integrated"])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:file_sha256)
  end
end
