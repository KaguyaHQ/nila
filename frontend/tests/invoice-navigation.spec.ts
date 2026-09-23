import { expect, test } from "@playwright/test";
import type { SalesInvoiceReviewData } from "../src/lib/sales-review-api";

function invoice(id: string): SalesInvoiceReviewData {
  return {
    client: { id: 1, name: "Breeze Tech" },
    period: "2026-06",
    invoice: {
      id,
      number: id === "one" ? "INV-001" : "INV-002",
      date: "",
      buyer_name: "Customer A",
      buyer_gstin: "",
      place_of_supply: "Not determined",
    },
    facts: { invoice_number: "INV-001" },
    lines: [],
    totals: [],
    printed_totals: {},
    checks: [],
    issues: [],
    source: null,
    states: [],
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
    editable_fields: { facts: ["invoice_number"], line: [], totals: [] },
  };
}

test.beforeEach(async ({ page }) => {
  await page.route("**/api/workspace/sales/1/2026-06/invoices/*", (route) =>
    route.fulfill({ json: invoice(new URL(route.request().url()).pathname.split("/").at(-1)!) }),
  );
});

test("invoice picker searches, navigates with keyboard, and returns focus on Escape", async ({
  page,
}, testInfo) => {
  await page.goto("/app/gst/1/2026-06/sales/invoices/one?q=Customer+A");
  const trigger = page.getByRole("button", { name: "Invoice list" });
  await trigger.click();
  const search = page.getByRole("combobox", { name: "Find invoice" });
  await expect(search).toBeFocused();
  await search.fill("no match");
  await expect(page.getByText("No invoices found.")).toBeVisible();
  await search.fill("Customer B");
  await expect(page.getByRole("option")).toContainText("₹2,360.00");
  await expect(page.getByRole("option")).toHaveCount(1);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/invoices\/two\?q=Customer\+A/);
  await trigger.click();
  await page.keyboard.press("Escape");
  await expect(search).not.toBeVisible();
  await expect(trigger).toBeFocused();
  await expect(page.getByRole("link", { name: "Back to register", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-06/sales/register?q=Customer+A",
  );
  await page.setViewportSize({ width: 390, height: 844 });
  await trigger.click();
  await expect(search).toBeVisible();
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({ path: testInfo.outputPath("invoice-picker-narrow.png") });
});

test("invoice picker respects active status filter", async ({ page }) => {
  await page.goto("/app/gst/1/2026-06/sales/invoices/one?filter=needs_review");
  await page.getByRole("button", { name: "Invoice list" }).click();
  await expect(page.getByRole("option")).toHaveCount(1);
  await expect(page.getByRole("option")).toContainText("INV-001");
});

test("register search survives opening an invoice and returning", async ({ page }) => {
  await page.route("**/api/workspace/sales/1/2026-06", (route) =>
    route.fulfill({
      json: {
        client: { id: 1, name: "Breeze Tech" },
        clients: [{ id: 1, name: "Breeze Tech" }],
        user: { name: "Accountant", org: "Firm" },
        period: "2026-06",
        month_label: "June 2026",
        can_upload: true,
        deadline: "2026-07-11",
        invoice_count: 1,
        review_count: 1,
        month_issue_count: 0,
        taxable: "₹1,000.00",
        tax: "₹180.00",
        uploads: { files: 1, unfinished: false },
        sections: [],
        rows: [
          {
            id: "one",
            number: "INV-001",
            date: null,
            customer: "Customer A",
            gstin: null,
            status: "needs_review",
            taxable: "₹1,000.00",
            tax: "₹180.00",
            reason: null,
            path: "/gst/1/2026-06/sales/invoices/one",
          },
        ],
        links: {
          upload: "/gst/upload",
          uploads: "/gst/1/2026-06/sales/uploads",
          working: "/gst/1/2026-06/sales",
          purchases: "/gst/1/2026-06/purchases",
        },
      },
    }),
  );
  await page.goto("/app/gst/1/2026-06/sales/register?filter=needs_review&q=Customer+A");
  await page.getByRole("link", { name: "INV-001", exact: true }).click();
  await expect(page).toHaveURL(/invoices\/one\?filter=needs_review&q=Customer\+A/);
  await page.getByRole("link", { name: "Back to register", exact: true }).click();
  await expect(
    page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" }),
  ).toHaveValue("Customer A");
  await expect(page).toHaveURL(/register\?filter=needs_review&q=Customer\+A/);
});

test("sales correction saves with Control Enter without losing field focus", async ({ page }) => {
  let writes = 0;
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) => {
    const data = invoice("one");
    if (route.request().method() === "PATCH") {
      writes++;
      expect(route.request().postDataJSON().values.invoice_number).toBe("CORRECTED");
    }
    return route.fulfill({ json: data });
  });
  await page.goto("/app/gst/1/2026-06/sales/invoices/one");
  const trigger = page.getByRole("button", { name: "Edit invoice details", exact: true });
  await trigger.click();
  await page.getByLabel("Invoice number", { exact: true }).fill("CORRECTED");
  await page.keyboard.press("Control+Enter");
  await expect(page.getByRole("dialog")).not.toBeVisible();
  expect(writes).toBe(1);
  await expect(trigger).toBeFocused();
});
