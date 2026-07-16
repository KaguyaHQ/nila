defmodule Nila.Gst.Signoffs do
  @moduledoc """
  The maker-checker sign-off on a worked month. The operator (member) works
  the month and resolves exceptions; only an owner/admin can certify it. A
  sign-off does three things atomically: checks the `sign_off` capability,
  freezes the effective workings into a persisted snapshot, and moves the
  month to `reviewed`. Signed months render from the snapshot — never from a
  live re-derivation — so the numbers under the signature cannot drift when
  the engine improves.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Accounts.Policy
  alias Nila.Gst.{ClientMonth, Resolutions, Signoff}
  alias Nila.Repo

  @doc """
  Certifies `month`: inserts the append-only signoff row with the frozen
  snapshot and transitions the month to `reviewed`, in one transaction.

  Returns `{:error, :not_allowed}` when the scope lacks the `sign_off`
  capability, `{:error, :already_signed}` when the month is not in `worked`.
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
            |> Signoff.changeset(%{snapshot: snapshot})
            |> Repo.insert!()

          month
          |> ClientMonth.changeset(%{state: "reviewed"})
          |> Repo.update!()

          {:ok, signoff}
        end)
    end
  end

  @doc "The most recent signoff for a month, with the signer preloaded. `{:error, :not_found}` when unsigned."
  def latest_signoff(client_month_id) do
    Repo.fetch_one(
      from s in Signoff,
        where: s.client_month_id == ^client_month_id,
        order_by: [desc: s.inserted_at, desc: s.id],
        limit: 1,
        preload: [:signed_by]
    )
  end
end
