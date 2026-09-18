defmodule Nila.Gst.Portal.Challenge do
  @moduledoc false
  # LiveView crash reports may inspect assigns; never print the GST transaction.
  @derive {Inspect, except: [:account]}
  defstruct [:account, :client_id, :org_id, :requested_at]
end
