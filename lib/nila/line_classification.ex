defmodule Nila.LineClassification do
  @moduledoc """
  Goods-vs-service classification for line items — the input that drives
  place-of-supply derivation (goods follow the movement/ship-to state; services
  follow the recipient's registration state) and the UQC requirement (goods
  carry a Unit Quantity Code; services don't).

  `kind` is stored explicitly on every line item, but **defaults** from the
  HSN/SAC code prefix when unset: SAC codes (services) live in the `99xxxx`
  block, everything else is goods. We default, never derive live, so a later HSN
  edit can't silently flip a line's tax character.
  """

  @kinds ~w(goods service)
  def kinds, do: @kinds

  @doc """
  Default kind for an HSN/SAC code: `"service"` for SAC (`99xxxx`), else `"goods"`.
  """
  def default_kind(code) when is_binary(code) do
    if code |> String.trim() |> String.starts_with?("99"), do: "service", else: "goods"
  end

  def default_kind(_), do: "goods"

  # Unit Quantity Codes (CGST Rules / GSTR-1) required on goods lines; services
  # (SAC) carry none. Canonical subset in active use — extend as the catalog
  # grows. Enforcement on the line-item changeset is intentionally deferred until
  # the PO-extraction path normalizes its free-text units (e.g. "EA") onto this
  # vocabulary; `valid_uqc?/1` is the seam that check will use.
  @uqc_labels [
    {"NOS", "Numbers"},
    {"KGS", "Kilograms"},
    {"LTR", "Litres"},
    {"MTR", "Metres"},
    {"SQM", "Square metres"},
    {"CBM", "Cubic metres"},
    {"BOX", "Box"},
    {"SET", "Sets"},
    {"PCS", "Pieces"},
    {"UNT", "Units"},
    {"BAG", "Bags"},
    {"BTL", "Bottles"},
    {"DZN", "Dozens"},
    {"GMS", "Grams"},
    {"KLR", "Kilolitres"},
    {"PAC", "Packs"},
    {"ROL", "Rolls"},
    {"TUB", "Tubes"},
    {"DAY", "Days"}
  ]

  @uqc Enum.map(@uqc_labels, &elem(&1, 0))
  def uqc_codes, do: @uqc

  @doc """
  `{label, code}` options for a unit select, sorted by label — staff pick
  "Kilograms (KGS)", the stored value stays the bare UQC. For wide form fields
  (the catalog item form) where the full name aids discovery; the line-item grid
  uses `uqc_code_options/0` so the narrow cell shows just the code.
  """
  def uqc_options do
    @uqc_labels
    |> Enum.map(fn {code, name} -> {"#{name} (#{code})", code} end)
    |> Enum.sort()
  end

  @doc """
  `{code, code}` options for the narrow line-item grid cell, sorted by code — the
  closed select shows the bare UQC (`NOS`, `BAG`), which is also what prints on
  the GST invoice. Full names live in `uqc_options/0` for wide form fields.
  """
  def uqc_code_options do
    @uqc |> Enum.sort() |> Enum.map(&{&1, &1})
  end

  @doc "True when `unit` is a recognized UQC (case-insensitive)."
  def valid_uqc?(unit) when is_binary(unit), do: String.upcase(String.trim(unit)) in @uqc
  def valid_uqc?(_), do: false

  # Free-text unit synonyms the PO-extraction path emits, mapped onto the canonical
  # UQC. Keep this to genuine aliases ("EA"/"EACH" ⇒ NOS) — anything already a valid
  # UQC passes straight through `normalize_uqc/1`, and an unrecognized unit is left
  # as-is so the line-item changeset rejects it rather than this silently guessing.
  @uqc_synonyms %{
    "EA" => "NOS",
    "EACH" => "NOS",
    "NO" => "NOS",
    "NO." => "NOS",
    "NOS." => "NOS",
    "PC" => "PCS",
    "PIECE" => "PCS",
    "PIECES" => "PCS",
    "UNIT" => "UNT",
    "UNITS" => "UNT",
    "KG" => "KGS",
    "KGM" => "KGS",
    "MTRS" => "MTR",
    "METER" => "MTR",
    "METRE" => "MTR",
    "LTRS" => "LTR",
    "LITRE" => "LTR",
    "SETS" => "SET",
    "BOXES" => "BOX"
  }

  @doc """
  Best-effort map of a free-text unit onto its canonical UQC: trims/upcases,
  resolves a known synonym, and returns an already-valid UQC unchanged. An
  unrecognized unit is returned upcased (still invalid) so the caller's changeset
  is the one that rejects it.
  """
  def normalize_uqc(unit) when is_binary(unit) do
    code = unit |> String.trim() |> String.upcase()
    Map.get(@uqc_synonyms, code, code)
  end

  def normalize_uqc(unit), do: unit
end
