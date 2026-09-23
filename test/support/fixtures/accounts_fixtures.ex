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
    n = System.unique_integer([:positive, :monotonic])

    attrs =
      Enum.into(attrs, %{
        name: "Test Org #{n}",
        legal_name: "Test Org Private Limited",
        gstin: unique_gstin(n)
      })

    Orgs.create_org!(attrs)
  end

  # Vary a PAN letter as well as the digits so a long test run does not wrap
  # after 10,000 generated identifiers. Then calculate a valid check digit
  # (only 36 candidates), so entities that validate their GSTIN accept it.
  defp unique_gstin(n) do
    body = n |> Integer.to_string() |> String.pad_leading(4, "0") |> String.slice(-4, 4)
    letter = <<?A + rem(div(n, 10_000), 26)>>
    prefix = "29ABCD#{letter}#{body}F1Z"

    check =
      Enum.find(String.graphemes("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"), fn c ->
        Nila.Gstin.valid?(prefix <> c)
      end)

    prefix <> check
  end

  def user_with_org_fixture(attrs \\ %{}) do
    user = user_fixture(Map.get(attrs, :user, %{}))
    org = org_fixture(Map.get(attrs, :org, %{}))
    {:ok, membership} = Orgs.add_user(org, user.id, Map.get(attrs, :role, "owner"))

    %{user: user, org: org, membership: membership}
  end
end
