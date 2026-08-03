defmodule Nila.Integrations.ResendInboundTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.{Arrivals, InboundAddress, Messages}
  alias Nila.Integrations.ResendInboundWorker

  @period "2026-08"

  setup do
    adapter = Application.get_env(:nila, :resend_adapter)
    Application.put_env(:nila, :resend_adapter, Nila.Integrations.ResendStub)

    on_exit(fn ->
      if adapter do
        Application.put_env(:nila, :resend_adapter, adapter)
      else
        Application.delete_env(:nila, :resend_adapter)
      end
    end)

    org = org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        email: "ravi@example.com"
      })

    {:ok, address} = InboundAddress.build(org.id, client.id, @period)

    %{org: org, client: client, address: address}
  end

  test "attachments land against the client and month the address names", ctx do
    stub_attachments([
      %{
        id: "att_1",
        filename: "purchase-register.pdf",
        content_type: "application/pdf",
        download_url: "https://resend.test/att_1"
      }
    ])

    Process.put({:resend_download, "https://resend.test/att_1"}, "%PDF-1.4 register")

    assert :ok = perform_job(ResendInboundWorker, args(ctx.address))

    assert [arrival] = Arrivals.pending_for_org(ctx.org.id)
    assert arrival.client_id == ctx.client.id
    assert arrival.source == "email"
    assert arrival.filename == "purchase-register.pdf"
    assert arrival.source_ref == "resend:email_abc:att_1"
  end

  test "attribution follows the address, not the sender", ctx do
    stub_attachments([
      %{
        id: "att_1",
        filename: "bill.pdf",
        content_type: "application/pdf",
        download_url: "https://resend.test/att_1"
      }
    ])

    Process.put({:resend_download, "https://resend.test/att_1"}, "%PDF-1.4 bill")

    # The accountant forwards from a personal address that matches no client.
    args = ctx.address |> args() |> Map.put("from", "Someone Else <personal@gmail.com>")

    assert :ok = perform_job(ResendInboundWorker, args)

    assert [arrival] = Arrivals.pending_for_org(ctx.org.id)
    assert arrival.client_id == ctx.client.id
    assert arrival.sender == "personal@gmail.com"
  end

  test "the reply body is kept as evidence for the month", ctx do
    stub_attachments([])

    assert :ok = perform_job(ResendInboundWorker, args(ctx.address))

    assert [message] = Messages.list(ctx.org.id, ctx.client.id, @period)
    assert message.channel == "email"
    assert message.body == "PFA the purchase bills."
    assert message.sender == "ravi@example.com"
    assert message.period == @period
  end

  test "unsupported attachment types are skipped", ctx do
    stub_attachments([
      %{
        id: "att_1",
        filename: "notes.docx",
        content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        download_url: "https://resend.test/att_1"
      },
      %{
        id: "att_2",
        filename: "scan.jpg",
        content_type: "image/jpeg",
        download_url: "https://resend.test/att_2"
      }
    ])

    Process.put({:resend_download, "https://resend.test/att_2"}, "jpeg-bytes")

    assert :ok = perform_job(ResendInboundWorker, args(ctx.address))

    assert [arrival] = Arrivals.pending_for_org(ctx.org.id)
    assert arrival.filename == "scan.jpg"
  end

  test "mail to an address Nila never issued is dropped, not retried", ctx do
    stub_attachments([])

    args = args("stranger@inbound.nila.tax")

    assert :ok = perform_job(ResendInboundWorker, args)

    assert Arrivals.pending_for_org(ctx.org.id) == []
    assert Messages.list(ctx.org.id, ctx.client.id, @period) == []
  end

  test "a forged signature on a real client's address is refused", ctx do
    stub_attachments([])

    forged = String.replace(ctx.address, ~r/\.[^.]+@/, ".000000000000@")

    assert :ok = perform_job(ResendInboundWorker, args(forged))
    assert Arrivals.pending_for_org(ctx.org.id) == []
  end

  test "a failed download fails the job so Oban retries before the URL expires", ctx do
    stub_attachments([
      %{
        id: "att_1",
        filename: "bill.pdf",
        content_type: "application/pdf",
        download_url: "https://resend.test/att_1"
      }
    ])

    Process.put({:resend_download, "https://resend.test/att_1"}, {:error, :timeout})

    assert {:error, :timeout} = perform_job(ResendInboundWorker, args(ctx.address))
    assert Arrivals.pending_for_org(ctx.org.id) == []
  end

  test "Resend redelivering the same email does not duplicate the arrival", ctx do
    stub_attachments([
      %{
        id: "att_1",
        filename: "bill.pdf",
        content_type: "application/pdf",
        download_url: "https://resend.test/att_1"
      }
    ])

    Process.put({:resend_download, "https://resend.test/att_1"}, "%PDF-1.4 bill")

    assert :ok = perform_job(ResendInboundWorker, args(ctx.address))
    assert :ok = perform_job(ResendInboundWorker, args(ctx.address))

    assert [_only_one] = Arrivals.pending_for_org(ctx.org.id)
    assert [_one_message] = Messages.list(ctx.org.id, ctx.client.id, @period)
  end

  defp stub_attachments(attachments) do
    Process.put({:resend_attachments, "email_abc"}, attachments)
  end

  defp args(address) do
    %{
      "email_id" => "email_abc",
      "to" => [address],
      "from" => "Ravi <ravi@example.com>",
      "subject" => "Re: Documents for August 2026 GST",
      "text" => "PFA the purchase bills."
    }
  end
end
