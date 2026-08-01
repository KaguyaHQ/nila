defmodule Nila.Gst.Rates.ImporterTest do
  use Nila.DataCase, async: false

  alias Nila.Gst.Rates.{Directory, Importer, Release, Rule}

  test "activation leaves one active immutable rate release and loads its rules" do
    first = insert_release!("first")
    assert {:ok, active_first} = Importer.activate(first.id)
    assert active_first.status == "active"

    second = insert_release!("second")

    Repo.insert!(%Rule{
      release_id: second.id,
      serial_number: 3,
      schedule: "IV",
      total_rate: Decimal.new("3"),
      raw_code_expression: "7106",
      raw_description: "Silver",
      parsed_scope: %{
        "includes" => ["7106"],
        "excludes" => [],
        "ranges" => [],
        "any_chapter" => false
      },
      parser_confidence: "automatic"
    })

    assert {:ok, active_second} = Importer.activate(second.id)
    assert Repo.reload!(active_first).status == "superseded"
    assert active_second.status == "active"
    assert Repo.aggregate(from(r in Release, where: r.status == "active"), :count) == 1

    assert {:ok, directory} = Directory.active()
    assert directory.release.id == second.id
    assert [%Rule{raw_code_expression: "7106"}] = directory.rules
  end

  defp insert_release!(suffix) do
    now = DateTime.utc_now()

    %Release{}
    |> Release.changeset(%{
      notification_number: "9/2025-Integrated Tax (Rate)",
      tax_type: "integrated",
      source_name: "#{suffix}.pdf",
      file_sha256: String.duplicate(suffix, 16),
      published_on: ~D[2025-09-17],
      effective_from: ~D[2025-09-22],
      observed_at: now
    })
    |> Repo.insert!()
  end
end
