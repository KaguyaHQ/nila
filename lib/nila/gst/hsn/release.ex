defmodule Nila.Gst.Hsn.Release do
  use Nila.Schema

  @statuses ~w(staged active superseded)

  schema "hsn_master_releases" do
    field :source_name, :string
    field :source_url, :string
    field :file_sha256, :string
    field :status, :string, default: "staged"
    field :observed_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec

    has_many :entries, Nila.Gst.Hsn.Entry

    timestamps(updated_at: false)
  end

  def changeset(release, attrs) do
    release
    |> cast(attrs, [
      :source_name,
      :source_url,
      :file_sha256,
      :status,
      :observed_at,
      :activated_at
    ])
    |> validate_required([:source_name, :file_sha256, :status, :observed_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:file_sha256)
  end
end
