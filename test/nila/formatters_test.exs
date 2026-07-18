defmodule Nila.FormattersTest do
  use ExUnit.Case, async: true

  alias Nila.Formatters

  describe "format_money/2" do
    test "formats nil as zero rupees" do
      assert Formatters.format_money(nil) == "INR 0"
    end

    test "uses Indian digit grouping" do
      assert Formatters.format_money(12_34_56_789_00) == "INR 12,34,56,789"
    end

    test "accepts a custom prefix" do
      assert Formatters.format_money(12_34_567_00, prefix: "₹") == "₹12,34,567"
    end
  end

  describe "format_money_with_paise/2" do
    test "formats paise with Indian grouping and decimal paise" do
      assert Formatters.format_money_with_paise(12_34_567_89) == "₹12,34,567.89"
    end

    test "keeps nil as nil for optional structured outputs" do
      assert Formatters.format_money_with_paise(nil) == nil
    end
  end

  describe "parse_rupees/1" do
    test "parses free-text rupee strings into paise" do
      assert Formatters.parse_rupees("₹1,23,456.78") == 1_23_456_78
      assert Formatters.parse_rupees("1234.5") == 1234_50
      assert Formatters.parse_rupees("1,000") == 1000_00
    end

    test "parses integers and floats as rupees" do
      assert Formatters.parse_rupees(1234) == 1234_00
      assert Formatters.parse_rupees(1234.56) == 1234_56
    end

    test "rounds the trailing paise up into the next rupee" do
      assert Formatters.parse_rupees(1234.999) == 1235_00
    end

    test "returns nil when there is no number to read" do
      assert Formatters.parse_rupees("") == nil
      assert Formatters.parse_rupees("₹") == nil
      assert Formatters.parse_rupees(nil) == nil
    end

    test "round-trips into format_money_with_paise" do
      assert "₹1,23,456.78" =
               "1,23,456.78" |> Formatters.parse_rupees() |> Formatters.format_money_with_paise()
    end
  end

  describe "format_integer/1" do
    test "formats integers with Indian grouping" do
      assert Formatters.format_integer(123) == "123"
      assert Formatters.format_integer(1_23_456) == "1,23,456"
      assert Formatters.format_integer(-1_23_456) == "-1,23,456"
    end
  end

  describe "humanize_label/1" do
    test "formats nil, strings, and atoms" do
      assert Formatters.humanize_label(nil) == "—"
      assert Formatters.humanize_label("grn_booked") == "Grn Booked"
      assert Formatters.humanize_label(:manual_review) == "Manual Review"
    end
  end

  describe "recon_verdict/1" do
    test "uses the shared operator vocabulary and humanizes unknown codes" do
      assert Formatters.recon_verdict("ambiguous_matches") == "Two possible 2B matches"

      assert Formatters.recon_verdict("invoice_number_mismatch") ==
               "Invoice number differs from 2B"

      assert Formatters.recon_verdict("relaxed_match_weak_corroboration") ==
               "Probable match — verify"

      assert Formatters.recon_verdict("fuzzy_name_weak_corroboration") ==
               "Name-only match — verify"

      assert Formatters.recon_verdict("no_confident_gstr2b_match") == "No 2B match found"
      assert Formatters.recon_verdict("missing_in_books") == "Ask the client for this bill"
      assert Formatters.recon_verdict("future_reason_code") == "Future Reason Code"
    end
  end

  describe "human_status/1" do
    test "preserves the old status helper as a wrapper" do
      assert Formatters.human_status(nil) == "—"
      assert Formatters.human_status("grn_booked") == "Grn Booked"
    end
  end

  describe "date and datetime formatters" do
    test "formats display dates" do
      assert Formatters.format_display_date(~D[2026-05-30]) == "30 May 2026"
      assert Formatters.format_long_display_date(~D[2026-05-30]) == "Sat 30 May 2026"
      assert Formatters.format_display_date(nil) == "—"
    end

    test "formats SDC and ISO dates for non-UI consumers" do
      assert Formatters.format_sdc_date(~D[2026-05-30]) == "30.05.2026"
      assert Formatters.format_sdc_date(nil) == nil
      assert Formatters.format_iso_date(~D[2026-05-30]) == "2026-05-30"
      assert Formatters.format_iso_date(nil) == nil
    end

    test "formats datetimes with and without time" do
      datetime = ~U[2026-05-30 13:45:00Z]
      naive = ~N[2026-05-30 13:45:00]

      assert Formatters.format_display_datetime(datetime) == "30 May 2026"
      assert Formatters.format_display_datetime(naive) == "30 May 2026"
      assert Formatters.format_display_datetime_with_time(datetime) == "30 May 2026, 13:45"
      assert Formatters.format_display_datetime_with_time(naive) == "30 May 2026, 13:45"
      assert Formatters.format_iso_datetime(datetime) == "2026-05-30T13:45:00Z"
      assert Formatters.format_iso_datetime(naive) == "2026-05-30T13:45:00"
      assert Formatters.format_time(datetime) == "13:45"
    end
  end

  describe "amount_in_words/1" do
    test "zero" do
      assert Formatters.amount_in_words(0) == "Rupees Zero and Zero paise only"
    end

    test "small amounts" do
      assert Formatters.amount_in_words(100) == "Rupees One and Zero paise only"
      assert Formatters.amount_in_words(150) == "Rupees One and Fifty paise only"
      assert Formatters.amount_in_words(67) == "Rupees Zero and Sixty Seven paise only"
    end

    test "hundreds and thousands" do
      # 12345.67 rupees = 1234567 paise
      assert Formatters.amount_in_words(12_34_567) ==
               "Rupees Twelve Thousand Three Hundred Forty Five and Sixty Seven paise only"
    end

    test "lakhs" do
      # 100,000 rupees = 10_000_000 paise — One Lakh
      assert Formatters.amount_in_words(1_00_000_00) ==
               "Rupees One Lakh and Zero paise only"

      # 1,23,456.78 rupees = 12345678 paise
      assert Formatters.amount_in_words(1_23_45_678) ==
               "Rupees One Lakh Twenty Three Thousand Four Hundred Fifty Six and Seventy Eight paise only"
    end

    test "crores" do
      # 1 Crore ₹ = 10_000_000 ₹ = 1_000_000_000 paise
      assert Formatters.amount_in_words(1_000_000_000) ==
               "Rupees One Crore and Zero paise only"

      # ₹12,34,56,789.00 = 123_456_789 ₹ = 12_345_678_900 paise (Indian: 12 Crore 34 Lakh 56 Thousand 789)
      assert Formatters.amount_in_words(12_345_678_900) ==
               "Rupees Twelve Crore Thirty Four Lakh Fifty Six Thousand Seven Hundred Eighty Nine and Zero paise only"
    end

    test "negative amounts get a Minus prefix" do
      assert Formatters.amount_in_words(-150) == "Minus Rupees One and Fifty paise only"
    end
  end
end
