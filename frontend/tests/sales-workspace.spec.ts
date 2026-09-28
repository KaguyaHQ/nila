import { test, expect } from "@playwright/test";
import type { SalesWorkspace } from "../src/lib/sales-api";
import type { SalesInvoiceReviewData } from "../src/lib/sales-review-api";
import { chooseSelect } from "./select-field";

test("buyer group keeps records beside evidence and saves only the selected invoice", async ({
  page,
}, info) => {
  const gstin = "33AIEPL7786Q1ZE";
  const rows = ["one", "two"].map((id, i) => ({
    id,
    number: `INV-${i + 1}`,
    customer: "MRL ENTERPRISES",
    date: "2026-08-01",
    gstin,
    status: "needs_review" as const,
    taxable: "₹1,000.00",
    tax: "₹180.00",
    reason: "Check buyer GST registration",
    issues: [{ code: "buyer_gst_registration_review", title: "Check buyer GST registration" }],
    path: `/gst/1/2026-08/sales/invoices/${id}`,
  }));
  const month: SalesWorkspace = {
    client: { id: 1, name: "RSK Marketing" },
    clients: [{ id: 1, name: "RSK Marketing" }],
    user: { name: "Staff", org: "Firm" },
    period: "2026-08",
    month_label: "August 2026",
    can_upload: true,
    deadline: "2026-09-11",
    invoice_count: 2,
    review_count: 2,
    month_issue_count: 0,
    taxable: "₹2,000.00",
    tax: "₹360.00",
    uploads: { files: 1, unfinished: false },
    rows,
    sections: [],
    details: {},
    exports: { items: [], blockers: [], status: "" },
    links: { upload: "", uploads: "", working: "", purchases: "" },
  };
  const review = (id: string): SalesInvoiceReviewData => ({
    client: month.client,
    period: month.period,
    invoice: {
      id,
      number: id === "one" ? "INV-1" : "INV-2",
      date: "2026-08-01",
      buyer_name: "MRL ENTERPRISES",
      buyer_gstin: gstin,
      place_of_supply: "Tamil Nadu",
    },
    facts: { buyer_name: "MRL ENTERPRISES", buyer_gstin: gstin },
    lines: [],
    totals: [],
    printed_totals: {},
    checks: [],
    issues: [
      {
        target: `${id}:gst`,
        code: "buyer_gst_registration_review",
        title: "Check buyer GST registration",
        message: "The buyer registration was cancelled.",
        status: "open",
        can_confirm: false,
        action_label: null,
      },
    ],
    buyer_registration: {
      gstin,
      legal_name: "MUTHU LOGESHWARAN",
      trade_name: "MRL ENTERPRISES",
      registration_status: "Cancelled suo-moto",
      checked_at: "26 Sep 2026",
      cancellation_date: "01/05/2024",
    },
    source: {
      url: null,
      name: "B2B-1.xlsx",
      pages: [],
      images: [],
      spreadsheet: {
        url: "/source",
        granularity: "invoice_rate",
        selected: [{ file: "B2B-1.xlsx", sheet: "B2B", rows: [4] }],
      },
    },
    states: [],
    queue: rows.map((row) => ({
      id: row.id,
      number: row.number,
      status: "needs_review",
      buyer_gstin: gstin,
      issue_codes: ["buyer_gst_registration_review"],
    })),
    can_edit: true,
    lock_reason: null,
    editable_fields: { facts: ["buyer_name", "buyer_gstin"], line: [], totals: [] },
  });
  await page.route("**/api/workspace/sales/1/2026-08", (route) => route.fulfill({ json: month }));
  let patched: unknown;
  await page.route("**/api/workspace/sales/1/2026-08/invoices/*", (route) => {
    const id = route.request().url().split("/").pop()!;
    const data = review(id);
    if (route.request().method() === "PATCH") {
      patched = { id, ...route.request().postDataJSON() };
      data.facts.buyer_name = "MRL NEW NAME";
      data.invoice.buyer_name = "MRL NEW NAME";
    }
    return route.fulfill({ json: data });
  });
  await page.goto("/app/gst/1/2026-08/sales/register");
  await page.getByLabel("Search customer, invoice or GSTIN").fill("  MRL  ");
  await expect(page.getByRole("link", { name: "Inspect invoice INV-1" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Inspect invoice INV-2" })).toBeVisible();
  await chooseSelect(page.getByLabel("Check type"), "buyer_gst_registration_review");
  await page.getByRole("button", { name: "MRL ENTERPRISES · 2", exact: true }).click();
  const inspector = page.getByRole("complementary", { name: "Selected invoice" });
  await expect(inspector.getByText("Cancellation effective 01/05/2024")).toBeVisible();
  await expect(page.getByRole("link", { name: "Inspect invoice INV-2" })).toBeVisible();
  await inspector.getByRole("button", { name: "Correct buyer details" }).click();
  await inspector.getByLabel("Buyer name").fill("MRL NEW NAME");
  page.once("dialog", (dialog) => dialog.dismiss());
  await page.getByRole("link", { name: "Inspect invoice INV-2" }).click();
  await expect(inspector.getByLabel("Buyer name")).toHaveValue("MRL NEW NAME");
  await inspector.getByRole("button", { name: "Save correction" }).click();
  await expect(inspector.getByRole("status")).toHaveText("Buyer details saved for this invoice.");
  expect(patched).toEqual({ id: "one", section: "facts", values: { buyer_name: "MRL NEW NAME" } });
  await expect(inspector.getByRole("link", { name: "Open full review" })).toHaveAttribute(
    "href",
    /origin=register/,
  );
  await page.screenshot({ path: info.outputPath("sales-buyer-workspace.png"), fullPage: true });
});
