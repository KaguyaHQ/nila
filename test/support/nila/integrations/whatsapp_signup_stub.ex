defmodule Nila.Integrations.WhatsAppSignupStub do
  def complete_signup("valid-code", session) do
    {:ok,
     %{
       access_token: "embedded-signup-token",
       token_type: "bearer",
       expires_at: "2027-01-01T00:00:00Z",
       two_step_pin: "581063",
       business_id: session["business_id"],
       waba_id: session["waba_id"],
       waba_name: "Test WABA",
       phone_number_id: session["phone_number_id"],
       display_phone_number: "+91 98765 43210",
       verified_name: "Test Firm",
       phone_status: "CONNECTED",
       code_verification_status: "VERIFIED",
       quality_rating: "GREEN",
       account_review_status: "APPROVED",
       business_verification_status: "verified",
       webhook_subscribed: true,
       registered: true
     }}
  end

  def complete_signup(_code, _session), do: {:error, :invalid_authorization_code}

  def verify_connection(connection) do
    {:ok,
     Map.merge(connection.settings || %{}, %{
       "phone_status" => "CONNECTED",
       "webhook_subscribed" => true,
       "readiness_checked_at" => "2026-08-03T00:00:00Z"
     })}
  end
end
