defmodule Nila.Accounts.ConfirmationTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Repo

  setup do
    user = user_fixture() |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()
    %{user: user}
  end

  test "deliver_user_confirmation_instructions/2 emails a verification link", %{user: user} do
    assert {:ok, _email} =
             Accounts.deliver_user_confirmation_instructions(user, fn token ->
               send(self(), {:confirmation_token, token})
               "http://localhost/users/confirm/#{token}"
             end)

    assert_received {:confirmation_token, token}
    assert_email_sent(fn email -> assert email.text_body =~ "/users/confirm/#{token}" end)
  end

  test "confirm_user/1 confirms the user and burns the token", %{user: user} do
    Accounts.deliver_user_confirmation_instructions(user, fn token ->
      send(self(), {:confirmation_token, token})
      "http://localhost/users/confirm/#{token}"
    end)

    assert_received {:confirmation_token, token}
    assert {:ok, confirmed} = Accounts.confirm_user(token)
    assert confirmed.confirmed_at
    assert {:error, :not_found} = Accounts.confirm_user(token)
  end
end
