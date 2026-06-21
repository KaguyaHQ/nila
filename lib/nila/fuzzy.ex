defmodule Nila.Fuzzy do
  @moduledoc """
  In-app fuzzy string matching over small, in-memory pools.

  Deliberately dependency-free: `String.jaro_distance/2` with prefix/substring
  boosts, run linearly over a per-org pool of a few hundred rows. If a pool ever
  outgrows that, swap a `pg_trgm` GIN index in behind these functions — the
  callers only depend on this signature, not the engine.

  Callers own thresholds, tie-breaking, and ranking; this module owns only the
  normalization rule and the per-string similarity score, so the two cannot drift.
  """

  @doc """
  Comparison-normalized form: downcased, every run of non-alphanumerics collapsed
  to a single space, trimmed. So `"5.5TR"` and `"5.5 tr"` normalize equal.
  """
  def normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  @doc """
  Similarity in `[0.0, 1.0]` between an **already-normalized** query and target.

  Jaro distance, floored by structural boosts: exact = 1.0, prefix match ≥ 0.92,
  substring match ≥ 0.82. Pass values through `normalize/1` first.
  """
  def match_score(normalized_query, normalized_target) do
    base = String.jaro_distance(normalized_query, normalized_target)

    cond do
      normalized_target == normalized_query -> 1.0
      String.starts_with?(normalized_target, normalized_query) -> max(base, 0.92)
      String.contains?(normalized_target, normalized_query) -> max(base, 0.82)
      true -> base
    end
  end

  @doc """
  Best `match_score/2` of an already-normalized query against a list of raw
  targets (e.g. a record's name plus its aliases). Each target is normalized
  here. Returns `0.0` for an empty list.
  """
  def best_score(_normalized_query, []), do: 0.0

  def best_score(normalized_query, targets) when is_list(targets) do
    targets
    |> Enum.map(&match_score(normalized_query, normalize(&1)))
    |> Enum.max()
  end
end
