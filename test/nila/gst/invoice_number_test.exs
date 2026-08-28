defmodule Nila.Gst.InvoiceNumberTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.InvoiceNumber

  describe "key/1" do
    test "the same invoice printed differently keys the same" do
      for variant <- ["INV-001", "inv-001", " INV-001 ", "(INV-001)", "INV-001.", "*INV-001*"] do
        assert InvoiceNumber.key(variant) == "INV-001", "#{inspect(variant)} keyed differently"
      end
    end

    test "collapses internal whitespace without deleting it" do
      assert InvoiceNumber.key("INV  001") == "INV 001"
      # Not the same invoice as "INV001" — the space is real, only its width is not.
      refute InvoiceNumber.key("INV  001") == InvoiceNumber.key("INV001")
    end

    test "keeps genuinely different numbers apart" do
      refute InvoiceNumber.key("INV-001") == InvoiceNumber.key("INV-002")
      refute InvoiceNumber.key("A/001") == InvoiceNumber.key("B/001")
    end

    test "nil keys to the empty string rather than nil" do
      # Callers embed this in composite match keys; a nil would group every
      # numberless invoice with a real one.
      assert InvoiceNumber.key(nil) == ""
    end
  end

  describe "legacy_key/1" do
    test "is the weaker historical rule, kept only for persisted digests" do
      assert InvoiceNumber.legacy_key(" inv-001 ") == "INV-001"
      # The difference that matters: surrounding punctuation survives.
      assert InvoiceNumber.legacy_key("(INV-001)") == "(INV-001)"
      refute InvoiceNumber.legacy_key("(INV-001)") == InvoiceNumber.key("(INV-001)")
    end
  end

  describe "store/1" do
    test "tidies for display without stripping what is printed on the bill" do
      assert InvoiceNumber.store(" inv-001 ") == "INV-001"
      assert InvoiceNumber.store("(INV-001)") == "(INV-001)"
      assert InvoiceNumber.store(nil) == nil
    end
  end

  describe "smell/2" do
    test "distinguishes a missing number from an empty row" do
      assert InvoiceNumber.smell(nil, true) == :missing
      assert InvoiceNumber.smell("", true) == :missing
      assert InvoiceNumber.smell(nil, false) == nil
    end

    test "recognizes phone numbers and dates without rejecting ordinary series" do
      assert InvoiceNumber.smell("9876543210", true) == :phone_number
      assert InvoiceNumber.smell("28/08/2026", true) == :date
      assert InvoiceNumber.smell("2026-08-28", true) == :date
      assert InvoiceNumber.smell("INV/2026-27/008", true) == nil
    end
  end
end
