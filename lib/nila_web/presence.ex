defmodule NilaWeb.Presence do
  use Phoenix.Presence,
    otp_app: :nila,
    pubsub_server: Nila.PubSub
end
