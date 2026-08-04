defmodule Nila.Gst.Intake.InboundAddressTest do
  # Not async: one test blanks the signing secret in `Application` env, which is
  # global. It flaked under concurrency, failing an unrelated test in this file
  # with `:inbound_not_configured`.
  use ExUnit.Case, async: false

  alias Nila.Gst.Intake.InboundAddress

  test "an issued address resolves back to the org, client, and period it names" do
    {:ok, address} = InboundAddress.build(7, 42, "2026-08")

    assert address =~ "@inbound.nila.tax"
    assert {:ok, routing} = InboundAddress.parse(address)
    assert routing == %{org_id: 7, client_id: 42, period: "2026-08"}
  end

  test "each client and month gets a distinct address" do
    {:ok, one} = InboundAddress.build(7, 42, "2026-08")
    {:ok, other_client} = InboundAddress.build(7, 43, "2026-08")
    {:ok, other_month} = InboundAddress.build(7, 42, "2026-09")

    assert one != other_client
    assert one != other_month
  end

  test "editing the client or period in an address invalidates it" do
    {:ok, address} = InboundAddress.build(7, 42, "2026-08")
    tampered = String.replace(address, "n.7.42.", "n.7.43.")

    assert tampered != address
    assert {:error, :bad_signature} = InboundAddress.parse(tampered)
  end

  test "a guessed address without a signature is refused" do
    assert {:error, :unrecognized_address} =
             InboundAddress.parse("n.7.42.202608@inbound.nila.tax")

    assert {:error, :unrecognized_address} = InboundAddress.parse("hello@inbound.nila.tax")
    assert {:error, :unrecognized_address} = InboundAddress.parse("not-an-address")
  end

  test "reads the address out of a display-name header and ignores a +tag" do
    {:ok, address} = InboundAddress.build(7, 42, "2026-08")
    [local, domain] = String.split(address, "@")

    assert {:ok, routing} = InboundAddress.parse(~s(Nila Intake <#{address}>))
    assert routing.client_id == 42

    assert {:ok, ^routing} = InboundAddress.parse("#{local}+reply@#{domain}")
    assert {:ok, ^routing} = InboundAddress.parse(String.upcase(address))
  end

  test "find/1 picks our address out of the other recipients on a reply" do
    {:ok, address} = InboundAddress.build(7, 42, "2026-08")

    assert {:ok, routing} =
             InboundAddress.find(["balaji@bvcandco.in", address, "partner@example.com"])

    assert routing.client_id == 42

    assert {:error, :no_inbound_recipient} =
             InboundAddress.find(["balaji@bvcandco.in", "partner@example.com"])

    assert {:error, :no_inbound_recipient} = InboundAddress.find([])
  end

  test "an unparseable period is refused rather than issued" do
    assert {:error, :invalid_period} = InboundAddress.build(7, 42, "August 2026")
  end

  test "no address is issued when inbound is unconfigured" do
    config = Application.get_env(:nila, InboundAddress)
    Application.put_env(:nila, InboundAddress, Keyword.put(config, :secret, ""))
    on_exit(fn -> Application.put_env(:nila, InboundAddress, config) end)

    refute InboundAddress.configured?()
    assert {:error, :inbound_not_configured} = InboundAddress.build(7, 42, "2026-08")
  end
end
