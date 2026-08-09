defmodule Nila.Gst.Purchase.Review do
  @moduledoc "Pure projection of purchase workings into the route-backed review rail."

  alias Nila.Gst.Purchase.{Groups, Reconciliation}
  alias Nila.Gst.Proposals

  @sections [
    %{
      key: :decisions,
      kinds: [:books, :itc],
      title: "Decisions",
      blurb: "Your call. Review the bill against the portal evidence and freeze the conclusion."
    },
    %{
      key: :collection,
      kinds: [:gstr2b],
      title: "Bills to collect",
      blurb: "The portal reported these supplies, but no document was supplied."
    }
  ]

  def project(workings, opts \\ []) do
    month = Keyword.fetch!(opts, :month)
    asked_at = Keyword.get(opts, :asked_at)
    gaps = Keyword.get(opts, :evidence_gaps, %{})

    baseline_decision_ids =
      for bucket <- ["needs_human", "in_books_not_2b"],
          entry <- workings.baseline[bucket] || [],
          books = entry["books"],
          into: MapSet.new(),
          do: books["id"]

    effective =
      Enum.filter(workings.groups, fn group ->
        group.state != :settled or
          Enum.any?(group.books, &MapSet.member?(baseline_decision_ids, &1["id"]))
      end)

    dismissed =
      workings.baseline
      |> Groups.build()
      |> Enum.filter(fn group ->
        group.state == :awaiting_bill and
          Enum.all?(group.counterparts, fn counterpart ->
            workings.gstr2b_decisions[Reconciliation.gstr2b_ref(counterpart)] == "dismiss_2b"
          end)
      end)

    reconciliation_items =
      (workings.groups ++ effective ++ dismissed)
      |> Enum.uniq_by(& &1.key)
      |> Enum.flat_map(fn
        %{state: :awaiting_bill, counterparts: [_ | _]} = group ->
          [missing_item(group, workings, month, asked_at)]

        %{state: :awaiting_bill} ->
          []

        group ->
          [decision_item(group, workings, month, gaps)]
      end)

    itc_items = Enum.map(workings.itc["blocks"] || [], &itc_item(&1, workings.rows, month))
    items = reconciliation_items ++ itc_items

    needs_you =
      items
      |> Enum.reject(& &1.resolved)
      |> Enum.sort_by(& &1.tax_paise, :desc)

    all = Enum.sort_by(items, &register_order(&1, workings.rows))
    decisions = Enum.filter(items, & &1.review_origin?)

    %{
      needs_you: needs_you,
      all: all,
      progress: %{done: Enum.count(decisions, & &1.resolved), total: length(decisions)},
      missing_count: Enum.count(items, &(&1.kind == :gstr2b and not &1.resolved))
    }
  end

  def route_state(review, item, scope) do
    selected = lookup(review.all, item) || List.first(review.needs_you) || List.first(review.all)
    scope = valid_scope(scope, selected)
    scoped = Map.fetch!(review, scope)

    selected =
      lookup(scoped, item) || (selected && lookup(scoped, selected.id)) || List.first(scoped)

    %{scope: scope, item: selected && selected.id, focus: member_focus(selected, item)}
  end

  def items(review, scope) when scope in [:needs_you, :all], do: Map.fetch!(review, scope)

  def sections(review, scope) do
    scoped = items(review, scope)

    Enum.flat_map(@sections, fn section ->
      case Enum.filter(scoped, &(&1.kind in section.kinds)) do
        [] ->
          []

        items ->
          tax = Enum.sum(Enum.map(items, & &1.tax_paise))

          proposal =
            if section.key == :collection, do: Proposals.for_missing_bill(length(items), tax)

          [
            Map.merge(section, %{
              items: items,
              count: length(items),
              tax_paise: tax,
              proposal: proposal
            })
          ]
      end
    end)
  end

  def lookup(items, id) do
    Enum.find(items, fn item ->
      item.id == id or item.group_key == id or id in item.member_ids
    end)
  end

  def focus(nil, _member_id), do: nil

  def focus(item, member_id) when is_binary(member_id) do
    case Enum.find(item.books_members, &(&1["id"] == member_id)) do
      nil ->
        item

      member ->
        %{
          item
          | books: member,
            books_members: [member | Enum.reject(item.books_members, &(&1["id"] == member_id))],
            vendor: member["vendor_name"],
            invoice_number: member["invoice_number"],
            images: item.member_images[member_id] || [],
            evidence_gap: item.member_evidence_gaps[member_id],
            candidates: Enum.sort_by(item.candidates, &(&1.books_id != member_id))
        }
    end
  end

  def focus(item, _member_id), do: item

  def next(review, scope, current_id) do
    scoped = items(review, scope)
    index = Enum.find_index(scoped, &matches?(&1, current_id)) || -1

    scoped
    |> Enum.drop(index + 1)
    |> Enum.find(&(&1.kind != :gstr2b and (scope == :all or not &1.resolved)))
  end

  def pair_payload(item, books_id, ref, decision) do
    candidate = Enum.find(item.candidates, &(&1.books_id == books_id and &1.ref == ref))

    %{
      "decision" => decision,
      "reason" => item.reason,
      "proposal" => proposal_snapshot(item),
      "books" => candidate && candidate.books,
      "counterpart" => candidate && candidate.gstr2b,
      "alternatives" =>
        Enum.map(item.candidates, fn alternative ->
          %{
            "books_id" => alternative.books_id,
            "gstr2b_ref" => alternative.ref,
            "books" => alternative.books,
            "counterpart" => alternative.gstr2b
          }
        end)
    }
  end

  defp decision_item(group, workings, month, gaps) do
    books_members = group.books
    books = hd(books_members)
    entry = baseline_books_entry(workings.baseline, books["id"])
    type = (entry && get_in(entry, ["reason", "code"])) || group.code

    candidates =
      books_members
      |> Enum.flat_map(fn member ->
        fallback =
          group.edges
          |> Enum.filter(&(&1.books_ref == member["id"]))
          |> Enum.map(fn edge ->
            Enum.find(group.counterparts, fn counterpart ->
              Reconciliation.gstr2b_ref(counterpart) == edge.gstr2b_ref
            end)
          end)
          |> Enum.reject(&is_nil/1)

        workings.recon
        |> effective_candidates(member["id"], fallback)
        |> Enum.map(fn candidate ->
          %{
            books: member,
            books_id: member["id"],
            gstr2b: candidate,
            ref: Reconciliation.gstr2b_ref(candidate)
          }
        end)
      end)
      |> Enum.uniq_by(&{&1.books_id, &1.ref})

    resolved = group.state == :settled
    verbs = books_members |> Enum.map(&workings.decisions[&1["id"]]) |> Enum.reject(&is_nil/1)

    accepted =
      books_members |> Enum.map(&workings.accepted_reasons[&1["id"]]) |> Enum.reject(&is_nil/1)

    verb = verbs |> Enum.uniq() |> List.first()
    accepted_reason = accepted |> Enum.uniq() |> List.first()

    %{
      id: group.key,
      group_key: group.key,
      member_ids: Enum.map(books_members, & &1["id"]),
      kind: :books,
      type: type,
      vendor: books["vendor_name"],
      invoice_number: books["invoice_number"],
      reason: (entry && get_in(entry, ["reason", "message"])) || "Review the possible pairings.",
      books: books,
      books_members: books_members,
      gstr2b: nil,
      counterparts: group.counterparts,
      candidates: candidates,
      member_images: Map.new(books_members, &{&1["id"], image_urls(&1, month)}),
      member_evidence_gaps: Map.new(books_members, &{&1["id"], evidence_gap(&1, gaps)}),
      images: Enum.flat_map(books_members, &image_urls(&1, month)),
      evidence_gap: Enum.find_value(books_members, &evidence_gap(&1, gaps)),
      tax_paise: group.tax_paise,
      action: action(type, candidates, length(books_members)),
      verb: verb,
      resolved: resolved,
      review_origin?: review_origin?(books_members, workings),
      outcome: outcome(verb, type, accepted_reason),
      asked_at: nil
    }
  end

  defp missing_item(%{counterparts: [gstr2b | _]} = group, workings, month, asked_at) do
    ref = Reconciliation.gstr2b_ref(gstr2b)
    verb = workings.gstr2b_decisions[ref]

    entry =
      Enum.find(
        workings.baseline["in_2b_not_books"] || [],
        &(Reconciliation.gstr2b_ref(&1["gstr2b"] || &1) == ref)
      ) || %{}

    case_line =
      workings
      |> Map.get(:case_lines, [])
      |> Enum.find(fn line ->
        get_in(line.source_refs, ["gstr2b", month.period]) == ref
      end)

    document_state = case_line && case_line.document_state
    resolved = verb == "dismiss_2b" or document_state in ~w(present held not_held)

    %{
      id: group.key,
      group_key: group.key,
      member_ids: [],
      kind: :gstr2b,
      type: get_in(entry, ["reason", "code"]) || "missing_in_books",
      vendor: gstr2b["vendor_name"],
      invoice_number: gstr2b["invoice_number"],
      reason: get_in(entry, ["reason", "message"]) || "This GSTR-2B bill is not in the books.",
      books: nil,
      books_members: [],
      gstr2b: gstr2b,
      gstr2b_ref: ref,
      counterparts: group.counterparts,
      candidates: [],
      member_images: %{},
      member_evidence_gaps: %{},
      images: [],
      evidence_gap: nil,
      tax_paise: group.tax_paise,
      action: :gstr2b,
      verb: verb,
      resolved: resolved,
      review_origin?: true,
      outcome: missing_outcome(verb, document_state),
      asked_at: (case_line && case_line.asked_at) || asked_at,
      itc_case_id: case_line && case_line.case_id,
      document_state: document_state
    }
  end

  @doc "Counts every unresolved human judgement in the purchase lane."
  def open_decision_count(workings) do
    reconciliation = Enum.count(workings.groups, &(&1.state == :needs_decision))
    blocks = Enum.count(workings.itc["blocks"] || [], &(&1["state"] == "recommended"))

    documents =
      workings
      |> Map.get(:document_cases, [])
      |> Enum.count(&(&1.document_state not in ~w(held not_held)))

    reconciliation + blocks + documents
  end

  defp itc_item(block, rows, month) do
    row =
      Enum.find(rows, fn row ->
        row["invoice_number"] == block["invoice_number"] and row["vendor_name"] == block["vendor"]
      end)

    state = block["state"]

    %{
      id: "itc-#{block["block_id"]}",
      group_key: "itc-#{block["block_id"]}",
      member_ids: [],
      kind: :itc,
      type: block["code"],
      vendor: block["vendor"],
      invoice_number: block["invoice_number"],
      reason: block["reason"],
      books: nil,
      books_members: [],
      gstr2b: nil,
      counterparts: [],
      candidates: [],
      member_images: %{},
      member_evidence_gaps: %{},
      images: image_urls(row || %{}, month),
      evidence_gap: nil,
      tax_paise: block["tax_paise"] || 0,
      action: :itc,
      verb: state,
      resolved: state != "recommended",
      review_origin?: true,
      outcome: itc_outcome(state),
      asked_at: nil,
      itc_block: block
    }
  end

  defp itc_outcome("blocked"), do: "Credit blocked"
  defp itc_outcome("allowed"), do: "Credit kept"
  defp itc_outcome(_state), do: nil

  defp missing_outcome("dismiss_2b", _document_state), do: "Dismissed — not ours"
  defp missing_outcome(_verb, "present"), do: "Prior-period bill on file — ready to claim"
  defp missing_outcome(_verb, "held"), do: "Client holds the tax invoice"
  defp missing_outcome(_verb, "not_held"), do: "Withheld — carry forward"
  defp missing_outcome(_verb, _document_state), do: nil

  defp valid_scope("needs_you", _), do: :needs_you
  defp valid_scope("all", _), do: :all
  defp valid_scope(:needs_you, _), do: :needs_you
  defp valid_scope(:all, _), do: :all
  defp valid_scope(_, %{resolved: true}), do: :all
  defp valid_scope(_, _), do: :needs_you

  defp member_focus(nil, _), do: nil

  defp member_focus(item, id),
    do: if(id in item.member_ids, do: id, else: List.first(item.member_ids))

  defp matches?(item, id), do: item.id == id or id in item.member_ids

  defp register_order(item, rows) do
    ids = MapSet.new(item.member_ids)

    Enum.find_index(rows, fn row ->
      MapSet.member?(ids, row["id"]) or
        (item.kind == :gstr2b and row["bucket"] == "in_2b_not_books" and
           Reconciliation.gstr2b_ref(row) == item.gstr2b_ref) or
        (item.kind == :itc and row["invoice_number"] == item.invoice_number and
           row["vendor_name"] == item.vendor)
    end) || 1_000_000
  end

  defp baseline_books_entry(recon, books_id) do
    Enum.find_value(["needs_human", "in_books_not_2b"], fn bucket ->
      Enum.find(recon[bucket] || [], &(get_in(&1, ["books", "id"]) == books_id))
    end)
  end

  defp effective_candidates(recon, books_id, fallback) do
    case Enum.find(recon["needs_human"] || [], &(get_in(&1, ["books", "id"]) == books_id)) do
      nil -> fallback
      entry -> entry["candidates"] || []
    end
  end

  defp action(_, [_ | _], count) when count > 1, do: :ambiguous
  defp action("ambiguous_matches", [_ | _], _), do: :ambiguous

  defp action(type, [_], _)
       when type in [
              "invoice_number_mismatch",
              "relaxed_match_weak_corroboration",
              "fuzzy_name_weak_corroboration"
            ],
       do: :pair

  defp action(_, _, _), do: :unmatched

  defp outcome("confirm_pair", "ambiguous_matches", _), do: "Matched to the chosen 2B row"
  defp outcome("confirm_pair", _, _), do: "Confirmed — same bill"
  defp outcome("correct_field", _, _), do: "Corrected & re-matched"
  defp outcome("accept_unmatched", _, "await_2b"), do: "Kept — awaiting vendor's 2B"
  defp outcome("accept_unmatched", _, "not_claimable"), do: "Not claimable this month"
  defp outcome("dismiss_2b", _, _), do: "Dismissed — not ours"
  defp outcome(_, _, _), do: nil

  defp review_origin?(members, workings) do
    baseline_ids =
      MapSet.new(
        for bucket <- ["needs_human", "in_books_not_2b"],
            entry <- workings.baseline[bucket] || [],
            do: get_in(entry, ["books", "id"])
      )

    Enum.any?(members, fn member ->
      MapSet.member?(baseline_ids, member["id"]) or not is_nil(workings.decisions[member["id"]])
    end)
  end

  defp proposal_snapshot(item), do: %{type: item.type, action: item.action}

  defp image_urls(books, month) do
    Enum.map(books["images"] || [], fn path ->
      "/gst/#{month.client_id}/#{month.period}/evidence/#{Path.basename(path)}"
    end)
  end

  defp evidence_gap(books, gaps) do
    case {books["images"] || [], Regex.run(~r/\Ad(\d+)_/, to_string(books["id"]))} do
      {[], [_match, dump_id]} -> Map.get(gaps, String.to_integer(dump_id))
      _ -> nil
    end
  end
end
