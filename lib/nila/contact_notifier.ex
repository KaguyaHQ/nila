defmodule Nila.ContactNotifier do
  import Swoosh.Email

  alias Nila.ContactRequest
  alias Nila.Mailer

  def deliver_callback_request(%ContactRequest{} = request) do
    email =
      new()
      |> to("hello@nila.tax")
      |> from(Application.fetch_env!(:nila, :mail_from))
      |> subject("New callback request from nila.tax")
      |> text_body("""
      A CA firm requested a callback from the Nila contact page.

      Name: #{request.name}
      Firm: #{request.firm}
      Phone: #{request.phone}
      """)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
