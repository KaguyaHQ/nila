import { expect, test, type Page } from "@playwright/test";
import type { BusinessBootstrap, BusinessInvoice } from "../src/lib/business-api";
const bootstrap: BusinessBootstrap = { services: [], business: { id: 1, address: "Chennai", name: "Breeze Services", gstin: "33AABCT3518Q1ZF" }, profile: { legal_name: "Breeze Services", address: "Chennai", state_code: "33", domestic_services_only: true, e_invoice_not_applicable: true }, customers: [{ id: 4, name: "Harbour Labs", gstin: null, address: "Chennai", state_code: "33" }], invoices: [], states: [{ code: "33", name: "Tamil Nadu" }, { code: "29", name: "Karnataka" }] };
const invoice: BusinessInvoice = { original_invoice_id: null, converted_invoice_id: null, valid_until: null, purchase_order_number: null, purchase_order_date: null, delivery_address: null, snapshot: {}, issued_at: null, inserted_at: "2026-09-22T10:00:00Z", id: 9, number: null, status: "draft", document_type: "invoice", customer_id: 4, invoice_date: "2026-09-22", due_date: "", place_of_supply: "33", lines: [{ description: "Consulting", sac: "998313", quantity: "1", unit_price: "1000", gst_rate: "18" }], notes: "", totals: { taxable_paise: 100000, cgst_paise: 9000, sgst_paise: 9000, igst_paise: 0, total_paise: 118000 } };
function previewPdf(text = "Draft invoice") {
  const stream = `BT /F1 18 Tf 48 760 Td (${text.replace(/[()\\]/g, " ")}) Tj ET`;
  const objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`];
  let pdf = "%PDF-1.4\n"; const offsets = [0]; objects.forEach((object, index) => { offsets.push(pdf.length); pdf += `${index + 1} 0 obj\n${object}\nendobj\n`; }); const start = pdf.length;
  pdf += `xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(offset => `${String(offset).padStart(10, "0")} 00000 n \n`).join("")}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${start}\n%%EOF`; return Buffer.from(pdf);
}
async function setup(page: Page) {
  await page.route(/\/api\/business\/invoices\/calculate$/, route => route.fulfill({ json: { totals: invoice.totals, lines: [{ taxable_paise: 100000, cgst_paise: 9000, sgst_paise: 9000, igst_paise: 0 }] } }));
  await page.route(/\/api\/business\/invoices\/preview$/, route => route.fulfill({ contentType: "application/pdf", body: previewPdf() }));
  await page.route(/\/api\/business\/invoices\/\d+\/pdf$/, route => route.fulfill({ contentType: "application/pdf", body: previewPdf("Issued invoice") }));
  await page.route(/\/api\/business$/, route => route.fulfill({ json: bootstrap }));
  await page.addInitScript(() => document.addEventListener("DOMContentLoaded", () => { const meta = document.createElement("meta"); meta.name = "csrf-token"; meta.content = "business-csrf"; document.head.append(meta); }));
}
async function chooseCustomer(page: Page, name: string) {
  await page.locator("#business-customer").click();
  await page.getByRole("combobox", { name: "Search customers" }).fill(name);
  await page.getByRole("option", { name, exact: true }).click();
}

test("draft save then issue is explicit; PDF failures stay visible", async ({ page }, testInfo) => {
  await setup(page); let saved = { ...invoice }; let issues = 0;
  await page.route(/\/api\/business\/invoices$/, async route => { expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf"); expect(String(route.request().postDataJSON().invoice.customer_id)).toBe("4"); await route.fulfill({ json: { invoice: saved } }); });
  await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice: saved } }));
  await page.route(/\/api\/business\/invoices\/9\/issue$/, route => { issues++; saved = { ...saved, status: "issued", number: "INV/26-27/0001" }; return route.fulfill({ json: { invoice: saved } }); });
  await page.route(/\/api\/business\/invoices\/9\/pdf$/, route => route.fulfill({ status: 503, json: { error: "PDF temporarily unavailable." } }));
  await page.goto("/app/business/invoices/new"); await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeDisabled();
  await chooseCustomer(page, "Harbour Labs"); await page.locator("#invoice-pos").selectOption("33"); await page.locator("#line-0-description").fill("Consulting"); await page.locator("#line-0-sac").fill("998313"); await page.locator("#line-0-price").fill("1000");
  await page.getByRole("button", { name: "Save draft", exact: true }).click(); await expect(page).toHaveURL(/\/business\/invoices\/9$/); await expect(page.getByText("₹1,180.00", { exact: true })).toBeVisible(); expect(issues).toBe(0);
  await page.screenshot({ path: testInfo.outputPath("business-invoice-desktop.png"), fullPage: true }); await page.setViewportSize({ width: 390, height: 844 }); await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); await page.screenshot({ path: testInfo.outputPath("business-invoice-narrow.png"), fullPage: true });
  await page.getByRole("button", { name: "Issue invoice", exact: true }).click(); await expect(page.getByText("INV/26-27/0001", { exact: true }).first()).toBeVisible(); expect(issues).toBe(1); await expect(page.locator("#line-0-description")).toBeDisabled();
  await page.getByRole("button", { name: "Download PDF", exact: true }).click(); await expect(page.getByRole("alert").first()).toContainText("PDF temporarily unavailable.");
});

test("server validation retains draft without false issued state", async ({ page }) => {
  await setup(page); await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice } })); await page.route(/\/api\/business\/invoices\/9\/issue$/, route => route.fulfill({ status: 422, json: { error: "Complete business details before issuing." } }));
  await page.goto("/app/business/invoices/9"); await page.getByRole("button", { name: "Issue invoice", exact: true }).click(); await expect(page.getByRole("alert").first()).toContainText("Complete business details"); await expect(page.getByRole("button", { name: "Download PDF" })).toHaveCount(0); await expect(page.locator("#line-0-description")).toHaveValue("Consulting");
});
test("forbidden workspace exposes no customer or invoice controls", async ({ page }) => {
  await page.route(/\/api\/business$/, route => route.fulfill({ status: 403, json: { error: "You do not have access to this business." } })); await page.goto("/app/business/invoices"); await expect(page.getByRole("alert")).toContainText("do not have access"); await expect(page.getByRole("link", { name: "New invoice" })).toHaveCount(0);
});
test("unsaved changes disable issue until saved", async ({ page }) => {
  await setup(page); await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice } })); await page.goto("/app/business/invoices/9"); await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeEnabled(); await page.locator("#line-0-description").fill("Revised services"); await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeDisabled();
});
test("customer saves scoped and business profile confirms save", async ({ page }) => {
  await setup(page); await page.route(/\/api\/business\/customers$/, async route => { const body = route.request().postDataJSON(); expect(body.customer.name).toBe("New customer"); expect(body.customer.client_id).toBeUndefined(); expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf"); await route.fulfill({ json: { customer: { id: 5, ...body.customer } } }); });
  await page.goto("/app/business/customers"); await page.getByRole("button", { name: "Add customer", exact: true }).click(); await page.getByLabel("Customer name").fill("New customer"); await page.getByLabel("Billing address").fill("Chennai"); await page.getByLabel("State", { exact: true }).selectOption("33"); await page.getByRole("button", { name: "Save customer" }).click(); await expect(page.locator("#business-customer-form")).toHaveCount(0);
  await page.route(/\/api\/business\/profile$/, route => { expect(route.request().postDataJSON().profile.address).toBe("New address"); return route.fulfill({ json: { profile: bootstrap.profile } }); }); await page.getByRole("link", { name: "Business details", exact: true }).click(); await page.getByLabel("Business address").fill("New address"); await page.getByRole("button", { name: "Save business details" }).click(); await expect(page.getByRole("status")).toHaveText("Business details saved.");
});
test("credit note carries original customer and services with explicit save and issue", async ({ page }) => {
  await setup(page); await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice: { ...invoice, status: "issued", number: "INV/26-27/0001", snapshot: { supplier: { name: "Breeze Services", address: "Chennai", gstin: bootstrap.business.gstin }, customer: bootstrap.customers[0] } } } })); await page.goto("/app/business/invoices/9"); await page.getByRole("link", { name: "Create credit note" }).click(); await expect(page.getByRole("heading", { name: "Credit note", exact: true })).toBeVisible(); await expect(page.getByRole("article", { name: "Editable invoice" })).toContainText("Harbour Labs"); await expect(page.locator("#line-0-description")).toHaveValue("Consulting"); await expect(page.getByRole("button", { name: "Issue credit note" })).toBeDisabled(); await expect(page.getByText("INV/26-27/0001", { exact: true }).first()).toBeVisible();
});
test("saved edits survive reopen and issued party names use frozen snapshot", async ({ page }) => {
  await setup(page); let current = { ...invoice }; await page.route(/\/api\/business\/invoices\/9$/, async route => { if (route.request().method() === "PATCH") current = { ...current, ...route.request().postDataJSON().invoice }; await route.fulfill({ json: { invoice: current } }); }); await page.route(/\/api\/business$/, route => route.fulfill({ json: { ...bootstrap, invoices: [current] } }));
  await page.goto("/app/business/invoices/9"); await page.locator("#line-0-description").fill("Saved revision"); await page.getByRole("button", { name: "Save draft" }).click(); await expect(page.getByRole("status").filter({ hasText: "Draft saved." })).toBeVisible(); await page.getByRole("link", { name: "Invoices", exact: true }).first().click(); await page.getByRole("link", { name: "Draft", exact: true }).click(); await expect(page.locator("#line-0-description")).toHaveValue("Saved revision");
  await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice: { ...current, status: "issued", number: "INV/26-27/0001", snapshot: { supplier: { name: "Original supplier", address: "Old supplier address", gstin: bootstrap.business.gstin }, customer: { name: "Original customer", address: "Old customer address", gstin: null, state_code: "33" } } } } })); await page.reload(); await expect(page.getByRole("region", { name: "Issued party details" })).toContainText("Original customer"); await expect(page.getByRole("region", { name: "Issued party details" })).toContainText("Original supplier");
});
test("focus and reconnect preserve unsaved edits", async ({ page }) => {
  await setup(page); let reads = 0; await page.route(/\/api\/business\/invoices\/9$/, route => { reads++; return route.fulfill({ json: { invoice } }); }); await page.goto("/app/business/invoices/9"); await page.locator("#line-0-description").fill("Unsaved local edit"); const before = reads; await page.evaluate(() => { window.dispatchEvent(new Event("offline")); window.dispatchEvent(new Event("online")); window.dispatchEvent(new Event("focus")); document.dispatchEvent(new Event("visibilitychange")); }); await expect(page.locator("#line-0-description")).toHaveValue("Unsaved local edit"); await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeDisabled(); expect(reads).toBe(before);
});
test("empty document is editable immediately and totals come from Phoenix without saving or PDF", async ({ page }, testInfo) => {
  await setup(page); let previews = 0, writes = 0, calculations = 0;
  await page.route(/\/api\/business\/invoices\/preview$/, route => { previews++; return route.fulfill({ contentType: "application/pdf", body: previewPdf() }); }); await page.route(/\/api\/business\/invoices$/, route => { writes++; return route.fulfill({ json: { invoice } }); });
  await page.route(/\/api\/business\/invoices\/calculate$/, route => { calculations++; expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf"); return route.fulfill({ json: { totals: { ...invoice.totals, total_paise: 1234567 }, lines: [{ taxable_paise: 100000 }] } }); });
  await page.goto("/app/business/invoices/new"); await expect(page.getByRole("article", { name: "Editable invoice" })).toBeVisible(); await expect(page.locator("#line-0-description")).toBeVisible(); await expect(page.getByRole("dialog")).toHaveCount(0); await expect(page.locator("canvas")).toHaveCount(0); await page.locator("#invoice-pos").selectOption("33"); await page.locator("#line-0-price").fill("1000"); await expect(page.getByText("₹12,345.67", { exact: true })).toBeVisible(); expect(calculations).toBeGreaterThan(0); expect(previews).toBe(0); expect(writes).toBe(0);
  await page.screenshot({ path: testInfo.outputPath("invoice-document-desktop.png"), fullPage: true }); await page.setViewportSize({ width: 390, height: 844 }); await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); await page.screenshot({ path: testInfo.outputPath("invoice-document-narrow.png"), fullPage: true });
});
test("new customer sheet keeps draft lines and selects saved customer", async ({ page }) => {
  await setup(page); const customers = [...bootstrap.customers]; await page.route(/\/api\/business$/, route => route.fulfill({ json: { ...bootstrap, customers } })); let invoiceWrites = 0; await page.route(/\/api\/business\/invoices$/, route => { invoiceWrites++; return route.fulfill({ json: { invoice } }); }); await page.route(/\/api\/business\/customers$/, route => { const body = route.request().postDataJSON(); expect(body.customer.client_id).toBeUndefined(); const customer = { id: 5, ...body.customer }; customers.push(customer); return route.fulfill({ json: { customer } }); });
  await page.goto("/app/business/invoices/new"); await page.locator("#line-0-description").fill("Keep these services"); await page.locator("#line-0-price").fill("2300"); await page.locator("#business-customer").click(); await page.getByRole("combobox", { name: "Search customers" }).fill("New buyer"); await page.getByRole("option", { name: /^Create/ }).click(); await expect(page.locator("#invoice-customer-name")).toHaveValue("New buyer"); await page.locator("#invoice-customer-address").fill("Chennai"); await page.locator("#invoice-customer-state").selectOption("33"); await page.locator("#business-save-customer").click(); await expect(page.locator("#business-customer-sheet")).toHaveCount(0); await expect(page.locator("#business-customer")).toContainText("New buyer"); await expect(page.locator("#line-0-description")).toHaveValue("Keep these services"); await expect(page.locator("#line-0-price")).toHaveValue("2300"); await expect(page).toHaveURL(/\/invoices\/new$/); expect(invoiceWrites).toBe(0);
});
test("PDF preview is explicit, uses unsaved input, reports errors and releases URL on close", async ({ page }) => {
  await setup(page); let previews = 0;
  await page.addInitScript(() => { const active = new Set<string>(); (window as unknown as { activePdfUrls: Set<string> }).activePdfUrls = active; const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL); URL.createObjectURL = object => { const url = create(object); if (object instanceof Blob && object.type.includes("pdf")) active.add(url); return url; }; URL.revokeObjectURL = url => { active.delete(url); revoke(url); }; });
  await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice } })); await page.route(/\/api\/business\/invoices\/preview$/, route => { previews++; const input = route.request().postDataJSON().invoice; return input.notes === "Reject preview" ? route.fulfill({ status: 422, json: { error: "Check your service rate." } }) : route.fulfill({ contentType: "application/pdf", body: previewPdf(input.lines[0].description) }); });
  await page.goto("/app/business/invoices/9"); await page.locator("#line-0-description").fill("Unsaved PDF services"); expect(previews).toBe(0); await page.getByRole("button", { name: "Preview PDF", exact: true }).click(); const dialog = page.getByRole("dialog", { name: "PDF preview", exact: true }); await expect(dialog.locator("[data-pdf-text]")).toContainText("Unsaved PDF services"); await expect(dialog.locator("canvas")).toHaveAttribute("width", /[1-9][0-9]+/); await page.keyboard.press("Escape"); await expect(dialog).toHaveCount(0); await expect.poll(() => page.evaluate(() => (window as unknown as { activePdfUrls: Set<string> }).activePdfUrls.size)).toBe(0); await expect(page.locator("#line-0-description")).toHaveValue("Unsaved PDF services"); await page.locator("#invoice-notes").fill("Reject preview"); await page.getByRole("button", { name: "Preview PDF", exact: true }).click(); await expect(dialog.getByRole("alert")).toContainText("Check your service rate."); await expect(dialog.locator("canvas")).toHaveCount(0);
});
test("saved decimal GST rate shows its supported rate without a silent fallback", async ({ page }) => {
  await setup(page); await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice: { ...invoice, lines: [{ ...invoice.lines[0], gst_rate: "18.00" }] } } }));
  await page.goto("/app/business/invoices/9"); await expect(page.locator("#line-0-gst")).toHaveValue("18"); await expect(page.locator("#line-0-gst option:checked")).toHaveText("18%");
});
test("new and saved credit notes keep the original billed identity after customer edits", async ({ page }) => {
  await setup(page);
  const original = { ...invoice, status: "issued", number: "INV/26-27/0001", snapshot: { supplier: { name: "Breeze Services", address: "Chennai", gstin: bootstrap.business.gstin }, customer: { name: "Original billed customer", address: "Original billing address", gstin: null, state_code: "33" } } };
  await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice: original } }));
  await page.route(/\/api\/business\/invoices\/10$/, route => route.fulfill({ json: { invoice: { ...invoice, id: 10, document_type: "credit_note", original_invoice_id: 9 } } }));
  for (const path of ["/app/business/invoices/new?credit_for=9", "/app/business/invoices/10"]) {
    await page.goto(path); const document = page.getByRole("article", { name: "Editable invoice" });
    await expect(document).toContainText("Original billed customer"); await expect(document).toContainText("Original billing address");
    await expect(document).not.toContainText("Harbour Labs");
  }
});
const quotation: BusinessInvoice = { ...invoice, id: 21, document_type: "quotation", valid_until: "2026-10-10", purchase_order_number: "WO-4821", purchase_order_date: "2026-09-15", delivery_address: "Project office", notes: "Payment within 15 days." };

test("quotation list separates quotations from issued invoices", async ({ page }) => {
  await setup(page); const readyQuote = { ...quotation, status: "issued" as const, number: "QUO/2627/0001" };
  await page.route(/\/api\/business$/, route => route.fulfill({ json: { ...bootstrap, invoices: [{ ...invoice, status: "issued", number: "INV/2627/0001" }, readyQuote] } }));
  await page.goto("/app/business/quotations"); await expect(page.getByRole("heading", { name: "Quotations", exact: true })).toBeVisible(); await expect(page.getByRole("link", { name: "QUO/2627/0001", exact: true })).toBeVisible(); await expect(page.getByRole("link", { name: "INV/2627/0001", exact: true })).toHaveCount(0);
  await page.getByRole("link", { name: "Invoices", exact: true }).first().click(); await expect(page.getByRole("link", { name: "INV/2627/0001", exact: true })).toBeVisible(); await expect(page.getByRole("link", { name: "QUO/2627/0001", exact: true })).toHaveCount(0);
});

test("quotation builder finalizes explicitly, accepts, and converts to one invoice draft with fields retained", async ({ page }, testInfo) => {
  await setup(page); let current = { ...quotation }; let savedInput: Record<string, unknown> = {}; let conversions = 0;
  const converted = { ...quotation, id: 22, document_type: "invoice" as const, valid_until: null, status: "draft" as const, number: null };
  await page.route(/\/api\/business$/, route => route.fulfill({ json: { ...bootstrap, invoices: [current] } }));
  await page.route(/\/api\/business\/invoices$/, route => { savedInput = route.request().postDataJSON().invoice; expect(savedInput.document_type).toBe("quotation"); expect(savedInput.valid_until).toBe("2026-10-10"); current = { ...current, ...savedInput }; return route.fulfill({ json: { invoice: current } }); });
  await page.route(/\/api\/business\/invoices\/21$/, route => route.fulfill({ json: { invoice: current } }));
  await page.route(/\/api\/business\/invoices\/22$/, route => route.fulfill({ json: { invoice: { ...converted, ...savedInput, document_type: "invoice", valid_until: null } } }));
  await page.route(/\/api\/business\/invoices\/21\/issue$/, route => { current = { ...current, status: "issued", number: "QUO/2627/0001" }; return route.fulfill({ json: { invoice: current } }); });
  await page.route(/\/api\/business\/invoices\/21\/quotation-status$/, route => { expect(route.request().postDataJSON().status).toBe("accepted"); current = { ...current, status: "accepted" }; return route.fulfill({ json: { invoice: current } }); });
  await page.route(/\/api\/business\/invoices\/21\/convert$/, async route => { conversions++; expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf"); current = { ...current, status: "converted", converted_invoice_id: 22 }; await route.fulfill({ json: { invoice: { ...converted, ...savedInput, document_type: "invoice", valid_until: null }, quotation: current } }); });
  await page.goto("/app/business/quotations/new"); await expect(page.getByRole("heading", { name: "Quotation", exact: true })).toBeVisible(); await expect(page.getByRole("button", { name: "Finalize quotation", exact: true })).toBeDisabled();
  await chooseCustomer(page, "Harbour Labs"); await page.locator("#invoice-pos").selectOption("33"); await page.locator("#invoice-date").fill("2026-09-22"); await page.getByLabel("Valid until", { exact: false }).fill("2026-10-10"); await page.locator("#line-0-description").fill("Quoted consulting"); await page.locator("#line-0-sac").fill("998313"); await page.locator("#line-0-price").fill("1000"); await page.locator("#invoice-notes").fill("Payment within 15 days."); await page.getByRole("button", { name: "Add reference / PO" }).click(); await page.locator("#invoice-reference").fill("WO-4821");
  await page.getByRole("button", { name: "Save draft", exact: true }).click(); await expect(page).toHaveURL(/\/quotations\/21$/); await page.getByRole("button", { name: "Finalize quotation", exact: true }).click(); await expect(page.getByRole("button", { name: "Download PDF", exact: true })).toBeVisible(); await expect(page.locator("#line-0-description")).toBeDisabled(); await expect(page.getByRole("link", { name: "Create credit note" })).toHaveCount(0);
  const download = page.waitForEvent("download"); await page.getByRole("button", { name: "Download PDF", exact: true }).click(); expect((await download).suggestedFilename()).toMatch(/\.pdf$/);
  await page.getByRole("button", { name: "Mark accepted", exact: true }).click(); await expect(page.getByRole("button", { name: "Convert to invoice", exact: true })).toBeVisible(); await page.screenshot({ path: testInfo.outputPath("quotation-accepted.png"), fullPage: true }); await page.getByRole("button", { name: "Convert to invoice", exact: true }).click();
  await expect(page).toHaveURL(/\/invoices\/22$/); expect(conversions).toBe(1); await expect(page.getByRole("heading", { name: "Tax invoice", exact: true })).toBeVisible(); await expect(page.locator("#line-0-description")).toHaveValue("Quoted consulting"); await expect(page.locator("#invoice-reference")).toHaveValue("WO-4821"); await expect(page.locator("#invoice-notes")).toHaveValue("Payment within 15 days."); await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeVisible();
});

test("quotation transition errors stay visible and conversion does not claim success", async ({ page }) => {
  await setup(page); const accepted = { ...quotation, status: "accepted", number: "QUO/2627/0001" };
  await page.route(/\/api\/business\/invoices\/21$/, route => route.fulfill({ json: { invoice: accepted } })); await page.route(/\/api\/business\/invoices\/21\/convert$/, route => route.fulfill({ status: 409, json: { error: "Quotation changed. Reload before converting." } }));
  await page.goto("/app/business/quotations/21"); await page.getByRole("button", { name: "Convert to invoice", exact: true }).click(); await expect(page.getByRole("alert").first()).toContainText("Quotation changed"); await expect(page).toHaveURL(/\/quotations\/21$/);
});

const savedService = { id: 31, description: "Monthly consulting", sac: "998313", unit: "hour", unit_price: "2500.50", gst_rate: "18.00" };
async function mockServices(page: Page) {
  let services = [{ ...savedService }];
  await page.route(/\/api\/business$/, route => route.fulfill({ json: { ...bootstrap, services } }));
  await page.route(/\/api\/business\/services(?:\/\d+)?$/, async route => {
    const request = route.request(); const id = Number(new URL(request.url()).pathname.split("/").at(-1));
    if (request.method() === "GET") return route.fulfill({ json: { services } });
    expect(request.headers()["x-csrf-token"]).toBe("business-csrf");
    if (request.method() === "DELETE") { services = services.filter(service => service.id !== id); return route.fulfill({ json: { ok: true } }); }
    const attrs = request.postDataJSON().service; expect(attrs.client_id).toBeUndefined();
    const service = { ...attrs, id: request.method() === "PATCH" ? id : 32 };
    services = request.method() === "PATCH" ? services.map(current => current.id === id ? service : current) : [...services, service];
    return route.fulfill({ json: { service } });
  });
}

test("saved services catalogue creates, edits and removes reusable defaults", async ({ page }) => {
  await setup(page); await mockServices(page); await page.goto("/app/business/services");
  await expect(page.getByRole("heading", { name: "Services", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Add service", exact: true }).click();
  let dialog = page.getByRole("dialog"); await dialog.getByLabel("Description", { exact: true }).fill("Annual support"); await dialog.getByLabel("SAC", { exact: true }).fill("998313"); await dialog.getByLabel("Unit", { exact: false }).fill("year"); await dialog.getByLabel("Rate", { exact: false }).fill("12000"); await dialog.getByLabel("GST", { exact: false }).selectOption("18"); await dialog.getByRole("button", { name: "Save service", exact: true }).click();
  await expect(dialog).toHaveCount(0); await expect(page.getByText("Annual support", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Edit Annual support", exact: true }).click(); dialog = page.getByRole("dialog"); await dialog.getByLabel("Rate", { exact: false }).fill("14000"); await dialog.getByRole("button", { name: "Save service", exact: true }).click(); await expect(dialog).toHaveCount(0); await expect(page.getByText("₹14,000.00", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Delete Annual support", exact: true }).click(); await page.getByRole("button", { name: "Remove service", exact: true }).click(); await expect(page.getByText("Annual support", { exact: true })).toHaveCount(0); await expect(page.getByText("Monthly consulting", { exact: true })).toBeVisible();
});

for (const document of ["invoices", "quotations"]) test(`saved services picker fills ${document} without changing quantity or preventing manual edits`, async ({ page }) => {
  await setup(page); await mockServices(page); let writes = 0;
  await page.route(/\/api\/business\/services(?:\/\d+)?$/, route => { if (route.request().method() !== "GET") writes++; return route.fulfill({ json: { services: [savedService] } }); });
  await page.goto(`/app/business/${document}/new`); await page.locator("#line-0-quantity").fill("3.5"); await page.getByRole("button", { name: "Select saved service 1", exact: true }).click(); await page.getByRole("combobox", { name: "Search services" }).fill("consulting"); await page.getByRole("option", { name: /Monthly consulting/ }).click();
  await expect(page.locator("#line-0-description")).toHaveValue("Monthly consulting"); await expect(page.locator("#line-0-sac")).toHaveValue("998313"); await expect(page.locator("#line-0-price")).toHaveValue("2500.50"); await expect(page.locator("#line-0-unit")).toHaveValue("hour"); await expect(page.locator("#line-0-gst")).toHaveValue("18"); await expect(page.locator("#line-0-quantity")).toHaveValue("3.5");
  await page.locator("#line-0-description").fill("Client-specific consulting"); await page.locator("#line-0-price").fill("2400"); await expect(page.locator("#line-0-description")).toHaveValue("Client-specific consulting"); expect(writes).toBe(0);
});

test("saved invoice lines stay unchanged after catalogue edits", async ({ page }) => {
  await setup(page); await mockServices(page); await page.route(/\/api\/business\/invoices\/9$/, route => route.fulfill({ json: { invoice: { ...invoice, lines: [{ ...savedService, quantity: "2" }] } } }));
  await page.goto("/app/business/services"); await page.getByRole("button", { name: "Edit Monthly consulting", exact: true }).click(); const dialog = page.getByRole("dialog"); await dialog.getByLabel("Description", { exact: true }).fill("Repriced consulting"); await dialog.getByLabel("Rate", { exact: false }).fill("9999"); await dialog.getByRole("button", { name: "Save service", exact: true }).click(); await expect(dialog).toHaveCount(0);
  await page.goto("/app/business/invoices/9"); await expect(page.locator("#line-0-description")).toHaveValue("Monthly consulting"); await expect(page.locator("#line-0-price")).toHaveValue("2500.50"); await expect(page.locator("#line-0-quantity")).toHaveValue("2");
});


test("nullable profile facts become blank editable fields", async ({ page }, testInfo) => {
  await setup(page);
  await page.route(/\/api\/business$/, route => route.fulfill({ json: {
    ...bootstrap, profile: { ...bootstrap.profile, legal_name: null, address: null, state_code: null },
  } }));
  let submitted: unknown;
  await page.route(/\/api\/business\/profile$/, async route => {
    submitted = route.request().postDataJSON();
    await route.fulfill({ json: { profile: bootstrap.profile } });
  });
  await page.goto("/app/business/settings");
  await expect(page.locator("#business-name")).toHaveValue("Breeze Services");
  await expect(page.locator("#business-address")).toHaveValue("");
  await page.locator("#business-address").fill("Chennai");
  await page.getByRole("button", { name: "Save business details" }).click();
  await expect(page.getByRole("status")).toHaveText("Business details saved.");
  expect(submitted).toMatchObject({ profile: { legal_name: "Breeze Services", address: "Chennai", state_code: "33" } });
  await page.screenshot({ path: testInfo.outputPath("business-settings.png") });
});
