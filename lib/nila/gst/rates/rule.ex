defmodule Nila.Gst.Rates.Rule do
  use Nila.Schema

  schema "gst_rate_rules" do
    field :serial_number, :integer
    field :schedule, :string
    field :total_rate, :decimal
    field :raw_code_expression, :string
    field :raw_description, :string
    field :parsed_scope, :map
    field :parser_confidence, :string

    belongs_to :release, Nila.Gst.Rates.Release

    timestamps(updated_at: false)
  end
end
