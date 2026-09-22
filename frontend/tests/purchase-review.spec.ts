import { expect, test, type Page } from "@playwright/test";
import type { PurchaseReviewData } from "../src/lib/purchase-review-api";

function review(id = "one"): PurchaseReviewData {
  return {
    client: { id: 1, name: "Breeze Tech", gstin: "33AABCT3518Q1ZF" }, period: "2026-06", month_label: "June 2026", can_edit: true, lock_reason: null, filter: "needs_review", q: "",
    queue: [{ id: "one", number: "P-001", vendor: "Supplier One", status: "Needs treatment", needs_review: true, case_ids: [1] }, { id: "two", number: "P-002", vendor: "Supplier Two", status: "Needs treatment", needs_review: true, case_ids: [2] }],
    item: { id, number: id === "one" ? "P-001" : "P-002", vendor: "Supplier One", document_type: "invoice", status: "Matched", reason: "Books and GSTR-2B agree. Choose the ITC treatment.", pairing_pending: false, case_ids: [id === "one" ? 1 : 2], comparisons: [{ id: "pair1", facts: [{ label: "Invoice", books: "P-001", portal: "P-001", different: false }, { label: "GST", books: "₹180.00", portal: "₹180.00", different: false }], original_url: "/gst/1/2026-06/original/1/0" }], images: [], legacy_url: "/gst/1/2026-06/purchases/review/one" },
    cases: [1, 2].map(caseId => ({ id: caseId, basis: `basis-${caseId}`, number: `P-00${caseId}`, vendor: "Supplier One", available: true, unavailable_reason: null, claimable: true, can_claim_split: true, claim_block_reason: null, cess_issue: null, can_record_document: false, document_state: "held", heads: [{ id: "cgst", label: "CGST", amount: "₹90.00", value: "90.00" }, { id: "sgst", label: "SGST", amount: "₹90.00", value: "90.00" }, { id: "igst", label: "IGST", amount: "₹0.00", value: "0.00" }], values: { choice: null, later_reason: "", exclude_reason: "", note: "", split: { claim: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" }, later: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" }, exclude: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" } } } })),
    reasons: { later: [{ id: "other", label: "Other" }], exclude: [{ id: "blocked_credit", label: "Blocked credit" }] }, legacy_url: "/gst/1/2026-06/purchases/bills",
  };
}
async function setup(page: Page, data = (id: string) => review(id)) {
  await page.addInitScript(() => document.addEventListener("DOMContentLoaded", () => { const meta = document.createElement("meta"); meta.name = "csrf-token"; meta.content = "purchase-csrf"; document.head.append(meta); }));
  await page.route("**/api/workspace/purchases/1/2026-06/review**", route => {
    const url = new URL(route.request().url());
    const id = url.pathname.split("/review/")[1] ?? "one";
    return route.fulfill({ json: { ...data(id), filter: url.searchParams.get("filter") ?? "needs_review", q: url.searchParams.get("q") ?? "" } });
  });
}

test("comparison navigation stays in React and preserves queue context", async ({ page }, testInfo) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/purchases/review/one?filter=all&q=Supplier");
  await expect(page.getByRole("heading", { name: "Purchase P-001" })).toBeVisible();
  await expect(page.getByRole("columnheader", { name: "Purchase books" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Open original source", exact: false })).toHaveAttribute("href", "/gst/1/2026-06/original/1/0");
  await page.evaluate(() => { (window as unknown as { retained: boolean }).retained = true; });
  await page.getByRole("button", { name: "Set ITC treatment" }).click();
  await page.keyboard.press("Alt+ArrowRight");
  await expect(page).toHaveURL(/review\/one\?filter=all&q=Supplier$/);
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByRole("button", { name: "Set ITC treatment" })).toBeFocused();
  await page.keyboard.press("Alt+ArrowRight");
  await expect(page).toHaveURL(/review\/two\?filter=all&q=Supplier$/);
  expect(await page.evaluate(() => (window as unknown as { retained: boolean }).retained)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("purchase-review-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("purchase-review-narrow.png"), fullPage: true });
});

test("save and next posts explicit case basis and real server result", async ({ page }) => {
  await setup(page);
  let posted: unknown;
  await page.route("**/review/one/treatment?*", route => {
    posted = route.request().postDataJSON();
    expect(route.request().headers()["x-csrf-token"]).toBe("purchase-csrf");
    const fresh = review(); fresh.cases[0].values.choice = "later";
    return route.fulfill({ json: fresh });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Set ITC treatment" }).click();
  await page.getByRole("radio", { name: "Claim later", exact: true }).click();
  await page.getByLabel("Why claim later?").selectOption("other");
  await page.getByLabel("Note", { exact: true }).fill("Awaiting goods receipt");
  await page.keyboard.press("Control+Enter");
  await expect(page.getByRole("heading", { name: "Purchase P-002" })).toBeVisible();
  expect(posted).toMatchObject({ case_ids: [1], basis: { "1": "basis-1" }, values: { choice: "later", later_reason: "other", note: "Awaiting goods receipt" } });
});

test("split decimal strings reach server and validation errors keep edits", async ({ page }) => {
  await setup(page);
  await page.route("**/review/one/treatment?*", route => {
    expect(route.request().postDataJSON().values.split.claim.cgst).toBe("45.25");
    return route.fulfill({ status: 422, json: { error: "Each tax head must add up to its available amount.", code: "invalid_split" } });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Set ITC treatment" }).click();
  await page.getByRole("radio", { name: "Split amounts", exact: true }).click();
  await page.getByLabel("CGST claim", { exact: true }).fill("45.25");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("dialog").getByRole("alert")).toHaveText("Each tax head must add up to its available amount.");
  await expect(page.getByLabel("CGST claim", { exact: true })).toHaveValue("45.25");
});

test("stale save closes editor and requires fresh inspection", async ({ page }) => {
  let current = review(); await setup(page, () => current);
  await page.route("**/review/one/treatment?*", route => { current = { ...review(), can_edit: false, lock_reason: "This month was signed off." }; return route.fulfill({ status: 409, json: { error: "The source changed. Review it again.", code: "stale_basis" } }); });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Set ITC treatment" }).click();
  await page.getByRole("radio", { name: "Claim this month", exact: true }).click();
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByText("This month was signed off.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Set ITC treatment" })).toBeDisabled();
});

test("document possession must be recorded before claim becomes available", async ({ page }) => {
  const current = review(); current.cases[0].claimable = false; current.cases[0].can_record_document = true; current.cases[0].claim_block_reason = "Confirm that you hold the invoice.";
  await setup(page, () => current);
  await page.route("**/review/one/document?*", route => { expect(route.request().postDataJSON()).toEqual({ case_ids: [1], basis: { "1": "basis-1" } }); return route.fulfill({ json: review() }); });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Set ITC treatment" }).click();
  await expect(page.getByRole("radio", { name: "Claim this month", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await page.getByRole("button", { name: "I have this invoice" }).click();
  await expect(page.getByRole("status")).toHaveText("Invoice possession recorded. Review the available ITC choices.");
  await page.getByRole("button", { name: "Set ITC treatment" }).click();
  await expect(page.getByRole("radio", { name: "Claim this month", exact: true })).toBeEnabled();
});

test("uncertain pairing blocks treatment with an explicit source-review handoff", async ({ page }) => {
  const current = review(); current.item!.pairing_pending = true;
  await setup(page, () => current);
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await expect(page.getByRole("button", { name: "Set ITC treatment" })).toBeDisabled();
  await expect(page.getByText("Resolve the uncertain pairing before setting ITC treatment.")).toBeVisible();
  await expect(page.getByRole("link", { name: "Open source corrections and pairing" })).toHaveAttribute("href", current.item!.legacy_url);
});


test("ITC radio choices support arrows and preserve multiline notes", async ({ page }, testInfo) => {
  await setup(page);
  let posted: unknown;
  await page.route("**/review/one/treatment?*", route => {
    posted = route.request().postDataJSON();
    return route.fulfill({ json: review() });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Set ITC treatment" }).click();
  const claim = page.getByRole("radio", { name: "Claim this month", exact: true });
  await claim.check();
  await page.keyboard.press("ArrowRight");
  await expect(page.getByRole("radio", { name: "Claim later", exact: true })).toBeChecked();
  await expect(page).toHaveURL(/review\/one$/);
  await page.getByLabel("Why claim later?").selectOption("other");
  const note = page.getByLabel("Note", { exact: true });
  await expect(note).toHaveJSProperty("tagName", "TEXTAREA");
  await note.fill("Awaiting goods receipt\nSupplier called on Monday.");
  await page.screenshot({ path: testInfo.outputPath("itc-controls-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("itc-controls-narrow.png"), fullPage: true });
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(posted).toMatchObject({ values: { choice: "later", note: "Awaiting goods receipt\nSupplier called on Monday." } });
});
