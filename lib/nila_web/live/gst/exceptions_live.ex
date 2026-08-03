defmodule NilaWeb.Gst.ExceptionsLive do
  use NilaWeb, :live_view

  alias Nila.Clients

  @moduledoc "One-release compatibility redirect from the retired exceptions page."

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case org && Clients.get_client(org.id, client_id) do
      {:ok, client} ->
        {:ok, push_navigate(socket, to: ~p"/gst/#{client.id}/#{period}")}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That month isn't available.")
         |> push_navigate(to: ~p"/today")}
    end
  end
end
