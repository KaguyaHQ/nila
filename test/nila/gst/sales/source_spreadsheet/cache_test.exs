defmodule Nila.Gst.Sales.SourceSpreadsheet.CacheTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.SourceSpreadsheet.Cache

  test "reuses a decoded workbook for the same immutable source identity" do
    key = {:source_spreadsheet_test, make_ref()}
    caller = self()

    assert {:ok, %{sheets: ["original"]}} =
             Cache.fetch(key, fn ->
               send(caller, :decoded)
               {:ok, %{sheets: ["original"]}}
             end)

    assert_receive :decoded

    assert {:ok, %{sheets: ["original"]}} =
             Cache.fetch(key, fn ->
               send(caller, :decoded_again)
               {:ok, %{sheets: ["changed"]}}
             end)

    refute_receive :decoded_again
  end
end
