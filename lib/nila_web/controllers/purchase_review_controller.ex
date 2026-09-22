defmodule NilaWeb.PurchaseReviewController do
  use NilaWeb, :controller
  alias Nila.Accounts.Policy
  alias NilaWeb.Gst.PurchaseReviewWorkspace, as: Workspace

  def show(conn, params), do: dispatch(conn, params, :show)
  def treatment(conn, params), do: dispatch(conn, params, :treatment)
  def document(conn, params), do: dispatch(conn, params, :document)

  defp dispatch(conn, %{"client_id" => id, "period" => period} = params, action) do
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope, action),
         {client_id, ""} when client_id > 0 and client_id <= 9_223_372_036_854_775_807 <-
           Integer.parse(id),
         true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01"),
         true <- date.year >= 2017,
         true <- is_binary(params["q"] || "") and is_binary(params["filter"] || "all"),
         {:ok, context} <- Workspace.load(scope, client_id, period, params),
         :ok <- perform(action, context, params),
         {:ok, context} <- refresh(action, context, scope, client_id, period, params) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(Workspace.project(context))
    else
      {:error, :unauthenticated} ->
        error(conn, 401, :unauthenticated, "Sign in to continue.")

      {:error, :forbidden} ->
        error(conn, 403, :forbidden, "Your role cannot change purchase decisions.")

      {:error, :not_found} ->
        error(conn, 404, :not_found, "This purchase is not available.")

      {:error, :stale} ->
        error(
          conn,
          409,
          :stale,
          "This purchase changed. Refresh and review its current amounts before saving."
        )

      {:error, :signed_off} ->
        error(
          conn,
          409,
          :signed_off,
          "This month is signed off or filed. Reopen it before changing decisions."
        )

      {:error, reason} ->
        error(conn, 422, reason, message(reason))

      _ ->
        error(conn, 400, :invalid, "Choose a valid client, month and purchase.")
    end
  end

  defp access(nil, _), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}, _), do: {:error, :forbidden}
  defp access(%{current_org: nil}, _), do: {:error, :forbidden}
  defp access(_, :show), do: :ok

  defp access(scope, _),
    do: if(Policy.can?(scope, :edit_records), do: :ok, else: {:error, :forbidden})

  defp perform(:show, _, _), do: :ok
  defp perform(_, %{signed_off?: true}, _), do: {:error, :signed_off}

  defp perform(action, context, params) do
    case Workspace.decide(context, params, action) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp refresh(:show, context, _, _, _, _), do: {:ok, context}

  defp refresh(_, _, scope, client, period, params),
    do: Workspace.load(scope, client, period, params)

  defp message(:invalid_amount), do: "Enter rupee amounts with no more than two decimal places."
  defp message(:invalid_amounts), do: message(:invalid_amount)

  defp message(:amounts_do_not_balance),
    do: "Split amounts must add up to each available tax head."

  defp message(:reason_required), do: "Choose a reason for this treatment. Other needs a note."
  defp message(:invalid_note), do: "Enter a note of no more than 1,000 characters."

  defp message(:cess_review_required),
    do:
      "CESS cannot be claimed or carried forward in Nila. Review it separately and exclude it in a split."

  defp message(:pairing_pending), do: "Resolve the possible pairing before setting ITC treatment."

  defp message(:claim_not_available),
    do: "Claim is blocked. Review the document and its checks first."

  defp message(:itc_blocked), do: "Review the credit block before claiming ITC."

  defp message(:later_treatment_exists),
    do: "A later month already has a treatment for this invoice. Change that month first."

  defp message(:later_signed_treatment),
    do: "A later signed working depends on this invoice. Reopen that month first."

  defp message(:already_allocated),
    do: "This credit is included in a signed working. Reopen it before changing treatment."

  defp message(_), do: "Choose an available purchase and a valid ITC treatment."

  defp error(conn, status, code, message),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{
        error: message,
        code: if(is_atom(code), do: Atom.to_string(code), else: "invalid")
      })
end
