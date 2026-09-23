import { expect, test, type Page } from "@playwright/test";
import type { SalesInvoiceReviewData } from "../src/lib/sales-review-api";

function invoice(id = "one"): SalesInvoiceReviewData {
  return {
    client: { id: 1, name: "Breeze Tech" },
    period: "2026-06",
    invoice: {
      id,
      number: id === "one" ? "INV-001" : "INV-002",
      date: "2026-06-10",
      buyer_name: "Customer A",
      buyer_gstin: "33AABCT3518Q1ZF",
      place_of_supply: "Tamil Nadu (33)",
    },
    facts: {
      invoice_number: id === "one" ? "INV-001" : "INV-002",
      invoice_date: "2026-06-10",
      buyer_name: "Customer A",
      buyer_gstin: "33AABCT3518Q1ZF",
      place_of_supply: "33",
      narration: "",
    },
    lines: [
      {
        index: 0,
        values: {
          description: "Repair service",
          hsn_sac: "998719",
          quantity: "1",
          uom: "NOS",
          printed_unit_price: "1000.00",
          taxable_value: "1000.00",
          cgst_rate: "9",
          cgst_amount: "90.00",
          sgst_rate: "9",
          sgst_amount: "90.00",
          igst_rate: "",
          igst_amount: "",
        },
        display: {
          description: "Repair service",
          hsn_sac: "998719",
          quantity: "1",
          uom: "NOS",
          printed_unit_price: "₹1,000.00",
          taxable_value: "₹1,000.00",
          cgst_rate: "9",
          cgst_amount: "₹90.00",
          sgst_rate: "9",
          sgst_amount: "₹90.00",
        },
      },
    ],
    totals: [
      {
        field: "taxable",
        label: "Taxable",
        calculated: "₹1,000.00",
        printed: "₹1,100.00",
        difference: "₹100.00",
        status: "mismatch",
      },
      {
        field: "tax",
        label: "GST",
        calculated: "₹180.00",
        printed: "₹180.00",
        difference: null,
        status: "matches",
      },
      {
        field: "total",
        label: "Grand total",
        calculated: "₹1,180.00",
        printed: "—",
        difference: null,
        status: "unavailable",
      },
    ],
    printed_totals: {
      printed_total_taxable: "1100.00",
      printed_total_tax: "180.00",
      printed_grand_total: "",
    },
    checks: [
      {
        label: "Printed taxable",
        title: "Taxable total",
        detail: "Extracted lines differ from the printed taxable amount.",
        secondary: "Uses the printed total from the source bill.",
        difference: "₹100.00 difference",
        status: "failed",
      },
      {
        label: "Invoice total",
        title: "Invoice total",
        detail: "No printed invoice total was found.",
        secondary: null,
        difference: null,
        status: "unavailable",
      },
    ],
    issues: [
      {
        target: "invoice:one:printed",
        code: "printed_taxable_mismatch",
        title: "Printed amount differs",
        message: "Confirm the extracted lines only after checking the source bill.",
        status: "open",
        can_confirm: true,
        action_label: "Use extracted lines",
      },
      {
        target: "invoice:one:blocked",
        code: "unsupported",
        title: "Unsupported treatment",
        message: "This supply needs attention before filing.",
        status: "open",
        can_confirm: false,
        action_label: null,
      },
    ],
    source: null,
    states: [
      { label: "Tamil Nadu (33)", value: "33" },
      { label: "Karnataka (29)", value: "29" },
    ],
    queue: [
      { id: "one", number: "INV-001", status: "needs_review" },
      { id: "two", number: "INV-002", status: "ready" },
    ],
    can_edit: true,
    lock_reason: null,
    editable_fields: {
      facts: [
        "invoice_number",
        "invoice_date",
        "buyer_name",
        "buyer_gstin",
        "place_of_supply",
        "narration",
      ],
      line: [
        "description",
        "hsn_sac",
        "quantity",
        "uom",
        "printed_unit_price",
        "taxable_value",
        "cgst_rate",
        "cgst_amount",
        "sgst_rate",
        "sgst_amount",
      ],
      totals: ["printed_total_taxable", "printed_total_tax", "printed_grand_total"],
    },
  };
}

