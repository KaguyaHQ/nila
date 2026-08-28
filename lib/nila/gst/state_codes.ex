defmodule Nila.Gst.StateCodes do
  @moduledoc """
  Canonical GST state codes — the statutory first two digits of a GSTIN — and the
  list of Indian states/UTs they map to.

  Single source for both the name↔code mapping used across quotes, invoices, and
  PDFs and the state list used by form selects (`Nila.Orgs.Org.indian_states/0`
  delegates here).
  """

  # {state name, GST state code}, ordered alphabetically by name so `all/0` is a
  # stable, sorted list for `<select>` options.
  @states [
    {"Andaman and Nicobar Islands", "35"},
    {"Andhra Pradesh", "37"},
    {"Arunachal Pradesh", "12"},
    {"Assam", "18"},
    {"Bihar", "10"},
    {"Chandigarh", "04"},
    {"Chhattisgarh", "22"},
    {"Dadra and Nagar Haveli and Daman and Diu", "26"},
    {"Delhi", "07"},
    {"Goa", "30"},
    {"Gujarat", "24"},
    {"Haryana", "06"},
    {"Himachal Pradesh", "02"},
    {"Jammu and Kashmir", "01"},
    {"Jharkhand", "20"},
    {"Karnataka", "29"},
    {"Kerala", "32"},
    {"Ladakh", "38"},
    {"Lakshadweep", "31"},
    {"Madhya Pradesh", "23"},
    {"Maharashtra", "27"},
    {"Manipur", "14"},
    {"Meghalaya", "17"},
    {"Mizoram", "15"},
    {"Nagaland", "13"},
    {"Odisha", "21"},
    {"Puducherry", "34"},
    {"Punjab", "03"},
    {"Rajasthan", "08"},
    {"Sikkim", "11"},
    {"Tamil Nadu", "33"},
    {"Telangana", "36"},
    {"Tripura", "16"},
    {"Uttar Pradesh", "09"},
    {"Uttarakhand", "05"},
    {"West Bengal", "19"}
  ]

  @names Enum.map(@states, &elem(&1, 0))
  @code_by_name Map.new(@states)
  @name_by_code Map.new(@states, fn {name, code} -> {code, name} end)

  @doc "All Indian state/UT names, alphabetical."
  def all, do: @names

  @doc "GST state code for a state name (e.g. `\"Delhi\"` → `\"07\"`), or nil."
  def code_for(name) when is_binary(name), do: Map.get(@code_by_name, name)
  def code_for(_), do: nil

  @doc """
  State name for a GST state code. Accepts canonical 2-character codes ("33",
  "07") and also single-character forms ("7" → "Delhi"); non-digits are stripped
  and codes longer than two digits are sliced to the leading pair. Returns nil for
  unknown codes.
  """
  def name_for(code) when is_binary(code) do
    case normalize_code(code) do
      nil -> nil
      normalized -> Map.get(@name_by_code, normalized)
    end
  end

  def name_for(_), do: nil

  @doc """
  Normalises a GST state code to its canonical 2-character form, or nil. Strips
  non-digits, pads a single digit ("7" → "07"), and slices a longer string (a full
  GSTIN, say) to its leading two digits.
  """
  def normalize_code(code) when is_binary(code) do
    digits = String.replace(code, ~r/[^\d]/, "")

    case String.length(digits) do
      1 -> "0" <> digits
      2 -> digits
      n when n > 2 -> String.slice(digits, 0, 2)
      _ -> nil
    end
  end

  def normalize_code(_), do: nil

  @doc "Returns the leading GST state code from GSTIN text, or nil when absent."
  def from_gstin(gstin) when is_binary(gstin) do
    case String.trim(gstin) do
      <<code::binary-size(2), _rest::binary>> -> code
      _missing -> nil
    end
  end

  def from_gstin(_gstin), do: nil
end
