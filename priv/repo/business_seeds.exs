# Optional sample business documents. The default local setup contains no invoices.
if Mix.env() != :dev, do: raise("Business examples are development-only")
%{client: client, business: user} = Nila.Development.setup()
alias Nila.{Business.Invoicing, Repo}
alias Nila.Business.{Customer, Invoice, Service}

customer =
  Repo.get_by(Customer, client_id: client.id, name: "Example Customer") ||
    elem(
      Invoicing.create_customer(client, %{
        name: "Example Customer",
        address: "Chennai, Tamil Nadu",
        state_code: "33"
      }),
      1
    )

unless Repo.get_by(Service, client_id: client.id, description: "Consulting") do
  {:ok, _} =
    Invoicing.create_service(client, %{
      description: "Consulting",
      sac: "998312",
      unit: "service",
      unit_price: "10000",
      gst_rate: "18"
    })
end

unless Repo.get_by(Invoice, client_id: client.id, purchase_order_number: "EXAMPLE-DRAFT") do
  {:ok, _} =
    Invoicing.save_draft(client, user.id, %{
      "customer_id" => customer.id,
      "invoice_date" => Date.to_iso8601(Date.utc_today()),
      "place_of_supply" => "33",
      "purchase_order_number" => "EXAMPLE-DRAFT",
      "lines" => [
        %{
          "description" => "Consulting",
          "sac" => "998312",
          "quantity" => "1",
          "unit" => "service",
          "unit_price" => "10000",
          "gst_rate" => "18"
        }
      ]
    })
end

IO.puts("Optional business examples are ready.")
