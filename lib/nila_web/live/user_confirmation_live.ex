defmodule NilaWeb.UserConfirmationLive do
  use NilaWeb, :live_view

  alias Nila.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Verify email")}
  end

  def handle_event("resend", _params, socket) do
    user = socket.assigns.current_scope.user

    Accounts.deliver_user_confirmation_instructions(user, fn token ->
      url(~p"/users/confirm/#{token}")
    end)

    {:noreply, put_flash(socket, :info, "Verification email sent to #{user.email}.")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="verify-email-page" class="space-y-section mx-auto max-w-xl">
        <.page_header eyebrow="Account" title="Verify your email">
          Confirm your work email before you rely on this firm for filings,
          approvals, and integrations.
        </.page_header>

        <.card class="space-y-block">
          <div class="space-y-related">
            <h2 class="text-base-content text-h4 font-semibold">
              {if @current_scope.user.confirmed_at, do: "Email verified", else: "Check your inbox"}
            </h2>
            <p class="text-body text-ink-muted">
              {if @current_scope.user.confirmed_at do
                "#{@current_scope.user.email} is verified."
              else
                "We sent a verification link to #{@current_scope.user.email}."
              end}
            </p>
          </div>

          <.form
            :if={is_nil(@current_scope.user.confirmed_at)}
            for={%{}}
            id="resend-confirmation-form"
            phx-submit="resend"
          >
            <.button>
              Resend verification email
            </.button>
          </.form>

          <.link navigate={~p"/today"} class="text-primary text-small inline-flex font-semibold">
            Back to Today
          </.link>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
