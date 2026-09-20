defmodule Nila.Gst.Purchase.ItcCaseEvent do
  use Nila.Schema

  @event_types ~w(
    documents_requested
    client_holds_document
    document_not_held
    excluded_not_ours
    reopened
    treatment_decided
    case_merged
    case_merge_reversed
  )

  def event_types, do: @event_types

  schema "gst_itc_case_events" do
    field :event_type, :string
    field :payload, :map, default: %{}

    belongs_to :itc_case, Nila.Gst.Purchase.ItcCase, foreign_key: :case_id
    belongs_to :effective_client_month, Nila.Gst.Purchase.Month
    belongs_to :org, Nila.Orgs.Org
    belongs_to :decided_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :payload])
    |> validate_required([:case_id, :effective_client_month_id, :org_id, :event_type])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_treatment()
  end

  defp validate_treatment(changeset) do
    if get_field(changeset, :event_type) == "treatment_decided" do
      changeset = validate_required(changeset, [:decided_by_id])
      payload = get_field(changeset, :payload) || %{}

      result =
        if Nila.Gst.Purchase.ItcTreatment.valid?(payload["opening_heads"]),
          do: Nila.Gst.Purchase.ItcTreatment.build(payload["opening_heads"], payload),
          else: {:error, :invalid_amounts}

      case result do
        {:ok, built} ->
          if Map.take(built, ~w(claim later exclude)) ==
               Map.take(payload, ~w(claim later exclude)),
             do: changeset,
             else: add_error(changeset, :payload, "amounts must match the treatment")

        _ ->
          add_error(
            changeset,
            :payload,
            "must allocate every tax head and give structured reasons"
          )
      end
    else
      changeset
    end
  end
end
