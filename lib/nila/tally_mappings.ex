defmodule Nila.TallyMappings do
  @moduledoc "Company-scoped resolution of invoice evidence to existing Tally ledgers."

  import Ecto.Query

  alias Nila.Repo
  alias Nila.TallyDevices.{Company, SyncedMaster}
  alias Nila.TallyMappings.{PartyMapping, PostingProfile, SalesLineMapping}

  def list_ledger_choices(org_id, company_id)
      when is_integer(org_id) and is_integer(company_id) do
    Repo.all(
      from master in ledger_query(org_id, company_id),
        order_by: [asc: master.name, asc: master.identity]
    )
  end

  def list_ledger_choices(_org_id, _company_id), do: []

  def list_sales_ledger_choices(org_id, company_id)
      when is_integer(org_id) and is_integer(company_id) do
    org_id
    |> list_ledger_choices(company_id)
    |> Enum.filter(&sales_ledger?/1)
  end

  def list_sales_ledger_choices(_org_id, _company_id), do: []

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

  def resolve_sales_ledger(org_id, company_id, line)
      when is_integer(org_id) and is_integer(company_id) and is_map(line) do
    with {:ok, normalized} <- normalize_sales_line(line),
         {:ok, _company} <- company(org_id, company_id),
         %SalesLineMapping{} = mapping <-
           Repo.get_by(SalesLineMapping,
             org_id: org_id,
             company_id: company_id,
             source_key: normalized.source_key
           ),
         %SyncedMaster{} = ledger <- sales_ledger(org_id, company_id, mapping.ledger_identity) do
      {:ok, %{ledger: ledger, matched_by: :saved}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def resolve_sales_ledger(_org_id, _company_id, _line), do: {:error, :invalid_line}

  def save_sales_ledger_choice(org_id, company_id, line, ledger_identity)
      when is_integer(org_id) and is_integer(company_id) and is_map(line) and
             is_binary(ledger_identity) do
    Repo.transact(fn ->
      save_sales_ledger_choice_in_transaction(org_id, company_id, line, ledger_identity)
    end)
  end

  def save_sales_ledger_choice(_org_id, _company_id, _line, _ledger_identity),
    do: {:error, :invalid_line}

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
      save_sales_posting_in_transaction(
        org_id,
        company_id,
        identity,
        party_ledger_identity,
        profile_attrs
      )
    end)
  end

  def save_sales_posting(_org_id, _company_id, _identity, _party_ledger_identity, _profile_attrs),
    do: {:error, :invalid_posting}

  @doc false
  def save_sales_posting_in_transaction(
        org_id,
        company_id,
        identity,
        party_ledger_identity,
        profile_attrs
      ) do
    with {:ok, normalized_identity} <- normalize_identity(identity),
         {:ok, _company} <- company(org_id, company_id),
         %SyncedMaster{} = party_ledger <- ledger(org_id, company_id, party_ledger_identity),
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
  end

  @doc false
  def save_sales_ledger_choice_in_transaction(org_id, company_id, line, ledger_identity) do
    with {:ok, normalized} <- normalize_sales_line(line),
         {:ok, _company} <- company(org_id, company_id),
         %SyncedMaster{} = ledger <- sales_ledger(org_id, company_id, ledger_identity) do
      put_sales_line_mapping(org_id, company_id, normalized, ledger)
    else
      nil -> {:error, :sales_ledger_not_found}
      error -> error
    end
  end

  @doc false
  def save_sales_ledger_choices_in_transaction(org_id, company_id, invoice, ledger_identities)
      when is_map(invoice) and is_map(ledger_identities) do
    lines = Map.get(invoice, "line_items", [])

    with {:ok, prepared} <-
           prepare_sales_line_mappings(org_id, company_id, lines, ledger_identities) do
      Enum.reduce_while(prepared, {:ok, []}, fn {normalized, ledger}, {:ok, mappings} ->
        case put_sales_line_mapping(org_id, company_id, normalized, ledger) do
          {:ok, mapping} -> {:cont, {:ok, [mapping | mappings]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, mappings} -> {:ok, Enum.reverse(mappings)}
        error -> error
      end
    end
  end

  def save_sales_ledger_choices_in_transaction(
        _org_id,
        _company_id,
        _invoice,
        _ledger_identities
      ),
      do: {:error, :invalid_line_mappings}

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

  defp put_sales_line_mapping(org_id, company_id, normalized, ledger) do
    attrs = %{
      source_key: normalized.source_key,
      hsn_sac: normalized.hsn_sac,
      normalized_description: normalized.description,
      ledger_identity: ledger.identity,
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    case Repo.get_by(SalesLineMapping,
           org_id: org_id,
           company_id: company_id,
           source_key: normalized.source_key
         ) do
      nil ->
        %SalesLineMapping{org_id: org_id, company_id: company_id}
        |> SalesLineMapping.changeset(attrs)
        |> Repo.insert()

      mapping ->
        mapping |> SalesLineMapping.changeset(attrs) |> Repo.update()
    end
  end

  defp prepare_sales_line_mappings(org_id, company_id, lines, ledger_identities)
       when is_list(lines) do
    with {:ok, _company} <- company(org_id, company_id) do
      lines
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, prepared} ->
        identity =
          Map.get(ledger_identities, index) || Map.get(ledger_identities, to_string(index))

        with true <- is_binary(identity) and String.trim(identity) != "",
             {:ok, normalized} <- normalize_sales_line(line),
             %SyncedMaster{} = ledger <- sales_ledger(org_id, company_id, identity) do
          {:cont, {:ok, [{normalized, ledger} | prepared]}}
        else
          false -> {:halt, {:error, {:sales_ledger_required, index}}}
          nil -> {:halt, {:error, {:sales_ledger_not_found, index}}}
          {:error, reason} -> {:halt, {:error, {reason, index}}}
        end
      end)
      |> case do
        {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
        error -> error
      end
    end
  end

  defp prepare_sales_line_mappings(_org_id, _company_id, _lines, _ledger_identities),
    do: {:error, :invalid_line_mappings}

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

  defp sales_ledger(org_id, company_id, identity) do
    case ledger(org_id, company_id, identity) do
      %SyncedMaster{} = ledger -> if sales_ledger?(ledger), do: ledger
      nil -> nil
    end
  end

  defp sales_ledger?(ledger) do
    parent = ledger.data["parent"] || ledger.data[:parent]
    is_binary(parent) and String.downcase(String.trim(parent)) == "sales accounts"
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

  defp normalize_sales_line(line) do
    hsn_sac =
      line
      |> Map.get(:hsn_sac, Map.get(line, "hsn_sac"))
      |> normalize_hsn_sac()

    description =
      normalize_name(Map.get(line, :item_name, Map.get(line, "item_name"))) ||
        normalize_name(Map.get(line, :description, Map.get(line, "description")))

    if description do
      digest = :crypto.hash(:sha256, description) |> Base.url_encode64(padding: false)

      {:ok,
       %{
         source_key: "hsn:#{hsn_sac || "-"}:description:#{digest}",
         hsn_sac: hsn_sac,
         description: description
       }}
    else
      {:error, :invalid_line}
    end
  end

  defp normalize_hsn_sac(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_hsn_sac(value) when is_binary(value) do
    value = value |> String.upcase() |> String.replace(~r/[^A-Z0-9]/u, "")
    if value == "", do: nil, else: value
  end

  defp normalize_hsn_sac(_value), do: nil

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
