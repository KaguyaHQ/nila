defmodule Nila.Gst.InvoiceNumber do
  @moduledoc """
  Invoice-number normalization, in the two forms this codebase actually needs.

  `key/1` answers "are these the same invoice?" — it is the form to group,
  match and deduplicate on, and it is deliberately aggressive. `store/1`
  answers "what do we write down and show a reviewer?" — it is conservative,
  because the register prints this value next to a scan and a number that has
  been tidied past recognition is worse than one that is merely ugly.

  There were four copies of the matching rule and three behaviours: purchase
  reconciliation stripped surrounding punctuation and collapsed internal
  whitespace, while `Workings` and `ItcPosition` did not. That is not a
  cosmetic drift — reconciliation matched `"(INV-001)"` to `INV-001` and then
  the ITC pipeline, keying the same supply the weak way, failed to find the
  accepted row that was supposed to suppress it. The supply reappeared in the
  attestation queue after a reviewer had already answered for it.

  So: one matching rule, named, with the weak historical rule kept as
  `legacy_key/1` for the one place that has persisted digests built from it.
  """

  @doc """
  The matching key: uppercased, whitespace collapsed, surrounding punctuation
  stripped.

  Always returns a string — `nil` keys to `""` — because callers use this
  inside composite match keys where a `nil` would silently group every
  numberless invoice together with a real one. Callers that care about absence
  must check the raw value first; `Reconciliation` and `Flags` both do.
  """
  def key(invoice_number) do
    invoice_number
    |> to_string()
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/^[^0-9A-Z]+|[^0-9A-Z]+$/, "")
  end

  @doc """
  The historical weak key: trim and upcase only.

  Kept for `Workings.attestation_target/1`, whose digests are persisted inside
  signed resolutions. Recomputing those under `key/1` would orphan every
  attestation a reviewer has already given. New writes use `key/1`; this exists
  so old answers can still be found. Nothing else should call it.
  """
  def legacy_key(invoice_number),
    do: invoice_number |> to_string() |> String.trim() |> String.upcase()

  @doc """
  The storage form: trimmed and uppercased, `nil` preserved.

  Uppercasing is safe (invoice series are case-insensitive in practice and the
  portal treats them so); stripping punctuation is not, because the reviewer is
  comparing this against a printed bill.
  """
  def store(nil), do: nil
  def store(invoice_number), do: invoice_number |> to_string() |> String.trim() |> String.upcase()

  @doc "Classifies a missing or obviously misread invoice number."
  def smell(invoice_number, row_has_values?) do
    normalized = invoice_number |> to_string() |> String.trim()

    cond do
      normalized == "" and row_has_values? ->
        :missing

      Regex.match?(~r/^[6-9]\d{9}$/, normalized) ->
        :phone_number

      Regex.match?(
        ~r/^(?:\d{1,2}[-\/.]\d{1,2}[-\/.]\d{2,4}|\d{4}[-\/.]\d{1,2}[-\/.]\d{1,2})$/,
        normalized
      ) ->
        :date

      true ->
        nil
    end
  end
end
