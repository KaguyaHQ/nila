defmodule Nila.FuzzyTest do
  use ExUnit.Case, async: true

  alias Nila.Fuzzy

  describe "normalize/1" do
    test "downcases, collapses non-alphanumerics to single spaces, trims" do
      assert Fuzzy.normalize("  5.5TR  Ducted-AC ") == "5 5tr ducted ac"
    end

    test "collapses punctuation runs but does not insert word breaks" do
      # "5.5TR" has no separator before TR, so it stays joined; only real
      # separators (the space in "5.5 TR") split the token.
      assert Fuzzy.normalize("5.5TR") == "5 5tr"
      assert Fuzzy.normalize("5.5 TR") == "5 5 tr"
    end

    test "case and punctuation-style variants normalize equal" do
      assert Fuzzy.normalize("Ducted-AC") == Fuzzy.normalize("ducted ac")
    end

    test "tolerates non-binary input" do
      assert Fuzzy.normalize(nil) == ""
    end
  end

  describe "match_score/2" do
    test "exact normalized match scores 1.0" do
      assert Fuzzy.match_score("ducted ac", "ducted ac") == 1.0
    end

    test "prefix match is floored at 0.92" do
      assert Fuzzy.match_score("ducted", "ducted ac unit") >= 0.92
    end

    test "substring match is floored at 0.82" do
      assert Fuzzy.match_score("ac unit", "ducted ac unit") >= 0.82
    end

    test "unrelated strings score low" do
      assert Fuzzy.match_score("ducted ac", "zzz widget") < 0.6
    end
  end

  describe "best_score/2" do
    test "returns the best score across a name + aliases list" do
      assert Fuzzy.best_score("5 5 ton ac", ["Cooling Coil", "5.5 Ton AC"]) == 1.0
    end

    test "empty target list scores 0.0" do
      assert Fuzzy.best_score("anything", []) == 0.0
    end
  end
end
