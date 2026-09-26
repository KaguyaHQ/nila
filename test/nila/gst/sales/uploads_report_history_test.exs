defmodule Nila.Gst.Sales.UploadsReportHistoryTest do
  use Nila.DataCase, async: true
  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.Uploads

  test "a report packet lists each original file in its upload history" do
    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Packet client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, dump} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{
        period: "2026-08",
        kind: "sales",
        status: "extracted",
        file_keys: ["packet/b2b.csv", "packet/b2cs.csv"],
        meta: %{
          "excel_import" => true,
          "original_name" => "B2B.csv",
          "file_manifest" => [
            %{"filename" => "B2B.csv", "sha256" => "first"},
            %{"filename" => "B2CS.csv", "sha256" => "second"}
          ]
        }
      })

    assert %{batches: [batch]} = Uploads.history(org.id, client.id, "2026-08")
    assert Enum.map(batch.files, & &1.name) == ["B2B.csv", "B2CS.csv"]

    assert Enum.map(batch.files, & &1.original_url) == [
             "/gst/#{client.id}/2026-08/original/#{dump.id}/0",
             "/gst/#{client.id}/2026-08/original/#{dump.id}/1"
           ]

    assert Enum.map(batch.files, & &1.label) == ["Imported", "Imported"]
  end
end
