defmodule Nila.AccountsFixtures do
  alias Nila.Accounts
  alias Nila.Orgs

  @password "devpassword123"

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: @password

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      name: "Test User",
      password: @password
    })
  end

  def user_fixture(attrs \\ %{}) do
    attrs
    |> valid_user_attributes()
    |> Accounts.register_user!()
  end

  def org_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Org #{System.unique_integer([:positive])}",
        legal_name: "Test Org Private Limited",
        gstin: "29ABCDE1234F1ZW"
      })

    Orgs.create_org!(attrs)
  end

  def user_with_org_fixture(attrs \\ %{}) do
    user = user_fixture(Map.get(attrs, :user, %{}))
    org = org_fixture(Map.get(attrs, :org, %{}))
    {:ok, membership} = Orgs.add_user(org, user.id, Map.get(attrs, :role, "owner"))

    %{user: user, org: org, membership: membership}
  end
end
