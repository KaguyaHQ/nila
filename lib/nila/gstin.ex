defmodule Nila.Gstin do
  @moduledoc """
  GST Identification Number validation: structural format plus the official
  base-36 check digit.

  Layout (15 chars): 2 digits state code, 5 letters + 4 digits (PAN body),
  1 letter (PAN entity type), 1 alphanumeric (entity number), `Z`, 1
  alphanumeric check digit. The check digit is a weighted base-36 sum over
  the first 14 characters with alternating weights 1, 2.

  Single source of truth for GSTIN checks — `Nila.Orgs.Org` and
  `Nila.Clients.Client` defer here so the rule cannot drift.
  """

  import Ecto.Changeset

  @format ~r/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/
  @charset "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  @charlist String.graphemes(@charset)
  @index @charlist |> Enum.with_index() |> Map.new()

  @doc """
  Returns `true` when `gstin` is a structurally valid GSTIN with a correct
  base-36 check digit. Anything that is not a 15-char string is `false`.
  """
  def valid?(gstin) when is_binary(gstin) do
    gstin = String.trim(gstin)
    Regex.match?(@format, gstin) and checksum_ok?(gstin)
  end

  def valid?(_), do: false

  @doc """
  Changeset validator. Rejects a non-nil, non-blank `field` value that fails
  `valid?/1`; nil/blank pass through (use `validate_required/2` separately when
  the GSTIN is mandatory).
  """
  def validate_gstin(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      cond do
        value in [nil, ""] -> []
        valid?(value) -> []
        true -> [{field, "is not a valid GSTIN"}]
      end
    end)
  end

  # The glyph pairs a scanner confuses, in both directions. Deliberately short:
  # every pair added widens the search and weakens the uniqueness argument that
  # makes a repair safe.
  @confusions %{
    "0" => ~w(O D Q),
    "1" => ~w(I L T),
    "2" => ~w(Z),
    "5" => ~w(S),
    "6" => ~w(G),
    "8" => ~w(B),
    "O" => ~w(0),
    "D" => ~w(0),
    "Q" => ~w(0),
    "I" => ~w(1),
    "L" => ~w(1),
    "T" => ~w(1),
    "Z" => ~w(2),
    "S" => ~w(5),
    "G" => ~w(6),
    "B" => ~w(8)
  }

  @doc """
  Repairs an OCR-damaged GSTIN, but only when the damage has exactly one legal
  reading.

  A GSTIN is a fixed grammar with a check digit, which makes this arithmetic
  rather than guesswork: two digits, five letters, four digits, a letter, an
  alphanumeric, a literal `Z`, and a check character over the other fourteen. A
  scan that reads `32ABSP14532L1ZG` has a `1` where the grammar demands a
  letter; the only glyphs a scanner confuses with `1` are `I`, `L` and `T`, and
  of those only one produces a string whose check digit verifies. That is not a
  best guess, it is the solution to a constraint — so the value is corrected and
  the correction recorded.

  Returns `{:ok, gstin}` for an already-valid input, `{:repaired, gstin}` when
  exactly one candidate verifies, and `:error` when none do or several do. Two
  solutions means the evidence does not decide, and a coin flip on a supplier's
  identity is worse than a flag.
  """
  def repair(value) when is_binary(value) do
    candidate = value |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")

    cond do
      valid?(candidate) -> {:ok, candidate}
      String.length(candidate) != 15 -> :error
      true -> unique_reading(candidate)
    end
  end

  def repair(_value), do: :error

  defp unique_reading(candidate) do
    case candidate |> String.graphemes() |> readings() |> Enum.filter(&valid?/1) |> Enum.uniq() do
      [only] -> {:repaired, only}
      _none_or_ambiguous -> :error
    end
  end

  # Every string reachable by substituting confusable glyphs into positions whose
  # character class is currently violated. Positions that already fit the grammar
  # are left alone: a page that reads a legal character is evidence, not noise.
  defp readings(graphemes) do
    graphemes
    |> Enum.with_index()
    |> Enum.map(fn {char, index} ->
      if fits?(char, index), do: [char], else: [char | Map.get(@confusions, char, [])]
    end)
    |> cartesian()
    |> Enum.map(&Enum.join/1)
  end

  defp cartesian(lists) do
    Enum.reduce(lists, [[]], fn options, acc ->
      for prefix <- acc, option <- options, do: prefix ++ [option]
    end)
  end

  defp fits?(char, index) when index in 0..1, do: digit?(char)
  defp fits?(char, index) when index in 2..6, do: letter?(char)
  defp fits?(char, index) when index in 7..10, do: digit?(char)
  defp fits?(char, 11), do: letter?(char)
  defp fits?(char, 12), do: digit?(char) or letter?(char)
  defp fits?(char, 13), do: char == "Z"
  defp fits?(char, 14), do: digit?(char) or letter?(char)

  defp digit?(char), do: char =~ ~r/^[0-9]$/
  defp letter?(char), do: char =~ ~r/^[A-Z]$/

  defp checksum_ok?(gstin) do
    {first14, [check]} = gstin |> String.graphemes() |> Enum.split(14)

    sum =
      first14
      |> Enum.with_index()
      |> Enum.reduce(0, fn {ch, i}, acc ->
        weight = if rem(i, 2) == 0, do: 1, else: 2
        v = Map.fetch!(@index, ch) * weight
        acc + div(v, 36) + rem(v, 36)
      end)

    Enum.at(@charlist, rem(36 - rem(sum, 36), 36)) == check
  end
end
