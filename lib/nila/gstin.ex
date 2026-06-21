defmodule Nila.Gstin do
  @moduledoc """
  GST Identification Number validation: structural format plus the official
  base-36 check digit.

  Layout (15 chars): 2 digits state code, 5 letters + 4 digits (PAN body),
  1 letter (PAN entity type), 1 alphanumeric (entity number), `Z`, 1
  alphanumeric check digit. The check digit is a weighted base-36 sum over
  the first 14 characters with alternating weights 1, 2.

  Single source of truth for GSTIN checks — `Nila.Orgs.Entity` defers here so the
  rule cannot drift.
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
