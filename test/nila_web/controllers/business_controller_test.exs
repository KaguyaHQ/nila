defmodule NilaWeb.BusinessControllerTest do
  import NilaWeb.ApiContract, only: [contract_response: 2, contract_response: 3, contract_file: 2]
  use NilaWeb.ConnCase, async: false

  alias Nila.{Accounts, Clients}
  alias Nila.Accounts.Scope
  alias Nila.Business.Access

  setup do
    %{user: ca, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Service business",
        type: "company",
        gstin: org.gstin
      })

    {:ok, invited} =
      Access.invite(Scope.for_user(ca), client.id, %{name: "Owner", email: unique_user_email()})

    {:ok, owner} = Accounts.accept_invite(invited.user, %{password: valid_user_password()})
    %{ca: ca, client: client, owner: owner}
  end

  defp business_root(client), do: "/api/business/#{client.id}"

  test "one user sees only the selected business and its invoices", %{
    ca: ca,
    owner: owner,
    client: first
  } do
    {:ok, second} =
      Clients.create_client(%{org_id: first.org_id, name: "Breeze Tech", type: "company"})

    {:ok, _} =
      Access.invite(Scope.for_user(ca), second.id, %{name: "Owner", email: owner.email})

    conn = build_conn() |> log_in_user(owner)

    workspaces = conn |> get("/api/business/workspaces") |> contract_response(200)
    assert Enum.map(workspaces["businesses"], & &1["id"]) == [second.id, first.id]
    assert workspaces["ca_workspace"] == %{"available" => false}

    first_customer =
      conn
      |> post("#{business_root(first)}/customers", %{
        customer: %{name: "Caltech buyer", address: "Chennai", state_code: "33"}
      })
      |> contract_response(200)
      |> Map.fetch!("customer")

    second_customer =
      conn
      |> post("#{business_root(second)}/customers", %{
        customer: %{name: "Breeze buyer", address: "Chennai", state_code: "33"}
      })
      |> contract_response(200)
      |> Map.fetch!("customer")

    first_bootstrap = conn |> get("#{business_root(first)}/bootstrap") |> contract_response(200)
    second_bootstrap = conn |> get("#{business_root(second)}/bootstrap") |> contract_response(200)
    assert Enum.map(first_bootstrap["customers"], & &1["id"]) == [first_customer["id"]]
    assert Enum.map(second_bootstrap["customers"], & &1["id"]) == [second_customer["id"]]

    invoice_attrs = %{
      customer_id: first_customer["id"],
      invoice_date: "2026-09-22",
      place_of_supply: "33",
      lines: [
        %{
          description: "Consulting",
          sac: "998312",
          quantity: "1",
          unit_price: "1000",
          gst_rate: "18"
        }
      ]
    }

    invoice =
      conn
      |> post("#{business_root(first)}/invoices", %{invoice: invoice_attrs})
      |> contract_response(200)
      |> Map.fetch!("invoice")

    assert conn
           |> get("#{business_root(second)}/invoices/#{invoice["id"]}")
           |> contract_response(404)

    assert conn
           |> post("#{business_root(second)}/invoices/#{invoice["id"]}/issue")
           |> contract_response(404)

    assert conn
           |> post("#{business_root(second)}/invoices", %{invoice: invoice_attrs})
           |> contract_response(404)

    assert conn
           |> get("#{business_root(first)}/invoices/#{invoice["id"]}")
           |> contract_response(200)
           |> get_in(["invoice", "id"]) == invoice["id"]
  end

  test "CA firm membership alone grants no Business access", %{ca: ca, client: client} do
    {:ok, other} =
      Clients.create_client(%{org_id: client.org_id, name: "Other client", type: "company"})

    conn = build_conn() |> log_in_user(ca)
    assert build_conn() |> get("/api/business/workspaces") |> contract_response(401)

    assert conn |> get("/api/business/workspaces") |> contract_response(200) == %{
             "businesses" => [],
             "ca_workspace" => %{"available" => true}
           }

    assert conn |> get("#{business_root(client)}/bootstrap") |> contract_response(403)

    {:ok, _} =
      Access.invite(Scope.for_user(ca), client.id, %{name: "CA", email: ca.email})

    assert conn |> get("#{business_root(client)}/bootstrap") |> contract_response(200)
    assert conn |> get("#{business_root(other)}/bootstrap") |> contract_response(403)

    assert conn |> get("/api/business/workspaces") |> contract_response(200) == %{
             "businesses" => [
               %{"id" => client.id, "name" => client.name, "gstin" => client.gstin}
             ],
             "ca_workspace" => %{"available" => true}
           }
  end

  test "business API isolates firm accounts and unauthenticated visitors", %{
    ca: ca,
    owner: owner,
    client: client
  } do
    assert build_conn()
           |> post("#{business_root(client)}/invoices/calculate", %{invoice: %{}})
           |> contract_response(401)

    assert build_conn()
           |> log_in_user(ca)
           |> post("#{business_root(client)}/invoices/calculate", %{invoice: %{}})
           |> contract_response(403)

    assert build_conn() |> get("#{business_root(client)}/bootstrap") |> contract_response(401)

    assert build_conn()
           |> log_in_user(ca)
           |> get("#{business_root(client)}/bootstrap")
           |> contract_response(403)

    assert build_conn()
           |> post("#{business_root(client)}/invoices/preview", %{invoice: %{}})
           |> contract_response(401)

    assert build_conn()
           |> log_in_user(ca)
           |> post("#{business_root(client)}/invoices/preview", %{invoice: %{}})
           |> contract_response(403)

    response =
      build_conn()
      |> log_in_user(owner)
      |> get("#{business_root(client)}/bootstrap")
      |> contract_response(200)

    assert response["business"]["name"] == "Service business"
    assert %{"name" => _, "code" => _} = hd(response["states"])
    assert response["invoices"] == []
    assert response["invoice_numbering"]["style"] == "nila"

    calculated =
      build_conn()
      |> log_in_user(owner)
      |> post("#{business_root(client)}/invoices/calculate", %{
        invoice: %{
          place_of_supply: "29",
          lines: [%{quantity: "1", unit_price: "1000", gst_rate: "18"}]
        }
      })
      |> contract_response(200)

    assert calculated["totals"]["total_paise"] == 118_000

    assert build_conn() |> log_in_user(owner) |> get("/app/clients") |> redirected_to() ==
             "/app/business/#{client.id}/invoices"
  end

  test "draft CRUD cannot access another business and PDF requests return a useful error", %{
    owner: owner,
    client: client
  } do
    conn = build_conn() |> log_in_user(owner)

    customer =
      conn
      |> post("#{business_root(client)}/customers", %{
        customer: %{name: "Customer", address: "Bengaluru", state_code: "29"}
      })
      |> contract_response(200)
      |> Map.fetch!("customer")

    attrs = %{
      customer_id: customer["id"],
      invoice_date: "2026-09-22",
      place_of_supply: "29",
      lines: [
        %{
          description: "Consulting",
          sac: "998312",
          quantity: "1",
          unit_price: "1000.00",
          gst_rate: "18"
        }
      ]
    }

    invoice =
      conn
      |> post("#{business_root(client)}/invoices", %{invoice: attrs})
      |> contract_response(200)
      |> Map.fetch!("invoice")

    assert invoice["status"] == "draft"

    assert conn
           |> put_req_header("accept", "application/pdf")
           |> get("#{business_root(client)}/invoices/#{invoice["id"]}/pdf")
           |> contract_response(422)

    assert conn |> get("#{business_root(client)}/invoices/not-an-id") |> contract_response(404)

    assert conn
           |> post("#{business_root(client)}/invoices/preview", %{invoice: %{customer_id: "bad"}})
           |> contract_response(404)

    assert conn
           |> post("#{business_root(client)}/invoices/preview", %{
             invoice: %{customer_id: customer["id"], lines: []}
           })
           |> contract_response(422)

    assert conn
           |> post("#{business_root(client)}/invoices", %{
             invoice: %{attrs | customer_id: 9_999_999}
           })
           |> contract_response(404)

    %{user: other_ca, org: other_org} = user_with_org_fixture()

    {:ok, other_client} =
      Clients.create_client(%{org_id: other_org.id, name: "Other", type: "company"})

    {:ok, invited} =
      Access.invite(Scope.for_user(other_ca), other_client.id, %{
        name: "Other owner",
        email: unique_user_email()
      })

    {:ok, other} = Accounts.accept_invite(invited.user, %{password: valid_user_password()})

    assert build_conn()
           |> log_in_user(other)
           |> get("#{business_root(client)}/invoices/#{invoice["id"]}")
           |> contract_response(403)

    assert build_conn()
           |> log_in_user(other)
           |> post("#{business_root(client)}/invoices/#{invoice["id"]}/issue")
           |> contract_response(403)
  end

  test "customer address API lists, saves and scopes addresses", %{owner: owner, client: client} do
    conn = build_conn() |> log_in_user(owner)

    customer =
      conn
      |> post("#{business_root(client)}/customers", %{
        customer: %{name: "Siemens", address: "Chennai", state_code: "33"}
      })
      |> contract_response(200)
      |> Map.fetch!("customer")

    bootstrap = conn |> get("#{business_root(client)}/bootstrap") |> contract_response(200)

    assert [%{"label" => "Primary address", "customer_id" => customer_id}] =
             bootstrap["customer_addresses"]

    assert customer_id == customer["id"]

    address =
      conn
      |> post("#{business_root(client)}/customers/#{customer_id}/addresses", %{
        address: %{
          label: "Bengaluru Office",
          address: "Bengaluru",
          state_code: "29",
          usage: "billing"
        }
      })
      |> contract_response(200)
      |> Map.fetch!("address")

    assert address["label"] == "Bengaluru Office"
    assert address["customer_id"] == customer_id

    assert conn
           |> post("#{business_root(client)}/customers/999999/addresses", %{
             address: %{label: "Wrong", address: "Delhi", state_code: "07", usage: "billing"}
           })
           |> contract_response(404)

    assert conn
           |> patch("#{business_root(client)}/customers/999999/addresses/#{address["id"]}", %{
             address: %{label: "Wrong"}
           })
           |> contract_response(404)
  end

  test "profile validation and issue failures preserve draft", %{owner: owner, client: client} do
    conn = build_conn() |> log_in_user(owner)

    assert conn
           |> patch("#{business_root(client)}/profile", %{
             profile: %{legal_name: "Business", address: "Bengaluru", state_code: "33"}
           })
           |> contract_response(422)

    customer =
      conn
      |> post("#{business_root(client)}/customers", %{
        customer: %{name: "Customer", address: "Bengaluru", state_code: "29"}
      })
      |> contract_response(200)
      |> Map.fetch!("customer")

    attrs = %{
      customer_id: customer["id"],
      invoice_date: "2026-09-22",
      place_of_supply: "29",
      lines: [
        %{
          description: "Consulting",
          sac: "998312",
          quantity: "1",
          unit_price: "1000",
          gst_rate: "18"
        }
      ]
    }

    invoice =
      conn
      |> post("#{business_root(client)}/invoices", %{invoice: attrs})
      |> contract_response(200)
      |> Map.fetch!("invoice")

    assert conn
           |> post("#{business_root(client)}/invoices/#{invoice["id"]}/issue")
           |> contract_response(422)

    saved =
      conn |> get("#{business_root(client)}/invoices/#{invoice["id"]}") |> contract_response(200)

    assert saved["invoice"]["status"] == "draft"
    assert is_nil(saved["invoice"]["number"])

    assert conn
           |> post("#{business_root(client)}/invoices/finalize", %{
             invoice: attrs,
             id: invoice["id"]
           })
           |> contract_response(422)

    assert conn
           |> get("#{business_root(client)}/invoices/#{invoice["id"]}")
           |> contract_response(200)
           |> get_in(["invoice", "status"]) == "draft"
  end

  test "quotation actions authenticate, return linked invoice and preserve PDF", %{
    owner: owner,
    ca: ca,
    client: client
  } do
    alias Nila.Business.Invoicing

    {:ok, customer} =
      Invoicing.create_customer(client, %{name: "Buyer", address: "Chennai", state_code: "33"})

    {:ok, _} =
      Invoicing.save_profile(client, %{
        legal_name: "Services",
        address: "Chennai",
        state_code: String.slice(client.gstin, 0, 2)
      })

    attrs = %{
      customer_id: customer.id,
      document_type: "quotation",
      invoice_date: "2026-09-22",
      valid_until: "2026-10-22",
      place_of_supply: "33",
      lines: [
        %{
          description: "Consulting",
          sac: "998312",
          quantity: "1",
          unit_price: "1000",
          gst_rate: "18"
        }
      ]
    }

    conn = build_conn() |> log_in_user(owner)

    quote =
      conn
      |> post("#{business_root(client)}/invoices", %{invoice: attrs})
      |> contract_response(200)
      |> Map.fetch!("invoice")

    id = quote["id"]
    assert quote["valid_until"] == "2026-10-22"
    assert quote["document_type"] == "quotation"

    assert conn
           |> post("#{business_root(client)}/invoices/#{id}/quotation-status", %{
             status: "accepted"
           })
           |> contract_response(422)

    assert build_conn()
           |> post("#{business_root(client)}/invoices/#{id}/convert")
           |> contract_response(401)

    assert build_conn()
           |> log_in_user(ca)
           |> post("#{business_root(client)}/invoices/#{id}/quotation-status", %{
             status: "accepted"
           })
           |> contract_response(403)

    assert {:ok, _} =
             Invoicing.issue(client, id, owner.id,
               render_pdf: fn _ -> {:ok, "%PDF-quotation"} end
             )

    accepted =
      conn
      |> post("#{business_root(client)}/invoices/#{id}/quotation-status", %{status: "accepted"})
      |> contract_response(200)

    assert accepted["invoice"]["status"] == "accepted"

    response =
      conn |> post("#{business_root(client)}/invoices/#{id}/convert") |> contract_response(200)

    assert response["invoice"]["status"] == "draft"
    assert response["invoice"]["document_type"] == "invoice"
    assert response["quotation"]["converted_invoice_id"] == response["invoice"]["id"]

    retry =
      conn |> post("#{business_root(client)}/invoices/#{id}/convert") |> contract_response(200)

    assert retry == response
    pdf = conn |> get("#{business_root(client)}/invoices/#{id}/pdf")
    assert contract_file(pdf, 200) == "%PDF-quotation"

    assert get_resp_header(pdf, "content-disposition") == [
             ~s(attachment; filename="quotation-#{id}.pdf")
           ]

    assert conn
           |> post("#{business_root(client)}/invoices/invalid/convert")
           |> contract_response(404)

    # Null has the same default invoice meaning as an omitted document type.
    normal =
      conn
      |> post("#{business_root(client)}/invoices", %{invoice: Map.put(attrs, :document_type, nil)})
      |> contract_response(200)

    assert normal["invoice"]["document_type"] == "invoice"
  end

  test "business owner configures quote numbering and uploads scoped branding", %{
    owner: owner,
    ca: ca,
    client: client
  } do
    alias Nila.Business.Invoicing

    assert build_conn()
           |> patch("#{business_root(client)}/quotation-numbering", %{
             numbering: %{next_quotation_number: "GR-79"}
           })
           |> contract_response(401)

    assert build_conn()
           |> log_in_user(ca)
           |> patch("#{business_root(client)}/quotation-numbering", %{
             numbering: %{next_quotation_number: "GR-79"}
           })
           |> contract_response(403)

    {:ok, _} =
      Invoicing.save_profile(client, %{
        legal_name: "Breeze Tech",
        address: "Chennai",
        state_code: String.slice(client.gstin, 0, 2)
      })

    conn = build_conn() |> log_in_user(owner)

    response =
      conn
      |> patch("#{business_root(client)}/quotation-numbering", %{
        numbering: %{next_quotation_number: "GR-79"}
      })
      |> contract_response(200)

    assert response["quotation_numbering"]["next_number"] == 79
    assert response["quotation_numbering"]["style"] == "custom"
    assert response["quotation_numbering"]["next_quotation_number"] == "GR-79"

    invoice_numbering =
      conn
      |> patch("#{business_root(client)}/invoice-numbering", %{
        numbering: %{style: "serial_fy", next_number: 129}
      })
      |> contract_response(200)

    assert invoice_numbering["invoice_numbering"]["next_number"] == 129
    assert invoice_numbering["invoice_numbering"]["style"] == "serial_fy"

    image = %Plug.Upload{
      path: Path.expand("priv/static/images/og-image.png"),
      filename: "logo.png",
      content_type: "image/png"
    }

    uploaded =
      conn
      |> post("#{business_root(client)}/profile/assets/logo", %{image: image})
      |> contract_response(200)

    assert uploaded["profile"]["has_logo"]

    assert conn |> get("#{business_root(client)}/profile/assets/logo") |> contract_file(200) ==
             File.read!(image.path)

    removed =
      conn |> delete("#{business_root(client)}/profile/assets/logo") |> contract_response(200)

    refute removed["profile"]["has_logo"]
    assert conn |> get("#{business_root(client)}/profile/assets/logo") |> contract_response(404)
  end

  test "service endpoints use business access and serialize catalogue decimals", %{
    owner: owner,
    ca: ca,
    client: client
  } do
    assert build_conn() |> get("#{business_root(client)}/services") |> contract_response(401)

    assert build_conn()
           |> log_in_user(ca)
           |> get("#{business_root(client)}/services")
           |> contract_response(403)

    conn = build_conn() |> log_in_user(owner)

    attrs = %{
      description: "Consulting",
      sac: "998312",
      unit: "hour",
      unit_price: "500.25",
      gst_rate: "18",
      client_id: -1
    }

    service =
      conn
      |> post("#{business_root(client)}/services", %{service: attrs})
      |> contract_response(200, request: false)
      |> Map.fetch!("service")

    assert service["unit_price"] == "500.25"
    assert service["unit"] == "hour"

    assert conn |> get("#{business_root(client)}/services") |> contract_response(200) == %{
             "services" => [service]
           }

    assert (conn
            |> get("#{business_root(client)}/bootstrap")
            |> contract_response(200))["services"] == [service]

    id = service["id"]

    edited =
      conn
      |> patch("#{business_root(client)}/services/#{id}", %{service: %{unit_price: "600"}})
      |> contract_response(200)

    assert Decimal.equal?(Decimal.new(edited["service"]["unit_price"]), Decimal.new(600))

    assert conn |> delete("#{business_root(client)}/services/#{id}") |> contract_response(200) ==
             %{
               "deleted" => true
             }

    assert conn
           |> patch("#{business_root(client)}/services/#{id}", %{service: attrs})
           |> contract_response(404)

    assert conn |> delete("#{business_root(client)}/services/invalid") |> contract_response(404)
  end

  test "saved services page loads directly for business users", %{owner: owner, client: client} do
    conn = build_conn() |> log_in_user(owner) |> get("/app/business/#{client.id}/services")
    assert html_response(conn, 200) =~ "root"
  end
end
