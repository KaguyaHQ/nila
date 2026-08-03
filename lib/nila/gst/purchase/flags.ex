defmodule Nila.Gst.Purchase.Flags do
  @moduledoc """
  Purchase-invoice validation flags: pure rules over extracted invoice maps.

  Every flag is sharp and specific about *what it saw* (amounts, GSTINs,
  markers that fired) but it is a suggestion routed to a human — reasons never
  claim an ITC eligibility decision, they name the evidence and the statutory
  hook and stop there. Whether a flag changes ITC or needs a decision is derived
  from its code by the workings pipeline; flags carry no presentation rank.
  """

  alias Nila.Formatters
  alias Nila.Fuzzy
  alias Nila.Gst.Hsn.Validation
  alias Nila.Gst.Rates.Validation, as: RateValidation
  alias Nila.Gst.StateCodes
  alias Nila.Gstin

  # Legitimate trade-vs-legal variants ("Redington Distribution" vs
  # "Redington Distribution Pvt Ltd") hit Nila.Fuzzy's prefix/substring boosts
  # and score >= 0.82; unrelated names land 0.50-0.65 on raw Jaro (which runs
  # generous on long strings). 0.75 splits those populations.
  @name_match_threshold 0.75

  # Scan quality is judged per packet (see `ocr_outlier_flags/1`): a bill has
  # to be worse than its own neighbours by this margin, or unreadable outright,
  # and no more than this share of a packet can carry the flag.
  @ocr_outlier_margin 0.15
  @ocr_unreadable_floor 0.5
  @ocr_outlier_share 0.2

  # Address comparison is token-evidence based, not whole-string fuzzy: OCR'd
  # multiline delivery addresses of the *same* place score badly on Jaro (the
  # October real-data run produced ~10 false 17(5) flags on the entity's own
  # address). We flag only on affirmative evidence of a different place: the
  # delivery address carries informative tokens and none of them appear in the
  # registered address (or entity name). Uninformative or overlapping
  # addresses are treated as the business's own.

  @blocked_patterns [
    {~r/refrigerator|\bfridge\b/, "refrigerator", "CGST Act 17(5)(g)"},
    {~r/air condition(er|ing)?\b|\bsplit ac\b|\bwindow ac\b/, "air conditioner",
     "CGST Act 17(5)(g)"},
    {~r/television|\btv\b/, "television", "CGST Act 17(5)(g)"},
    {~r/washing machine/, "washing machine", "CGST Act 17(5)(g)"},
    {~r/furniture/, "furniture", "CGST Act 17(5)(g)"},
    {~r/\bfood\b|catering|restaurant/, "food/catering", "CGST Act 17(5)(b)"},
    {~r/\bclub\b|membership/, "club/membership", "CGST Act 17(5)(b)"},
    {~r/motor vehicle|motorcycle|\bcar\b|\bbike\b/, "motor vehicle", "CGST Act 17(5)(a)"},
    {~r/beauty (treatment|parlou?r)|\bsalon\b|cosmetic surgery|plastic surgery|health (service|club|checkup)|\bgym\b|\bspa\b/,
     "health/beauty services", "CGST Act 17(5)(b)"},
    {~r/works contract/, "works contract (construction)", "CGST Act 17(5)(c)"}
  ]

  def evaluate(invoice, entity_ctx, vendor_dir \\ %{}) do
    [
      &check_source_attribution/3,
      &check_arithmetic_basis/3,
      &check_zero_value/3,
      &check_invoice_number/3,
      &check_gstin_presence_and_validity/3,
      &check_gstin_state_vs_tax/3,
      &check_name_vs_directory/3,
      &check_hsn_validity/3,
      &check_statutory_rate/3,
      &check_hsn_plausibility/3,
      &check_personal_expense/3,
      &check_tax_arithmetic/3
    ]
    |> Enum.flat_map(& &1.(invoice, entity_ctx, vendor_dir))
  end

  def evaluate_all(invoices, entity_ctx, vendor_dir \\ %{}) do
    duplicates = duplicate_flags(invoices)
    blurry = ocr_outlier_flags(invoices)

    Map.new(invoices, fn invoice ->
      {invoice["id"],
       evaluate(invoice, entity_ctx, vendor_dir) ++
         Map.get(duplicates, invoice["id"], []) ++ Map.get(blurry, invoice["id"], [])}
    end)
  end

  @doc """
  Scan-quality flags, judged against *this packet* rather than an absolute bar.

  A fixed threshold measures the client's phone camera, not the bill. On a
  packet photographed in one bad sitting every bill reads below any global
  line, so the flag fired on ~80% of rows, and a warning that fires on
  everything is not a warning: the ₹48,802 GSTIN problem ended up screaming
  exactly as loud as a ₹107 scooter bill.

  So this marks outliers instead. A bill flags when it is meaningfully worse
  than its own packet's baseline, or when it is bad in absolute terms
  (`#{@ocr_unreadable_floor}`) no matter how bad its neighbours are. Then the
  worst-first cap keeps it to #{trunc(@ocr_outlier_share * 100)}% of the
  packet, so the flag can never become the baseline again by construction.
  """
  def ocr_outlier_flags(invoices) when is_list(invoices) do
    scored =
      invoices
      |> Enum.filter(&is_number(ocr_minimum(&1)))
      |> Enum.sort_by(&ocr_minimum/1)

    case scored do
      [] ->
        %{}

      scored ->
        baseline = median(Enum.map(scored, &ocr_minimum/1))
        cap = max(1, ceil(length(invoices) * @ocr_outlier_share))

        scored
        |> Enum.filter(&ocr_outlier?(&1, baseline))
        |> Enum.take(cap)
        |> Map.new(&{&1["id"], [low_ocr_flag(&1)]})
    end
  end

  defp ocr_outlier?(invoice, baseline) do
    minimum = ocr_minimum(invoice)
    minimum < @ocr_unreadable_floor or minimum < baseline - @ocr_outlier_margin
  end

  defp ocr_minimum(invoice), do: get_in(invoice, ["confidence", "ocr_minimum"])

  defp median(sorted) do
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp low_ocr_flag(invoice) do
    flag(
      invoice,
      "low_ocr_confidence",
      "OCR minimum word confidence is #{Float.round(ocr_minimum(invoice) * 100, 1)}% — " <>
        "well below the rest of this packet. Inspect the original for omitted or " <>
        "misread handwritten values.",
      nil,
      ["confidence"],
      1.0
    )
  end

  @doc """
  Month-level flags: facts about the packet rather than any one invoice, so
  they carry `"invoice_id" => nil` and hang off the month, not a register row.

  Takes `Nila.Gst.Intake.Dumps.unaccounted_pages/4` — the pages extraction read
  but produced no invoice from. That is the loud version of the failure this
  engine most fears: the annotation model omitting a real bill while returning
  a clean 200. A blank or separator page fires it too, and dismissing one is a
  glance; silence would cost a month's ITC.
  """
  def document_flags(unaccounted_pages) when is_list(unaccounted_pages) do
    Enum.map(unaccounted_pages, fn %{"source" => source, "pages" => pages} ->
      %{
        "invoice_id" => nil,
        "code" => "pages_unaccounted",
        "reason" =>
          "#{page_label(pages)} of #{source} produced no invoice. The text was read, " <>
            "but nothing was extracted from #{pronoun(pages)}. Open the original and " <>
            "confirm no bill was missed; a blank or separator page is fine to dismiss.",
        "section" => nil,
        "fields" => ["pages"],
        "confidence" => 1.0
      }
    end)
  end

  @doc """
  Month-level flags for dumps whose pages could not be rendered — the register
  is complete, but no scanned bill sits beside its rows.

  Takes `Nila.Gst.Intake.Dumps.evidence_gaps/4`. A reviewer who cannot see the
  paper is checking arithmetic against arithmetic, which is not review; saying
  so out loud is the difference between a month signed knowingly and one signed
  because nothing objected.
  """
  def evidence_flags(gaps) when is_list(gaps) do
    Enum.map(gaps, fn %{"source" => source} ->
      %{
        "invoice_id" => nil,
        "code" => "evidence_unavailable",
        "reason" =>
          "#{source} was read, but its pages could not be rendered, so no scanned bill " <>
            "shows beside the invoices it produced. Check them against the original PDF " <>
            "before signing.",
        "section" => nil,
        "fields" => ["pages"],
        "confidence" => 1.0
      }
    end)
  end

  defp page_label([page]), do: "Page #{page}"
  defp page_label(pages), do: "Pages #{Enum.join(pages, ", ")}"

  defp pronoun([_page]), do: "it"
  defp pronoun(_pages), do: "them"

  defp duplicate_flags(invoices) do
    invoices
    |> Enum.reject(&(&1["invoice_number"] in [nil, ""]))
    |> Enum.group_by(fn inv ->
      {inv["vendor_gstin"], Fuzzy.normalize(inv["invoice_number"])}
    end)
    |> Enum.filter(fn {{gstin, _inum}, group} -> gstin != nil and length(group) > 1 end)
    |> Enum.flat_map(fn {_key, group} ->
      pages = group |> Enum.flat_map(&(&1["pages"] || [])) |> Enum.sort()

      Enum.map(group, fn inv ->
        others = Enum.reject(group, &(&1["id"] == inv["id"]))

        flag(
          inv,
          "duplicate_invoice",
          "Invoice #{inv["invoice_number"]} from #{inv["vendor_name"]} appears " <>
            "#{length(group)} times in this month's bills (pages #{Enum.join(pages, ", ")}) — " <>
            "likely the same bill scanned twice. Booking both would claim ITC of " <>
            "#{rupees(tax_total(inv))} twice; keep one (duplicates: " <>
            "#{Enum.map_join(others, ", ", & &1["id"])}).",
          nil,
          ["invoice_number"],
          0.9
        )
      end)
    end)
    |> Enum.group_by(& &1["invoice_id"])
  end

  defp tax_total(inv) do
    tax = inv["tax_paise"] || %{}
    (tax["cgst"] || 0) + (tax["sgst"] || 0) + (tax["igst"] || 0)
  end

  @doc "Narrow smell check shared by purchase and sales invoice validation."
  def invoice_number_smell(invoice_number, row_has_values?) do
    normalized = invoice_number |> to_string() |> String.trim()

    cond do
      normalized == "" and row_has_values? ->
        :missing

      Regex.match?(~r/^[6-9]\d{9}$/, normalized) ->
        :phone_number

      Regex.match?(
        ~r/^(?:\d{1,2}[-\/.]\d{1,2}[-\/.]\d{2,4}|\d{4}[-\/.]\d{1,2}[-\/.]\d{1,2})$/,
        normalized
      ) ->
        :date

      true ->
        nil
    end
  end

  defp check_source_attribution(%{"source_attribution" => attribution} = invoice, _ctx, _dir)
       when is_map(attribution) do
    if attribution["status"] == "verified" do
      []
    else
      [
        flag(
          invoice,
          "source_attribution_uncertain",
          source_attribution_reason(attribution),
          nil,
          ["source_attribution"],
          1.0
        )
      ]
    end
  end

  defp check_source_attribution(_invoice, _ctx, _dir), do: []

  defp source_attribution_reason(%{"status" => "ambiguous", "candidate_pages" => pages}) do
    "This invoice matches multiple source pages (#{Enum.join(pages, ", ")}) — open the original document and confirm the right pages."
  end

  defp source_attribution_reason(%{"status" => "unverified"}) do
    "The annotated source page could not be verified against OCR text — open the original document and confirm it."
  end

  defp source_attribution_reason(_attribution) do
    "No source page could be resolved for this invoice — open the original document and attach the right page."
  end

  defp check_arithmetic_basis(
         %{"arithmetic_basis" => "printed_final_reconciled"} = invoice,
         _ctx,
         _dir
       ) do
    [
      flag(
        invoice,
        "subtotal_breakdown_uncertain",
        "Taxable value, tax and grand total reconcile, but the printed subtotal/discount breakdown does not — confirm the source invoice.",
        nil,
        ["taxable_paise", "tax_paise", "total_paise"],
        1.0
      )
    ]
  end

  defp check_arithmetic_basis(_invoice, _ctx, _dir), do: []

  # A purchase row with no taxable value and no tax is not a bill — it is a page
  # the extractor produced nothing from. Rendering it in the register as ₹0 / ₹0
  # states as fact that a supplier issued a bill for nothing, and it silently
  # inflates the invoice count a reviewer reconciles against.
  defp check_zero_value(invoice, _entity_ctx, _vendor_dir) do
    if invoice_has_values?(invoice) do
      []
    else
      [
        flag(
          invoice,
          "zero_value_row",
          "No taxable value and no tax were read off this document — it is probably not an invoice, or the extraction failed. Check the scan before counting it in the register.",
          nil,
          ["taxable_paise", "total_paise"],
          0.9
        )
      ]
    end
  end

  defp check_invoice_number(invoice, _entity_ctx, _vendor_dir) do
    smell = invoice_number_smell(invoice["invoice_number"], invoice_has_values?(invoice))

    if smell do
      [
        flag(
          invoice,
          smell_code(smell),
          invoice_number_reason(smell, invoice["invoice_number"]),
          nil,
          ["invoice_number"],
          0.9
        )
      ]
    else
      []
    end
  end

  # "Invoice number looks wrong" is a claim about a number that exists. When the
  # extraction found none at all, that label sits beside an em-dash and asks the
  # reviewer to re-read a number that is not there. The engine already knows the
  # difference; only the code collapsed it.
  defp smell_code(:missing), do: "missing_invoice_number"
  defp smell_code(_looks_wrong), do: "implausible_invoice_number"

  defp invoice_has_values?(invoice) do
    (invoice["taxable_paise"] || 0) != 0 or (invoice["total_paise"] || 0) != 0 or
      tax_total(invoice) != 0 or
      Enum.any?(invoice["line_items"] || [], &((&1["taxable_paise"] || 0) != 0))
  end

  defp invoice_number_reason(:phone_number, invoice_number),
    do: "Invoice number #{invoice_number} looks like a phone number — verify it against the bill."

  defp invoice_number_reason(:date, invoice_number),
    do: "Invoice number #{invoice_number} looks like a date — verify it against the bill."

  defp invoice_number_reason(:missing, _invoice_number),
    do:
      "The row carries invoice values but no invoice number was extracted — verify it against the bill."

  defp check_gstin_presence_and_validity(invoice, entity_ctx, _vendor_dir) do
    gstin = normalize_gstin(invoice["vendor_gstin"])
    own = normalize_gstin(entity_ctx["gstin"])

    cond do
      gstin == nil ->
        [
          flag(
            invoice,
            "missing_gstin",
            "No vendor GSTIN extracted for \"#{invoice["vendor_name"]}\" invoice " <>
              "#{invoice["invoice_number"]} — B2C purchase or an extraction miss; " <>
              "ITC on #{rupees(invoice["total_paise"])} may be at risk. Needs a human look.",
            nil,
            ["vendor_gstin"],
            0.9
          )
        ]

      gstin == own ->
        [
          flag(
            invoice,
            "own_gstin_as_vendor",
            "Vendor GSTIN #{gstin} is this entity's own GSTIN — a purchase cannot " <>
              "name the buyer as its own supplier.",
            nil,
            ["vendor_gstin"],
            0.99
          )
        ]

      own != nil and not Gstin.valid?(gstin) and String.jaro_distance(gstin, own) >= 0.85 ->
        [
          flag(
            invoice,
            "own_gstin_as_vendor",
            "Vendor GSTIN #{gstin} is a near-match to this entity's own GSTIN #{own} — " <>
              "the extractor likely picked up the buyer's GSTIN off the bill instead of " <>
              "the vendor's (the bill may not print a vendor GSTIN). Treat the vendor " <>
              "GSTIN as unknown and identify the vendor by name and value.",
            nil,
            ["vendor_gstin"],
            0.9
          )
        ]

      not Gstin.valid?(gstin) ->
        [
          flag(
            invoice,
            "invalid_gstin",
            "Vendor GSTIN #{gstin} fails the GSTIN structure/check-digit test — " <>
              "likely an extraction error or a typo on the invoice.",
            nil,
            ["vendor_gstin"],
            0.98
          )
        ]

      true ->
        []
    end
  end

  defp check_gstin_state_vs_tax(invoice, entity_ctx, _vendor_dir) do
    gstin = normalize_gstin(invoice["vendor_gstin"])
    vendor_code = StateCodes.normalize_code(gstin || "")
    vendor_state = StateCodes.name_for(vendor_code)
    entity_code = StateCodes.normalize_code(entity_ctx["state_code"] || "")
    tax = invoice["tax_paise"] || %{}
    cgst = tax["cgst"] || 0
    sgst = tax["sgst"] || 0
    igst = tax["igst"] || 0

    cond do
      vendor_state == nil or entity_code == nil ->
        []

      vendor_code != entity_code and cgst + sgst > 0 ->
        [
          flag(
            invoice,
            "gstin_state_mismatch",
            "Vendor GSTIN #{gstin} is registered in #{vendor_state} (state code " <>
              "#{vendor_code}) while this entity is in state #{entity_code} — an " <>
              "inter-state supply would carry IGST, but the invoice charges CGST " <>
              "#{rupees(cgst)} and SGST #{rupees(sgst)}. Place of supply may differ; " <>
              "worth confirming.",
            "IGST Act s.10",
            ["vendor_gstin", "tax_paise"],
            0.85
          )
        ]

      vendor_code == entity_code and igst > 0 ->
        [
          flag(
            invoice,
            "gstin_state_mismatch",
            "Vendor GSTIN #{gstin} shares this entity's state (code #{vendor_code}, " <>
              "#{vendor_state}) — an intra-state supply would carry CGST/SGST, but " <>
              "the invoice charges IGST #{rupees(igst)}. Place of supply may differ; " <>
              "worth confirming.",
            "IGST Act s.10",
            ["vendor_gstin", "tax_paise"],
            0.85
          )
        ]

      true ->
        []
    end
  end

  defp check_name_vs_directory(invoice, _entity_ctx, vendor_dir) do
    gstin = normalize_gstin(invoice["vendor_gstin"])
    invoice_name = invoice["vendor_name"]

    with true <- is_binary(gstin),
         {:ok, trade_name} <- Map.fetch(vendor_dir, gstin),
         true <- is_binary(invoice_name) and invoice_name != "" do
      score = symmetric_score(invoice_name, trade_name)

      if score < @name_match_threshold do
        [
          flag(
            invoice,
            "name_gstin_mismatch",
            "Invoice names the vendor \"#{invoice_name}\" but GSTR-2B records GSTIN " <>
              "#{gstin} as \"#{trade_name}\" (similarity #{Float.round(score, 2)}). " <>
              "Could be a trade-vs-legal name split, or the wrong GSTIN — a human " <>
              "should confirm which.",
            nil,
            ["vendor_name", "vendor_gstin"],
            Float.round(1.0 - score, 2)
          )
        ]
      else
        []
      end
    else
      _ -> []
    end
  end

  defp check_hsn_validity(invoice, entity_ctx, _vendor_dir) do
    case entity_ctx["hsn_directory"] do
      nil ->
        []

      directory ->
        invoice
        |> then(&Validation.annotate_invoices([&1], directory))
        |> hd()
        |> Validation.purchase_flags()
    end
  end

  defp check_statutory_rate(invoice, entity_ctx, _vendor_dir) do
    with %{} = hsn_directory <- entity_ctx["hsn_directory"],
         %{} = rate_directory <- entity_ctx["rate_directory"] do
      invoice
      |> then(&Validation.annotate_invoices([&1], hsn_directory))
      |> RateValidation.annotate_invoices(rate_directory)
      |> hd()
      |> RateValidation.purchase_flags()
    else
      _not_configured -> []
    end
  end

  defp check_hsn_plausibility(invoice, entity_ctx, _vendor_dir) do
    prefixes = entity_ctx["business_hsn_prefixes"] || []

    if prefixes == [] do
      []
    else
      for %{"hsn_sac" => hsn} = line <- invoice["line_items"] || [],
          is_binary(hsn) and hsn != "",
          not Enum.any?(prefixes, &String.starts_with?(hsn, &1)) do
        flag(
          invoice,
          "hsn_implausible",
          "Line \"#{line["description"]}\" carries HSN/SAC #{hsn}, which starts with " <>
            "none of this business's usual prefixes (#{Enum.join(prefixes, ", ")}). " <>
            "Could be a genuine one-off purchase — a human should confirm.",
          nil,
          ["line_items"],
          0.6
        )
      end
    end
  end

  defp check_personal_expense(invoice, entity_ctx, _vendor_dir) do
    address_evidence = address_evidence(invoice, entity_ctx)

    line_flags =
      for line <- invoice["line_items"] || [],
          {_regex, label, section} <- blocked_pattern_hits(line["description"]) do
        {evidence, confidence} =
          case address_evidence do
            nil ->
              {"", 0.7}

            evidence ->
              {" and the " <> evidence, 0.85}
          end

        flag(
          invoice,
          "personal_expense_17_5",
          "#{rupees(line["taxable_paise"])} line \"#{line["description"]}\" from " <>
            "#{invoice["vendor_name"]} matches blocked-credit pattern \"#{label}\"" <>
            evidence <>
            " — likely #{section_gloss(section)}. Routed for human review, " <>
            "not a verdict.",
          section,
          personal_fields(address_evidence),
          confidence
        )
      end

    cond do
      line_flags != [] ->
        line_flags

      address_evidence != nil ->
        [
          flag(
            invoice,
            "personal_expense_17_5",
            "#{rupees(invoice["total_paise"])} invoice #{invoice["invoice_number"]} from " <>
              "#{invoice["vendor_name"]}: the #{address_evidence} — possible " <>
              "17(5)(g) personal consumption. Routed for human review, not a verdict.",
            "CGST Act 17(5)(g)",
            ["delivery_address"],
            0.6
          )
        ]

      true ->
        []
    end
  end

  defp check_tax_arithmetic(invoice, _entity_ctx, _vendor_dir) do
    lines = invoice["line_items"] || []
    line_sum = lines |> Enum.map(&(&1["taxable_paise"] || 0)) |> Enum.sum()
    taxable = invoice["taxable_paise"] || 0
    tax = invoice["tax_paise"] || %{}
    cgst = tax["cgst"] || 0
    sgst = tax["sgst"] || 0

    line_flag =
      if lines != [] and abs(line_sum - taxable) > 100 do
        [
          flag(
            invoice,
            "tax_arithmetic_off",
            "Line taxable values total #{rupees(line_sum)} but the invoice states " <>
              "taxable #{rupees(taxable)} — off by #{rupees(abs(line_sum - taxable))}.",
            nil,
            ["taxable_paise", "line_items"],
            0.95
          )
        ]
      else
        []
      end

    split_flag =
      if cgst + sgst > 0 and abs(cgst - sgst) > 1 do
        [
          flag(
            invoice,
            "tax_arithmetic_off",
            "CGST #{rupees(cgst)} and SGST #{rupees(sgst)} differ on an intra-state " <>
              "invoice — the two halves should be equal to the paise.",
            nil,
            ["tax_paise"],
            0.95
          )
        ]
      else
        []
      end

    line_flag ++ split_flag
  end

  defp blocked_pattern_hits(description) when is_binary(description) do
    normalized = Fuzzy.normalize(description)

    Enum.filter(@blocked_patterns, fn {regex, _label, _section} ->
      Regex.match?(regex, normalized)
    end)
  end

  defp blocked_pattern_hits(_), do: []

  defp address_evidence(invoice, entity_ctx) do
    delivery = invoice["delivery_address"]
    registered = entity_ctx["registered_address"]
    markers = entity_ctx["residential_markers"] || []

    with true <- is_binary(delivery) and delivery != "" do
      normalized_delivery = Fuzzy.normalize(delivery)

      marker =
        Enum.find(markers, fn m -> String.contains?(normalized_delivery, Fuzzy.normalize(m)) end)

      cond do
        marker != nil ->
          "delivery address \"#{delivery}\" matches residential marker \"#{marker}\""

        is_binary(registered) and registered != "" and
            different_place?(normalized_delivery, registered, entity_ctx["entity_name"]) ->
          "delivery address \"#{delivery}\" shares nothing with the registered address"

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp different_place?(normalized_delivery, registered, entity_name) do
    known =
      [registered, entity_name]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &Fuzzy.normalize/1)
      |> String.replace(" ", "")

    tokens =
      normalized_delivery
      |> String.split(" ", trim: true)
      |> Enum.filter(fn t -> String.length(t) >= 3 or t =~ ~r/\d/ end)

    informative? = Enum.any?(tokens, fn t -> String.length(t) >= 4 end)
    overlap? = Enum.any?(tokens, fn t -> String.contains?(known, t) end)

    informative? and not overlap?
  end

  defp personal_fields(nil), do: ["line_items"]
  defp personal_fields(_address_evidence), do: ["line_items", "delivery_address"]

  defp section_gloss("CGST Act 17(5)(a)"), do: "17(5)(a) motor vehicle blocked credit"
  defp section_gloss("CGST Act 17(5)(b)"), do: "17(5)(b) food/membership blocked credit"
  defp section_gloss("CGST Act 17(5)(c)"), do: "17(5)(c) works-contract blocked credit"
  defp section_gloss("CGST Act 17(5)(g)"), do: "17(5)(g) personal consumption"

  defp symmetric_score(a, b) do
    na = Fuzzy.normalize(a)
    nb = Fuzzy.normalize(b)
    max(Fuzzy.match_score(na, nb), Fuzzy.match_score(nb, na))
  end

  defp normalize_gstin(gstin) when is_binary(gstin) do
    case gstin |> String.trim() |> String.upcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_gstin(_), do: nil

  defp rupees(paise), do: Formatters.format_money_with_paise(paise || 0)

  defp flag(invoice, code, reason, section, fields, confidence) do
    %{
      "invoice_id" => invoice["id"],
      "code" => code,
      "reason" => reason,
      "section" => section,
      "fields" => fields,
      "confidence" => confidence
    }
  end
end
