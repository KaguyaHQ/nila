defmodule Nila.Gst.Sales.PartyNameMatch do
  @moduledoc "Tolerates report aliases without changing names or identifying a GSTIN."

  # These describe a business, rather than distinguish its name. Keep prefixes
  # such as NEW and MINI: KALYANI and MINI KALYANI may be different businesses.
  @descriptors ~w(store stores shop shops supermarket super market mart trader traders
    trading enterprise enterprises agency agencies company co private pvt limited ltd
    llp incorporated inc corporation corp and sri shri shree)

  @doc "Returns a match, a supported possible conflict, or uncertainty across both GST names."
  def compare(reported, registered_names) do
    reported = identity_text(reported)
    names = Enum.filter(registered_names, &(is_binary(&1) and String.trim(&1) != ""))

    cond do
      Enum.any?(names, &matches?(reported, &1)) ->
        :match

      company_name?(reported) and Enum.any?(names, &company_name?/1) and
          Enum.all?(names, &distinct_names?(reported, &1)) ->
        :possible_conflict

      true ->
        :uncertain
    end
  end

  def matches?(reported, registered) when is_binary(reported) and is_binary(registered) do
    left = reported |> identity_text() |> words()
    right = words(registered)

    cond do
      left == [] or right == [] -> false
      Enum.join(left) == Enum.join(right) -> true
      true -> core_matches?(left, right) or contains_full_name?(left, right)
    end
  end

  def matches?(_, _), do: false

  # Care-of identifies another party/address, not an extension of the buyer's
  # identity. Never use a company mentioned after this marker to establish a match.
  defp identity_text(value) when is_binary(value),
    do:
      value
      |> String.split(~r/\bc\s*\/\s*o\.?\s*|\bcare\s+of\b/iu, parts: 2)
      |> hd()
      |> String.trim()

  defp identity_text(_), do: ""

  defp core(words), do: Enum.reject(words, &(&1 in @descriptors))

  defp contains_full_name?(left, right) do
    left = core(left)
    right = core(right)

    # A full multi-word registered identity can appear inside a longer heading.
    # Do not extend this to one shared word, initials, or generic business words.
    Enum.count(right, &(String.length(&1) >= 4)) >= 2 and
      Enum.any?(Enum.chunk_every(left, length(right), 1, :discard), fn chunk ->
        Enum.zip(chunk, right) |> Enum.all?(fn {a, b} -> word_matches?(a, b) end)
      end)
  end

  defp company_name?(value) do
    tokens = words(value)

    Regex.match?(~r/\b(limited|ltd|llp|incorporated|inc|corporation|corp)\b/i, value) and
      Enum.count(core(tokens), &(String.length(&1) >= 4)) >= 2
  end

  defp distinct_names?(left, right) do
    a = core(words(left))
    b = core(words(right))

    # Low similarity alone is not a contradiction. Both sides must be spelled
    # out, with no common or even loosely similar identity word. Short aliases
    # in either registered name make this inconclusive instead.
    length(a) >= 2 and length(b) >= 2 and
      Enum.all?(a ++ b, &(String.length(&1) >= 4)) and
      not Enum.any?(a, fn x ->
        Enum.any?(b, fn y -> x == y or String.jaro_distance(x, y) >= 0.8 end)
      end)
  end

  defp core_matches?(left, right) do
    left = Enum.reject(left, &(&1 in @descriptors))
    right = Enum.reject(right, &(&1 in @descriptors))

    # The registered core must be present in full and in order. At most two
    # trailing report words may describe a branch; an arbitrary shared word
    # in the middle is not enough. Short initials require exact agreement.
    right != [] and Enum.any?(right, &(String.length(&1) >= 3)) and
      length(left) in length(right)..(length(right) + 2) and
      Enum.zip(Enum.take(left, length(right)), right)
      |> Enum.all?(fn {a, b} -> word_matches?(a, b) end)
  end

  defp word_matches?(a, b) do
    a == b or
      (min(String.length(a), String.length(b)) >= 7 and
         abs(String.length(a) - String.length(b)) <= 2 and
         String.first(a) == String.first(b) and String.jaro_distance(a, b) >= 0.93)
  end

  defp words(value) do
    value
    |> String.downcase()
    |> String.replace(~r/^m\s*\/\s*s\.?\s*/u, "")
    |> String.replace("&", " and ")
    |> String.replace(".", "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\bprivate\b/u, "pvt")
    |> String.replace(~r/\blimited\b/u, "ltd")
    |> String.replace(~r/\b(stores|traders)(\d+)\b/u, "\\1 \\2")
    |> String.split()
    |> Enum.reverse()
    |> Enum.drop_while(&Regex.match?(~r/^\d+$/, &1))
    |> Enum.reverse()
  end
end
