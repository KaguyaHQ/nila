defmodule Nila.Gst.Sales.PartyNameMatchTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Sales.PartyNameMatch

  test "full identities remain recognizable inside care-of and descriptive text" do
    for name <- [
          "Philips India Ltd C/o. UPS SCS (India) Pvt Ltd",
          "PHILIPS INDIA LIMITED care of UPS SCS INDIA PRIVATE LIMITED",
          "Philips India Ltd C / O UPS SCS (India) Pvt Ltd"
        ] do
      assert PartyNameMatch.compare(name, ["PHILIPS INDIA LIMITED", nil]) == :match
    end

    assert PartyNameMatch.compare(
             "Speciality Cancer Hospital Mangalore Institute of Oncology Pumpwell",
             ["MANGALORE INSTITUTE OF ONCOLOGY PRIVATE LIMITED"]
           ) == :match
  end

  test "uncertainty is distinct from a supported company-name conflict" do
    for name <- ["Healthcare Division - Chennai", "PIL", "P.H.I.L.I.P.S", "India", ""] do
      assert PartyNameMatch.compare(name, ["PHILIPS INDIA LIMITED"]) == :uncertain
    end

    assert PartyNameMatch.compare("ARUL SELVAM STORE", ["ARUL SELVAN STORES"]) == :uncertain

    assert PartyNameMatch.compare("Siemens Healthcare Pvt Ltd", ["PHILIPS INDIA LIMITED"]) ==
             :possible_conflict

    assert PartyNameMatch.compare("Siemens Healthcare Pvt Ltd C/o Philips India Ltd", [
             "PHILIPS INDIA LIMITED"
           ]) == :possible_conflict

    assert PartyNameMatch.compare("Siemens Healthcare Pvt Ltd", [
             "PHILIPS INDIA LIMITED",
             "SIEMENS HEALTHCARE"
           ]) == :match

    assert PartyNameMatch.compare("Siemens Healthcare Pvt Ltd", ["PHILIPS INDIA LIMITED", "SHC"]) ==
             :uncertain

    assert PartyNameMatch.compare("Siemens Healthcare Pvt Ltd", [nil, ""]) == :uncertain
  end

  test "August report aliases match without client-specific mappings" do
    for {reported, registered} <- [
          {"VIJAYALASHMI STORES MINJUR", "VIJAYALAKSHMI STORE"},
          {"NANDHINI 1", "NANDHINI STORES"},
          {"NEW ABOORVA SWEETS&BAKERY", "NEW ABOORVA SWEETS AND BAKERY"},
          {"MINI KALYANI STORE (MIN)", "MINI KALYANI STORE"},
          {"R.M.K.SHANU BAKES 2", "RMK SHANU BAKES"},
          {"JAYALAKSHMI ENTERPRISES", "JAYALAKSHMI STORES"},
          {"MRL ENTERPRISES (AVIN)", "MRL ENTERPRISES"},
          {"VISHNU STORE CG", "SRI VISHNU STORES"},
          {"VINAYAGA TRADERS2", "VINAYAGA TRADERS"},
          {"SUNDARAJ ST MIN", "SUNDARARAJ AGENCIES"},
          {"ADITHIYA DEPARTMENTAL STORE", "ADITHYA DEPARTMENTAL STORES"},
          {"PADMANABAN SUPER STORE", "PADMANABHAN SUPER STORE"},
          {"I.T.C LTD", "I T C LIMITED"}
        ] do
      assert PartyNameMatch.matches?(reported, registered), "#{reported} / #{registered}"
    end
  end

  test "shared store words, short similar names and partial business names are insufficient" do
    for {reported, registered} <- [
          {"VIJAYALASHMI STORES MINJUR", "JAYALAKSHMI STORES"},
          {"ARUL STORE", "ARUN STORE"},
          {"RAMU STORE", "RAMAN STORE"},
          {"MINI KALYANI STORE", "KALYANI STORE"},
          {"KALYANI STORE", "MINI KALYANI STORE"},
          {"NEW BALAMURUGAN STORE", "BALAMURUGAN STORE"},
          {"STORES", "NANDHINI STORES"},
          {"NANDHINI STORES", "STORES"},
          {"T.D.C.C.W.S", "THIRUVALLUR DISTRICT CONSUMER CO-OPERATIVE WHOLESALE STORES"},
          {"ARUL SELVAM STORE", "ARUL SELVAN STORES"},
          {"", "NANDHINI STORES"},
          {nil, "NANDHINI STORES"}
        ] do
      refute PartyNameMatch.matches?(reported, registered), "#{reported} / #{registered}"
    end
  end
end
