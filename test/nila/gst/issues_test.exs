defmodule Nila.Gst.IssuesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Issues

  describe "classification of literal level_for calls" do
    # `level_for/1` returns "required" for an unknown code, which fails safe but
    # is silent. A new check whose author forgot the table would gate output
    # with no kind, showing up as a blocker nobody can answer — so the table is
    # held against the emission sites themselves.
    test "every literal code passed to level_for/1 in lib/ is classified" do
      emitted =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          ~r/level_for\("([a-z_0-9]+)"\)/
          |> Regex.scan(File.read!(path))
          |> Enum.map(fn [_match, code] -> code end)
        end)
        |> Enum.uniq()

      # Guards the scan itself: if this ever reads empty the assertion below
      # would pass vacuously.
      assert length(emitted) > 15

      assert MapSet.subset?(MapSet.new(emitted), MapSet.new(Issues.known_codes())),
             "unclassified: #{inspect(MapSet.difference(MapSet.new(emitted), MapSet.new(Issues.known_codes())))}"
    end
  end

  describe "the two axes" do
    test "a blocker is a severity and the work is a separate lookup" do
      # A missing-page issue asks for confirmation. Unsupported cess has no
      # reviewer action that can make the exporter support it.
      assert Issues.level_for("pages_unaccounted") == "required"
      assert Issues.resolution_kind("pages_unaccounted") == :confirmation
      assert Issues.level_for("cess_unsupported") == "blocking"
      assert Issues.resolution_kind("cess_unsupported") == nil
    end

    test "HSN validity and statutory checks gate output" do
      for code <- ~w(invalid_hsn_sac incomplete_hsn_sac statutory_rate_mismatch
                     statutory_rate_review hsn_inferred_code) do
        assert Issues.level_for(code) == "required", "#{code} must still gate output"
      end
    end

    test "a self-contradicting invoice is a decision, not a correction" do
      # Both heads on one bill has no single right answer to look up: which head
      # is correct depends on where the supply actually happened, which is the
      # reviewer's call and not an arithmetic fix.
      assert Issues.level_for("mixed_tax_heads") == "required"
      assert Issues.resolution_kind("mixed_tax_heads") == :decision
    end

    test "gating, advisory and blocking are read off the level" do
      required = %{"code" => "grand_total_mismatch", "level" => "required"}
      advisory = %{"code" => "rounding_variance", "level" => "advisory"}
      settled = %{"code" => "rounding_variance", "level" => "info"}
      blocker = %{"code" => "export_supply_unsupported", "level" => "blocking"}

      assert Issues.gating?(required)
      assert Issues.gating?(blocker)
      refute Issues.gating?(advisory)
      refute Issues.gating?(settled)

      assert Issues.advisory?(advisory)
      assert Issues.blocking?(blocker)
      refute Issues.blocking?(required)
    end

    test "by_kind names the work, and ignores issues that ask for none" do
      issues = [
        %{"code" => "grand_total_mismatch", "level" => "required"},
        %{"code" => "pages_unaccounted", "level" => "required"},
        %{"code" => "line_arithmetic", "level" => "required"},
        %{"code" => "rounding_variance", "level" => "advisory"}
      ]

      assert Issues.by_kind(issues) ==
               %{decision: 1, confirmation: 1, correction: 1, blocked: 0}
    end

    test "a blocker asks for no work but is still counted" do
      # Unsupported capabilities have no resolution kind. They still count;
      # other blockers can ask for a correction or decision.
      issues = [
        %{"code" => "export_supply_unsupported", "level" => "blocking"},
        %{"code" => "cess_unsupported", "level" => "blocking"},
        %{"code" => "grand_total_mismatch", "level" => "required"},
        %{"code" => "rounding_variance", "level" => "advisory"}
      ]

      assert Issues.by_kind(issues) ==
               %{decision: 1, confirmation: 0, correction: 0, blocked: 2}
    end
  end

  describe "stored issue levels" do
    test "recognized levels stand as recorded" do
      for level <- ~w(blocking required advisory info) do
        assert Issues.level(%{"code" => "rounding_variance", "level" => level}) == level
      end
    end

    test "missing and unrecognized levels require review without inferring from the code" do
      for code <- ~w(rounding_variance invalid_hsn_sac some_unknown_code) do
        missing = %{"code" => code}
        assert Issues.level(missing) == "required"
        assert Issues.gating?(missing)

        for level <- [nil, "warning", "catastrophic"] do
          issue = %{"code" => code, "level" => level}
          assert Issues.level(issue) == "required"
          assert Issues.gating?(issue)
        end
      end
    end

    test "normalize writes the effective level without changing other fields" do
      issue = %{"code" => "rounding_variance", "level" => "warning", "m" => 1}

      assert Issues.normalize(issue) == %{
               "code" => "rounding_variance",
               "level" => "required",
               "m" => 1
             }

      advisory = %{"code" => "rounding_variance", "level" => "advisory", "m" => 1}
      assert Issues.normalize(advisory) == advisory
    end
  end
end
