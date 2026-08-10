defmodule Nila.Gst.Filing.Signoffs do
  @moduledoc """
  Maker-checker certification of the month's two return artifacts. The
  operator works the month and resolves exceptions; only an owner/admin can
  certify. Each sign-off freezes the artifact's effective workings into a
  persisted snapshot — signed artifacts render from the snapshot, never from
  a live re-derivation, so the numbers under a signature cannot drift when
  the engine improves.

  Two artifacts, two signatures, matching the filing cycle: the GSTR-1 is
  signed before it files (~11th), the GSTR-3B later (~20th) once 2B lands and
  ITC is decided. The 3B snapshot records the sales liability it consumed, so
  the dependency is explicit.

  A signature is a wall: resolution verbs on a signed artifact are rejected.
  The only way past it is `reopen/2` — a deliberate, logged, senior-only act
  that revokes the signature. Reopening a GSTR-1 cascades to the dependent
  GSTR-3B signature, because a 3B approved against a liability that is about
  to change is no longer approved.

  Filing is the step after signing: `mark_filed/3` records that the signed
  return went to the portal (who, when, optional ARN). It requires a live
  signature — the funnel is maker → checker → filed — and a filed artifact
  can no longer be reopened: a return on the portal is a fact; corrections
  go through the amendment path, not by unsigning history.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Accounts.Policy

  alias Nila.Gst.Filing.{Gstr3b, Signoff}
  alias Nila.Gst.Intake.{Confirmations, Dumps}
  alias Nila.Gst.Purchase.{ItcCases, Register, Resolutions}
  alias Nila.Gst.Purchase.Month, as: PurchaseMonth
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
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
  @snapshot_schema_version 2

  @doc "The snapshot format this module writes."
  def snapshot_schema_version, do: @snapshot_schema_version

  @doc """
  Certifies the month's GSTR-3B side (ITC, register, cash payable): inserts
  the append-only signoff row with the frozen snapshot and transitions the
  month to `reviewed`, in one transaction.

  Returns `{:error, :not_allowed}` without the `sign_off` capability,
  `{:error, :already_signed}` when the month is not in `worked`,
  `{:error, :not_reviewed}` while any register row is unsettled, and
  `{:error, {:sales_intake_incomplete, status}}` until sales collection is
  confirmed and current.
  """
  def sign_off(%PurchaseMonth{} = month, scope) do
    if Policy.can?(scope, :sign_off) do
      Repo.transact(fn ->
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
                 :ok <- require_sales_intake_complete(month),
                 :ok <- require_nonnegative_outward_liability(workings.gstr3b) do
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

  The approval transaction re-checks the effective issues and completeness,
  marks the worked month reviewed, and freezes the approved draft under the
  checker’s identity. The signature is its own durable fact, and "approved"
  means a live signoff row exists. Returns
  `{:error, :not_allowed}` without the `sign_off` capability,
  `{:error, :not_reviewed}` before the maker gate,
  `{:error, :already_signed}` when a live signature exists,
  `{:error, {:sales_intake_incomplete, status}}` until sales collection is
  confirmed and current, and `{:error, {:blocking_issues, codes}}` when the month holds a document the
  return has no table for (see `Nila.Gst.Sales.Gstr1.blocking_issues/1`).
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
                   :ok <- require_sales_intake_complete(month) do
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

  # s.16(2)(a) is a condition of the claim, so an unanswered question about it
  # withholds the signature. "Unknown" is a legitimate answer to give and a
  # legitimate reason to stop: it routes to a client chase rather than forcing
  # someone to assert "no" to proceed.
  defp require_documents_attested(workings) do
    if ItcCases.documents_settled?(workings.case_lines),
      do: :ok,
      else: {:error, :documents_unattested}
  end

  defp require_sales_intake_complete(month) do
    case Confirmations.status(month.org_id, month.client_id, month.period) do
      :complete -> :ok
      status -> {:error, {:sales_intake_incomplete, status}}
    end
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
          signoff = revoke!(signoff, scope)

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

  def mark_filed(%SalesMonth{} = month, scope, arn) do
    cond do
      month.filed_at -> {:error, :already_filed}
      not match?({:ok, _}, latest_gstr1_signoff(month.id)) -> {:error, :not_signed}
      true -> file!(month, SalesMonth, scope, arn)
    end
  end

  def mark_filed(%PurchaseMonth{} = month, scope, arn) do
    cond do
      month.filed_at -> {:error, :already_filed}
      not match?({:ok, _}, latest_signoff(month.id)) -> {:error, :not_signed}
      true -> file!(month, PurchaseMonth, scope, arn)
    end
  end

  defp file!(month, schema, scope, arn) do
    Repo.transact(fn ->
      filed =
        month
        |> schema.changeset(%{state: "filed", filing_arn: arn})
        |> Ecto.Changeset.put_change(:filed_at, DateTime.utc_now())
        |> Ecto.Changeset.put_change(:filed_by_id, scope.user.id)
        |> Repo.update!()

      settle_itc_allocations(filed)
      transition_held_dumps(filed)
      {:ok, filed}
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

  defp revoke!(%Signoff{} = signoff, scope) do
    signoff
    |> Ecto.Changeset.change(
      revoked_at: DateTime.utc_now(),
      revoked_by_id: scope.user.id
    )
    |> Repo.update!()
  end

  defp demote_client_month!(client_month_id) do
    Repo.get!(PurchaseMonth, client_month_id)
    |> PurchaseMonth.changeset(%{state: "worked"})
    |> Repo.update!()
  end

  # Reopening the outward return invalidates the 3B approved against it —
  # unless that 3B is already on the portal: a filed return is a fact, and
  # the discrepancy is an amendment problem, not an unsigning problem.
  defp cascade_to_gstr3b(%Signoff{sales_month_id: sales_month_id}, scope) do
    sales_month = Repo.get!(SalesMonth, sales_month_id)

    with {:ok, client_month} <-
           PurchaseMonths.get_by_period(
             sales_month.org_id,
             sales_month.client_id,
             sales_month.period
           ),
         nil <- client_month.filed_at,
         {:ok, gstr3b_signoff} <- latest_signoff(client_month.id) do
      revoke!(gstr3b_signoff, scope)
      ItcCases.release_allocations!(gstr3b_signoff)
      demote_client_month!(client_month.id)
    end

    :ok
  end
end
