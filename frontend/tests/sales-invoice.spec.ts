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
      {
        id: "one",
        number: "INV-001",
        customer: "Customer A",
        amount: "₹1,180.00",
        status: "needs_review",
      },
      {
        id: "two",
        number: "INV-002",
        customer: "Customer B",
        amount: "₹2,360.00",
        status: "ready",
      },
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
  await expect(page.getByText("No invoices need review", { exact: true })).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Decision saved.");
  await expect(page.getByRole("heading", { name: "Invoice INV-001", exact: true })).toBeVisible();
  await expect(page).toHaveURL(/filter=needs_review/);
  await expect(page.getByRole("button", { name: "Next invoice", exact: true })).toBeDisabled();
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

function previewPdf(text = "Draft invoice", secondPage = false) {
  const stream = `BT /F1 18 Tf 48 760 Td (${text.replace(/[()\\]/g, " ")}) Tj ET`;
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    secondPage
      ? "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"
      : "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
  ];
  if (secondPage) {
    const secondStream = "BT /F1 18 Tf 48 760 Td (Second invoice page) Tj ET";
    objects.push(
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R >>",
      `<< /Length ${secondStream.length} >>\nstream\n${secondStream}\nendstream`,
    );
  }
  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(pdf.length);
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const start = pdf.length;
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets
    .slice(1)
    .map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`)
    .join("")}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${start}\n%%EOF`;
  return Buffer.from(pdf);
}

