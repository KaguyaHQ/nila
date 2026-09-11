defmodule NilaWeb.Gst.SalesBillReview.SourceEditor do
  @moduledoc """
  Persists edits to extracted invoice facts.

  Source edits are durable corrections shared by every month containing the
  source invoice. The workbench owns the selected invoice and its presentation;
  this module owns correction commands and their form errors. A successful edit
  returns the corrected invoice; the caller refreshes any dependent views.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Sales.Invoice.Corrections, as: SourceCorrections

  @doc "Saves top-level invoice facts for the selected source invoice."
  def save_invoice_facts(socket, attrs) do
    case save(socket, attrs) do
      {:ok, %{invoice: corrected_invoice}} ->
        {:ok, corrected_invoice}

      {:error, {:invalid_correction, _field, :invalid_number}} ->
        {:error,
         socket
         |> assign(:invoice_facts_form, to_form(attrs, as: :invoice_facts))
         |> assign(
           :invoice_facts_error,
           "Enter a valid amount of zero or more, such as ₹23,100.50."
         )}

      {:error, _reason} ->
        {:error,
         socket
         |> assign(:invoice_facts_form, to_form(attrs, as: :invoice_facts))
         |> assign(:invoice_facts_error, "Those invoice facts could not be saved.")}
    end
  end

  @doc "Saves one edited line for the selected source invoice."
  def save_line(socket, index, attrs) do
    case save(socket, %{"line_items" => %{to_string(index) => attrs}}) do
      {:ok, %{invoice: corrected_invoice}} ->
        {:ok, corrected_invoice}

      {:error, _reason} ->
        {:error,
         socket
         |> assign(:line_edit_form, to_form(attrs, as: :line_edit))
         |> assign(:line_edit_error, "That invoice line could not be saved.")}
    end
  end

  defp save(socket, changes) do
    SourceCorrections.save(
      socket.assigns.current_scope.current_org.id,
      socket.assigns.client.id,
      socket.assigns.batch_ref,
      Invoice.source_id(socket.assigns.selected_invoice),
      changes,
      socket.assigns.current_scope.user.id
    )
  end
end
