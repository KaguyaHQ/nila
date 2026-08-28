defmodule Nila.Gst.Intake.Dumps do
  @moduledoc """
  Intake for a client's GST month: dumps arrive one at a time, each is
  recorded and extracted on its own, and the month is derived from the union.

  The shape follows how documents actually reach a firm: one main pile early,
  then stragglers — chase responses, forgotten bills — in ones and twos. Each
  arrival extracts only its own pages (the normalized invoices persist on the
  dump), so a two-bill straggler never re-reads the fifty-page main dump, and
  invoice ids from earlier dumps stay stable — which is what lets recorded
  resolutions survive accretion. GSTR-2B is the exception: it is a portal
  snapshot, whole and authoritative, so a new 2B *replaces* the old
  (superseded dumps keep their rows for audit but drop out of the effective
  set).
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Intake.Dump
  alias Nila.Gst.Purchase.Books
  alias Nila.Repo

  @active_statuses ~w(received extracting)

  @doc """
  Records one arrival. Tenancy (`org_id`, `client_id`) and attribution
  (`brought_in_by_id`) are set on the struct, never cast.
  """
  def record(%{org_id: org_id, client_id: client_id} = scope, attrs) do
    with {:ok, sales_batch_id} <- sales_batch_id(scope, attrs) do
      %Dump{
        org_id: org_id,
        client_id: client_id,
        brought_in_by_id: scope[:brought_in_by_id],
        sales_batch_id: sales_batch_id
      }
      |> Dump.changeset(attrs)
      |> Repo.insert()
    end
  end

  defp sales_batch_id(%{sales_batch_id: sales_batch_id}, _attrs)
       when is_integer(sales_batch_id),
       do: {:ok, sales_batch_id}

  defp sales_batch_id(scope, %{kind: "sales", meta: %{"sales_batch" => true} = meta}) do
    import_ref = Map.get(meta, "sales_import_ref") || Ecto.UUID.generate()

    case Nila.Gst.Sales.Batch.create(scope.org_id, scope.client_id, import_ref) do
      {:ok, batch} -> {:ok, batch.id}
      error -> error
    end
  end

  defp sales_batch_id(_scope, _attrs), do: {:ok, nil}

  @doc "All dumps for `(org, client, period)`, oldest first (arrival order)."
  def list(org_id, client_id, period) do
    Repo.all(
      from d in Dump,
        where: d.org_id == ^org_id and d.client_id == ^client_id and d.period == ^period,
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: [:brought_in_by]
    )
  end

  @doc """
  One original file of an org's dump, for download: the dump row is the
  authority — the path's client/period must match it — and `index` addresses
  into `file_keys`. `{:error, :not_found}` on any mismatch.
  """
  def fetch_original(org_id, client_id, period, dump_id, index) do
    with {:ok, dump} <- fetch(org_id, dump_id),
         true <- to_string(dump.client_id) == to_string(client_id) and dump.period == period,
         key when is_binary(key) <- Enum.at(dump.file_keys, index),
         {:ok, bytes} <- Nila.Storage.get(key) do
      {:ok, dump, key, bytes}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Fetches one rendered sales-bill page using the dump as the authority.

  Unlike filing-month evidence, a Sales Bills upload does not require a
  `SalesMonth` row. The requested basename must occur on that exact org/client
  dump before its storage key is read.
  """
  def fetch_sales_evidence(org_id, client_id, dump_id, basename) do
    with true <- valid_evidence_basename?(basename),
         {:ok, dump} <- fetch(org_id, dump_id),
         true <-
           dump.kind == "sales" and to_string(dump.client_id) == to_string(client_id) and
             evidence_basename?(dump.invoices, basename),
         {:ok, bytes} <-
           Nila.Storage.get(
             Nila.Gst.Sales.Months.evidence_key(
               dump.org_id,
               dump.client_id,
               dump.period,
               basename
             )
           ) do
      {:ok, bytes}
    else
      _ -> {:error, :not_found}
    end
  end

  defp valid_evidence_basename?(basename) when is_binary(basename) do
    Path.basename(basename) == basename and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\.(?:png|jpe?g|webp)\z/i, basename)
  end

  defp valid_evidence_basename?(_basename), do: false

  defp evidence_basename?(invoices, basename) when is_list(invoices) do
    Enum.any?(invoices, fn invoice ->
      invoice
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> then(&List.wrap(&1["images"] || &1["image"]))
      |> Enum.any?(&(is_binary(&1) and Path.basename(&1) == basename))
    end)
  end

  defp evidence_basename?(_invoices, _basename), do: false

  @doc """
  What each period of a client already holds:
  `%{"2026-04" => %{bills: 14, gstr2b?: true}}`, extracted arrivals only.

  Asked by the intake form so a period is never a bare label. The upload form
  cannot know the dates inside the file it is being handed, but it can say that
  June is empty and April is full — the tell in every wrong-month upload, and
  the one the pre-selected closeable period hides.
  """
  def holdings(org_id, client_id) do
    Repo.all(
      from d in Dump,
        where: d.org_id == ^org_id and d.client_id == ^client_id and d.status == "extracted",
        select: {d.period, d.kind, fragment("coalesce(array_length(?, 1), 0)", d.invoices)}
    )
    |> Enum.reduce(%{}, fn {period, kind, count}, acc ->
      held = Map.get(acc, period, %{bills: 0, gstr2b?: false})

      held =
        case kind do
          "gstr2b" -> %{held | gstr2b?: true}
          _bills -> %{held | bills: held.bills + count}
        end

      Map.put(acc, period, held)
    end)
  end

  @doc "Non-terminal dumps for `(org, client, period)`, oldest first."
  def active(org_id, client_id, period) do
    Repo.all(
      from d in Dump,
        where:
          d.org_id == ^org_id and d.client_id == ^client_id and d.period == ^period and
            d.status in ^@active_statuses,
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: [:brought_in_by]
    )
  end

  @doc "All non-terminal dumps for an org, used to mark processing client-months."
  def active_for_org(org_id) do
    Repo.all(
      from d in Dump,
        where: d.org_id == ^org_id and d.status in ^@active_statuses,
        order_by: [asc: d.inserted_at, asc: d.id]
    )
  end

  @doc "Whether a supplied packet of `kind` still needs processing or a human decision."
  def unresolved?(org_id, client_id, period, kind) do
    org_id |> list(client_id, period) |> unresolved?(kind)
  end

  def unresolved?(dumps, kind) when is_list(dumps) do
    superseded = superseded_failures(dumps)

    Enum.any?(dumps, fn dump ->
      dump.kind == kind and dump.id not in superseded and
        dump.status in ~w(received extracting failed held needs_confirmation)
    end)
  end

  @doc "Fetches one dump scoped to the org. `{:error, :not_found}` otherwise."
  def fetch(org_id, dump_id) do
    Repo.fetch_by(Dump, id: dump_id, org_id: org_id)
  end

  @doc "Fetches one upload batch, preserving the order in which its dump ids were supplied."
  def fetch_batch(org_id, client_id, dump_ids) when is_list(dump_ids) do
    ids = Enum.uniq(dump_ids)

    dumps =
      Repo.all(
        from d in Dump,
          where: d.org_id == ^org_id and d.client_id == ^client_id and d.id in ^ids
      )
      |> Map.new(&{&1.id, &1})

    if ids != [] and map_size(dumps) == length(ids) do
      {:ok, Enum.map(ids, &Map.fetch!(dumps, &1))}
    else
      {:error, :not_found}
    end
  end

  @doc """
  The `{client_id, period}` pairs an extracted GSTR-2B has landed for.

  Asked once per org rather than per row, because it decides a *state*, not a
  detail: with no 2B there is nothing for the books to be reconciled against,
  every invoice is unmatched by construction, and a purchase month's open
  count is an artifact of the missing snapshot rather than a pile of real
  decisions.
  """
  def gstr2b_months(org_id) do
    Repo.all(
      from d in Dump,
        where: d.org_id == ^org_id and d.kind == "gstr2b" and d.status == "extracted",
        distinct: true,
        select: {d.client_id, d.period}
    )
    |> MapSet.new()
  end

  @doc """
  The effective dump set for deriving a month: every extracted bill dump of
  `kind`, arrival order. For `"gstr2b"` and `"filed_gstr1"` the latest
  extracted dump alone — a portal snapshot replaces its predecessors.
  """
  def effective(org_id, client_id, period, kind) when kind in ~w(gstr2b filed_gstr1) do
    org_id
    |> extracted(client_id, period, kind)
    |> Enum.take(-1)
  end

  def effective(org_id, client_id, period, kind) when kind in ~w(sales purchase) do
    extracted(org_id, client_id, period, kind)
  end

  @doc """
  The return the portal actually holds for this month, or nil: the latest
  extracted `filed_gstr1` dump's parsed JSON. A re-upload replaces its
  predecessors — the 2B rule — because there is only ever one filed return.
  """
  def filed_gstr1(org_id, client_id, period) do
    case effective(org_id, client_id, period, "filed_gstr1") do
      [dump] -> List.first(dump.invoices)
      [] -> nil
    end
  end

  @doc """
  Every extracted `kind` dump of this client in *other* periods, oldest period
  first — what a new packet's invoices are checked against for a bill already
  booked in another month.

  Scoped to the client, never the org: two clients legitimately hold the same
  vendor's invoice number.
  """
  def extracted_elsewhere(org_id, client_id, period, kind) do
    Repo.all(
      from d in Dump,
        where:
          d.org_id == ^org_id and d.client_id == ^client_id and d.kind == ^kind and
            d.status == "extracted" and d.period != ^period,
        order_by: [asc: d.period, asc: d.id]
    )
  end

  @doc """
  The union of normalized invoices across the effective dumps of `kind`,
  arrival order. Invoice ids and image basenames were namespaced per-dump at
  extraction time, so the union is plain concatenation — nothing collides,
  nothing renumbers, and earlier resolutions stay valid when a straggler
  arrives.
  """
  def union_invoices(org_id, client_id, period, kind) do
    org_id
    |> effective(client_id, period, kind)
    |> Enum.flat_map(& &1.invoices)
    |> Enum.map(&rehydrate/1)
  end

  @doc """
  The pages of each effective dump that no extracted invoice claims, in arrival
  order: `[%{"dump_id" => 3, "source" => "oct-bills.pdf", "pages" => [51]}]`.

  Page numbers are per dump — each arrival is its own document — so the ledger
  names the dump alongside them. Dumps whose every page is accounted for drop
  out, leaving `[]` for a clean month.
  """
  def unaccounted_pages(org_id, client_id, period, kind) do
    org_id
    |> effective(client_id, period, kind)
    |> Enum.flat_map(fn dump ->
      case Map.get(dump.meta || %{}, "unaccounted_pages") do
        pages when is_list(pages) and pages != [] ->
          [%{"dump_id" => dump.id, "source" => source_name(dump), "pages" => pages}]

        _none ->
          []
      end
    end)
  end

  @doc """
  Physical pages read across the effective `kind` dumps, or `nil` when any of
  them predates the count being recorded on `meta` — the month's account omits
  its pages clause rather than guessing low.
  """
  def source_page_count(org_id, client_id, period, kind) do
    case effective(org_id, client_id, period, kind) do
      [] ->
        nil

      dumps ->
        counts = Enum.map(dumps, &Map.get(&1.meta || %{}, "source_page_count"))
        if Enum.all?(counts, &is_integer/1), do: Enum.sum(counts)
    end
  end

  @doc """
  The effective dumps whose pages could not be rendered, in arrival order:
  `[%{"dump_id" => 3, "source" => "oct-bills.pdf"}]`.

  A failed render never fails a read — a month with no pictures beats no month
  — so this is what keeps the hole visible. Without it a packet nobody can
  eyeball looks exactly like a packet that had nothing worth showing.
  """
  def evidence_gaps(org_id, client_id, period, kind) do
    org_id
    |> effective(client_id, period, kind)
    |> Enum.filter(&(Map.get(&1.meta || %{}, "evidence_unavailable") == true))
    |> Enum.map(&%{"dump_id" => &1.id, "source" => source_name(&1)})
  end

  defp source_name(%Dump{file_keys: [key | _rest]}) when is_binary(key), do: Path.basename(key)
  defp source_name(%Dump{id: id}), do: "dump ##{id}"

  @doc """
  Restores types the JSONB round-trip flattens: `invoice_date` comes back an
  ISO string; the recon and flags expect `Date`.

  Parses printed dates too, not just the ISO the round-trip writes. Sales
  invoices extracted before dates were parsed at the boundary are stored as the
  model printed them (`"05.06.2026"`), and a rehydrate that only read ISO left
  every one of those months invisible to the checks that match on `Date` — the
  guard failing open on exactly the history it exists to compare against.
  """
  def rehydrate(invoice) do
    Map.update(invoice, "invoice_date", nil, fn
      %Date{} = date -> date
      value when is_binary(value) -> Books.parse_date(value) || value
      other -> other
    end)
  end

  def mark_extracting(%Dump{} = dump),
    do: dump |> Dump.changeset(%{status: "extracting", error: nil}) |> Repo.update!()

  def mark_extracted(%Dump{} = dump, invoices, meta \\ %{}) do
    dump
    |> Dump.changeset(%{
      status: "extracted",
      invoices: invoices,
      meta: Map.merge(dump.meta || %{}, meta)
    })
    |> Repo.update!()
  end

  def mark_failed(%Dump{} = dump, error),
    do: dump |> Dump.changeset(%{status: "failed", error: truncate(error)}) |> Repo.update!()

  def mark_held(%Dump{} = dump),
    do: dump |> Dump.changeset(%{status: "held"}) |> Repo.update!()

  @doc """
  Extracted, stored, and deliberately not derived: the packet raises a question
  about whether it is even the right work for this month. `finding` is the
  `Nila.Gst.Intake.Preconditions` shape, recorded on `meta["precondition"]`.
  """
  def mark_needs_confirmation(%Dump{} = dump, finding) do
    dump
    |> Dump.changeset(%{
      status: "needs_confirmation",
      meta: Map.put(meta(dump), "precondition", finding)
    })
    |> Repo.update!()
  end

  @doc """
  The question stopped standing on its own — derivable again, with no answer
  recorded, because nobody answered it.

  A precondition is a claim about the world around the dump, not about the dump:
  `cross_month_duplicate` names a sibling, and once that sibling is moved,
  discarded, or itself put in question, the finding outlives its reason. Nothing
  re-reads it, so a re-check is the only thing that can retire it — and a
  re-check that derived the month while leaving the dump questioned would build
  the month from everything *except* the packet whose question had just been
  dropped.

  Distinct from `confirm_kept/2` on purpose: that one records a human saying
  "it belongs here anyway", which is what a signature stands on. Writing an
  answer here would forge one.
  """
  def clear_precondition(%Dump{status: "needs_confirmation"} = dump) do
    dump
    |> Dump.changeset(%{status: "extracted", meta: Map.delete(meta(dump), "precondition")})
    |> Repo.update!()
  end

  def clear_precondition(%Dump{} = dump), do: dump

  @doc "Answered: the packet belongs here after all. Derivable again."
  def confirm_kept(%Dump{} = dump, answer),
    do:
      dump
      |> Dump.changeset(%{status: "extracted", meta: answered(dump, answer)})
      |> Repo.update()

  @doc """
  Answered: the packet belongs to `period`. The dump is repointed and left
  derivable — nothing about the extraction is re-run, because nothing about it
  was wrong.
  """
  def confirm_moved(%Dump{} = dump, period, answer) do
    dump
    |> Dump.changeset(%{status: "extracted", period: period, meta: answered(dump, answer)})
    |> Repo.update()
  end

  @doc "Answered: the packet was a double upload. Terminal, never derived."
  def mark_discarded(%Dump{} = dump, answer),
    do:
      dump
      |> Dump.changeset(%{status: "discarded", meta: answered(dump, answer)})
      |> Repo.update()

  @doc """
  The answer a human gave to this dump's precondition question, or `nil`.

  Kept on the dump rather than thrown away with the flag: "we knew, and here is
  why we booked it anyway" is the sentence a signature has to stand on.
  """
  def precondition_answer(%Dump{} = dump), do: Map.get(meta(dump), "precondition_answer")

  @doc "The open precondition question on this dump, or `nil`."
  def precondition(%Dump{} = dump), do: Map.get(meta(dump), "precondition")

  defp meta(%Dump{meta: meta}) when is_map(meta), do: meta
  defp meta(%Dump{}), do: %{}

  defp answered(dump, answer) do
    dump |> meta() |> Map.delete("precondition") |> Map.put("precondition_answer", answer)
  end

  def mark_after_filing(%Dump{} = dump),
    do: dump |> Dump.changeset(%{status: "after_filing"}) |> Repo.update!()

  @doc "Re-queues a held dump as received so a worker can derive it in."
  def release(%Dump{status: "held"} = dump),
    do: dump |> Dump.changeset(%{status: "received"}) |> Repo.update!()

  @doc """
  Abandons a packet whose extraction failed — the exit from an otherwise
  permanent block.

  Failed packets are otherwise permanent unresolved intake: re-uploading adds
  a *new* packet beside them and `list/3` is unfiltered. Abandoning records the
  deliberate decision to stop waiting for a packet that produced no rows.

  A failed extraction produced no rows, so abandoning it moves no figure. What
  is recorded is that a human looked at the packet and chose not to wait for it.
  """
  def abandon_failed(dump, user_id)

  def abandon_failed(%Dump{status: "failed"} = dump, user_id) do
    dump
    |> Dump.changeset(%{
      status: "discarded",
      meta: Map.put(meta(dump), "abandoned_by_id", user_id)
    })
    |> Repo.update()
  end

  def abandon_failed(%Dump{}, _user_id), do: {:error, :not_failed}

  # A later successful extraction of the same artifact kind is the operational
  # answer to an earlier failed upload; requiring a second manual dismissal
  # would leave a dead packet blocking a month after its replacement succeeded.
  defp superseded_failures(dumps) do
    indexed = Enum.with_index(dumps)

    last_extracted =
      for {dump, index} <- indexed,
          dump.status == "extracted",
          into: %{},
          do: {dump.kind, index}

    for {dump, index} <- indexed,
        dump.status == "failed",
        index < Map.get(last_extracted, dump.kind, -1),
        into: MapSet.new(),
        do: dump.id
  end

  defp extracted(org_id, client_id, period, kind) do
    org_id
    |> list(client_id, period)
    |> Enum.filter(&(&1.kind == kind and &1.status == "extracted"))
  end

  defp truncate(error) do
    error |> to_string() |> String.slice(0, 255)
  end
end
