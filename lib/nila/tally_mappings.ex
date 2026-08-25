defmodule Nila.TallyMappings do
  @moduledoc "Company-scoped resolution of invoice evidence to existing Tally ledgers."

  import Ecto.Query

  alias Nila.Repo
  alias Nila.TallyDevices.{Company, SyncedMaster}
  alias Nila.TallyMappings.{PartyMapping, PostingProfile}

  def list_ledger_choices(org_id, company_id)
      when is_integer(org_id) and is_integer(company_id) do
    Repo.all(
      from master in ledger_query(org_id, company_id),
        order_by: [asc: master.name, asc: master.identity]
    )
  end

  def list_ledger_choices(_org_id, _company_id), do: []

  def resolve_party(org_id, company_id, identity)
      when is_integer(org_id) and is_integer(company_id) and is_map(identity) do
    with {:ok, normalized} <- normalize_identity(identity),
         {:ok, _company} <- company(org_id, company_id) do
      ledgers = list_ledger_choices(org_id, company_id)

      case saved_ledger(org_id, company_id, normalized.source_key, ledgers) do
        %SyncedMaster{} = ledger ->
          {:ok, %{ledger: ledger, matched_by: :saved}}

        nil ->
          resolve_gstin_or_name(normalized, ledgers)
      end
    end
  end

  def resolve_party(_org_id, _company_id, _identity), do: {:error, :invalid_identity}

  def save_confirmed_party_choice(org_id, company_id, identity, ledger_identity)
      when is_integer(org_id) and is_integer(company_id) and is_map(identity) and
             is_binary(ledger_identity) do
    Repo.transact(fn ->
      with {:ok, normalized} <- normalize_identity(identity),
           {:ok, _company} <- company(org_id, company_id),
           %SyncedMaster{} = ledger <- ledger(org_id, company_id, ledger_identity) do
        put_party_mapping(org_id, company_id, normalized, ledger)
      else
        nil -> {:error, :ledger_not_found}
        error -> error
      end
    end)
  end

  def save_confirmed_party_choice(_org_id, _company_id, _identity, _ledger_identity),
    do: {:error, :invalid_identity}

  def get_posting_profile(org_id, company_id)
      when is_integer(org_id) and is_integer(company_id) do
    Repo.fetch_one(
      from profile in PostingProfile,
        where: profile.org_id == ^org_id and profile.company_id == ^company_id
    )
  end

  def get_posting_profile(_org_id, _company_id), do: {:error, :not_found}

  def save_posting_profile(org_id, company_id, attrs)
      when is_integer(org_id) and is_integer(company_id) and is_map(attrs) do
    Repo.transact(fn ->
      with {:ok, _company} <- company(org_id, company_id),
           {:ok, normalized} <- normalize_profile_attrs(attrs),
           :ok <- validate_profile_ledgers(org_id, company_id, normalized) do
        put_posting_profile(org_id, company_id, normalized)
      end
    end)
  end

  def save_posting_profile(_org_id, _company_id, _attrs), do: {:error, :invalid_profile}

  def save_sales_posting(
        org_id,
        company_id,
        identity,
        party_ledger_identity,
        profile_attrs
      )
      when is_integer(org_id) and is_integer(company_id) and is_map(identity) and
             is_binary(party_ledger_identity) and is_map(profile_attrs) do
    Repo.transact(fn ->
      with {:ok, normalized_identity} <- normalize_identity(identity),
           {:ok, _company} <- company(org_id, company_id),
           %SyncedMaster{} = party_ledger <-
             ledger(org_id, company_id, party_ledger_identity),
           {:ok, normalized_profile} <- normalize_profile_attrs(profile_attrs),
           :ok <- validate_profile_ledgers(org_id, company_id, normalized_profile),
           {:ok, mapping} <-
             put_party_mapping(org_id, company_id, normalized_identity, party_ledger),
           {:ok, profile} <- put_posting_profile(org_id, company_id, normalized_profile) do
        {:ok, %{party_mapping: mapping, posting_profile: profile}}
      else
        nil -> {:error, :ledger_not_found}
        error -> error
      end
    end)
  end

  def save_sales_posting(_org_id, _company_id, _identity, _party_ledger_identity, _profile_attrs),
    do: {:error, :invalid_posting}

  defp resolve_gstin_or_name(normalized, ledgers) do
    case unique_match(ledgers, &same_gstin?(&1, normalized.gstin)) do
      {:ok, ledger} -> {:ok, %{ledger: ledger, matched_by: :gstin}}
      :none -> resolve_name(normalized.name, ledgers)
      {:ambiguous, matches} -> {:error, {:ambiguous, matches}}
    end
  end

  defp put_party_mapping(org_id, company_id, normalized, ledger) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      source_key: normalized.source_key,
      gstin: normalized.gstin,
      normalized_name: normalized.name,
      ledger_identity: ledger.identity,
      confirmation_source: "manual",
      confirmed_at: now
    }

    case Repo.get_by(PartyMapping,
           org_id: org_id,
           company_id: company_id,
           source_key: normalized.source_key
         ) do
      nil ->
        %PartyMapping{org_id: org_id, company_id: company_id}
        |> PartyMapping.changeset(attrs)
        |> Repo.insert()

      mapping ->
        mapping |> PartyMapping.changeset(attrs) |> Repo.update()
    end
  end

  defp put_posting_profile(org_id, company_id, attrs) do
    case Repo.get_by(PostingProfile, org_id: org_id, company_id: company_id) do
      nil ->
        %PostingProfile{org_id: org_id, company_id: company_id}
        |> PostingProfile.changeset(attrs)
        |> Repo.insert()

      profile ->
        profile |> PostingProfile.changeset(attrs) |> Repo.update()
    end
  end

  defp resolve_name(nil, _ledgers), do: {:error, :not_found}

  defp resolve_name(name, ledgers) do
    case unique_match(ledgers, &(normalize_name(&1.name) == name)) do
      {:ok, ledger} -> {:ok, %{ledger: ledger, matched_by: :name}}
      :none -> {:error, :not_found}
      {:ambiguous, matches} -> {:error, {:ambiguous, matches}}
    end
  end

  defp saved_ledger(org_id, company_id, source_key, ledgers) do
    case Repo.get_by(PartyMapping, org_id: org_id, company_id: company_id, source_key: source_key) do
      %PartyMapping{ledger_identity: identity} -> Enum.find(ledgers, &(&1.identity == identity))
      nil -> nil
    end
  end

  defp unique_match(ledgers, matcher) do
    case Enum.filter(ledgers, matcher) do
      [] -> :none
      [ledger] -> {:ok, ledger}
      matches -> {:ambiguous, matches}
    end
  end

  defp same_gstin?(_ledger, nil), do: false

  defp same_gstin?(ledger, gstin) do
    normalize_gstin(ledger.data["gstin"] || ledger.data[:gstin]) == gstin
  end

  defp company(org_id, company_id) do
    Repo.fetch_one(
      from company in Company, where: company.org_id == ^org_id and company.id == ^company_id
    )
  end

  defp ledger(org_id, company_id, identity) do
    Repo.one(from master in ledger_query(org_id, company_id), where: master.identity == ^identity)
  end

  defp ledger_query(org_id, company_id) do
    from master in SyncedMaster,
      where:
        master.org_id == ^org_id and master.company_id == ^company_id and master.kind == "ledger"
  end

  defp validate_profile_ledgers(org_id, company_id, attrs) do
    identities =
      PostingProfile.ledger_fields()
      |> Enum.map(&Map.get(attrs, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    found =
      Repo.aggregate(
        from(master in ledger_query(org_id, company_id), where: master.identity in ^identities),
        :count
      )

    if found == length(identities), do: :ok, else: {:error, :ledger_not_found}
  end

  defp normalize_profile_attrs(attrs) do
    normalized =
      PostingProfile.ledger_fields()
      |> Enum.reduce(%{}, fn field, normalized ->
        string_field = Atom.to_string(field)

        cond do
          Map.has_key?(attrs, field) ->
            Map.put(normalized, field, normalize_optional(attrs[field]))

          Map.has_key?(attrs, string_field) ->
            Map.put(normalized, field, normalize_optional(attrs[string_field]))

          true ->
            normalized
        end
      end)

    if map_size(normalized) > 0,
      do: {:ok, normalized},
      else: {:error, :invalid_profile}
  end

  defp normalize_identity(identity) do
    gstin = normalize_gstin(Map.get(identity, :gstin, Map.get(identity, "gstin")))
    name = normalize_name(Map.get(identity, :name, Map.get(identity, "name")))

    manual_key =
      identity
      |> Map.get(:source_key, Map.get(identity, "source_key"))
      |> normalize_optional()

    source_key =
      cond do
        gstin -> "gstin:#{gstin}"
        manual_key -> "source:#{manual_key}"
        name -> "name:#{name}"
        true -> nil
      end

    if source_key && byte_size(source_key) <= 400,
      do: {:ok, %{source_key: source_key, gstin: gstin, name: name}},
      else: {:error, :invalid_identity}
  end

  defp normalize_gstin(value) when is_binary(value) do
    value = value |> String.upcase() |> String.replace(~r/[^A-Z0-9]/u, "")
    if value == "", do: nil, else: value
  end

  defp normalize_gstin(_value), do: nil

  defp normalize_name(value) when is_binary(value) do
    value =
      value
      |> String.downcase()
      |> String.replace(~r/[^[:alnum:]]+/u, " ")
      |> String.split()
      |> Enum.join(" ")

    if value == "", do: nil, else: value
  end

  defp normalize_name(_value), do: nil

  defp normalize_optional(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional(_value), do: nil
end