test("invoices from one PDF reuse the document and show the selected page", async ({ page }) => {
  let loads = 0;
  await page.route("**/api/workspace/sales/1/2026-06/invoices/*", (route) => {
    const id = new URL(route.request().url()).pathname.split("/").at(-1)!;
    const data = invoice(id);
    data.source = {
      name: "packet.pdf",
      url: "/review-fixture/packet.pdf",
      pages: [id === "one" ? 1 : 2],
      images: [],
    };
    return route.fulfill({ json: data });
  });
  await page.route("**/review-fixture/packet.pdf", (route) => {
    loads++;
    return route.fulfill({
      contentType: "application/pdf",
      body: previewPdf("First invoice page", true),
    });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  const source = page.getByRole("region", { name: "Source document" });
  await expect(source.locator("[data-pdf-text]")).toHaveText("First invoice page");
  await page.getByRole("button", { name: "Next invoice", exact: true }).click();
  await expect(source.locator("[data-pdf-text]")).toHaveText("Second invoice page");
  await page.getByRole("button", { name: "Zoom in", exact: true }).click();
  await expect(source.locator("[data-rendered-page]")).toHaveAttribute("data-rendered-page", "2");
  await page.getByRole("button", { name: "Previous invoice", exact: true }).click();
  await expect(source.locator("[data-pdf-text]")).toHaveText("First invoice page");
  expect(loads).toBe(1);
  await page.getByRole("link", { name: "Back to register" }).click();
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await expect(source.locator("[data-pdf-text]")).toHaveText("First invoice page");
  expect(loads).toBe(2);
});

test("four-line review keeps totals visible and preserves split and zoom between invoices", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.route("**/api/workspace/sales/1/2026-06/invoices/*", (route) => {
    const id = new URL(route.request().url()).pathname.split("/").at(-1)!;
    const data = invoice(id);
    data.lines = Array.from({ length: 4 }, (_, index) => ({ ...data.lines[0], index }));
    data.source = { name: `${id}.pdf`, url: `/review-fixture/${id}.pdf`, pages: [1], images: [] };
    return route.fulfill({ json: data });
  });
  await page.route("**/review-fixture/*.pdf", (route) =>
    route.fulfill({
      contentType: "application/pdf",
      body: previewPdf(
        route.request().url().includes("one.pdf") ? "Invoice INV-001" : "Invoice INV-002",
      ),
    }),
  );
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  const source = page.getByRole("region", { name: "Source document" });
  const canvas = source.locator("canvas");
  await expect
    .poll(() => canvas.evaluate((el: HTMLCanvasElement) => el.width))
    .toBeGreaterThan(100);
  await expect(page.getByRole("definition").first()).toBeInViewport();
  await page.screenshot({ path: testInfo.outputPath("four-lines-desktop.png") });
  const separator = page.getByRole("separator", { name: "Resize source document" });
  const before = (await source.boundingBox())!.width;
  const handle = (await separator.boundingBox())!;
  await page.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
  await page.mouse.down();
  await page.mouse.move(handle.x + 100, handle.y + handle.height / 2, { steps: 8 });
  await page.mouse.up();
  await expect.poll(async () => (await source.boundingBox())!.width).toBeGreaterThan(before + 70);
  await separator.focus();
  await page.keyboard.press("ArrowLeft");
  const resized = (await source.boundingBox())!.width;
  await page.getByRole("button", { name: "Zoom in", exact: true }).click();
  await expect
    .poll(() => canvas.evaluate((el) => el.getBoundingClientRect().width))
    .toBeGreaterThan(resized);
  const zoomed = await canvas.evaluate((el) => el.getBoundingClientRect().width);
  await source.locator("[data-pdf-surface]").evaluate((el) => {
    el.scrollTop = 150;
  });
  await page.getByRole("button", { name: "Next invoice", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Invoice INV-002", exact: true })).toBeVisible();
  await expect
    .poll(async () => Math.abs((await source.boundingBox())!.width - resized))
    .toBeLessThan(2);
  await expect
    .poll(() =>
      canvas.evaluate(
        (el, expected) => Math.abs(el.getBoundingClientRect().width - expected),
        zoomed,
      ),
    )
    .toBeLessThan(2);
  await expect(source.locator("[data-pdf-surface]")).toHaveJSProperty("scrollTop", 0);
  await expect(source.getByRole("link", { name: "Download source PDF" })).toHaveAttribute(
    "href",
    "/review-fixture/two.pdf",
  );
  await page.getByRole("button", { name: "Previous invoice", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Invoice INV-001", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Invoice list", exact: true }).click();
  await expect(page.getByRole("option").first()).toHaveAttribute("aria-current", "true");
  await page.screenshot({
    path: testInfo.outputPath("invoice-drawer-desktop.png"),
    animations: "disabled",
  });
});

test("review trims repeated labels and keeps GST lookup evidence expandable", async ({
  page,
}, testInfo) => {
  await setup(page);
  const message =
    "The bill says “Philips India Ltd C/o. UPS SCS (India) Pvt Ltd”. GST records say “PHILIPS INDIA LIMITED”.";
  const details =
    "GST portal: PHILIPS INDIA LIMITED; Active. Checked 18 Sep 2026 at 20:05 IST. This is the status at lookup, not on the invoice date.";
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) => {
    const data = invoice();
    data.issues = [
      {
        ...data.issues[0],
        code: "buyer_gst_name_review",
        title: "Check buyer name against GST records",
        message,
        lookup_details: details,
      },
    ];
    return route.fulfill({ json: data });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await expect(page.getByRole("heading", { name: "Invoice lines", exact: true })).toHaveCount(0);
  await expect(page.getByText("1 line", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Needs your review", exact: true })).toHaveCount(
    0,
  );
  await expect(page.getByRole("heading", { name: "Calculated totals", exact: true })).toBeVisible();
  await expect(page.getByText(message, { exact: true })).toBeVisible();
  const lookup = page.getByRole("button", { name: "GST lookup details", exact: true });
  await expect(lookup).toHaveAttribute("aria-expanded", "false");
  await expect(page.getByText(details, { exact: true })).not.toBeVisible();
  await lookup.focus();
  await page.keyboard.press("Enter");
  await expect(page.getByText(details, { exact: true })).toBeVisible();
  await page.keyboard.press("Enter");
  await expect(page.getByText(details, { exact: true })).not.toBeVisible();
  await page.screenshot({
    path: testInfo.outputPath("simplified-review.png"),
    animations: "disabled",
  });
});

test("seller mismatch can move the entire upload without rereading PDFs", async ({
  page,
}, info) => {
  await setup(page);
  const current = { ...invoice(), upload_ref: "38-39" };
  current.issues = [
    {
      target: "one:seller_identity_mismatch",
      code: "seller_identity_mismatch",
      title: "Seller differs from client",
      message: "These bills belong to Caltech.",
      status: "open",
      can_confirm: true,
      action_label: "Checked against the bill",
    },
  ];
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) =>
    route.fulfill({ json: current }),
  );
  await page.route("**/api/workspace/sales/2/2026-06/invoices/one", (route) =>
    route.fulfill({ json: { ...invoice(), client: { id: 2, name: "Caltech" }, issues: [] } }),
  );
  let moves = 0;
  let releaseMove!: () => void;
  const pendingMove = new Promise<void>((resolve) => {
    releaseMove = resolve;
  });
  await page.route("**/api/workspace/sales/1/2026-06/uploads/38-39/move", async (route) => {
    if (route.request().method() === "GET")
      return route.fulfill({
        json: {
          batch_ref: "38-39",
          period: "2026-06",
          invoice_count: 5,
          files: ["caltech.pdf", "caltech-2.pdf"],
          seller: { name: "Caltech", gstin: "33BPPPK1081A1ZA" },
          clients: [
            { id: 2, name: "Caltech", gstin: "33BPPPK1081A1ZA" },
            { id: 3, name: "Other client", gstin: "33AEWPH4158J1Z3" },
          ],
          basis: "preview-basis",
        },
      });
    moves++;
    expect(route.request().postDataJSON()).toEqual({
      destination_client_id: 2,
      basis: "preview-basis",
    });
    expect(route.request().headers()["x-csrf-token"]).toBe("review-csrf");
    await pendingMove;
    await route.fulfill({
      json: {
        client_id: 2,
        period: "2026-06",
        invoice_count: 5,
        review_url: "/gst/2/2026-06/sales/invoices/one",
      },
    });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await page.getByRole("button", { name: "Move upload…", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Move upload to another client" });
  await expect(dialog).toContainText("5 invoices · 2 PDFs");
  const search = dialog.getByRole("combobox", { name: "Destination client" });
  await search.fill("Other");
  await page.getByRole("option", { name: /Other client/ }).click();
  await expect(dialog.getByRole("button", { name: "Move upload", exact: true })).toBeDisabled();
  await search.fill("Caltech");
  await page.getByRole("option", { name: /Caltech/ }).click();
  await expect(dialog).toContainText("Move 5 invoices from Breeze Tech to Caltech · June 2026.");
  await expect(dialog.getByRole("link", { name: "Add client in a new tab" })).toHaveAttribute(
    "target",
    "_blank",
  );
  await page.screenshot({ path: info.outputPath("move-upload.png") });
  await dialog.getByRole("button", { name: "Move upload", exact: true }).click();
  await expect(dialog.getByRole("button", { name: "Moving…" })).toBeDisabled();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeVisible();
  releaseMove();
  await expect(page).toHaveURL("http://127.0.0.1:5174/app/gst/2/2026-06/sales/invoices/one");
  await expect(page.getByRole("heading", { name: "Invoice INV-001" })).toBeVisible();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText("Moved 5 invoices", { exact: true })).toBeVisible();
  expect(moves).toBe(1);
});

test("unmovable uploads explain the reason without offering a save", async ({ page }) => {
  await setup(page);
  const current = { ...invoice(), upload_ref: "38" };
  current.issues = [
    {
      target: "one:seller_identity_mismatch",
      code: "seller_identity_mismatch",
      title: "Seller differs from client",
      message: "Check the seller.",
      status: "open",
      can_confirm: false,
      action_label: null,
    },
  ];
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) =>
    route.fulfill({ json: current }),
  );
  await page.route("**/uploads/38/move", (route) =>
    route.fulfill({
      status: 409,
      json: {
        error: "These bills have different sellers. The whole upload cannot be moved together.",
      },
    }),
  );
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await page.getByRole("button", { name: "Move upload…", exact: true }).click();
  await expect(page.getByRole("dialog").getByRole("alert")).toContainText("different sellers");
  await expect(page.getByRole("button", { name: "Move upload", exact: true })).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(page.getByRole("button", { name: "Move upload…", exact: true })).toBeFocused();
});

test("remove invoice confirms scope, prevents repeat saves and opens the next invoice", async ({
  page,
}, info) => {
  await setup(page);
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) =>
    route.fulfill({ json: { ...invoice(), upload_ref: "38" } }),
  );
  let saves = 0;
  let release!: () => void;
  const pending = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/uploads/38/removal", async (route) => {
    saves++;
    expect(route.request().postDataJSON()).toEqual({ action: "remove", source_ids: ["one"] });
    await pending;
    await route.fulfill({ json: { ok: true } });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  await page.getByRole("button", { name: "Invoice actions" }).click();
  await page.getByRole("menuitem", { name: "Remove invoice…" }).click();
  const dialog = page.getByRole("alertdialog", { name: "Remove invoice INV-001?" });
  await expect(dialog).toContainText("Remove from Breeze Tech’s June 2026 working");
  await expect(dialog.getByRole("button", { name: "Cancel", exact: true })).toBeFocused();
  await page.mouse.click(10, 500);
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByRole("button", { name: "Invoice actions" })).toBeFocused();
  await page.getByRole("button", { name: "Invoice actions" }).click();
  await page.getByRole("menuitem", { name: "Remove invoice…" }).click();

  await page.screenshot({ path: info.outputPath("remove-invoice.png"), animations: "disabled" });
  await dialog.getByRole("button", { name: "Remove", exact: true }).click();
  await expect(dialog.getByRole("button", { name: "Saving…" })).toBeDisabled();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeVisible();
  release();
  await expect(page).toHaveURL(/invoices\/two/);
  await expect(page.getByRole("heading", { name: "Invoice INV-002" })).toBeVisible();
  expect(saves).toBe(1);
});
