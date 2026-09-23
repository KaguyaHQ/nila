// Compile-only regressions: the generated contract must reject invalid writes.
import { businessRequest } from "../src/lib/business-api";
import { gstr2bRequest } from "../src/lib/gstr2b-api";
import { savePurchaseTreatment } from "../src/lib/purchase-review-api";

function invalidRequests(signal: AbortSignal) {
  // @ts-expect-error An invoice ID is required for issuance.
  businessRequest("issueBusinessInvoice", {});
  // @ts-expect-error A quotation status must be a supported transition.
  businessRequest("setQuotationStatus", { id: 1, body: { status: "ignore" } });
  // @ts-expect-error This operation requires invoice facts, not a customer body.
  businessRequest("createBusinessInvoice", { body: { customer: {} } });
  // @ts-expect-error OTP verification must include the server challenge.
  gstr2bRequest(1, "2026-09", signal, { action: "verify", body: { otp: "123456" } });
  savePurchaseTreatment(
    "1",
    "2026-09",
    "row",
    "all",
    "",
    // @ts-expect-error Every treatment write needs the current evidence basis.
    { case_ids: [1], values: { choice: "claim" } },
    signal,
  );
}
void invalidRequests;
