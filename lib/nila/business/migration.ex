defmodule Nila.Business.Migration do
  @moduledoc """
  Validates and applies agent-prepared Nila Business migration packets.

  Source-specific spreadsheet interpretation stays outside Nila. This module owns the
  stable packet boundary, business validation, duplicate checks and persistence.
  """

  import Ecto.Query

  alias Nila.Accounts.User

  alias Nila.Business.{
    ClientAccess,
    Customer,
    CustomerAddress,
    Invoice,
    Invoicing,
    Profile,
    Service
  }

  alias Nila.Clients.Client
  alias Nila.Repo

  @version 1
  @states Enum.map(Nila.Gst.StateCodes.all(), &Nila.Gst.StateCodes.code_for/1)

  def preview(%Client{} = client, packet) when is_map(packet) do
    packet = string_keys(packet)
    customers = list(packet["customers"])
    services = list(packet["services"])
    quotations = list(packet["quotations"])
    unresolved = list(packet["unresolved"])

    customer_refs = refs(customers)
    service_refs = refs(services)

    address_values =
      Enum.flat_map(customers, fn customer ->
        [customer["primary_address_ref"] | Enum.map(list(customer["addresses"]), & &1["ref"])]
      end)

    address_refs = address_values |> Enum.filter(&present?/1) |> MapSet.new()

    errors =
      []
      |> require(packet["version"] == @version, "version must be #{@version}")
      |> require(is_list(packet["customers"]), "customers must be a list")
      |> require(is_list(packet["services"]), "services must be a list")
      |> require(is_list(packet["quotations"]), "quotations must be a list")
      |> require(is_list(packet["unresolved"]), "unresolved must be a list")
      |> add_errors(validate_unique_refs(customers, "customer"))
      |> add_errors(validate_unique_refs(services, "service"))
      |> add_errors(validate_unique_refs(quotations, "quotation", "source_ref"))
      |> add_errors(validate_unique_values(address_values, "address ref"))
      |> add_errors(
        validate_unique_values(
          quotations |> Enum.map(& &1["number"]) |> Enum.filter(&present?/1),
          "quotation number"
        )
      )
      |> add_errors(Enum.flat_map(customers, &validate_customer/1))
      |> add_errors(Enum.flat_map(services, &validate_service/1))
      |> add_errors(
        Enum.flat_map(quotations, fn quotation ->
          validate_quotation(
            client,
            quotation,
            customer_refs,
            address_refs,
            service_refs,
            services
          )
        end)
      )
      |> add_errors(validate_existing_quotations(client, quotations, customers, services))
      |> add_errors(validate_profile(client, quotations))

    existing_numbers =
      quotations
      |> Enum.map(& &1["number"])
      |> Enum.filter(&present?/1)
      |> then(fn numbers ->
        if numbers == [] do
          []
        else
          Repo.all(
            from i in Invoice,
              where: i.client_id == ^client.id and i.number in ^numbers,
              select: i.number,
              order_by: i.number
          )
        end
      end)

    report = %{
      ready?: errors == [] and unresolved == [],
      source: packet["source"] || %{},
      counts: %{
        customers: length(customers),
        services: length(services),
        quotations: length(quotations)
      },
      existing_numbers: existing_numbers,
      unresolved: unresolved,
      errors: Enum.reverse(errors)
    }

    {:ok, report}
  end

  def preview(%Client{}, _packet), do: {:error, :invalid_packet}

  def apply_packet(%Client{} = client, actor_id, packet, opts \\ []) do
    with {:ok, report} <- preview(client, packet),
         true <- report.ready? || {:error, {:packet_not_ready, report}},
         %User{} <- Repo.get(User, actor_id) || {:error, :actor_not_found},
         true <- actor_has_access?(client, actor_id) || {:error, :actor_not_authorized},
         {:ok, customer_refs, address_refs, customer_results} <-
           import_customers(client, list(packet["customers"])),
         {:ok, service_refs, service_results} <-
           import_services(client, list(packet["services"])),
         {:ok, quotation_results} <-
           import_quotations(
             client,
             actor_id,
             list(packet["quotations"]),
             customer_refs,
             address_refs,
             service_refs,
             opts
           ) do
      {:ok,
       %{
         customers: customer_results,
         services: service_results,
         quotations: quotation_results
       }}
    else
      false -> {:error, :packet_not_ready}
      {:error, _} = error -> error
    end
  end

  defp validate_customer(customer) do
    ref = label(customer, "customer")

    errors =
      validate_changeset(
        Customer.changeset(%Customer{}, Map.take(customer, ~w(name address gstin state_code))),
        ref
      )

    primary_ref = customer["primary_address_ref"]

    errors
    |> require(present?(primary_ref), "#{ref}: primary_address_ref is required")
    |> add_errors(
      Enum.flat_map(list(customer["addresses"]), fn address ->
        address_ref = label(address, "address")

        []
        |> require(present?(address["ref"]), "#{ref}: address ref is required")
        |> add_errors(
          validate_changeset(
            CustomerAddress.changeset(
              %CustomerAddress{},
              Map.take(
                address,
                ~w(label address state_code gstin usage is_primary_billing is_primary_shipping)
              )
            ),
            "#{ref}/#{address_ref}"
          )
        )
      end)
    )
    |> add_errors(validate_unique_refs(list(customer["addresses"]), "#{ref} address"))
  end

  defp validate_service(service) do
    validate_changeset(
      Service.changeset(
        %Service{},
        Map.take(service, ~w(description sac kind unit unit_price gst_rate))
      ),
      label(service, "service")
    )
  end

  defp validate_quotation(
         client,
         quotation,
         customer_refs,
         address_refs,
         service_refs,
         services
       ) do
    ref = label(quotation, "quotation", "source_ref")
    status = quotation["status"] || "issued"
    lines = resolve_lines(list(quotation["lines"]), services)

    errors =
      []
      |> require(present?(quotation["source_ref"]), "quotation source_ref is required")
      |> require(
        MapSet.member?(customer_refs, quotation["customer_ref"]),
        "#{ref}: unknown customer_ref"
      )
      |> require(status in ~w(draft issued), "#{ref}: status must be draft or issued")
      |> require(
        status != "issued" or present?(quotation["number"]),
        "#{ref}: issued quotation needs number"
      )
      |> require(
        status != "draft" or not present?(quotation["number"]),
        "#{ref}: draft quotation cannot have number"
      )
      |> require(
        valid_date?(quotation["invoice_date"]),
        "#{ref}: invoice_date must be YYYY-MM-DD"
      )
      |> require(
        is_nil(quotation["valid_until"]) or valid_date?(quotation["valid_until"]),
        "#{ref}: valid_until must be YYYY-MM-DD"
      )
      |> require(quotation["place_of_supply"] in @states, "#{ref}: invalid place_of_supply")
      |> require(
        is_nil(quotation["billing_address_ref"]) or
          MapSet.member?(address_refs, quotation["billing_address_ref"]),
        "#{ref}: unknown billing_address_ref"
      )
      |> require(
        is_nil(quotation["shipping_address_ref"]) or
          MapSet.member?(address_refs, quotation["shipping_address_ref"]),
        "#{ref}: unknown shipping_address_ref"
      )
      |> add_errors(validate_line_refs(ref, list(quotation["lines"]), service_refs))

    case Invoicing.calculate_lines(
           lines,
           Nila.Gst.StateCodes.from_gstin(client.gstin) == quotation["place_of_supply"]
         ) do
      {:ok, calculated} ->
        add_errors(
          errors,
          validate_expected_totals(ref, calculated, quotation["expected_totals_paise"])
        )

      {:error, reason} ->
        ["#{ref}: #{reason}" | errors]
    end
  end

  defp validate_line_refs(ref, lines, service_refs) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      service_ref = line["service_ref"]

      if is_nil(service_ref) or MapSet.member?(service_refs, service_ref),
        do: [],
        else: ["#{ref}: line #{index} has unknown service_ref"]
    end)
  end

  defp validate_expected_totals(_ref, _calculated, nil), do: []

  defp validate_expected_totals(ref, calculated, expected) when is_map(expected) do
    actual = %{
      "taxable" => Enum.sum(Enum.map(calculated, & &1["taxable_paise"])),
      "tax" =>
        Enum.sum(Enum.map(calculated, &(&1["cgst_paise"] + &1["sgst_paise"] + &1["igst_paise"]))),
      "total" =>
        Enum.sum(
          Enum.map(
            calculated,
            &(&1["taxable_paise"] + &1["cgst_paise"] + &1["sgst_paise"] + &1["igst_paise"])
          )
        )
    }

    Enum.flat_map(~w(taxable tax total), fn key ->
      if expected[key] == actual[key],
        do: [],
        else: ["#{ref}: expected #{key} #{inspect(expected[key])}, calculated #{actual[key]}"]
    end)
  end

  defp validate_expected_totals(ref, _calculated, _expected),
    do: ["#{ref}: expected_totals_paise must be an object"]

  defp validate_profile(client, quotations) do
    if Enum.any?(quotations, &((&1["status"] || "issued") == "issued")) do
      profile = Invoicing.get_profile(client)

      []
      |> require(Nila.Gstin.valid?(client.gstin), "business GSTIN is incomplete")
      |> require(Profile.changeset(profile, %{}).valid?, "business profile is incomplete")
      |> require(
        profile.state_code == Nila.Gst.StateCodes.from_gstin(client.gstin),
        "business profile state does not match its GSTIN"
      )
    else
      []
    end
  end

  defp validate_existing_quotations(client, quotations, customers, services) do
    Enum.flat_map(quotations, fn quotation ->
      existing =
        if present?(quotation["number"]),
          do: Repo.get_by(Invoice, client_id: client.id, number: quotation["number"]),
          else: nil

      case existing do
        nil ->
          []

        %Invoice{} = invoice ->
          if quotation_matches_packet?(client, invoice, quotation, customers, services),
            do: [],
            else: [
              "#{label(quotation, "quotation", "source_ref")}: existing number has different facts"
            ]
      end
    end)
  end

  defp actor_has_access?(client, actor_id) do
    Repo.exists?(
      from access in ClientAccess,
        where: access.client_id == ^client.id and access.user_id == ^actor_id
    )
  end

  defp quotation_matches_packet?(client, invoice, quotation, customers, services) do
    customer = Enum.find(customers, &(&1["ref"] == quotation["customer_ref"])) || %{}
    addresses = packet_addresses(customer)

    billing =
      addresses[quotation["billing_address_ref"] || customer["primary_address_ref"]] || %{}

    shipping = addresses[quotation["shipping_address_ref"]]
    lines = resolve_lines(list(quotation["lines"]), services)

    with true <- invoice.document_type == "quotation" and invoice.status != "draft",
         {:ok, calculated} <-
           Invoicing.calculate_lines(
             lines,
             Nila.Gst.StateCodes.from_gstin(client.gstin) == quotation["place_of_supply"]
           ) do
      snapshot = invoice.snapshot
      buyer = snapshot["customer"] || %{}

      invoice.invoice_date == parse_date(quotation["invoice_date"]) and
        invoice.valid_until == parse_optional_date(quotation["valid_until"]) and
        invoice.place_of_supply == quotation["place_of_supply"] and
        invoice.subject == quotation["subject"] and invoice.notes == quotation["notes"] and
        invoice.purchase_order_number == quotation["purchase_order_number"] and
        invoice.purchase_order_date == parse_optional_date(quotation["purchase_order_date"]) and
        buyer["name"] == customer["name"] and buyer["address"] == billing["address"] and
        normalize_blank(buyer["gstin"]) == normalize_blank(billing["gstin"]) and
        buyer["state_code"] == billing["state_code"] and
        snapshot["delivery_address"] == shipping_value(shipping, quotation, "address") and
        snapshot["delivery_state_code"] == shipping_value(shipping, quotation, "state_code") and
        snapshot["shipping_name"] == if(shipping, do: shipping["label"], else: nil) and
        normalize_blank(snapshot["shipping_gstin"]) ==
          normalize_blank(if(shipping, do: shipping["gstin"], else: nil)) and
        comparable_lines(snapshot["lines"]) == comparable_lines(calculated)
    else
      _ -> false
    end
  end

  defp packet_addresses(customer) do
    primary = %{
      "label" => "Primary address",
      "address" => customer["address"],
      "state_code" => customer["state_code"],
      "gstin" => customer["gstin"]
    }

    customer
    |> Map.get("addresses", [])
    |> list()
    |> Map.new(&{&1["ref"], &1})
    |> Map.put(customer["primary_address_ref"], primary)
  end

  defp shipping_value(nil, quotation, "address"), do: quotation["delivery_address"]
  defp shipping_value(nil, quotation, "state_code"), do: quotation["delivery_state_code"]
  defp shipping_value(shipping, _quotation, key), do: shipping[key]

  defp import_customers(client, customers) do
    Enum.reduce_while(customers, {:ok, %{}, %{}, []}, fn attrs,
                                                         {:ok, customer_refs, address_refs,
                                                          results} ->
      case import_customer(client, attrs) do
        {:ok, customer, addresses, action} ->
          customer_refs = Map.put(customer_refs, attrs["ref"], customer)
          address_refs = Map.merge(address_refs, addresses)
          result = %{ref: attrs["ref"], id: customer.id, action: action}
          {:cont, {:ok, customer_refs, address_refs, results ++ [result]}}

        {:error, reason} ->
          {:halt, {:error, {:customer, attrs["ref"], reason}}}
      end
    end)
  end

  defp import_customer(client, attrs) do
    customer_attrs = Map.take(attrs, ~w(name address gstin state_code))

    with {:ok, customer, action} <- find_or_create_customer(client, customer_attrs),
         {:ok, primary} <- primary_address(client, customer),
         {:ok, addresses} <- import_addresses(client, customer, list(attrs["addresses"])) do
      refs = Map.put(addresses, attrs["primary_address_ref"], primary)
      {:ok, customer, refs, action}
    end
  end

  defp find_or_create_customer(client, attrs) do
    customer =
      if present?(attrs["gstin"]) do
        Repo.get_by(Customer,
          client_id: client.id,
          gstin: String.upcase(String.trim(attrs["gstin"]))
        )
      else
        Repo.get_by(Customer,
          client_id: client.id,
          name: attrs["name"],
          address: attrs["address"],
          state_code: attrs["state_code"]
        )
      end

    case customer do
      nil ->
        with {:ok, created} <- Invoicing.create_customer(client, attrs),
             do: {:ok, created, :created}

      %Customer{} = existing ->
        if customer_matches?(existing, attrs),
          do: {:ok, existing, :reused},
          else: {:error, :existing_customer_differs}
    end
  end

  defp customer_matches?(customer, attrs) do
    Enum.all?(~w(name address state_code gstin), fn key ->
      normalize_blank(Map.get(customer, String.to_existing_atom(key))) ==
        normalize_blank(attrs[key])
    end)
  end

  defp primary_address(client, customer) do
    case Enum.find(Invoicing.list_customer_addresses(client), fn address ->
           address.customer_id == customer.id and address.is_primary_billing
         end) do
      %CustomerAddress{} = address -> {:ok, address}
      nil -> {:error, :primary_address_missing}
    end
  end

  defp import_addresses(client, customer, addresses) do
    Enum.reduce_while(addresses, {:ok, %{}}, fn attrs, {:ok, refs} ->
      matching_location =
        Invoicing.list_customer_addresses(client)
        |> Enum.find(fn address ->
          address.customer_id == customer.id and address.label == attrs["label"] and
            address.address == attrs["address"] and address.state_code == attrs["state_code"] and
            normalize_blank(address.gstin) == normalize_blank(attrs["gstin"])
        end)

      result =
        case matching_location do
          nil ->
            Invoicing.create_customer_address(client, customer.id, attrs)

          %CustomerAddress{} = existing ->
            if address_settings_match?(existing, attrs),
              do: {:ok, existing},
              else: {:error, :existing_address_differs}
        end

      case result do
        {:ok, address} -> {:cont, {:ok, Map.put(refs, attrs["ref"], address)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp address_settings_match?(address, attrs) do
    address.usage == (attrs["usage"] || "either") and
      address.is_primary_billing == (attrs["is_primary_billing"] || false) and
      address.is_primary_shipping == (attrs["is_primary_shipping"] || false)
  end

  defp import_services(client, services) do
    Enum.reduce_while(services, {:ok, %{}, []}, fn attrs, {:ok, refs, results} ->
      service_attrs = Map.take(attrs, ~w(description sac kind unit unit_price gst_rate))

      existing =
        Invoicing.list_services(client)
        |> Enum.find(&service_matches?(&1, service_attrs))

      result =
        if existing, do: {:ok, existing, :reused}, else: create_service(client, service_attrs)

      case result do
        {:ok, service, action} ->
          {:cont,
           {:ok, Map.put(refs, attrs["ref"], service),
            results ++ [%{ref: attrs["ref"], id: service.id, action: action}]}}

        {:error, reason} ->
          {:halt, {:error, {:service, attrs["ref"], reason}}}
      end
    end)
  end

  defp create_service(client, attrs) do
    case Invoicing.create_service(client, attrs) do
      {:ok, service} -> {:ok, service, :created}
      error -> error
    end
  end

  defp service_matches?(service, attrs) do
    Enum.all?(~w(description sac kind unit), fn key ->
      to_string(Map.get(service, String.to_existing_atom(key))) == to_string(attrs[key])
    end) and Decimal.equal?(service.unit_price, Decimal.new(attrs["unit_price"])) and
      Decimal.equal?(service.gst_rate, Decimal.new(attrs["gst_rate"]))
  end

  defp import_quotations(
         client,
         actor_id,
         quotations,
         customer_refs,
         address_refs,
         service_refs,
         opts
       ) do
    Enum.reduce_while(quotations, {:ok, []}, fn quotation, {:ok, results} ->
      case import_quotation(
             client,
             actor_id,
             quotation,
             customer_refs,
             address_refs,
             service_refs,
             opts
           ) do
        {:ok, invoice, action} ->
          {:cont,
           {:ok,
            results ++
              [
                %{
                  source_ref: quotation["source_ref"],
                  id: invoice.id,
                  number: invoice.number,
                  action: action
                }
              ]}}

        {:error, reason} ->
          {:halt, {:error, {:quotation, quotation["source_ref"], reason}}}
      end
    end)
  end

  defp import_quotation(
         client,
         actor_id,
         quotation,
         customer_refs,
         address_refs,
         service_refs,
         opts
       ) do
    customer = customer_refs[quotation["customer_ref"]]
    lines = resolve_import_lines(list(quotation["lines"]), service_refs)

    attrs =
      quotation
      |> Map.take(
        ~w(invoice_date valid_until place_of_supply notes purchase_order_number purchase_order_date delivery_address delivery_state_code subject)
      )
      |> Map.put("customer_id", customer.id)
      |> Map.put("lines", lines)
      |> put_address_id("billing_address_id", quotation["billing_address_ref"], address_refs)
      |> put_address_id("shipping_address_id", quotation["shipping_address_ref"], address_refs)

    case quotation["status"] || "issued" do
      "draft" ->
        with {:ok, invoice} <-
               Invoicing.save_draft(
                 client,
                 actor_id,
                 Map.put(attrs, "document_type", "quotation")
               ),
             do: {:ok, invoice, :created}

      "issued" ->
        import_issued_quotation(client, actor_id, attrs, quotation["number"], opts)
    end
  end

  defp import_issued_quotation(client, actor_id, attrs, number, opts) do
    case Repo.get_by(Invoice, client_id: client.id, number: number) do
      nil ->
        with {:ok, invoice} <-
               Invoicing.finalize_imported_quotation(client, actor_id, attrs, number, opts),
             do: {:ok, invoice, :created}

      %Invoice{} = invoice ->
        if quotation_matches?(client, invoice, attrs),
          do: {:ok, invoice, :reused},
          else: {:error, :existing_number_differs}
    end
  end

  defp quotation_matches?(client, invoice, attrs) do
    with true <- invoice.document_type == "quotation" and invoice.status != "draft",
         true <- invoice.customer_id == attrs["customer_id"],
         {:ok, calculated} <-
           Invoicing.calculate_lines(
             attrs["lines"],
             Nila.Gst.StateCodes.from_gstin(client.gstin) == attrs["place_of_supply"]
           ) do
      invoice.invoice_date == parse_date(attrs["invoice_date"]) and
        invoice.place_of_supply == attrs["place_of_supply"] and
        invoice.valid_until == parse_optional_date(attrs["valid_until"]) and
        invoice.billing_address_id == attrs["billing_address_id"] and
        invoice.shipping_address_id == attrs["shipping_address_id"] and
        invoice.delivery_address == attrs["delivery_address"] and
        invoice.delivery_state_code == attrs["delivery_state_code"] and
        invoice.subject == attrs["subject"] and invoice.notes == attrs["notes"] and
        invoice.purchase_order_number == attrs["purchase_order_number"] and
        invoice.purchase_order_date == parse_optional_date(attrs["purchase_order_date"]) and
        comparable_lines(invoice.snapshot["lines"]) == comparable_lines(calculated)
    else
      _ -> false
    end
  end

  defp comparable_lines(lines) do
    Enum.map(
      lines || [],
      &Map.take(
        &1,
        ~w(description kind sac unit quantity unit_price gst_rate taxable_paise cgst_paise sgst_paise igst_paise)
      )
    )
  end

  defp resolve_lines(lines, services) do
    by_ref = Map.new(services, &{&1["ref"], &1})

    Enum.map(lines, fn line ->
      service = Map.get(by_ref, line["service_ref"], %{})

      service
      |> Map.take(~w(description sac kind unit unit_price gst_rate))
      |> Map.merge(Map.drop(line, ~w(service_ref)))
    end)
  end

  defp resolve_import_lines(lines, service_refs) do
    Enum.map(lines, fn line ->
      service = service_refs[line["service_ref"]]

      defaults =
        if service do
          %{
            "description" => service.description,
            "sac" => service.sac,
            "kind" => service.kind,
            "unit" => service.unit,
            "unit_price" => Decimal.to_string(service.unit_price, :normal),
            "gst_rate" => Decimal.to_string(service.gst_rate, :normal)
          }
        else
          %{}
        end

      defaults |> Map.merge(Map.drop(line, ~w(service_ref)))
    end)
  end

  defp put_address_id(attrs, _field, nil, _address_refs), do: attrs

  defp put_address_id(attrs, field, ref, address_refs) do
    Map.put(attrs, field, address_refs[ref].id)
  end

  defp validate_changeset(changeset, label) do
    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, _} -> []
      {:error, invalid} -> Enum.map(format_errors(invalid), &"#{label}: #{&1}")
    end
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, text ->
        String.replace(text, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
  end

  defp validate_unique_refs(items, noun, key \\ "ref") do
    values = Enum.map(items, & &1[key])

    []
    |> require(Enum.all?(values, &present?/1), "every #{noun} needs #{key}")
    |> require(
      length(values) == length(Enum.uniq(values)),
      "#{noun} #{key} values must be unique"
    )
  end

  defp validate_unique_values(values, noun) do
    if length(values) == length(Enum.uniq(values)),
      do: [],
      else: ["#{noun} values must be unique"]
  end

  defp refs(items), do: items |> Enum.map(& &1["ref"]) |> Enum.filter(&present?/1) |> MapSet.new()

  defp require(errors, true, _message), do: errors
  defp require(errors, false, message), do: [message | errors]
  defp add_errors(errors, more), do: Enum.reverse(more) ++ errors

  defp list(value) when is_list(value) do
    Enum.map(value, fn
      item when is_map(item) -> string_keys(item)
      _ -> %{}
    end)
  end

  defp list(_), do: []

  defp string_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp label(item, fallback, key \\ "ref"), do: item[key] || fallback
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_date?(value), do: match?({:ok, _}, Date.from_iso8601(to_string(value)))

  defp parse_date(value) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_optional_date(nil), do: nil
  defp parse_optional_date(value), do: parse_date(value)

  defp normalize_blank(nil), do: nil
  defp normalize_blank(""), do: nil
  defp normalize_blank(value) when is_binary(value), do: String.trim(value)
  defp normalize_blank(value), do: value
end
