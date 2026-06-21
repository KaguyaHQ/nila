defmodule Nila.Gst do
  @moduledoc """
  Pure GST jurisdiction logic: given the seller's state and the place of supply,
  decide whether tax is intra-state (CGST + SGST) or inter-state (IGST), and
  split a total GST amount accordingly.

  Context-neutral and pure on purpose — it takes plain state strings and integer
  paise, never schemas or the database, so the GST-correctness rules live in one
  testable place and cannot drift between quotes and invoices. Treat the tests
  against this module as the spec.
  """

  @doc """
  Returns `:intra_state` when seller and place of supply share a state,
  `:inter_state` otherwise (including when either is unknown).
  """
  def derive_gst_treatment(seller_state, pos_state)
      when is_binary(seller_state) and is_binary(pos_state) and seller_state == pos_state,
      do: :intra_state

  def derive_gst_treatment(_seller_state, _pos_state), do: :inter_state

  @doc """
  Maps the jurisdiction atom to the persisted `gst_treatment` string used on
  quotes and invoices.

    - `:intra_state` → `"cgst_sgst"`
    - `:inter_state` → `"igst"`
  """
  def treatment_to_persisted(:intra_state), do: "cgst_sgst"
  def treatment_to_persisted(:inter_state), do: "igst"

  @doc """
  Splits a total GST amount (paise) into `{cgst, sgst, igst}` for the treatment.

  Intra-state halves into CGST/SGST with the odd paise going to CGST (so they sum
  back exactly and stay within 1 paise of each other); inter-state is all IGST.
  """
  def split_tax(0, _treatment), do: {0, 0, 0}

  def split_tax(gst, :intra_state) do
    sgst = div(gst, 2)
    {gst - sgst, sgst, 0}
  end

  def split_tax(gst, :inter_state), do: {0, 0, gst}

  @doc """
  Classifies a persisted CGST/SGST/IGST split into the tax rows a document should
  show, so quote and invoice render the same statutory breakdown and cannot drift.

  Returns an ordered list of `{label, paise}`:

    - intra-state (cgst/sgst present) → `[{"CGST", cgst}, {"SGST", sgst}]`
    - inter-state (igst present) → `[{"IGST", igst}]`
    - neither (no split derived yet) → `[{fallback_label, gst}]`

  The fallback covers in-progress drafts whose place of supply isn't set, so the
  caller still shows a single tax line carrying `gst`; pass the label its document
  uses (e.g. `"GST"` on a quote, `"Total tax"` on a tax invoice).
  """
  def tax_breakdown(cgst, sgst, igst, gst, fallback_label) do
    cond do
      pos?(cgst) or pos?(sgst) -> [{"CGST", cgst || 0}, {"SGST", sgst || 0}]
      pos?(igst) -> [{"IGST", igst}]
      true -> [{fallback_label, gst || 0}]
    end
  end

  defp pos?(n), do: is_integer(n) and n > 0
end
