defmodule NilaWeb.TallySocket do
  use Phoenix.Socket

  alias Nila.TallyDevices

  channel "tally_device:*", NilaWeb.TallyDeviceChannel

  @impl true
  def connect(_params, socket, connect_info) do
    with token when is_binary(token) <- connect_info[:auth_token],
         %{} = device <- TallyDevices.authenticate_device(token) do
      {:ok, assign(socket, :device, device)}
    else
      _invalid -> :error
    end
  end

  @impl true
  def id(%{assigns: %{device: device}}), do: "tally_device_socket:#{device.id}"
end
