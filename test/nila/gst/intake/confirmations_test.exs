defmodule Nila.Gst.Intake.ConfirmationsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Intake.{Confirmation, Confirmations, Dump, Dumps}
  alias Nila.Repo

  @period "2025-10"

  setup do
    %{user: owner, org: org, membership: membership} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        phone: "9876543210"
      })

    %{
      owner_scope: %Scope{user: owner, current_org: org, membership: membership},
      org: org,
      client: client
    }
  end

  test "client yes/no events are attributed, append-only, and latest wins", context do
    assert :open == status(context)

    assert {:ok, yes} =
             record_client(context, %{
               decision: "client_yes",
               channel: "whatsapp",
               source_ref: "wamid.yes",
               actor_phone: "+91 98765 43210"
             })

    assert yes.actor_phone == "919876543210"
    assert yes.actor_user_id == nil
    assert :complete == status(context)

    assert {:ok, no} =
             record_client(context, %{
               decision: "client_no",
               channel: "whatsapp",
               source_ref: "wamid.no",
               actor_phone: context.client.phone
             })

    assert no.id != yes.id
    assert :client_no == status(context)
    assert {:ok, latest} = latest(context)
    assert latest.id == no.id
    assert Repo.aggregate(Confirmation, :count) == 2
  end

  test "source references make webhook recording idempotent", context do
    attrs = %{
      decision: "client_yes",
      channel: "whatsapp",
      source_ref: "wamid.duplicate",
      actor_phone: context.client.phone
    }

    assert {:ok, first} = record_client(context, attrs)
    assert {:ok, duplicate} = record_client(context, %{attrs | decision: "client_no"})
    assert duplicate.id == first.id
    assert duplicate.decision == "client_yes"
    assert Repo.aggregate(Confirmation, :count) == 1
  end

  test "senior override is scoped, attributed, capability-gated, and requires a reason",
       context do
    assert {:error, changeset} =
             Confirmations.record_override(
               context.owner_scope,
               context.client.id,
               @period,
               %{reason: "   "}
             )

    assert "can't be blank" in errors_on(changeset).reason

    member = user_fixture()
    {:ok, membership} = Nila.Orgs.add_user(context.org, member.id, "member")
    member_scope = %Scope{user: member, current_org: context.org, membership: membership}

    assert {:error, :not_allowed} =
             Confirmations.record_override(member_scope, context.client.id, @period, %{
               reason: "Client confirmed by phone"
             })

    assert {:ok, override} =
             Confirmations.record_override(
               context.owner_scope,
               context.client.id,
               @period,
               %{reason: "  Client confirmed by phone  "}
             )

    assert override.decision == "senior_override"
    assert override.channel == "manual"
    assert override.reason == "Client confirmed by phone"
    assert override.actor_user_id == context.owner_scope.user.id
    assert :complete == status(context)
  end

  test "senior override re-fetches the client under the current org", context do
    %{org: other_org} = user_with_org_fixture()

    {:ok, other_client} =
      Clients.create_client(%{org_id: other_org.id, name: "Other Client", type: "company"})

    assert {:error, :not_found} =
             Confirmations.record_override(
               context.owner_scope,
               other_client.id,
               @period,
               %{reason: "Should not cross tenants"}
             )
  end

  test "a later active/effective sales dump is stale until the client reconfirms", context do
    assert {:ok, first} =
             record_client(context, %{
               decision: "client_yes",
               channel: "whatsapp",
               source_ref: "wamid.before"
             })

    {:ok, dump} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    assert Confirmations.stale?(first)
    assert :stale == status(context)

    Dumps.mark_extracted(dump, [])
    assert :stale == status(context)

    assert {:ok, second} =
             record_client(context, %{
               decision: "client_yes",
               channel: "whatsapp",
               source_ref: "wamid.after"
             })

    assert second.id != first.id
    refute Confirmations.stale?(second)
    assert :complete == status(context)
  end

  test "a packet still processing or questioned blocks readiness even after confirmation",
       context do
    for status <- ~w(received extracting failed held needs_confirmation) do
      {:ok, dump} =
        Dumps.record(
          %{org_id: context.org.id, client_id: context.client.id},
          %{period: @period, kind: "sales"}
        )

      dump |> Dump.changeset(%{status: status}) |> Repo.update!()

      assert {:ok, _} =
               record_client(context, %{
                 decision: "client_yes",
                 channel: "whatsapp",
                 source_ref: "wamid.#{status}"
               })

      assert :stale == status(context)
      dump |> Dump.changeset(%{status: "discarded"}) |> Repo.update!()
    end
  end

  test "abandoning a failed packet is the exit from an otherwise permanent block", context do
    {:ok, dump} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    failed = dump |> Dump.changeset(%{status: "failed"}) |> Repo.update!()

    assert {:ok, _} =
             record_client(context, %{
               decision: "client_yes",
               channel: "whatsapp",
               source_ref: "wamid.failed"
             })

    # The trap: nothing moved a dump out of `failed`, re-uploading only added a
    # second packet beside it, and the senior override could not help because
    # staleness is re-derived from the dump list rather than read off the
    # confirmation. The month was unfileable through the product forever.
    assert :stale == status(context)

    assert {:ok, abandoned} = Dumps.abandon_failed(failed, context.owner_scope.user.id)
    assert abandoned.status == "discarded"
    assert abandoned.meta["abandoned_by_id"] == context.owner_scope.user.id

    assert :complete == status(context)
  end

  test "a clean re-upload supersedes the failed packet it replaces", context do
    {:ok, first} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    first |> Dump.changeset(%{status: "failed"}) |> Repo.update!()

    # Bringing the original in again is the answer to a failed extraction. Once
    # it lands, nothing is waiting on the dead packet, so the senior should not
    # have to dismiss it as well before the month can be confirmed.
    {:ok, replacement} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    Dumps.mark_extracted(replacement, [])

    assert {:ok, _} =
             record_client(context, %{
               decision: "client_yes",
               channel: "whatsapp",
               source_ref: "wamid.after-replacement"
             })

    assert :complete == status(context)

    # A failure after the last clean extraction is not superseded by it — that
    # packet is still unaccounted for.
    {:ok, later} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    later |> Dump.changeset(%{status: "failed"}) |> Repo.update!()
    assert :stale == status(context)
  end

  test "supersession does not swallow a re-upload that lands after the confirmation", context do
    {:ok, failed} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    failed |> Dump.changeset(%{status: "failed"}) |> Repo.update!()

    assert {:ok, confirmation} =
             record_client(context, %{
               decision: "client_yes",
               channel: "whatsapp",
               source_ref: "wamid.before-replacement"
             })

    {:ok, replacement} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    Dumps.mark_extracted(replacement, [])

    # The packet that supersedes is itself new sales material the client has not
    # confirmed. Silencing the failure must not silence that.
    assert Confirmations.stale?(confirmation)
    assert :stale == status(context)
  end

  test "an extraction of another kind supersedes nothing", context do
    {:ok, failed} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    failed |> Dump.changeset(%{status: "failed"}) |> Repo.update!()

    # A purchase packet landing cleanly says nothing about the sales bills that
    # never made it through, so the sales failure still holds the month.
    {:ok, purchase} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "purchase"}
      )

    Dumps.mark_extracted(purchase, [])

    assert {:ok, _} =
             record_client(context, %{
               decision: "client_yes",
               channel: "whatsapp",
               source_ref: "wamid.cross-kind"
             })

    assert :stale == status(context)
  end

  test "only a failed packet can be abandoned", context do
    {:ok, dump} =
      Dumps.record(
        %{org_id: context.org.id, client_id: context.client.id},
        %{period: @period, kind: "sales"}
      )

    assert {:error, :not_failed} = Dumps.abandon_failed(dump, context.owner_scope.user.id)
  end

  test "WhatsApp client events reject a sender other than the client's phone", context do
    assert {:error, :sender_mismatch} =
             Confirmations.record_client(
               %{org_id: context.org.id},
               context.client.id,
               @period,
               %{
                 decision: "client_yes",
                 channel: "whatsapp",
                 source_ref: "wamid.wrong-sender",
                 actor_phone: "919999999999"
               }
             )
  end

  test "purchase and portal snapshot dumps do not stale sales completeness", context do
    assert {:ok, _} =
             record_client(context, %{
               decision: "client_yes",
               channel: "whatsapp",
               source_ref: "wamid.non-sales"
             })

    for kind <- ~w(purchase gstr2b filed_gstr1) do
      {:ok, _} =
        Dumps.record(
          %{org_id: context.org.id, client_id: context.client.id},
          %{period: @period, kind: kind}
        )
    end

    assert :complete == status(context)
  end

  defp record_client(context, attrs) do
    attrs = Map.put_new(attrs, :actor_phone, context.client.phone)

    Confirmations.record_client(
      %{org_id: context.org.id},
      context.client.id,
      @period,
      attrs
    )
  end

  defp status(context),
    do: Confirmations.status(context.org.id, context.client.id, @period)

  defp latest(context),
    do: Confirmations.latest(context.org.id, context.client.id, @period)
end
