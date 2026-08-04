defmodule Nila.Gst.CessTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Cess

  defp invoice(date, lines) do
    %{
      "invoice_date" => date,
      "line_items" =>
        Enum.map(lines, fn {description, hsn} ->
          %{"description" => description, "hsn_sac" => hsn}
        end)
    }
  end

  @post_reform ~D[2026-02-14]
  @pre_reform ~D[2025-06-10]

  test "the ordinary SMB bill is settled without asking anyone" do
    ordinary =
      invoice(@post_reform, [
        {"Refrigeration unit", "8415"},
        {"Installation service", "9987"},
        {"134A Gas", "2903"},
        {"Silver Rod 43%", "71069290"}
      ])

    assert Cess.hits(ordinary) == []
  end

  test "tobacco headings are caught in full" do
    for {description, hsn} <- [
          {"Unmanufactured tobacco", "24011010"},
          {"Cigarettes", "24022010"},
          {"Chewing tobacco", "24039910"},
          {"Beedis", "24039920"},
          {"Pan masala", "21069020"}
        ] do
      assert [%{hsn: ^hsn}] = Cess.hits(invoice(@post_reform, [{description, hsn}])),
             "#{description} (#{hsn}) must be screened as a cess candidate"
    end
  end

  # Heading 2106 is "food preparations not elsewhere specified" — the grocery
  # and FMCG trade lives there, and a prefix wider than pan masala's own eight
  # digits would reinstate the standing question for exactly the clients who owe
  # no cess.
  test "the rest of heading 2106 is not pan masala" do
    assert Cess.hits(invoice(@post_reform, [{"Supari", "21069030"}])) == []
    assert Cess.hits(invoice(@post_reform, [{"Sherbet", "21069011"}])) == []
    assert Cess.hits(invoice(@post_reform, [{"Namkeen", "210690"}])) == []
  end

  test "the categories 02/2025 exempted are screened before it, not after" do
    withdrawn = [
      {"Aerated water", "22021010"},
      {"Coal", "27011200"},
      {"SUV", "87032329"},
      {"Motorcycle 500cc", "87115000"}
    ]

    for {description, hsn} <- withdrawn do
      line = [{description, hsn}]

      assert [%{hsn: ^hsn}] = Cess.hits(invoice(@pre_reform, line)),
             "#{hsn} carried cess before 2025-09-22"

      assert Cess.hits(invoice(@post_reform, line)) == [],
             "#{hsn} was exempted by Notification 02/2025"
    end
  end

  # Cess ran on engine capacity over 350cc, and heading 8711 is every two-wheeler
  # in the country. A commuter bike is the volume of the trade and owes nothing.
  test "small motorcycles are not screened even before the reform" do
    assert Cess.hits(invoice(@pre_reform, [{"Scooter 110cc", "87111020"}])) == []
    assert Cess.hits(invoice(@pre_reform, [{"Commuter bike 150cc", "87112019"}])) == []
    assert Cess.hits(invoice(@pre_reform, [{"Cruiser 500cc", "87115000"}])) != []
  end

  test "the reform boundary is the day the notification took effect" do
    coal = [{"Coal", "27011200"}]

    assert Cess.hits(invoice(~D[2025-09-21], coal)) != []
    assert Cess.hits(invoice(~D[2025-09-22], coal)) == []
  end

  test "an unreadable date is screened against both eras rather than assumed clean" do
    coal = [{"Coal", "27011200"}]

    assert Cess.hits(invoice("not a date", coal)) != []
    assert Cess.hits(invoice(nil, coal)) != []
  end

  test "a hit names the line, its wording and the code that raised it" do
    mixed =
      invoice(@post_reform, [
        {"AC service", "8415"},
        {"Zarda", "2403 99 10"},
        {"Transport", "9987"},
        {"Cigarettes", "24022010"}
      ])

    assert Cess.hits(mixed) == [
             %{line: 2, description: "Zarda", hsn: "24039910"},
             %{line: 4, description: "Cigarettes", hsn: "24022010"}
           ]
  end

  test "a line with no HSN raises nothing here" do
    assert Cess.hits(invoice(@post_reform, [{"Sundry", nil}])) == []
    assert Cess.hits(invoice(@post_reform, [{"Sundry", ""}])) == []
    assert Cess.hits(%{"invoice_date" => @post_reform, "line_items" => nil}) == []
  end
end
