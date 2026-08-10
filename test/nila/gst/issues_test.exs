defmodule Nila.Gst.IssuesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Issues

  describe "the classification covers what the engine emits" do
    # `level_for/1` returns "required" for an unknown code, which fails safe but
    # is silent. A new check whose author forgot the table would gate approval
    # with no kind, showing up as a blocker nobody can answer — so the table is
    # held against the emission sites themselves.
    test "every code passed to level_for/1 in lib/ is classified" do
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
      # Same kind of work, two severities: both are confirmations, and only one
      # can be answered at all.
      assert Issues.level_for("pages_unaccounted") == "required"
      assert Issues.resolution_kind("pages_unaccounted") == :confirmation
      assert Issues.level_for("cess_unsupported") == "blocking"
      assert Issues.resolution_kind("cess_unsupported") == nil
    end

    test "novelty is context; every check that asserts an error still gates" do
      assert Issues.level_for("hsn_new_code") == "advisory"
      assert Issues.resolution_kind("hsn_new_code") == nil

      for code <- ~w(invalid_hsn_sac incomplete_hsn_sac hsn_multiple_rates
                     statutory_rate_mismatch rate_history_conflict hsn_inferred_code) do
        assert Issues.level_for(code) == "required", "#{code} must still gate approval"
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
      advisory = %{"code" => "hsn_new_code", "level" => "advisory"}
      settled = %{"code" => "rounding_variance", "level" => "info"}
      blocker = %{"code" => "debit_note_unsupported", "level" => "blocking"}

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
        %{"code" => "grand_total_mismatch"},
        %{"code" => "hsn_multiple_rates"},
        %{"code" => "pages_unaccounted"},
        %{"code" => "line_arithmetic"},
        %{"code" => "hsn_new_code"}
      ]

      assert Issues.by_kind(issues) ==
               %{decision: 2, confirmation: 1, correction: 1, blocked: 0}
    end

    test "a blocker asks for no work but is still counted" do
      # Every blocking code has no resolution kind — that is what makes it
      # blocking. Dropping it here would leave a count that gates the filing
      # while being invisible in the copy that reports what is open.
      issues = [
        %{"code" => "debit_note_unsupported"},
        %{"code" => "cess_unsupported"},
        %{"code" => "grand_total_mismatch"},
        %{"code" => "hsn_new_code"}
      ]

      assert Issues.by_kind(issues) ==
               %{decision: 1, confirmation: 0, correction: 0, blocked: 2}
    end
  end

  describe "legacy levels map on read, never on write" do
    test "a nil level resolves to what that code means today" do
      assert Issues.level(%{"code" => "grand_total_mismatch", "level" => nil}) == "required"
      assert Issues.level(%{"code" => "hsn_new_code"}) == "advisory"
    end

    test "a warning level resolves by code, not by blanket mapping" do
      assert Issues.level(%{"code" => "hsn_new_code", "level" => "warning"}) == "advisory"
      assert Issues.level(%{"code" => "invalid_hsn_sac", "level" => "warning"}) == "required"
    end

    test "an unknown or future level withholds approval rather than permitting one" do
      # Fail safe: an issue nobody can rank must not be silently cleared.
      assert Issues.level(%{"code" => "hsn_new_code", "level" => "catastrophic"}) == "required"
      assert Issues.level(%{"code" => "some_code_from_the_future"}) == "required"
    end

    test "normalize writes the effective level in without touching anything else" do
      normalized = Issues.normalize(%{"code" => "hsn_new_code", "level" => "warning", "m" => 1})

      assert normalized == %{"code" => "hsn_new_code", "level" => "advisory", "m" => 1}
    end

    test "every legacy fallback is visible in telemetry" do
      handler = "legacy-level-#{System.unique_integer([:positive])}"
      test = self()

      # Telemetry is global and the suite is async, so this listens for one
      # code nothing else raises rather than for any fallback at all.
      code = "issues_test_code_#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:nila, :gst, :issues, :legacy_level],
        fn _event, measurements, %{code: raised} = metadata, _config ->
          if raised == code, do: send(test, {:legacy_level, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert Issues.level(%{"code" => code, "level" => "warning"}) == "required"

      assert_receive {:legacy_level, %{count: 1},
                      %{code: ^code, stored: "warning", mapped: "required"}}

      # A level this module knows is not a fallback and must stay silent.
      assert Issues.level(%{"code" => code, "level" => "advisory"}) == "advisory"
      refute_receive {:legacy_level, _measurements, _metadata}
    end
  end
end
