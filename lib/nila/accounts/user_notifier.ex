defmodule Nila.Accounts.UserNotifier do
  import Swoosh.Email

  alias Nila.Mailer

  def deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Application.fetch_env!(:nila, :mail_from))
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Emails an invited user the link to set their password and join a workspace.
  """
  def deliver_invitation(user, org, url) do
    deliver(user.email, "You've been invited to #{org.name} on Nila", """

    Hi #{user.name},

    You've been invited to the #{org.name} workspace on Nila.

    Set your password and sign in:

    #{url}

    This link expires in 14 days. If you weren't expecting this, you can ignore
    this email.
    """)
  end

  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirm your Nila account", """

    Hi #{user.name},

    Confirm your Nila account with this link:

    #{url}

    This link expires in 7 days. If you didn't create a Nila account, you can
    ignore this email.
    """)
  end

  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset your Nila password", """

    Hi #{user.name},

    Use this link to reset your Nila password:

    #{url}

    This link expires in 1 day. If you didn't request a password reset, you can
    ignore this email.
    """)
  end

  def deliver_update_email_instructions(user, email, url) do
    deliver(email, "Confirm your new Nila email", """

    Hi #{user.name},

    Use this link to confirm your new email address for Nila:

    #{url}

    This link expires in 1 day. If you didn't request this change, you can ignore
    this email.
    """)
  end
end