async function setup(page: Page) {
  await page.addInitScript(() =>
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "review-csrf";
      document.head.append(meta);
    }),
  );
  await page.route("**/api/workspace/sales/1/2026-06/invoices/*", (route) =>
    route.fulfill({ json: invoice(new URL(route.request().url()).pathname.split("/").at(-1)) }),
  );
}

test("review navigation preserves filters, stays in React and ignores editing keyboard input", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await expect(page.getByRole("heading", { name: "Invoice INV-001", exact: true })).toBeVisible();
  await expect(page.getByText("No source document is available for this invoice.")).toBeVisible();
  await page.evaluate(() => {
    (window as unknown as { sameDocument: boolean }).sameDocument = true;
  });
  const opener = page.getByRole("button", { name: "Edit invoice details", exact: true });
  await opener.click();
  await page.getByLabel("Invoice number", { exact: true }).focus();
  await page.keyboard.press("Alt+ArrowRight");
  await expect(page).toHaveURL(/\/invoices\/one$/);
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(opener).toBeFocused();
  await page.keyboard.press("Alt+ArrowRight");
  await expect(page).toHaveURL(/\/invoices\/two$/);
  await expect(page.getByRole("heading", { name: "Invoice INV-002", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Needs review 1", exact: true }).click();
  await expect(page).toHaveURL(/\/invoices\/one\?filter=needs_review$/);
  await expect(page.getByRole("link", { name: "Back to register", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-06/sales/register?filter=needs_review",
  );
  expect(
    await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument),
  ).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("invoice-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({ path: testInfo.outputPath("invoice-narrow.png"), fullPage: true });
});

test("facts keep field errors and save only server-authorized raw fields", async ({ page }) => {
  await setup(page);
  let writes = 0;
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) => {
    if (route.request().method() === "GET") {
      const current = invoice();
      current.facts.buyer_gstin = "INVALID";
      return route.fulfill({ json: current });
    }
    expect(route.request().method()).toBe("PATCH");
    expect(route.request().headers()["x-csrf-token"]).toBe("review-csrf");
    const change = route.request().postDataJSON();
    expect(change.section).toBe("facts");
    expect(change.values.invoice_number).toBe(writes === 0 ? "DUPLICATE" : "CORRECTED-001");
    expect(change.values.place_of_supply).toBe("29");
    expect(Object.keys(change.values).sort()).toEqual(["invoice_number", "place_of_supply"]);
    expect(change.values.buyer_gstin).toBeUndefined();
    writes++;
    if (writes === 1)
      return route.fulfill({
        status: 422,
        json: {
          error: "Check the invoice number.",
          errors: { invoice_number: ["already exists"] },
        },
      });
    const updated = invoice();
    updated.facts = { ...updated.facts, ...change.values };
    updated.invoice.number = change.values.invoice_number;
    return route.fulfill({ json: updated });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  const opener = page.getByRole("button", { name: "Edit invoice details", exact: true });
  await opener.click();
  await page.getByLabel("Invoice number", { exact: true }).fill("DUPLICATE");
  await page.getByLabel("Place of supply").selectOption("29");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Check the invoice number.");
  await expect(page.getByLabel("Invoice number", { exact: true })).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await expect(page.getByLabel("Invoice number", { exact: true })).toHaveValue("DUPLICATE");
  await expect(page.getByLabel("Customer GSTIN", { exact: true })).toHaveValue("INVALID");
  await page.getByLabel("Invoice number", { exact: true }).fill("CORRECTED-001");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(
    page.getByRole("heading", { name: "Invoice CORRECTED-001", exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Changes saved.");
  await expect(opener).toBeFocused();
});

test("invoice saves once while pending and shows the saved result only after the response", async ({
  page,
}) => {
  await setup(page);
  let writes = 0;
  let release!: () => void;
  const response = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", async (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: invoice() });
    writes++;
    await response;
    const saved = invoice();
    saved.invoice.number = "SAVED-001";
    saved.facts.invoice_number = "SAVED-001";
    return route.fulfill({ json: saved });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await page.getByRole("button", { name: "Edit invoice details", exact: true }).click();
  await page.getByLabel("Invoice number", { exact: true }).fill("SAVED-001");
  await page
    .getByRole("dialog")
    .locator("form")
    .evaluate((form) => {
      (form as HTMLFormElement).requestSubmit();
      (form as HTMLFormElement).requestSubmit();
    });
  try {
    await expect.poll(() => writes).toBe(1);
    await expect(page.getByRole("button", { name: "Saving…", exact: true })).toBeDisabled();
    await expect(page.getByRole("button", { name: "Cancel", exact: true })).toBeDisabled();
    // The modal makes the unchanged page heading inaccessible until it closes.
    await expect(page.locator("h1")).toHaveText("Invoice INV-001");
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toBeVisible();
  } finally {
    release();
  }
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Invoice SAVED-001", exact: true })).toBeVisible();
  expect(writes).toBe(1);
});

test("line and printed-total edits use server comparisons without browser tax calculation", async ({
  page,
}) => {
  await setup(page);
  let current = invoice();
  current.lines[0].values.description = "";
  current.lines[0].values.item_name = "Item without description";
  current.lines[0].display.description = "—";
  current.lines[0].display.item_name = "Item without description";
  let lineWrites = 0;
  const sections: string[] = [];
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: current });
    const change = route.request().postDataJSON();
    sections.push(change.section);
    if (change.section === "line") {
      lineWrites++;
      if (lineWrites === 1)
        return route.fulfill({
          status: 422,
          json: {
            error: "Check the taxable value.",
            errors: { "line_items[0].taxable_value": ["Enter zero or more."] },
          },
        });
      expect(change.line_index).toBe(0);
      expect(change.values.quantity).toBe("2.50");
      expect(change.values.taxable_value).toBe("123.45");
      current = {
        ...current,
        totals: [
          {
            field: "taxable",
            label: "Taxable",
            calculated: "₹987.65",
            printed: "₹1,100.00",
            difference: "₹112.35",
            status: "mismatch",
          },
        ],
      };
    } else {
      expect(change.section).toBe("totals");
      expect(change.values.printed_grand_total).toBe("2000.01");
      current = {
        ...current,
        printed_totals: change.values,
        totals: [
          {
            field: "total",
            label: "Grand total",
            calculated: "₹987.65",
            printed: "₹2,000.01",
            difference: null,
            status: "unavailable",
          },
        ],
      };
    }
    return route.fulfill({ json: current });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await expect(page.getByText("Item without description", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Edit line 1", exact: true }).click();
  await page.getByLabel("Quantity", { exact: true }).fill("2.50");
  await page.getByLabel("Taxable value", { exact: true }).fill("-1");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByLabel("Taxable value", { exact: true })).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await expect(page.getByText("Enter zero or more.", { exact: true })).toBeVisible();
  await page.getByLabel("Taxable value", { exact: true }).fill("123.45");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("cell", { name: "₹987.65", exact: true })).toBeVisible();
  await expect(page.getByText("₹112.35 difference", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Edit printed totals", exact: true }).click();
  await page.getByLabel("Printed invoice total", { exact: true }).fill("2000.01");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("cell", { name: "₹2,000.01", exact: true })).toBeVisible();
  await expect(page.getByText("Not compared", { exact: true })).toBeVisible();
  expect(sections).toEqual(["line", "line", "totals"]);
});

test("checks show reasons and only server-permitted confirmation is offered", async ({ page }) => {
  await setup(page);
  await page.route("**/invoices/one/confirm", (route) => {
    expect(route.request().headers()["x-csrf-token"]).toBe("review-csrf");
    expect(route.request().postDataJSON()).toEqual({ target: "invoice:one:printed" });
    const updated = invoice();
    updated.queue = updated.queue.map((item) => ({ ...item, status: "ready" }));
    updated.issues = [];
    return route.fulfill({ json: updated });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one?filter=needs_review");
  await page.getByRole("button", { name: "1 check needs review", exact: true }).click();
  await expect(
    page.getByText("No printed invoice total was found.", { exact: true }),
  ).toBeVisible();
  await expect(page.getByText("Not checked", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Use extracted lines", exact: true })).toHaveCount(
    1,
  );
  await expect(page.getByRole("button", { name: "Confirm", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Use extracted lines", exact: true }).click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Use extracted lines", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "No invoices need review", exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Decision saved.");
});

test("filed conflict keeps edits visible but disables further writes after refreshing permission", async ({
  page,
}) => {
  await setup(page);
  let filed = false;
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) => {
    if (route.request().method() === "PATCH") {
      filed = true;
      return route.fulfill({ status: 409, json: { error: "This month has been filed." } });
    }
    return route.fulfill({
      json: {
        ...invoice(),
        can_edit: !filed,
        lock_reason: filed ? "This month has been filed." : null,
      },
    });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await page.getByRole("button", { name: "Edit invoice details", exact: true }).click();
  await page.getByLabel("Invoice number", { exact: true }).fill("UNSAVED");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("This month has been filed.");
  await expect(page.getByRole("button", { name: "Save changes", exact: true })).toBeDisabled();
  await expect(page.getByLabel("Invoice number", { exact: true })).toHaveValue("UNSAVED");
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Edit invoice details", exact: true }),
  ).toBeDisabled();
});

test("unknown invoice fails explicitly rather than showing another source invoice", async ({
  page,
}) => {
  await setup(page);
  await page.route("**/api/workspace/sales/1/2026-06/invoices/missing", (route) =>
    route.fulfill({ status: 404, json: { error: "Invoice not found." } }),
  );
  await page.goto("/app/gst/1/2026-06/sales/invoices/missing");
  await expect(page.getByRole("alert")).toHaveText("Invoice not found.");
  await expect(page.getByRole("heading", { name: "Invoice INV-001", exact: true })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Back to register", exact: true })).toBeVisible();
});

test("checks use a keyboard disclosure and the editor saves with Control Enter", async ({
  page,
}, testInfo) => {
  await setup(page);
  let writes = 0;
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: invoice() });
    writes++;
    const change = route.request().postDataJSON();
    expect(change).toEqual({ section: "facts", values: { invoice_number: "CORRECTED" } });
    const saved = invoice();
    saved.invoice.number = "CORRECTED";
    saved.facts.invoice_number = "CORRECTED";
    return route.fulfill({ json: saved });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one?q=Customer");
  const disclosure = page.getByRole("button", { name: "1 check needs review", exact: true });
  await expect(disclosure).toHaveAttribute("aria-expanded", "false");
  await disclosure.focus();
  await page.keyboard.press("Enter");
  await expect(disclosure).toHaveAttribute("aria-expanded", "true");
  await expect(page.getByText("Uses the printed total from the source bill.")).toBeVisible();
  await page.keyboard.press("Space");
  await expect(disclosure).toHaveAttribute("aria-expanded", "false");
  await page.getByRole("button", { name: "Edit invoice details", exact: true }).click();
  await page.getByLabel("Invoice number", { exact: true }).fill("CORRECTED");
  await page.keyboard.press("Control+Shift+Enter");
  expect(writes).toBe(0);
  await page.keyboard.press("Control+Enter");
  await expect(page.getByRole("heading", { name: "Invoice CORRECTED", exact: true })).toBeVisible();
  expect(writes).toBe(1);
  await expect(page.getByRole("link", { name: "Back to register", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-06/sales/register?q=Customer",
  );
  await page.screenshot({ path: testInfo.outputPath("review-controls.png"), fullPage: true });
});
