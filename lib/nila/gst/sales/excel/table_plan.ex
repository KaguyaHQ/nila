defmodule Nila.Gst.Sales.Excel.TablePlan do
  @moduledoc "A small, typed description of one source table's headings and record rules."

  @enforce_keys [:kind, :fields, :required]
  defstruct [:id, :kind, :fields, :required, version: 1, max_column: nil, max_header_row: 30]

  @type t :: %__MODULE__{
          kind: atom(),
          id: String.t() | nil,
          fields: %{optional(String.t()) => [String.t()]},
          required: [String.t()],
          version: pos_integer(),
          max_column: pos_integer() | nil,
          max_header_row: pos_integer()
        }
end
