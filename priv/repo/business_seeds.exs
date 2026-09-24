# Run separately with: mix run priv/repo/business_seeds.exs
# Keep demo identities and invoices out of production and test databases.
if Mix.env() != :dev, do: raise("Business demo seeds are development-only")

alias Nila.{Accounts, Clients, Repo}
alias Nila.Accounts.Scope
alias Nila.Business.{Access, Customer, Invoice, Invoicing, Profile, Service}
alias Nila.Clients.Client
alias Nila.Orgs.{Membership, Org}

org = Repo.get_by!(Org, gstin: "33AABCP9487A1ZG")
owner = Accounts.get_user_by_email("spare.me1180650@gmail.com")
membership = Repo.get_by!(Membership, org_id: org.id, user_id: owner.id, role: "owner")
scope = %Scope{user: owner, current_org: org, membership: membership}

client =
  Repo.get_by(Client, org_id: org.id, name: "Demo Business Services") ||
    then(
      Clients.create_client(%{
        org_id: org.id,
        name: "Demo Business Services",
        type: "company",
        gstin: "33AEWPH4158J1Z3",
        address: "12 Marina Road, Chennai, Tamil Nadu 600001"
      }),
      fn {:ok, record} -> record end
    )

user =
  Accounts.get_user_by_email("business@nila.test") ||
    Accounts.register_user!(%{
      name: "Dev Business",
      email: "business@nila.test",
      password: "devpassword123"
    })

{:ok, _access} = Access.invite(scope, client.id, %{name: user.name, email: user.email})

unless Repo.get_by(Profile, client_id: client.id) do
  {:ok, _profile} =
    Invoicing.save_profile(client, %{
      legal_name: client.name,
      address: client.address,
      state_code: "33",
      domestic_services_only: true,
      e_invoice_not_applicable: true
    })
end

customer =
  Repo.get_by(Customer, client_id: client.id, name: "Demo Harbour Studio") ||
    then(
      Invoicing.create_customer(client, %{
        name: "Demo Harbour Studio",
        address: "24 Lake Road, Chennai, Tamil Nadu 600028",
        state_code: "33"
      }),
      fn {:ok, record} -> record end
    )

unless Repo.get_by(Service, client_id: client.id, description: "Consulting services") do
  {:ok, _service} =
    Invoicing.create_service(client, %{
      description: "Consulting services",
      sac: "998312",
      unit: "service",
      unit_price: "10000",
      gst_rate: "18"
    })
end

for {reference, amount, issue?} <- [
      {"DEMO-ISSUED-01", "10000", true},
      {"DEMO-DRAFT-01", "15000", false},
      {"DEMO-DRAFT-02", "5000", false}
    ] do
  invoice =
    Repo.get_by(Invoice, client_id: client.id, purchase_order_number: reference) ||
      then(
        Invoicing.save_draft(client, user.id, %{
          "customer_id" => customer.id,
          "invoice_date" => Date.to_iso8601(Date.utc_today()),
          "place_of_supply" => "33",
          "purchase_order_number" => reference,
          "notes" => "Sample invoice for local development.",
          "lines" => [
            %{
              "description" => "Consulting services",
              "sac" => "998312",
              "quantity" => "1",
              "unit" => "service",
              "unit_price" => amount,
              "gst_rate" => "18"
            }
          ]
        }),
        fn {:ok, record} -> record end
      )

  if issue? && invoice.status == "draft" do
    {:ok, _issued} = Invoicing.issue(client, invoice.id, user.id)
  end
end

IO.puts("Dev Business is ready at /users/log_in (business@nila.test).")
