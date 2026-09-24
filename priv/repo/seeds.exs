alias Nila.Accounts
alias Nila.Accounts.User
alias Nila.Orgs
alias Nila.Orgs.Membership
alias Nila.Orgs.Org
alias Nila.Repo

# A single development firm (the CA firm) with an owner login. Idempotent — safe
# to run repeatedly.
org_attrs = %{
  name: "Nila Dev CA",
  legal_name: "Nila Dev CA LLP",
  gstin: "33AABCP9487A1ZG",
  address_line1: "1 Marina Boulevard",
  city: "Chennai",
  state: "Tamil Nadu",
  postal_code: "600001",
  country: "India"
}

org =
  case Repo.get_by(Org, gstin: org_attrs.gstin) do
    nil ->
      Orgs.create_org!(org_attrs)

    org ->
      {:ok, org} = Orgs.update_org(org, org_attrs)
      org
  end

owner =
  Repo.get_by(User, email: "spare.me1180650@gmail.com") ||
    Accounts.register_user!(%{
      name: "Dev Owner",
      email: "spare.me1180650@gmail.com",
      password: "devpassword123"
    })

_membership =
  Repo.get_by(Membership, org_id: org.id, user_id: owner.id) ||
    elem(Orgs.add_user(org, owner.id, "owner"), 1)

if Mix.env() == :dev do
  Code.eval_file("business_seeds.exs", __DIR__)
end
