defmodule Nila.Gst.Filing.Signoffs do
  @moduledoc """
  GSTR-3B certification and retained legacy return snapshots.

  Normal sales work uses current invoice facts and resolved exceptions without
  a separate GSTR-1 approval. Legacy GSTR-1 signatures remain available for
  recorded filing history; an unfiled legacy signature does not freeze sales.

  GSTR-3B signing freezes the effective return and reserves its ITC allocations.
  A later sales change revokes an unfiled dependent signature, releases those
  allocations, and returns the purchase month to `worked` for review. Explicit
  senior reopening uses the same invalidation behavior.

  Filing records who submitted the signed return, when, and an optional ARN.
  Filed returns and their allocations remain history; subsequent sales work
  does not revoke or rewrite them.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Accounts.Policy

  alias Nila.Gst.Filing.{Gstr3b, Signoff}
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.{ItcCases, Register, Resolutions}
  alias Nila.Gst.Purchase.Month, as: PurchaseMonth
  alias Nila.Gst.Sales.Review.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Month, as: SalesMonth
  alias Nila.Gst.Sales.Workings, as: SalesWorkings

  alias Nila.Repo

  # Stamped into every snapshot from here on. Snapshots are read back years
  # later by code that has moved on, and until now nothing in the record said
  # which shape it was written in — a reader had to probe for keys and guess,
  # which is how `printed_invoices` came to fall back to live data and how a
  # pre-money register renders a confident ₹0. A version does not migrate
  # anything by itself; it lets a reader refuse to guess.
  #
  # 1 — the first stamped shape. Older snapshots carry no key at all, which is
  # itself the signal: absent means "before stamping", not "version 0".
  # 2 — GSTR-3B snapshots include longitudinal ITC case lines.
  # 3 — GSTR-1 invoice lines retain taxable-basis resolution provenance.
  @snapshot_schema_version 3

  @doc "The snapshot format this module writes."
  def snapshot_schema_version, do: @snapshot_schema_version

  @doc """
  Certifies the month's GSTR-3B side (ITC, register, cash payable): inserts
  the append-only signoff row with the frozen snapshot and transitions the
  month to `reviewed`, in one transaction.

  Returns `{:error, :not_allowed}` without the `sign_off` capability,
  `{:error, :already_signed}` when the month is not in `worked`,
  `{:error, :not_reviewed}` while any register row is unsettled,
  `{:error, :sales_not_reviewed}` while an existing sales month has open required checks, and
  `{:error, :unresolved_sales_intake}` while a supplied sales packet is still
  processing or needs a human decision.
  """
  def sign_off(%PurchaseMonth{} = month, scope) do
    if Policy.can?(scope, :sign_off) do
      Repo.transact(fn ->
        # Sales mutations take this same lock before invalidating the dependent 3B.
        sales_month = lock_sales_month(month)

        month =
          Repo.one!(
            from m in PurchaseMonth,
              where: m.id == ^month.id,
              lock: "FOR UPDATE"
          )

        cond do
          match?({:ok, _}, latest_signoff(month.id)) ->
            {:error, :already_signed}

          month.state != "worked" ->
            {:error, :already_signed}

          true ->
            workings = Resolutions.workings(month)

            with :ok <- require_documents_attested(workings),
                 :ok <- require_settled_register(workings),
                 :ok <- require_resolved_sales_intake(month),
                 :ok <- require_reviewable_sales(sales_month),
                 :ok <- require_nonnegative_outward_liability(workings.gstr3b),
                 :ok <- require_nonnegative_net_itc(workings.gstr3b) do
              snapshot = %{
                "schema_version" => @snapshot_schema_version,
                "summary" => workings.summary,
                "itc" => workings.itc,
                "gstr3b" => workings.gstr3b,
                "rows" => workings.rows,
                "case_lines" => workings.case_lines,
                "review" => %{
                  "baseline" => workings.baseline,
                  "recon" => workings.recon,
                  "decisions" => workings.decisions,
                  "accepted_reasons" => workings.accepted_reasons,
                  "gstr2b_decisions" => workings.gstr2b_decisions,
                  "document_attestation" => workings.document_attestation
                }
              }

              signoff =
                %Signoff{
                  org_id: month.org_id,
                  client_month_id: month.id,
                  signed_by_id: scope.user.id
                }
                |> Signoff.changeset(%{artifact: "gstr3b", snapshot: snapshot})
                |> Repo.insert!()

              with :ok <-
                     ItcCases.reserve_claims(signoff, month, workings.case_lines, workings.itc) do
                month
                |> PurchaseMonth.changeset(%{state: "reviewed"})
                |> Repo.update!()

                {:ok, signoff}
              end
            end
        end
      end)
    else
      {:error, :not_allowed}
    end
  end

  @doc """
  Certifies the GSTR-1: freezes the effective outward return (invoices with
  corrections applied, issues as decided, the portal-shaped derivation) and
  transitions the sales month to `reviewed`, in one transaction.

  The approval transaction re-checks the effective issues, marks the worked
  month reviewed, and freezes the approved draft under the
  checker’s identity. The signature is its own durable fact, and "approved"
  means a live signoff row exists. Returns
  `{:error, :not_allowed}` without the `sign_off` capability,
  `{:error, :not_reviewed}` before the maker gate,
  `{:error, :already_signed}` when a live signature exists, and
  `{:error, :unresolved_sales_intake}` while a supplied sales packet is still
  processing or needs a human decision, and
  `{:error, {:blocking_issues, codes}}` when the month holds a document the
  return has no table for (see `Nila.Gst.Sales.Gstr1.Readiness.blocking_issues/1`).
  """
  def sign_off_gstr1(%SalesMonth{} = month, scope) do
    if Policy.can?(scope, :sign_off) do
      # The row lock serializes signing against SalesResolutions.record (which
      # locks the same row before checking for a live signature) — a decision
      # and a signature cannot interleave. The partial unique index
      # (gst_signoffs_live_gstr1_index) backstops concurrent double-signs.
      Repo.transact(fn ->
        month = Repo.one!(from m in SalesMonth, where: m.id == ^month.id, lock: "FOR UPDATE")

        cond do
          match?({:ok, _}, latest_gstr1_signoff(month.id)) ->
            {:error, :already_signed}

          true ->
            workings = SalesResolutions.workings(month)
            blocking = Enum.filter(workings.issues, &SalesWorkings.blocking?/1)

            if blocking == [] do
              with true <- SalesWorkings.reviewable?(workings.issues),
                   :ok <- require_resolved_sales_intake(month) do
                approve_gstr1(month, scope, workings)
              else
                false -> {:error, :not_reviewed}
                {:error, _reason} = error -> error
              end
            else
              {:error, {:blocking_issues, blocking |> Enum.map(& &1["code"]) |> Enum.uniq()}}
            end
        end
      end)
    else
      {:error, :not_allowed}
    end
  end

  # `need_decision`, not `open`: the gate must block on work whose answer
  # changes the return, and nothing else. A bill the client never sent and an
  # amount the vendor reported differently are both open money the register
  # keeps reporting, but neither is a fork in the filing — gating on them would
  # make the month unsignable by any route through the product, and blocking a
  # signature on work that changes nothing teaches people to click through.
  defp require_settled_register(workings) do
    if Register.need_decision(workings.summary) == 0, do: :ok, else: {:error, :not_reviewed}
  end

  defp require_nonnegative_outward_liability(gstr3b) do
    if Gstr3b.negative_outward_liability?(gstr3b),
      do: {:error, :negative_outward_liability_unsupported},
      else: :ok
  end

  defp require_nonnegative_net_itc(gstr3b) do
    if Gstr3b.negative_net_itc?(gstr3b),
      do: {:error, :negative_net_itc_unsupported},
      else: :ok
  end

  # s.16(2)(a) is a condition of the claim, so an unanswered question about it
  # withholds the signature. "Unknown" is a legitimate answer to give and a
  # legitimate reason to stop: it routes to a client chase rather than forcing
  # someone to assert "no" to proceed.
  defp require_documents_attested(workings) do
    if ItcCases.documents_settled?(workings.case_lines),
      do: :ok,
      else: {:error, :documents_unattested}
  end

  defp require_reviewable_sales(%SalesMonth{filed_at: nil} = sales_month) do
    if SalesWorkings.reviewable?(SalesResolutions.workings(sales_month).issues),
      do: :ok,
      else: {:error, :sales_not_reviewed}
  end

  defp require_reviewable_sales(_absent_or_filed), do: :ok

  defp lock_sales_month(month) do
    Repo.one(
      from m in SalesMonth,
        where:
          m.org_id == ^month.org_id and m.client_id == ^month.client_id and
            m.period == ^month.period,
        lock: "FOR UPDATE"
    )
  end

  defp require_resolved_sales_intake(month) do
    if Dumps.unresolved?(month.org_id, month.client_id, month.period, "sales"),
      do: {:error, :unresolved_sales_intake},
      else: :ok
  end

  defp approve_gstr1(month, scope, workings) do
    draft = %{
      "invoices" => workings.invoices,
      "printed_invoices" => workings.printed_active_invoices,
      "issues" => workings.issues,
      "derived" => workings.derived
    }

    # `draft_version` hashes the draft's content, so the format stamp goes on
    # after it — otherwise adding a stamp would change every draft's identity.
    snapshot =
      draft
      |> Map.put("draft_version", draft_version(draft))
      |> Map.put("schema_version", @snapshot_schema_version)

    month
    |> SalesMonth.changeset(%{state: "reviewed"})
    |> Repo.update!()

    {:ok,
     %Signoff{org_id: month.org_id, sales_month_id: month.id, signed_by_id: scope.user.id}
     |> Signoff.changeset(%{artifact: "gstr1", snapshot: snapshot})
     |> Repo.insert!()}
  end

  defp draft_version(draft) do
    draft
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Revokes a signature — the deliberate senior act that takes the wall down.
  Marks the signoff revoked (the row stays for audit) and cascades:
  reopening a GSTR-1 also revokes the dependent GSTR-3B signature for the
  same client-period, because the 3B was approved against a liability that
  is about to change. A revoked GSTR-3B demotes the purchase month back to
  `worked` (there the state flip was part of signing); the sales month's
  state stays maker-owned and is untouched.

  Returns `{:error, :not_allowed}` without the `sign_off` capability,
  `{:error, :already_revoked}` when the signature is not live.
  """
  def reopen(%Signoff{} = signoff, scope) do
    cond do
      not Policy.can?(scope, :sign_off) ->
        {:error, :not_allowed}

      signoff.revoked_at != nil ->
        {:error, :already_revoked}

      filed?(signoff) ->
        {:error, :filed}

      true ->
        Repo.transact(fn ->
          signoff = revoke!(signoff, scope.user.id)

          case signoff.artifact do
            "gstr1" ->
              cascade_to_gstr3b(signoff, scope)

            "gstr3b" ->
              ItcCases.release_allocations!(signoff)
              demote_client_month!(signoff.client_month_id)
          end

          {:ok, signoff}
        end)
    end
  end

  @doc """
  Records that a signed return was filed on the portal. `month` is the
  artifact's parent (`%SalesMonth{}` for GSTR-1, `%PurchaseMonth{}` for
  GSTR-3B). No capability gate — filing is mechanical; whoever uploaded the
  JSON marks it. Requires a live signature (`{:error, :not_signed}`),
  refuses a double mark (`{:error, :already_filed}`). `arn` is the portal's
  acknowledgment number, optional.
  """
  def mark_filed(month, scope, arn \\ nil)

  def mark_filed(%SalesMonth{} = month, scope, arn),
    do: file!(month, SalesMonth, scope, arn)

  def mark_filed(%PurchaseMonth{} = month, scope, arn),
    do: file!(month, PurchaseMonth, scope, arn)

  defp file!(month, schema, scope, arn) do
    Repo.transact(fn ->
      lock_sales_month(month)
      month = Repo.one!(from m in schema, where: m.id == ^month.id, lock: "FOR UPDATE")

      signature =
        case schema do
          SalesMonth -> latest_gstr1_signoff(month.id)
          PurchaseMonth -> latest_signoff(month.id)
        end

      cond do
        month.filed_at ->
          {:error, :already_filed}

        not match?({:ok, _}, signature) ->
          {:error, :not_signed}

        true ->
          filed =
            month
            |> schema.changeset(%{state: "filed", filing_arn: arn})
            |> Ecto.Changeset.put_change(:filed_at, DateTime.utc_now())
            |> Ecto.Changeset.put_change(:filed_by_id, scope.user.id)
            |> Repo.update!()

          settle_itc_allocations(filed)
          transition_held_dumps(filed)
          {:ok, filed}
      end
    end)
  end

  defp settle_itc_allocations(%PurchaseMonth{} = month) do
    {:ok, signoff} = latest_signoff(month.id)
    ItcCases.file_allocations!(signoff)
  end

  defp settle_itc_allocations(%SalesMonth{}), do: :ok

  defp transition_held_dumps(%SalesMonth{} = month),
    do: transition_held_dumps(month, ["sales"])

  defp transition_held_dumps(%PurchaseMonth{} = month),
    do: transition_held_dumps(month, ["purchase", "gstr2b"])

  defp transition_held_dumps(month, kinds) do
    month.org_id
    |> Dumps.list(month.client_id, month.period)
    |> Enum.filter(&(&1.status == "held" and &1.kind in kinds))
    |> Enum.each(&Dumps.mark_after_filing/1)
  end

  # Whether the signed artifact has been filed — filed returns are immutable.
  defp filed?(%Signoff{artifact: "gstr1", sales_month_id: id}),
    do: Repo.get!(SalesMonth, id).filed_at != nil

  defp filed?(%Signoff{artifact: "gstr3b", client_month_id: id}),
    do: Repo.get!(PurchaseMonth, id).filed_at != nil

  @doc "The live (unrevoked) GSTR-3B signoff for a client month, signer preloaded."
  def latest_signoff(client_month_id) do
    Repo.fetch_one(
      from s in Signoff,
        where:
          s.client_month_id == ^client_month_id and s.artifact == "gstr3b" and
            is_nil(s.revoked_at),
        order_by: [desc: s.inserted_at, desc: s.id],
        limit: 1,
        preload: [:signed_by]
    )
  end

  @doc "The live (unrevoked) GSTR-1 signoff for a sales month, signer preloaded."
  def latest_gstr1_signoff(sales_month_id) do
    Repo.fetch_one(
      from s in Signoff,
        where:
          s.sales_month_id == ^sales_month_id and s.artifact == "gstr1" and
            is_nil(s.revoked_at),
        order_by: [desc: s.inserted_at, desc: s.id],
        limit: 1,
        preload: [:signed_by]
    )
  end

  defp revoke!(%Signoff{} = signoff, revoked_by_id) do
    signoff
    |> Ecto.Changeset.change(
      revoked_at: DateTime.utc_now(),
      revoked_by_id: revoked_by_id
    )
    |> Repo.update!()
  end

  defp demote_client_month!(client_month_id) do
    Repo.get!(PurchaseMonth, client_month_id)
    |> PurchaseMonth.changeset(%{state: "worked"})
    |> Repo.update!()
  end

  @doc """
  Invalidates an unfiled GSTR-3B after its sales inputs change.
  Call inside the sales mutation transaction, before taking any purchase lock.
  Filed returns and their allocations remain recorded history.
  """
  def invalidate_gstr3b_in_transaction(%SalesMonth{} = sales_month, changed_by_id \\ nil) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "sales invalidation requires a transaction")

    lock_sales_month(sales_month)

    client_month =
      Repo.one(
        from m in PurchaseMonth,
          where:
            m.org_id == ^sales_month.org_id and m.client_id == ^sales_month.client_id and
              m.period == ^sales_month.period,
          lock: "FOR UPDATE"
      )

    with %PurchaseMonth{filed_at: nil} <- client_month,
         {:ok, signoff} <- latest_signoff(client_month.id) do
      revoke!(signoff, changed_by_id)
      ItcCases.release_allocations!(signoff)
      demote_client_month!(client_month.id)
    end

    :ok
  end

  defp cascade_to_gstr3b(%Signoff{sales_month_id: sales_month_id}, scope) do
    sales_month = Repo.get!(SalesMonth, sales_month_id)
    invalidate_gstr3b_in_transaction(sales_month, scope.user.id)
  end
end
