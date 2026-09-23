defmodule Nila.Gst.Portal.Challenge do
  @moduledoc false
  # Error reports may inspect this struct; never print the GST transaction.
  @derive {Inspect, except: [:account]}
  defstruct [:account, :client_id, :org_id, :requested_at]
end
