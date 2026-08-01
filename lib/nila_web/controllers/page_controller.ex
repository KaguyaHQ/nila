defmodule NilaWeb.PageController do
  use NilaWeb, :controller

  alias Nila.ContactNotifier
  alias Nila.ContactRequest
  alias Nila.RateLimiter

  @callback_scale_ms :timer.hours(1)
  @callback_limit 3

  def home(conn, _params) do
    render(conn, :home, page_title: "Nila — it works while you sleep")
  end

  def privacy(conn, _params) do
    render(conn, :privacy)
  end

  def terms(conn, _params) do
    render(conn, :terms)
  end

  def data_deletion(conn, _params) do
    render(conn, :data_deletion)
  end

  def contact(conn, _params) do
    render_contact(conn, ContactRequest.changeset(%ContactRequest{}, %{}))
  end

  def request_callback(conn, %{"callback" => callback_params}) do
    if ContactRequest.spam?(callback_params) do
      callback_requested(conn)
    else
      changeset = ContactRequest.changeset(%ContactRequest{}, callback_params)

      case Ecto.Changeset.apply_action(changeset, :insert) do
        {:ok, request} ->
          deliver_callback(conn, request, changeset)

        {:error, changeset} ->
          conn |> put_status(:unprocessable_entity) |> render_contact(changeset)
      end
    end
  end

  def request_callback(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render_contact(ContactRequest.changeset(%ContactRequest{}, %{}))
  end

  defp deliver_callback(conn, request, changeset) do
    case RateLimiter.check(callback_bucket(request), @callback_scale_ms, @callback_limit) do
      :allow ->
        case ContactNotifier.deliver_callback_request(request) do
          {:ok, _email} -> callback_requested(conn)
          {:error, _reason} -> callback_delivery_failed(conn, changeset)
        end

      :deny ->
        conn
        |> put_flash(:error, "Too many callback requests. Please arrange your test on WhatsApp.")
        |> put_status(:too_many_requests)
        |> render_contact(changeset)
    end
  end

  defp callback_requested(conn) do
    conn
    |> put_flash(:info, "Thanks — we’ll call you shortly to arrange the test.")
    |> redirect(to: ~p"/contact")
  end

  defp callback_delivery_failed(conn, changeset) do
    conn
    |> put_flash(
      :error,
      "We couldn’t request the callback. Please arrange your test on WhatsApp."
    )
    |> put_status(:service_unavailable)
    |> render_contact(changeset)
  end

  defp render_contact(conn, changeset) do
    render(conn, :contact,
      form: Phoenix.Component.to_form(changeset, as: :callback),
      page_title: "Put Nila to the test"
    )
  end

  defp callback_bucket(request) do
    digits = String.replace(request.phone, ~r/\D/, "")

    normalized =
      if String.starts_with?(digits, "91") and byte_size(digits) == 12,
        do: binary_part(digits, 2, 10),
        else: digits

    digest = :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower)
    "contact_callback:" <> digest
  end
end
