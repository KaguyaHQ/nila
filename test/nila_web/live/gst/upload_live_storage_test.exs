defmodule NilaWeb.Gst.UploadLiveStorageTest do
  @moduledoc """
  Intake when the bucket is unreachable.

  Swapping the storage adapter is global, so this cannot run alongside the rest
  of the intake suite.
  """

  # Swaps application env; must not run beside other tests.
  use NilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Nila.Clients

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    previous = Application.fetch_env!(:nila, Nila.Storage)

    Application.put_env(
      :nila,
      Nila.Storage,
      Keyword.put(previous, :adapter, Nila.TestFailingStorageAdapter)
    )

    on_exit(fn -> Application.put_env(:nila, Nila.Storage, previous) end)

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  # A refused entry comes back from LiveView as a generic per-file error, and
  # "Something went wrong with that file" reads as a bad scan — sending the
  # operator to re-export a file that was never the problem. The page-level line
  # is the only place that can say the drop is worth simply repeating.
  test "a bucket that cannot be reached says so instead of blaming the file", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload =
      file_input(view, "#gst-upload-form", :documents, [
        %{name: "bills.pdf", content: "%PDF-1.4 fake bills", type: "application/pdf"}
      ])

    render_upload(upload, "bills.pdf", 0)

    assert has_element?(view, "#gst-upload-error", "Nila could not reach storage")
  end
end
