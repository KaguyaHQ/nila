defmodule Nila.Formatters do
  @moduledoc """
  Shared display formatting for values used across Nila.
  """

  def format_money(paise, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "INR ")
    rupees = div(paise || 0, 100)

    prefix <> format_integer(rupees)
  end

  def format_money_with_paise(paise, opts \\ [])

  def format_money_with_paise(nil, _opts), do: nil

  def format_money_with_paise(paise, opts) when is_integer(paise) do
    prefix = Keyword.get(opts, :prefix, "₹")
    rupees = div(paise, 100)
    paise_part = rem(abs(paise), 100)

    prefix <> format_integer(rupees) <> "." <> pad2(paise_part)
  end

  def format_rupees(paise), do: paise |> div(100) |> Integer.to_string()

  @doc """
  Parses a free-text or numeric rupee amount into paise, or `nil` when it can't
  be read. Strips currency symbols, commas, and spaces from strings, so values
  like `"₹1,23,456.78"` or `"1234.5"` both parse. Pairs with
  `format_money_with_paise/2` (which also treats `nil` as "unknown").
  """
  def parse_rupees(n) when is_integer(n), do: n * 100
  def parse_rupees(n) when is_float(n), do: float_to_paise(n)

  def parse_rupees(s) when is_binary(s) do
    case s |> String.replace(~r/[^0-9.\-]/, "") |> Float.parse() do
      {f, _rest} -> float_to_paise(f)
      :error -> nil
    end
  end

  def parse_rupees(_), do: nil

  # round/1 carries 99.5+ paise up into the next rupee on its own, so
  # rupees * 100 + paise stays correct without a special carry clause.
  defp float_to_paise(f) do
    rupees = trunc(f)
    rupees * 100 + round((f - rupees) * 100)
  end

  # Operator language: what a CA-firm junior would say out loud, not the
  # engine's issue-code enum (DESIGN.md — "Speak the operator's language").
  # Codes stay stable in the data; this is purely a display dictionary.
  @issue_labels %{
    "printed_taxable_mismatch" => "Taxable total doesn't tally",
    "printed_tax_mismatch" => "Tax total doesn't tally",
    "grand_total_mismatch" => "Bill total doesn't tally",
    "invalid_gstin" => "GSTIN doesn't check out",
    "missing_gstin" => "No GSTIN on the bill",
    "sequence_gaps" => "Missing invoice numbers",
    "furniture_row_with_values" => "Blank row carries amounts",
    "rounding_variance" => "Rounding difference",
    "bucket_tax_mismatch" => "Tax doesn't match the rate",
    "line_arithmetic" => "Line doesn't multiply out",
    "lopsided_tax_split" => "CGST and SGST split unevenly",
    "tax_split_mismatch" => "Wrong tax type for the state",
    "personal_expense_17_5" => "Personal / 17(5)",
    "duplicate_invoice" => "Billed twice",
    "gstin_state_mismatch" => "Wrong-state GSTIN",
    "hsn_implausible" => "HSN looks wrong",
    "name_gstin_mismatch" => "Name doesn't match the GSTIN",
    "own_gstin_as_vendor" => "Client's own GSTIN as the vendor",
    "tax_arithmetic_off" => "Tax doesn't add up",
    "implausible_invoice_number" => "Invoice number looks wrong"
  }

  @doc """
  The operator-language label for an engine issue/flag code. Falls back to
  `humanize_label/1` for codes the dictionary doesn't know — a new engine
  check should still render something readable before its label is written.
  """
  def issue_label(code), do: Map.get(@issue_labels, code) || humanize_label(code)

  @recon_verdicts %{
    "ambiguous_matches" => "Two possible 2B matches",
    "invoice_number_mismatch" => "Invoice number differs from 2B",
    "relaxed_match_weak_corroboration" => "Probable match — verify",
    "fuzzy_name_weak_corroboration" => "Name-only match — verify",
    "no_confident_gstr2b_match" => "No 2B match found",
    "missing_in_books" => "In 2B — bill not received"
  }

  @doc "The short table-cell verdict for a reconciliation reason code."
  def recon_verdict(code), do: Map.get(@recon_verdicts, code) || humanize_label(code)

  @month_states %{
    "collecting" => "Collecting documents",
    "worked" => "Ready for review",
    "reviewed" => "Reviewed",
    "filed" => "Filed"
  }

  @doc "The operator-language name for a month state."
  def month_state_label(state), do: Map.get(@month_states, state) || humanize_label(state)

  @doc ~S|A `"2025-10"` period as `"Oct 2025"`. Unparseable input passes through.|
  def period_label(period) do
    case String.split(period, "-") do
      [year, month] ->
        name =
          Enum.at(
            ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec),
            String.to_integer(month) - 1
          )

        "#{name} #{year}"

      _ ->
        period
    end
  end

  def humanize_label(nil), do: "—"

  def humanize_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def human_status(value), do: humanize_label(value)

  def format_display_date(nil), do: "—"
  def format_display_date(%Date{} = date), do: Calendar.strftime(date, "%d %b %Y")

  def format_long_display_date(nil), do: "—"
  def format_long_display_date(%Date{} = date), do: Calendar.strftime(date, "%a %d %b %Y")

  def format_sdc_date(nil), do: nil
  def format_sdc_date(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%Y")

  def format_iso_date(nil), do: nil
  def format_iso_date(%Date{} = date), do: Date.to_iso8601(date)

  def format_iso_datetime(nil), do: nil
  def format_iso_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def format_iso_datetime(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  def format_display_datetime(nil), do: "—"

  def format_display_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_date()
    |> format_display_date()
  end

  def format_display_datetime(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.to_date()
    |> format_display_date()
  end

  def format_display_datetime_with_time(nil), do: "—"

  def format_display_datetime_with_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%d %b %Y, %H:%M")
  end

  def format_display_datetime_with_time(%NaiveDateTime{} = datetime) do
    Calendar.strftime(datetime, "%d %b %Y, %H:%M")
  end

  def format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M")
  def format_time(%NaiveDateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M")

  def format_integer(n) when is_integer(n) and n < 0,
    do: "-" <> format_integer(-n)

  def format_integer(n) when is_integer(n) and n < 1000, do: Integer.to_string(n)

  def format_integer(n) when is_integer(n) do
    last_three = rem(n, 1000)
    rest = div(n, 1000)

    grouped =
      rest
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{2})(?=\d)/, "\\1,")
      |> String.reverse()

    grouped <> "," <> String.pad_leading(Integer.to_string(last_three), 3, "0")
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # ---------------------------------------------------------------------------
  # Amount in words (Indian numbering: lakhs / crores)
  # ---------------------------------------------------------------------------

  @doc """
  Converts an integer paise amount to Indian-numbering words, e.g.
    `1_23_45_678` → `"Rupees One Crore Twenty Three Lakh Forty Five Thousand Six Hundred Seventy Six and Seventy Eight paise only"`.

  Rules: 2-digit groups after the first 3 (hundreds), groups labelled
  thousand → lakh → crore. Negative amounts get a "Minus" prefix. Printed on
  quotation and tax-invoice documents.
  """
  def amount_in_words(paise) when is_integer(paise) do
    {sign, magnitude} = if paise < 0, do: {"Minus ", -paise}, else: {"", paise}

    rupees = div(magnitude, 100)
    paise_part = rem(magnitude, 100)

    rupees_words =
      case rupees_in_words(rupees) do
        "" -> "Zero"
        words -> words
      end

    paise_words = two_digit_in_words(paise_part)

    "#{sign}Rupees #{rupees_words} and #{paise_words} paise only"
  end

  defp rupees_in_words(0), do: ""

  defp rupees_in_words(n) do
    crore = div(n, 10_000_000)
    after_crore = rem(n, 10_000_000)
    lakh = div(after_crore, 100_000)
    after_lakh = rem(after_crore, 100_000)
    thousand = div(after_lakh, 1_000)
    after_thousand = rem(after_lakh, 1_000)
    hundred = div(after_thousand, 100)
    last_two = rem(after_thousand, 100)

    [
      part(crore, "Crore"),
      part(lakh, "Lakh"),
      part(thousand, "Thousand"),
      part(hundred, "Hundred"),
      last_two_part(last_two)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp part(0, _label), do: ""
  defp part(n, label), do: "#{two_digit_in_words(n)} #{label}"

  # Omit a trailing "Zero" when higher parts already carry the value.
  defp last_two_part(0), do: ""
  defp last_two_part(n), do: two_digit_in_words(n)

  defp two_digit_in_words(0), do: "Zero"
  defp two_digit_in_words(1), do: "One"
  defp two_digit_in_words(2), do: "Two"
  defp two_digit_in_words(3), do: "Three"
  defp two_digit_in_words(4), do: "Four"
  defp two_digit_in_words(5), do: "Five"
  defp two_digit_in_words(6), do: "Six"
  defp two_digit_in_words(7), do: "Seven"
  defp two_digit_in_words(8), do: "Eight"
  defp two_digit_in_words(9), do: "Nine"
  defp two_digit_in_words(10), do: "Ten"
  defp two_digit_in_words(11), do: "Eleven"
  defp two_digit_in_words(12), do: "Twelve"
  defp two_digit_in_words(13), do: "Thirteen"
  defp two_digit_in_words(14), do: "Fourteen"
  defp two_digit_in_words(15), do: "Fifteen"
  defp two_digit_in_words(16), do: "Sixteen"
  defp two_digit_in_words(17), do: "Seventeen"
  defp two_digit_in_words(18), do: "Eighteen"
  defp two_digit_in_words(19), do: "Nineteen"

  defp two_digit_in_words(n) when n >= 20 and n < 100 do
    tens = div(n, 10) * 10
    ones = rem(n, 10)

    if ones == 0,
      do: tens_word(tens),
      else: "#{tens_word(tens)} #{two_digit_in_words(ones)}"
  end

  defp tens_word(20), do: "Twenty"
  defp tens_word(30), do: "Thirty"
  defp tens_word(40), do: "Forty"
  defp tens_word(50), do: "Fifty"
  defp tens_word(60), do: "Sixty"
  defp tens_word(70), do: "Seventy"
  defp tens_word(80), do: "Eighty"
  defp tens_word(90), do: "Ninety"
end
