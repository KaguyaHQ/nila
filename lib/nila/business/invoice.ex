defmodule Nila.Business.Invoice do
  use Nila.Schema

  schema "business_invoices" do
    belongs_to :client, Nila.Clients.Client
    belongs_to :customer, Nila.Business.Customer
    belongs_to :billing_address, Nila.Business.CustomerAddress
    belongs_to :shipping_address, Nila.Business.CustomerAddress
    belongs_to :created_by, Nila.Accounts.User
    belongs_to :issued_by, Nila.Accounts.User
    belongs_to :original_invoice, __MODULE__
    belongs_to :converted_invoice, __MODULE__
    belongs_to :revised_from, __MODULE__
    belongs_to :dump, Nila.Gst.Intake.Dump
    field :status, :string, default: "draft"
    field :document_type, :string, default: "invoice"
    field :number, :string
    field :invoice_date, :date
    field :due_date, :date
    field :valid_until, :date
    field :place_of_supply, :string
    field :lines, {:array, :map}, default: []
    field :notes, :string
    field :purchase_order_number, :string
    field :purchase_order_date, :date
    field :delivery_address, :string
    field :delivery_state_code, :string
    field :subject, :string
    field :snapshot, :map, default: %{}
    field :totals, :map, default: %{}
    field :pdf_key, :string
    field :pdf_sha256, :string
    field :issued_at, :utc_datetime_usec
    field :sent_on, :date
    field :cancelled_at, :utc_datetime_usec
    field :cancellation_reason, :string
    belongs_to :cancelled_by, Nila.Accounts.User
    timestamps()
  end

  def draft_changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :invoice_date,
      :due_date,
      :valid_until,
      :place_of_supply,
      :lines,
      :notes,
      :purchase_order_number,
      :purchase_order_date,
      :delivery_address,
      :delivery_state_code,
      :billing_address_id,
      :shipping_address_id,
      :subject
    ])
    |> validate_required([:invoice_date, :place_of_supply, :lines])
    |> validate_inclusion(
      :place_of_supply,
      Enum.map(Nila.Gst.StateCodes.all(), &Nila.Gst.StateCodes.code_for/1)
    )
    |> validate_length(:lines, min: 1, max: 100)
    |> validate_length(:notes, max: 2000)
    |> validate_length(:purchase_order_number, max: 100)
    |> validate_length(:delivery_address, max: 2000)
    |> validate_length(:subject, max: 200)
    |> validate_inclusion(
      :delivery_state_code,
      Enum.map(Nila.Gst.StateCodes.all(), &Nila.Gst.StateCodes.code_for/1)
    )
    |> validate_dates()
    |> validate_valid_until()
  end

  defp validate_valid_until(changeset) do
    case {get_field(changeset, :invoice_date), get_field(changeset, :valid_until)} do
      {%Date{} = date, %Date{} = until} ->
        if Date.compare(until, date) == :lt,
          do: add_error(changeset, :valid_until, "cannot precede the quotation date"),
          else: changeset

      _ ->
        changeset
    end
  end

  defp validate_dates(changeset) do
    case {get_field(changeset, :invoice_date), get_field(changeset, :due_date)} do
      {%Date{} = date, %Date{} = due} ->
        if Date.compare(due, date) == :lt,
          do: add_error(changeset, :due_date, "cannot precede the invoice date"),
          else: changeset

      _ ->
        changeset
    end
  end
end
