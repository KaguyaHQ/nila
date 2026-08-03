defmodule Mix.Tasks.Nila.Whatsapp.ConnectTest do
  use Nila.DataCase, async: false

  import ExUnit.CaptureIO

  alias Nila.Integrations
  alias Nila.Orgs

  setup do
    access_token = System.get_env("WHATSAPP_ACCESS_TOKEN")
    Mix.Task.reenable("nila.whatsapp.connect")

    on_exit(fn ->
      if access_token do
        System.put_env("WHATSAPP_ACCESS_TOKEN", access_token)
      else
        System.delete_env("WHATSAPP_ACCESS_TOKEN")
      end
    end)

    :ok
  end

  test "connects a WhatsApp phone-number ID without printing the token" do
    org =
      Orgs.create_org!(%{
        name: "WhatsApp Provisioning Test",
        legal_name: "WhatsApp Provisioning Test Company",
        gstin: "29ABCDE1234F1ZW"
      })

    System.put_env("WHATSAPP_ACCESS_TOKEN", "operator-secret-token")

    output =
      capture_io(fn ->
        Mix.Task.run("nila.whatsapp.connect", [
          "--org-id",
          to_string(org.id),
          "--phone-number-id",
          "123456789",
          "--label",
          "Firm WhatsApp"
        ])
      end)

    assert output =~ "Connected WhatsApp phone-number ID 123456789 to organisation #{org.id}."
    refute output =~ "operator-secret-token"

    connection = Integrations.first_active_connection(org.id, "whatsapp")
    assert connection.label == "Firm WhatsApp"
    assert connection.credentials == %{"access_token" => "operator-secret-token"}
  end

  test "requires the access token environment variable" do
    org =
      Orgs.create_org!(%{
        name: "WhatsApp Missing Token Test",
        legal_name: "WhatsApp Missing Token Test Company",
        gstin: "29ABCDE1234F1ZW"
      })

    System.delete_env("WHATSAPP_ACCESS_TOKEN")

    assert_raise Mix.Error, ~r/WHATSAPP_ACCESS_TOKEN must be set/, fn ->
      Mix.Task.run("nila.whatsapp.connect", [
        "--org-id",
        to_string(org.id),
        "--phone-number-id",
        "123456789"
      ])
    end
  end
end
