defmodule Nila.Gst.InvoiceLine do
  @moduledoc """
  Canonical line facts shared by sales invoices and purchase bills.

  Every monetary field is integer paise. Quantities and rates are `Decimal`
  values, and finite extraction states are atoms. String/number conversion is
  confined to the constructors and explicit JSON projections.
  """

  @behaviour Access

  @enforce_keys [:origin, :tax_paise]
  defstruct [
    :origin,
    :item_name,
    :description,
    :hsn_sac,
    :quantity,
    :uom,
    :unit_price_paise,
    :printed_line_amount_paise,
    :printed_line_total_paise,
    :printed_taxable_value_paise,
    :taxable_paise,
    :taxable_value_basis,
    :line_amount_tax_inclusion,
    :cgst_rate,
    :sgst_rate,
    :igst_rate,
    :tax_paise,
    :evidence
  ]

  @type taxable_value_basis ::
          :corrected
          | :printed_taxable_value
          | :derived_from_inclusive_line_amount
          | :printed_exclusive_line_amount
          | :line_amount_plus_tax_equals_total
          | :line_amount_times_rate_equals_tax
          | :derived_from_reconciled_invoice_totals

  @type tax_inclusion :: :inclusive | :exclusive | :unknown

  @taxable_value_bases %{
    "corrected" => :corrected,
    "printed_taxable_value" => :printed_taxable_value,
    "derived_from_inclusive_line_amount" => :derived_from_inclusive_line_amount,
    "printed_exclusive_line_amount" => :printed_exclusive_line_amount,
    "line_amount_plus_tax_equals_total" => :line_amount_plus_tax_equals_total,
    "line_amount_times_rate_equals_tax" => :line_amount_times_rate_equals_tax,
    "derived_from_reconciled_invoice_totals" => :derived_from_reconciled_invoice_totals
  }

  @tax_inclusions %{
    "inclusive" => :inclusive,
    "exclusive" => :exclusive,
    "unknown" => :unknown
  }

  @type t :: %__MODULE__{
          origin: :sales | :purchase,
          item_name: String.t() | nil,
          description: String.t() | nil,
          hsn_sac: String.t() | nil,
          quantity: Decimal.t() | nil,
          uom: String.t() | nil,
          unit_price_paise: integer() | nil,
          printed_line_amount_paise: integer() | nil,
          printed_line_total_paise: integer() | nil,
          printed_taxable_value_paise: integer() | nil,
          taxable_paise: integer() | nil,
          taxable_value_basis: taxable_value_basis() | nil,
          line_amount_tax_inclusion: tax_inclusion() | nil,
          cgst_rate: Decimal.t() | nil,
          sgst_rate: Decimal.t() | nil,
          igst_rate: Decimal.t() | nil,
          tax_paise: %{cgst: integer() | nil, sgst: integer() | nil, igst: integer() | nil},
          evidence: map()
        }

  @sales_money_fields %{
    unit_price_paise: "printed_unit_price",
    printed_line_amount_paise: "printed_line_amount",
    printed_line_total_paise: "printed_line_total",
    printed_taxable_value_paise: "printed_taxable_value",
    taxable_paise: "taxable_value"
  }

  @purchase_money_fields %{
    unit_price_paise: "unit_price_paise",
    printed_line_amount_paise: "printed_line_amount_paise",
    printed_line_total_paise: "printed_line_total_paise",
    printed_taxable_value_paise: "printed_taxable_value_paise",
    taxable_paise: "taxable_paise"
  }

  @doc "Converts a normalized sales line from rupees to canonical paise."
  def from_sales(line) when is_map(line), do: build(line, @sales_money_fields, :rupees)
  def from_sales(_line), do: {:error, :line_must_be_a_map}

  @doc "Validates and converts a normalized purchase line already expressed in paise."
  def from_purchase(line) when is_map(line), do: build(line, @purchase_money_fields, :paise)
  def from_purchase(_line), do: {:error, :line_must_be_a_map}

  @doc "Projects canonical line facts to the established sales JSON shape."
  def to_sales_map(%__MODULE__{} = line) do
    Map.merge(line.evidence, %{
      "item_name" => line.item_name,
      "description" => line.description,
      "hsn_sac" => line.hsn_sac,
      "quantity" => decimal_number(line.quantity),
      "uom" => line.uom,
      "unit_price" => rupees(line.unit_price_paise),
      "printed_unit_price" => rupees(line.unit_price_paise),
      "printed_line_amount" => rupees(line.printed_line_amount_paise),
      "printed_line_total" => rupees(line.printed_line_total_paise),
      "printed_taxable_value" => rupees(line.printed_taxable_value_paise),
      "taxable_value" => rupees(line.taxable_paise),
      "taxable_value_basis" => enum_string(line.taxable_value_basis),
      "line_amount_tax_inclusion" => enum_string(line.line_amount_tax_inclusion),
      "cgst_rate" => decimal_number(line.cgst_rate),
      "cgst_amount" => rupees(line.tax_paise.cgst),
      "sgst_rate" => decimal_number(line.sgst_rate),
      "sgst_amount" => rupees(line.tax_paise.sgst),
      "igst_rate" => decimal_number(line.igst_rate),
      "igst_amount" => rupees(line.tax_paise.igst)
    })
  end

  @doc "Projects canonical line facts to the established purchase JSON shape."
  def to_purchase_map(%__MODULE__{} = line) do
    Map.merge(line.evidence, %{
      "description" => line.description,
      "hsn_sac" => line.hsn_sac,
      "quantity" => decimal_number(line.quantity),
      "unit_price_paise" => line.unit_price_paise,
      "printed_line_amount_paise" => line.printed_line_amount_paise,
      "printed_line_total_paise" => line.printed_line_total_paise,
      "printed_taxable_value_paise" => line.printed_taxable_value_paise,
      "taxable_paise" => line.taxable_paise,
      "taxable_value_basis" => enum_string(line.taxable_value_basis),
      "line_amount_tax_inclusion" => enum_string(line.line_amount_tax_inclusion),
      "cgst_rate" => decimal_number(line.cgst_rate),
      "sgst_rate" => decimal_number(line.sgst_rate),
      "igst_rate" => decimal_number(line.igst_rate),
      "tax_paise" => %{
        "cgst" => line.tax_paise.cgst,
        "sgst" => line.tax_paise.sgst,
        "igst" => line.tax_paise.igst
      }
    })
  end

  @impl Access
  def fetch(%__MODULE__{} = line, key) do
    case key do
      "item_name" -> {:ok, line.item_name}
      "description" -> {:ok, line.description}
      "hsn_sac" -> {:ok, line.hsn_sac}
      "quantity" -> {:ok, decimal_number(line.quantity)}
      "uom" -> {:ok, line.uom}
      "unit_price" -> {:ok, rupees(line.unit_price_paise)}
      "printed_unit_price" -> {:ok, rupees(line.unit_price_paise)}
      "printed_line_amount" -> {:ok, rupees(line.printed_line_amount_paise)}
      "printed_line_total" -> {:ok, rupees(line.printed_line_total_paise)}
      "printed_taxable_value" -> {:ok, rupees(line.printed_taxable_value_paise)}
      "taxable_value" -> {:ok, rupees(line.taxable_paise)}
      "cgst_amount" -> {:ok, rupees(line.tax_paise.cgst)}
      "sgst_amount" -> {:ok, rupees(line.tax_paise.sgst)}
      "igst_amount" -> {:ok, rupees(line.tax_paise.igst)}
      "unit_price_paise" -> {:ok, line.unit_price_paise}
      "printed_line_amount_paise" -> {:ok, line.printed_line_amount_paise}
      "printed_line_total_paise" -> {:ok, line.printed_line_total_paise}
      "printed_taxable_value_paise" -> {:ok, line.printed_taxable_value_paise}
      "taxable_paise" -> {:ok, line.taxable_paise}
      "tax_paise" -> {:ok, tax_map(line.tax_paise)}
      "taxable_value_basis" -> {:ok, enum_string(line.taxable_value_basis)}
      "line_amount_tax_inclusion" -> {:ok, enum_string(line.line_amount_tax_inclusion)}
      "cgst_rate" -> {:ok, decimal_number(line.cgst_rate)}
      "sgst_rate" -> {:ok, decimal_number(line.sgst_rate)}
      "igst_rate" -> {:ok, decimal_number(line.igst_rate)}
      other -> Map.fetch(line.evidence, other)
    end
  end

  @impl Access
  def get_and_update(_line, _key, _function),
    do: raise(ArgumentError, "InvoiceLine facts are immutable; project them before editing")

  @impl Access
  def pop(_line, _key),
    do: raise(ArgumentError, "InvoiceLine facts are immutable; project them before editing")

  defp build(line, money_fields, unit) do
    with {:ok, money} <- money_fields(line, money_fields, unit),
         {:ok, tax} <- tax_fields(line, unit),
         {:ok, quantity} <- decimal_field(line, "quantity"),
         {:ok, cgst_rate} <- decimal_field(line, "cgst_rate"),
         {:ok, sgst_rate} <- decimal_field(line, "sgst_rate"),
         {:ok, igst_rate} <- decimal_field(line, "igst_rate"),
         {:ok, taxable_basis} <- taxable_value_basis(line["taxable_value_basis"]),
         {:ok, tax_inclusion} <- tax_inclusion(line["line_amount_tax_inclusion"]) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(money, %{
           item_name: text(line["item_name"]),
           origin: unit_origin(unit),
           description: text(line["description"]),
           hsn_sac: text(line["hsn_sac"]),
           quantity: quantity,
           uom: text(line["uom"]),
           taxable_value_basis: taxable_basis,
           line_amount_tax_inclusion: tax_inclusion,
           cgst_rate: cgst_rate,
           sgst_rate: sgst_rate,
           igst_rate: igst_rate,
           tax_paise: tax,
           evidence: evidence(line, money_fields, unit)
         })
       )}
    end
  end

  defp money_fields(line, fields, unit) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {target, source}, {:ok, values} ->
      case money(line[source], unit) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, target, value)}}
        {:error, reason} -> {:halt, {:error, {source, reason}}}
      end
    end)
  end

  defp tax_fields(line, :rupees) do
    with {:ok, cgst} <- money(line["cgst_amount"], :rupees),
         {:ok, sgst} <- money(line["sgst_amount"], :rupees),
         {:ok, igst} <- money(line["igst_amount"], :rupees) do
      {:ok, %{cgst: cgst, sgst: sgst, igst: igst}}
    end
  end

  defp tax_fields(line, :paise) do
    tax = line["tax_paise"] || %{}

    with {:ok, cgst} <- optional_paise(tax["cgst"]),
         {:ok, sgst} <- optional_paise(tax["sgst"]),
         {:ok, igst} <- optional_paise(tax["igst"]) do
      {:ok, %{cgst: cgst, sgst: sgst, igst: igst}}
    end
  end

  defp money(nil, _unit), do: {:ok, nil}
  defp money(value, :paise) when is_integer(value), do: {:ok, value}
  defp money(_value, :paise), do: {:error, :must_be_integer_paise}

  defp money(value, :rupees) do
    case Nila.Gst.Money.paise_or_error(value) do
      {:ok, paise} -> {:ok, paise}
      :missing -> {:ok, nil}
      :unreadable -> {:error, :unreadable_money}
    end
  end

  defp optional_paise(nil), do: {:ok, 0}
  defp optional_paise(value), do: money(value, :paise)

  defp decimal(nil), do: {:ok, nil}

  defp decimal(value) do
    case Nila.Gst.Money.decimal_or_error(value) do
      {:ok, decimal} -> {:ok, decimal}
      :missing -> {:ok, nil}
      :unreadable -> {:error, :unreadable_decimal}
    end
  end

  defp decimal_field(line, field) do
    case decimal(line[field]) do
      {:ok, decimal} -> {:ok, decimal}
      {:error, reason} -> {:error, {field, reason}}
    end
  end

  defp taxable_value_basis(value),
    do:
      enum(
        value,
        @taxable_value_bases,
        :unknown_taxable_value_basis
      )

  defp tax_inclusion(value) do
    enum(
      value,
      @tax_inclusions,
      :unknown_line_amount_tax_inclusion
    )
  end

  defp enum(nil, _values, _error), do: {:ok, nil}

  defp enum(value, values, error) when is_atom(value) do
    if value in Map.values(values), do: {:ok, value}, else: {:error, {error, value}}
  end

  defp enum(value, values, error) when is_binary(value) do
    case Map.fetch(values, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {error, value}}
    end
  end

  defp enum(value, _values, error), do: {:error, {error, value}}

  defp evidence(line, fields, unit) do
    consumed =
      fields
      |> Map.values()
      |> Kernel.++(
        ~w(item_name description hsn_sac quantity uom taxable_value_basis line_amount_tax_inclusion cgst_rate sgst_rate igst_rate)
      )
      |> Kernel.++(
        if(unit == :rupees, do: ~w(cgst_amount sgst_amount igst_amount), else: ["tax_paise"])
      )

    Map.drop(line, consumed)
  end

  defp text(nil), do: nil
  defp text(value), do: to_string(value)

  defp unit_origin(:rupees), do: :sales
  defp unit_origin(:paise), do: :purchase

  defp tax_map(tax), do: %{"cgst" => tax.cgst, "sgst" => tax.sgst, "igst" => tax.igst}

  defp enum_string(nil), do: nil
  defp enum_string(value), do: Atom.to_string(value)

  defp decimal_number(nil), do: nil

  defp decimal_number(%Decimal{} = value) do
    if Decimal.equal?(value, Decimal.round(value, 0)) do
      Decimal.to_integer(value)
    else
      Decimal.to_float(value)
    end
  end

  defp rupees(nil), do: nil

  defp rupees(paise) when rem(paise, 100) == 0, do: div(paise, 100)
  defp rupees(paise), do: paise |> Nila.Gst.Money.rupees() |> Decimal.to_float()
end
