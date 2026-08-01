defmodule Nila.Gst.Hsn.Entry do
  use Nila.Schema

  schema "hsn_master_entries" do
    field :code, :string
    field :description, :string
    field :kind, :string
    field :digits, :integer
    field :parent_code, :string
    field :has_children, :boolean, default: false

    belongs_to :release, Nila.Gst.Hsn.Release

    timestamps(updated_at: false)
  end
end
