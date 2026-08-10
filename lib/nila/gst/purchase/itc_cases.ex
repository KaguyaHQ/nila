defmodule Nila.Gst.Purchase.ItcCases do
  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Filing.Signoff
  alias Nila.Gst.InvoiceNumber

  alias Nila.Gst.Purchase.{
    Books,
    ItcAllocation,
    ItcCase,
    ItcCaseEvent,
    ItcSource,
    ItcSourceCaseEvent,
    Month,
    Reconciliation,
    Workings
  }

  alias Nila.Repo

  @decision_events ~w(client_holds_document document_not_held excluded_not_ours reopened)
  @line_keys ~w(case_id id identity_state merged? vendor supplier_gstin invoice_number invoice_date tax_heads tax_paise books_periods gstr2b_periods books_invoices has_sources? has_books? has_gstr2b? current_books? current_gstr2b? evidence_state eligibility_state settlement_state document_state asked_at allocation_id source_refs)

  def sync_month(%Month{} = month, recon) do
    sources =
      Enum.map(Workings.books_invoices(recon), &{"books", &1["id"], &1}) ++
        Enum.map(Workings.gstr2b_invoices(recon), fn invoice ->
          {"gstr2b", Reconciliation.gstr2b_ref(invoice), invoice}
        end)

    desired = MapSet.new(sources, fn {kind, source_ref, _invoice} -> {kind, source_ref} end)
    existing_sources = Repo.all(from s in ItcSource, where: s.client_month_id == ^month.id)
    sources_by_key = Map.new(existing_sources, &{{&1.kind, &1.source_ref}, &1})
    memberships = current_memberships(existing_sources)

    memberships =
      Enum.reduce(existing_sources, memberships, fn source, current ->
        membership = current[source.id]

        if not MapSet.member?(desired, {source.kind, source.source_ref}) and
             match?(%{action: "linked"}, membership) do
          event =
            append_membership_event!(
              source,
              membership.case_id,
              month,
              "unlinked",
              "source_removed"
            )

          Map.put(current, source.id, event)
        else
          current
        end
      end)

    {sources_by_key, memberships} =
      Enum.reduce(sources, {sources_by_key, memberships}, fn source_attrs, synced ->
        sync_source!(month, source_attrs, synced)
      end)

    recon
    |> pair_entries()
    |> Enum.reduce(memberships, fn entry, current ->
      link_pair!(month, entry["books"], entry["gstr2b"], sources_by_key, current)
    end)

    :ok
  end

  def list_for_month(%Month{} = month) do
    cases =
      Repo.all(
        from c in ItcCase,
          where: c.org_id == ^month.org_id and c.client_id == ^month.client_id,
          preload: [
            events: :effective_client_month,
            allocations: [:signoff, :client_month]
          ]
      )

    sources =
      Repo.all(
        from s in ItcSource,
          join: source_month in assoc(s, :client_month),
          where:
            s.org_id == ^month.org_id and source_month.client_id == ^month.client_id and
              source_month.period <= ^month.period,
          preload: [client_month: source_month]
      )

    source_ids = Enum.map(sources, & &1.id)

    membership_events =
      Repo.all(
        from e in ItcSourceCaseEvent,
          where: e.source_id in ^source_ids,
          preload: [:effective_client_month]
      )

    sources_by_case = sources_by_case_as_of(sources, membership_events, month.period)

    cases
    |> Enum.map(&project(&1, month, Map.get(sources_by_case, &1.id, [])))
    |> Enum.filter(&relevant?/1)
    |> Enum.sort_by(&{state_rank(&1), &1.invoice_number || "", &1.case_id})
  end

  def restore_case_lines(case_lines) do
    Enum.map(case_lines, fn line ->
      Enum.reduce(@line_keys, line, fn key, restored ->
        if Map.has_key?(line, key),
          do: Map.put(restored, String.to_existing_atom(key), line[key]),
          else: restored
      end)
    end)
  end

  def document_cases(case_lines) do
    case_lines
    |> restore_case_lines()
    |> Enum.filter(fn line ->
      line.current_gstr2b? and not line.has_books? and line.settlement_state != "excluded"
    end)
  end

  def documents_settled?(case_lines) do
    case_lines
    |> document_cases()
    |> Enum.all?(&(&1.document_state in ~w(held not_held)))
  end

  def carried_books(case_lines) do
    case_lines
    |> Enum.reject(& &1.current_books?)
    |> Enum.flat_map(& &1.books_invoices)
  end

  def claim_rows(case_lines, flags_by_id) do
    for line <- case_lines,
        line.current_gstr2b?,
        not line.current_books?,
        line.has_books?,
        line.evidence_state == "complete",
        book = List.last(line.books_invoices) do
      flags = Map.get(flags_by_id, book["id"], [])

      %{
        "id" => line.id,
        "vendor_name" => line.vendor,
        "vendor_gstin" => line.supplier_gstin,
        "invoice_number" => line.invoice_number,
        "cgst_paise" => line.tax_heads["cgst"],
        "sgst_paise" => line.tax_heads["sgst"],
        "igst_paise" => line.tax_heads["igst"],
        "bucket" => "matched",
        "flags" => Enum.map(flags, &Map.take(&1, ["code", "reason", "section"]))
      }
    end
  end

  def separate_rejected_pairs(%Month{} = month, attrs_list, decided_by_id) do
    Enum.each(attrs_list, fn attrs ->
      if (attrs["verb"] || attrs[:verb]) == "reject_pair" do
        separate_pair!(
          month,
          attrs["books_id"] || attrs[:books_id],
          attrs["gstr2b_ref"] || attrs[:gstr2b_ref],
          decided_by_id
        )
      end
    end)

    :ok
  end

  def move_source(%Month{} = month, source_id, target_case_id, reason, decided_by_id) do
    Repo.transact(fn ->
      month = Repo.one!(from m in Month, where: m.id == ^month.id, lock: "FOR UPDATE")

      with :ok <- refuse_signed(month) do
        move_source!(month, source_id, target_case_id, reason, decided_by_id)
      end
    end)
  end

  def record_event(%Month{} = month, case_id, event_type, decided_by_id, payload \\ %{}) do
    Repo.transact(fn ->
      month = Repo.one!(from m in Month, where: m.id == ^month.id, lock: "FOR UPDATE")

      with :ok <- refuse_signed(month) do
        insert_event(month, case_id, event_type, decided_by_id, payload)
      end
    end)
  end

  def insert_event(%Month{} = month, case_id, event_type, decided_by_id, payload \\ %{}) do
    case Repo.one(
           from c in ItcCase,
             where:
               c.id == ^case_id and c.org_id == ^month.org_id and
                 c.client_id == ^month.client_id,
             lock: "FOR UPDATE"
         ) do
      %ItcCase{} = itc_case ->
        %ItcCaseEvent{
          case_id: itc_case.id,
          effective_client_month_id: month.id,
          org_id: month.org_id,
          decided_by_id: decided_by_id
        }
        |> ItcCaseEvent.changeset(%{event_type: event_type, payload: payload})
        |> Repo.insert()

      nil ->
        {:error, :not_found}
    end
  end

  def reserve_claims(%Signoff{} = signoff, %Month{} = month, case_lines, itc) do
    current = Enum.filter(case_lines, & &1.current_gstr2b?)
    case_ids = current |> Enum.map(& &1.case_id) |> Enum.uniq() |> Enum.sort()

    Enum.each(case_ids, fn case_id ->
      Repo.one!(from c in ItcCase, where: c.id == ^case_id, lock: "FOR UPDATE")
    end)

    allocated_ids =
      Repo.all(
        from a in ItcAllocation,
          where: a.case_id in ^case_ids and is_nil(a.revoked_at),
          select: a.case_id
      )
      |> MapSet.new()

    ambiguous = Enum.filter(current, &(&1.identity_state == "ambiguous"))

    already_allocated =
      Enum.filter(current, fn line ->
        line.evidence_state == "complete" and MapSet.member?(allocated_ids, line.case_id)
      end)

    cond do
      ambiguous != [] ->
        {:error, {:ambiguous_itc_cases, Enum.map(ambiguous, & &1.case_id)}}

      already_allocated != [] ->
        {:error, {:itc_already_allocated, Enum.map(already_allocated, & &1.case_id)}}

      true ->
        blocked =
          for block <- itc["blocks"] || [], block["state"] == "blocked", into: MapSet.new() do
            {block["vendor"], InvoiceNumber.key(block["invoice_number"])}
          end

        current
        |> Enum.filter(fn line ->
          line.evidence_state == "complete" and line.settlement_state == "available" and
            not MapSet.member?(blocked, {line.vendor, InvoiceNumber.key(line.invoice_number)})
        end)
        |> Enum.sort_by(& &1.case_id)
        |> Enum.each(fn line ->
          %ItcAllocation{
            case_id: line.case_id,
            client_month_id: month.id,
            signoff_id: signoff.id,
            org_id: month.org_id
          }
          |> ItcAllocation.changeset(%{
            kind: "original_claim",
            tax_heads: line.tax_heads,
            tax_paise: line.tax_paise
          })
          |> Repo.insert!()
        end)

        :ok
    end
  end

  def release_allocations!(%Signoff{} = signoff) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(a in ItcAllocation,
        where: a.signoff_id == ^signoff.id and is_nil(a.filed_at) and is_nil(a.revoked_at)
      ),
      set: [revoked_at: now]
    )

    :ok
  end

  def file_allocations!(%Signoff{} = signoff) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(a in ItcAllocation,
        where: a.signoff_id == ^signoff.id and is_nil(a.filed_at) and is_nil(a.revoked_at)
      ),
      set: [filed_at: now]
    )

    :ok
  end

  defp sync_source!(
         month,
         {kind, source_ref, invoice},
         {sources_by_key, memberships}
       )
       when is_binary(source_ref) do
    key = {kind, source_ref}

    case sources_by_key[key] do
      %ItcSource{} = source ->
        case memberships[source.id] do
          %{action: "linked"} ->
            {sources_by_key, memberships}

          membership ->
            case_id =
              if membership,
                do: current_target_case_id(membership.case_id),
                else: matching_case(month, kind, invoice, identity_attrs(invoice)).id

            event =
              append_membership_event!(source, case_id, month, "linked", "source_restored")

            {sources_by_key, Map.put(memberships, source.id, event)}
        end

      nil ->
        attrs = identity_attrs(invoice)
        itc_case = matching_case(month, kind, invoice, attrs)

        source =
          %ItcSource{client_month_id: month.id, org_id: month.org_id}
          |> ItcSource.changeset(%{
            kind: kind,
            source_ref: source_ref,
            payload: json_map(invoice)
          })
          |> Repo.insert!()

        event =
          append_membership_event!(source, itc_case.id, month, "linked", "source_discovered")

        {Map.put(sources_by_key, key, source), Map.put(memberships, source.id, event)}
    end
  end

  defp sync_source!(_, _, synced), do: synced

  defp link_pair!(
         month,
         %{"id" => books_id},
         %{} = gstr2b,
         sources_by_key,
         memberships
       ) do
    books_source = Map.fetch!(sources_by_key, {"books", books_id})

    gstr2b_source =
      Map.fetch!(sources_by_key, {"gstr2b", Reconciliation.gstr2b_ref(gstr2b)})

    books_membership = Map.fetch!(memberships, books_source.id)
    gstr2b_membership = Map.fetch!(memberships, gstr2b_source.id)

    if books_membership.case_id != gstr2b_membership.case_id do
      {:ok, _} =
        move_source!(
          month,
          gstr2b_source.id,
          books_membership.case_id,
          "reconciliation_match",
          nil
        )

      merge_empty_case!(gstr2b_membership.case_id, books_membership.case_id, month)

      ItcCase
      |> Repo.get!(books_membership.case_id)
      |> ItcCase.changeset(%{identity_state: "confirmed"})
      |> Repo.update!()

      Map.put(memberships, gstr2b_source.id, %{
        gstr2b_membership
        | action: "linked",
          case_id: books_membership.case_id
      })
    else
      memberships
    end
  end

  defp link_pair!(_, _, _, _, memberships), do: memberships

  defp pair_entries(recon) do
    for bucket <- ~w(matched value_mismatch), entry <- recon[bucket] || [], do: entry
  end

  defp merge_empty_case!(case_id, merged_into_case_id, month) do
    itc_case =
      Repo.one!(
        from c in ItcCase,
          where: c.id == ^case_id,
          lock: "FOR UPDATE"
      )

    if is_nil(itc_case.merged_into_case_id) and current_sources_for_case_ids([case_id]) == %{} do
      itc_case
      |> ItcCase.changeset(%{
        identity_state: "merged",
        merged_into_case_id: merged_into_case_id
      })
      |> Repo.update!()

      %ItcCaseEvent{
        case_id: case_id,
        effective_client_month_id: month.id,
        org_id: month.org_id
      }
      |> ItcCaseEvent.changeset(%{
        event_type: "case_merged",
        payload: %{
          "merged_into_case_id" => merged_into_case_id,
          "previous_identity_state" => itc_case.identity_state
        }
      })
      |> Repo.insert!()
    end
  end

  defp separate_pair!(month, books_id, gstr2b_ref, decided_by_id)
       when is_binary(books_id) and is_binary(gstr2b_ref) do
    books_source =
      Repo.get_by(ItcSource,
        client_month_id: month.id,
        kind: "books",
        source_ref: books_id
      )

    gstr2b_source =
      Repo.get_by(ItcSource,
        client_month_id: month.id,
        kind: "gstr2b",
        source_ref: gstr2b_ref
      )

    books_membership = books_source && current_membership(books_source)
    gstr2b_membership = gstr2b_source && current_membership(gstr2b_source)

    if books_membership && gstr2b_membership &&
         books_membership.case_id == gstr2b_membership.case_id do
      attrs =
        gstr2b_source.payload
        |> identity_attrs()
        |> Map.put(:identity_state, "ambiguous")

      separate_case = create_case!(month, attrs)

      {:ok, _} =
        move_source!(
          month,
          gstr2b_source.id,
          separate_case.id,
          "pair_rejected",
          decided_by_id
        )

      ItcCase
      |> Repo.get!(books_membership.case_id)
      |> ItcCase.changeset(%{identity_state: "ambiguous"})
      |> Repo.update!()
    end
  end

  defp separate_pair!(_, _, _, _), do: :ok

  defp move_source!(month, source_id, target_case_id, reason, decided_by_id) do
    source =
      Repo.one(
        from s in ItcSource,
          join: source_month in assoc(s, :client_month),
          where:
            s.id == ^source_id and s.org_id == ^month.org_id and
              source_month.client_id == ^month.client_id,
          lock: "FOR UPDATE"
      )

    target_case =
      Repo.one(
        from c in ItcCase,
          where:
            c.id == ^target_case_id and c.org_id == ^month.org_id and
              c.client_id == ^month.client_id and is_nil(c.merged_into_case_id),
          lock: "FOR UPDATE"
      )

    with %ItcSource{} <- source,
         %ItcCase{} <- target_case do
      membership = current_membership(source)

      if membership && membership.action == "linked" && membership.case_id == target_case.id do
        {:ok, %{from_case_id: target_case.id, to_case_id: target_case.id}}
      else
        if membership && membership.action == "linked" do
          append_membership_event!(
            source,
            membership.case_id,
            month,
            "unlinked",
            reason,
            decided_by_id
          )
        end

        append_membership_event!(
          source,
          target_case.id,
          month,
          "linked",
          reason,
          decided_by_id
        )

        {:ok,
         %{
           from_case_id: membership && membership.case_id,
           to_case_id: target_case.id
         }}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp append_membership_event!(
         source,
         case_id,
         month,
         action,
         reason,
         decided_by_id \\ nil
       ) do
    Repo.one!(from s in ItcSource, where: s.id == ^source.id, lock: "FOR UPDATE")

    if action == "linked" do
      Repo.one!(
        from c in ItcCase,
          where: c.id == ^case_id and is_nil(c.merged_into_case_id),
          lock: "FOR UPDATE"
      )
    end

    %ItcSourceCaseEvent{
      source_id: source.id,
      case_id: case_id,
      effective_client_month_id: month.id,
      org_id: month.org_id,
      decided_by_id: decided_by_id
    }
    |> ItcSourceCaseEvent.changeset(%{action: action, reason: reason})
    |> Repo.insert!()
  end

  defp current_memberships([]), do: %{}

  defp current_memberships(sources) do
    source_ids = Enum.map(sources, & &1.id)

    Repo.all(from e in ItcSourceCaseEvent, where: e.source_id in ^source_ids)
    |> latest_memberships()
    |> Map.new(&{&1.source_id, &1})
  end

  defp current_membership(source) do
    Repo.one(
      from e in ItcSourceCaseEvent,
        where: e.source_id == ^source.id,
        order_by: [desc: e.id],
        limit: 1
    )
  end

  defp current_target_case_id(case_id) do
    case Repo.get!(ItcCase, case_id) do
      %{merged_into_case_id: nil} -> case_id
      %{merged_into_case_id: merged_into_case_id} -> current_target_case_id(merged_into_case_id)
    end
  end

  defp current_sources_for_case_ids(case_ids) do
    Repo.all(
      from e in ItcSourceCaseEvent,
        where: e.case_id in ^case_ids,
        preload: [source: :client_month]
    )
    |> current_sources_from_events()
  end

  defp sources_by_case_as_of(sources, membership_events, period) do
    sources_by_id = Map.new(sources, &{&1.id, &1})

    membership_events
    |> Enum.filter(&(&1.effective_client_month.period <= period))
    |> latest_memberships()
    |> Enum.filter(&(&1.action == "linked"))
    |> Enum.reduce(%{}, fn event, by_case ->
      Map.update(by_case, event.case_id, [sources_by_id[event.source_id]], fn case_sources ->
        [sources_by_id[event.source_id] | case_sources]
      end)
    end)
  end

  defp current_sources_from_events(events) do
    events
    |> latest_memberships()
    |> Enum.filter(&(&1.action == "linked"))
    |> Enum.group_by(& &1.case_id, & &1.source)
  end

  defp latest_memberships(events) do
    events
    |> Enum.group_by(& &1.source_id)
    |> Enum.map(fn {_source_id, source_events} ->
      Enum.max_by(source_events, & &1.id)
    end)
  end

  defp matching_case(month, _, _, %{match_key: nil} = attrs),
    do: create_case!(month, Map.put(attrs, :identity_state, "provisional"))

  defp matching_case(month, kind, invoice, attrs) do
    candidates =
      Repo.all(
        from c in ItcCase,
          where:
            c.org_id == ^month.org_id and c.client_id == ^month.client_id and
              c.match_key == ^attrs.match_key and is_nil(c.merged_into_case_id),
          preload: [source_events: [source: :client_month]]
      )

    sources_by_case =
      candidates
      |> Enum.flat_map(& &1.source_events)
      |> current_sources_from_events()

    compatible =
      Enum.filter(candidates, fn candidate ->
        compatible?(Map.get(sources_by_case, candidate.id, []), kind, invoice)
      end)

    case compatible do
      [itc_case] ->
        itc_case

      [] when candidates == [] ->
        create_case!(month, Map.put(attrs, :identity_state, "confirmed"))

      _ ->
        Enum.each(candidates, fn candidate ->
          candidate
          |> ItcCase.changeset(%{identity_state: "ambiguous"})
          |> Repo.update!()
        end)

        create_case!(month, Map.put(attrs, :identity_state, "ambiguous"))
    end
  end

  defp compatible?(sources, kind, invoice) do
    same_kind = Enum.filter(sources, &(&1.kind == kind))
    same_kind == [] or Enum.any?(same_kind, &corroborates?(&1.payload, invoice))
  end

  defp corroborates?(left, right) do
    date(left["invoice_date"]) == date(right["invoice_date"]) and
      tax_total(left) == tax_total(right) and
      (left["total_paise"] || 0) == (right["total_paise"] || 0)
  end

  defp create_case!(month, attrs) do
    %ItcCase{org_id: month.org_id, client_id: month.client_id}
    |> ItcCase.changeset(attrs)
    |> Repo.insert!()
  end

  defp identity_attrs(invoice) do
    number = invoice["invoice_number"]
    normalized = if present?(number), do: InvoiceNumber.key(number)
    fy = financial_year_start(date(invoice["invoice_date"]))
    gstin = invoice["vendor_gstin"] |> to_string() |> String.trim() |> String.upcase()
    gstin = if gstin == "", do: nil, else: gstin

    match_key =
      if gstin && normalized not in [nil, ""] && fy do
        Enum.join([gstin, "invoice", fy, normalized], "|")
      end

    %{
      supplier_gstin: gstin,
      document_type: "invoice",
      invoice_number: number,
      normalized_invoice_number: normalized,
      supplier_fy_start_year: fy,
      match_key: match_key
    }
  end

  defp project(itc_case, month, sources) do
    all_events = itc_case.events

    events =
      Enum.filter(
        all_events,
        &(&1.effective_client_month.period <= month.period)
      )

    sources = Enum.sort_by(sources, &{&1.client_month.period, &1.id})
    merged? = merged_as_of?(events)

    books = Enum.filter(sources, &(&1.kind == "books"))
    gstr2b = Enum.filter(sources, &(&1.kind == "gstr2b"))
    decision = latest_decision(events)

    allocation =
      itc_case.allocations
      |> Enum.filter(&(&1.client_month.period <= month.period))
      |> active_allocation()

    has_books? = books != []
    has_gstr2b? = gstr2b != []
    document_state = document_state(decision, has_books?)

    evidence_state =
      cond do
        not has_gstr2b? -> "awaiting_2b"
        not has_books? and document_state != "held" -> "awaiting_document"
        true -> "complete"
      end

    settlement_state = settlement_state(allocation, decision, evidence_state)
    basis = List.last(gstr2b) || List.last(books)
    payload = (basis && basis.payload) || %{}

    %{
      case_id: itc_case.id,
      id: "itc-case-#{itc_case.id}",
      identity_state: identity_state_as_of(itc_case, all_events, events, merged?),
      merged?: merged?,
      vendor: payload["vendor_name"] || itc_case.supplier_gstin || "Unknown vendor",
      supplier_gstin: itc_case.supplier_gstin,
      invoice_number: itc_case.invoice_number,
      invoice_date: payload["invoice_date"],
      tax_heads: tax_heads(payload),
      tax_paise: tax_total(payload),
      books_periods: Enum.map(books, & &1.client_month.period) |> Enum.uniq(),
      gstr2b_periods: Enum.map(gstr2b, & &1.client_month.period) |> Enum.uniq(),
      books_invoices: Enum.map(books, & &1.payload),
      has_sources?: sources != [],
      has_books?: has_books?,
      has_gstr2b?: has_gstr2b?,
      current_books?: Enum.any?(books, &(&1.client_month_id == month.id)),
      current_gstr2b?: Enum.any?(gstr2b, &(&1.client_month_id == month.id)),
      evidence_state: evidence_state,
      eligibility_state: eligibility_state(decision, evidence_state),
      settlement_state: settlement_state,
      document_state: document_state,
      asked_at: latest_event_at(events, "documents_requested"),
      allocation_id: allocation && allocation.id,
      source_refs:
        sources
        |> Enum.group_by(& &1.kind)
        |> Map.new(fn {kind, occurrences} ->
          {kind, Map.new(occurrences, &{&1.client_month.period, &1.source_ref})}
        end)
    }
  end

  defp merged_as_of?(events) do
    events
    |> Enum.filter(&(&1.event_type in ~w(case_merged case_merge_reversed)))
    |> Enum.max_by(&{&1.inserted_at, &1.id}, fn -> nil end)
    |> case do
      %{event_type: "case_merged"} -> true
      _ -> false
    end
  end

  defp identity_state_as_of(_, _, _, true), do: "merged"

  defp identity_state_as_of(%{identity_state: "merged"}, all_events, events, false) do
    reversed_identity =
      events
      |> Enum.find(&(&1.event_type == "case_merge_reversed"))
      |> case do
        %{payload: %{"identity_state" => identity_state}} -> identity_state
        _ -> nil
      end

    reversed_identity ||
      all_events
      |> Enum.find(&(&1.event_type == "case_merged"))
      |> case do
        %{payload: %{"previous_identity_state" => identity_state}} -> identity_state
        _ -> "confirmed"
      end
  end

  defp identity_state_as_of(itc_case, _, _, false), do: itc_case.identity_state

  defp latest_decision(events) do
    events
    |> Enum.filter(&(&1.event_type in @decision_events))
    |> Enum.max_by(&{&1.inserted_at, &1.id}, fn -> nil end)
  end

  defp latest_event_at(events, type) do
    events
    |> Enum.filter(&(&1.event_type == type))
    |> Enum.max_by(&{&1.inserted_at, &1.id}, fn -> nil end)
    |> case do
      nil -> nil
      event -> event.inserted_at
    end
  end

  defp document_state(_, true), do: "present"
  defp document_state(%{event_type: "client_holds_document"}, false), do: "held"
  defp document_state(%{event_type: "document_not_held"}, false), do: "not_held"
  defp document_state(_, false), do: "unknown"

  defp eligibility_state(%{event_type: "excluded_not_ours"}, _), do: "ineligible"
  defp eligibility_state(_, "complete"), do: "needs_rules"
  defp eligibility_state(_, _), do: "unassessed"

  defp settlement_state(%{filed_at: filed_at}, _, _) when not is_nil(filed_at),
    do: "claimed"

  defp settlement_state(%ItcAllocation{}, _, _), do: "reserved"

  defp settlement_state(_, %{event_type: "excluded_not_ours"}, _),
    do: "excluded"

  defp settlement_state(_, _, "complete"), do: "available"
  defp settlement_state(_, _, _), do: "pending"

  defp active_allocation(allocations) do
    Enum.find(allocations, &is_nil(&1.revoked_at))
  end

  defp relevant?(line) do
    not line.merged? and line.has_sources? and
      (line.current_books? or line.current_gstr2b? or
         (line.settlement_state not in ~w(claimed excluded) and is_nil(line.allocation_id)))
  end

  defp state_rank(%{settlement_state: "available"}), do: 0
  defp state_rank(%{evidence_state: "awaiting_document"}), do: 1
  defp state_rank(%{evidence_state: "awaiting_2b"}), do: 2
  defp state_rank(_), do: 3

  defp refuse_signed(month) do
    case Repo.fetch_one(
           from s in Signoff,
             where:
               s.client_month_id == ^month.id and s.artifact == "gstr3b" and is_nil(s.revoked_at),
             limit: 1
         ) do
      {:ok, _signoff} -> {:error, :signed_off}
      {:error, :not_found} -> :ok
    end
  end

  defp financial_year_start(%Date{month: month, year: year}) when month >= 4, do: year
  defp financial_year_start(%Date{year: year}), do: year - 1
  defp financial_year_start(_), do: nil

  defp date(%Date{} = date), do: date
  defp date(value) when is_binary(value), do: Books.parse_date(value)
  defp date(_), do: nil

  defp tax_heads(invoice) do
    Map.merge(%{"igst" => 0, "cgst" => 0, "sgst" => 0}, invoice["tax_paise"] || %{})
  end

  defp tax_total(invoice), do: invoice |> tax_heads() |> Map.values() |> Enum.sum()
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp json_map(value), do: value |> Jason.encode!() |> Jason.decode!()
end
