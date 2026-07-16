defmodule Nila.Gst.Signoffs do
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

  alias Nila.Gst.{
    ClientMonth,
    ClientMonths,
    Resolutions,
    SalesMonth,
    SalesResolutions,
    Signoff
  }

  alias Nila.Repo

  @doc """
  Certifies the month's GSTR-3B side (ITC, register, cash payable): inserts
  the append-only signoff row with the frozen snapshot and transitions the
  month to `reviewed`, in one transaction.

  Returns `{:error, :not_allowed}` without the `sign_off` capability,
  `{:error, :already_signed}` when the month is not in `worked`.
  """
  def sign_off(%ClientMonth{} = month, scope) do
    cond do
      not Policy.can?(scope, :sign_off) ->
        {:error, :not_allowed}

      month.state != "worked" ->
        {:error, :already_signed}

      true ->
        workings = Resolutions.workings(month)

        snapshot = %{
          "summary" => workings.summary,
          "itc" => workings.itc,
          "gstr3b" => workings.gstr3b,
          "rows" => workings.rows
        }

        Repo.transact(fn ->
          signoff =
            %Signoff{
              org_id: month.org_id,
              client_month_id: month.id,
              signed_by_id: scope.user.id
            }
            |> Signoff.changeset(%{artifact: "gstr3b", snapshot: snapshot})
            |> Repo.insert!()

          month
          |> ClientMonth.changeset(%{state: "reviewed"})
          |> Repo.update!()

          {:ok, signoff}
        end)
    end
  end

  @doc """
  Certifies the GSTR-1: freezes the effective outward return (invoices with
  corrections applied, issues as decided, the portal-shaped derivation) and
  transitions the sales month to `reviewed`, in one transaction.

  The maker gate comes first: the sales month must already be `reviewed`
  (`SalesResolutions.mark_reviewed/1`) — the checker signs what the maker
  finished. The signature is its own fact, not a state: the month's state
  stays maker-owned, and "signed" means a live signoff row exists. Returns
  `{:error, :not_allowed}` without the `sign_off` capability,
  `{:error, :not_reviewed}` before the maker gate,
  `{:error, :already_signed}` when a live signature exists.
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

          month.state != "reviewed" ->
            {:error, :not_reviewed}

          true ->
            workings = SalesResolutions.workings(month)

            snapshot = %{
              "invoices" => workings.invoices,
              "issues" => workings.issues,
              "derived" => workings.derived
            }

            {:ok,
             %Signoff{
               org_id: month.org_id,
               sales_month_id: month.id,
               signed_by_id: scope.user.id
             }
             |> Signoff.changeset(%{artifact: "gstr1", snapshot: snapshot})
             |> Repo.insert!()}
        end
      end)
    else
      {:error, :not_allowed}
    end
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
            "gstr1" -> cascade_to_gstr3b(signoff, scope)
            "gstr3b" -> demote_client_month!(signoff.client_month_id)
          end

          {:ok, signoff}
        end)
    end
  end

  @doc """
  Records that a signed return was filed on the portal. `month` is the
  artifact's parent (`%SalesMonth{}` for GSTR-1, `%ClientMonth{}` for
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

  def mark_filed(%ClientMonth{} = month, scope, arn) do
    cond do
      month.filed_at -> {:error, :already_filed}
      not match?({:ok, _}, latest_signoff(month.id)) -> {:error, :not_signed}
      true -> file!(month, ClientMonth, scope, arn)
    end
  end

  defp file!(month, schema, scope, arn) do
    {:ok,
     month
     |> schema.changeset(%{state: "filed", filing_arn: arn})
     |> Ecto.Changeset.put_change(:filed_at, DateTime.utc_now())
     |> Ecto.Changeset.put_change(:filed_by_id, scope.user.id)
     |> Repo.update!()}
  end

  # Whether the signed artifact has been filed — filed returns are immutable.
  defp filed?(%Signoff{artifact: "gstr1", sales_month_id: id}),
    do: Repo.get!(SalesMonth, id).filed_at != nil

  defp filed?(%Signoff{artifact: "gstr3b", client_month_id: id}),
    do: Repo.get!(ClientMonth, id).filed_at != nil

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
    Repo.get!(ClientMonth, client_month_id)
    |> ClientMonth.changeset(%{state: "worked"})
    |> Repo.update!()
  end

  # Reopening the outward return invalidates the 3B approved against it —
  # unless that 3B is already on the portal: a filed return is a fact, and
  # the discrepancy is an amendment problem, not an unsigning problem.
  defp cascade_to_gstr3b(%Signoff{sales_month_id: sales_month_id}, scope) do
    sales_month = Repo.get!(SalesMonth, sales_month_id)

    with {:ok, client_month} <-
           ClientMonths.get_by_period(
             sales_month.org_id,
             sales_month.client_id,
             sales_month.period
           ),
         nil <- client_month.filed_at,
         {:ok, gstr3b_signoff} <- latest_signoff(client_month.id) do
      revoke!(gstr3b_signoff, scope)
      demote_client_month!(client_month.id)
    end

    :ok
  end
end
