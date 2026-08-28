defmodule Nila.Gst.Sales.Batch do
  @moduledoc "One persisted sales-bill review and Tally-posting work unit."

  use Nila.Schema

  import Ecto.Query

  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Repo
  alias Nila.TallyDevices.Company

  schema "gst_sales_batches" do
    field :import_ref, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :tally_company, Company

    has_many :dumps, Dump, foreign_key: :sales_batch_id
    has_many :tally_jobs, Nila.TallyJobs.Job, foreign_key: :sales_batch_id

    timestamps()
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [:import_ref])
    |> validate_required([:org_id, :client_id, :import_ref])
    |> validate_length(:import_ref, max: 200)
    |> unique_constraint([:org_id, :client_id, :import_ref], error_key: :import_ref)
  end

  def create(org_id, client_id, import_ref)
      when is_integer(org_id) and is_integer(client_id) and is_binary(import_ref) do
    %__MODULE__{org_id: org_id, client_id: client_id}
    |> changeset(%{import_ref: import_ref})
    |> Repo.insert()
  end

  def fetch(org_id, client_id, batch_ref) do
    with {:ok, dump_ids} <- decode_ref(batch_ref),
         {:ok, dumps} <- Dumps.fetch_batch(org_id, client_id, dump_ids) do
      {:ok, dumps}
    end
  end

  def fetch_with_record(org_id, client_id, batch_ref) do
    with {:ok, dumps} <- fetch(org_id, client_id, batch_ref),
         {:ok, batch} <- record_for_dumps(org_id, client_id, dumps) do
      {:ok, batch, dumps}
    end
  end

  def ref(dumps) when is_list(dumps), do: Enum.map_join(dumps, "-", & &1.id)

  def source_prefix(%__MODULE__{id: id}) when is_integer(id),
    do: "sales-batch:#{id}:voucher:"

  def pin_destination(org_id, batch_id, company_id)
      when is_integer(org_id) and is_integer(batch_id) and is_integer(company_id) do
    Repo.transact(fn ->
      pin_destination_in_transaction(org_id, batch_id, company_id)
    end)
  end

  @doc false
  def pin_destination_in_transaction(org_id, batch_id, company_id) do
    with %__MODULE__{} = batch <-
           Repo.one(
             from batch in __MODULE__,
               where: batch.id == ^batch_id and batch.org_id == ^org_id,
               lock: "FOR UPDATE"
           ) || {:error, :not_found},
         %Company{} <-
           Repo.one(
             from company in Company,
               where: company.id == ^company_id and company.org_id == ^org_id
           ) || {:error, :not_found} do
      case batch.tally_company_id do
        nil ->
          batch
          |> Ecto.Changeset.change(tally_company_id: company_id)
          |> Repo.update()

        ^company_id ->
          {:ok, batch}

        _other_company_id ->
          {:error, :destination_already_pinned}
      end
    end
  end

  defp record_for_dumps(_org_id, _client_id, dumps) do
    org_id = hd(dumps).org_id
    client_id = hd(dumps).client_id

    case dumps |> Enum.map(& &1.sales_batch_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [batch_id] ->
        if Enum.all?(dumps, &(&1.sales_batch_id == batch_id)) do
          Repo.fetch_by(__MODULE__, id: batch_id, org_id: org_id, client_id: client_id)
        else
          {:error, :mixed_sales_batches}
        end

      [] ->
        {:error, :not_found}

      _mixed ->
        {:error, :mixed_sales_batches}
    end
  end

  defp decode_ref(batch_ref) when is_binary(batch_ref) do
    ids =
      batch_ref
      |> String.split("-", trim: true)
      |> Enum.map(&Integer.parse/1)

    if ids != [] and Enum.all?(ids, &match?({id, ""} when id > 0, &1)),
      do: {:ok, Enum.map(ids, &elem(&1, 0))},
      else: {:error, :not_found}
  end

  defp decode_ref(_batch_ref), do: {:error, :not_found}
end
