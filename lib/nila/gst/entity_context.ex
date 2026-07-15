defmodule Nila.Gst.EntityContext do
  @moduledoc """
  The reconciliation identity for a worked month: the CLIENT whose bills these
  are (their GSTIN decides intra/inter-state treatment and place-of-supply),
  not the CA firm that owns the org. Shared by the worker (first pass) and the
  workings assembler (re-derivation after human corrections) so both compute
  flags against the same context.
  """

  def for_client(%{gstin: gstin} = client) do
    %{
      "gstin" => gstin,
      "entity_name" => client.name,
      "state_code" => gstin && String.slice(gstin, 0, 2),
      "registered_address" => client.address,
      "business_hsn_prefixes" => [],
      "residential_markers" => []
    }
  end
end
