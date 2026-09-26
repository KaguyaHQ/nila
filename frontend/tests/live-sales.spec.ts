import { test, expect } from "@playwright/test";
import type { SalesWorkspace } from "../src/lib/sales-api";

function month(client = 1, period = "2026-06"): SalesWorkspace {
  return {
    details: {},
    exports: { items: [], blockers: [], status: "No exports available." },
    client: {
      id: client,
      name: client === 1 ? "Breeze Tech" : "Second client",
    },
    clients: [
      { id: 1, name: "Breeze Tech" },
      { id: 2, name: "Second client" },
    ],
    user: { name: "Test accountant", org: "Test firm" },
    period,
    month_label: period === "2026-06" ? "June 2026" : "July 2026",
    can_upload: true,
    deadline: "2026-07-11",
    invoice_count: client === 1 && period === "2026-06" ? 1 : 0,
    review_count: 0,
    month_issue_count: 0,
    taxable: "₹1,000.00",
    tax: "₹180.00",
    uploads: { files: 1, unfinished: false },
    rows:
      client === 1 && period === "2026-06"
        ? [
            {
              id: "one",
              number: "REAL-101",
              date: "2026-06-10",
              customer: "Customer A",
              gstin: null,
              status: "ready",
              taxable: "₹1,000.00",
              tax: "₹180.00",
              reason: null,
              path: "/gst/1/2026-06/sales/invoices/one",
            },
          ]
        : [],
    sections: [
      {
        id: "b2b",
        label: "B2B",
        count: "1 invoice",
        value: "₹1,000.00",
        status: "Prepared",
        variant: "success",
        path: "/gst/1/2026-06/sales/b2b",
      },
    ],
    links: {
      upload: "/gst/upload?client_id=1&period=2026-06&kind=sales",
      uploads: "/gst/1/2026-06/sales/uploads",
      working: "/gst/1/2026-06/sales",
      purchases: "/gst/1/2026-06/purchases",
    },
  };
}

test("Excel upload collects multiple reports and keeps them after a failed upload", async ({
  page,
}, info) => {
  await page.route("**/api/workspace/sales/1/2026-06", (route) => route.fulfill({ json: month() }));
  let uploadBody = "";
  await page.route("**/api/workspace/sales/1/2026-06/reports", (route) => {
    uploadBody = route.request().postDataBuffer()?.toString("utf8") ?? "";
    return route.fulfill({ status: 422, json: { error: "Test report needs correction." } });
  });
  await page.goto("/app/gst/1/2026-06/sales?upload=invoices");
  const dialog = page.getByRole("dialog", { name: "Add sales files" });
  await expect(dialog.getByText("Drop your sales PDFs here")).toBeVisible();
  await page.screenshot({ path: info.outputPath("pdf-upload.png"), fullPage: true });
  await dialog.getByRole("button", { name: "Excel report", exact: true }).click();
  await expect(dialog.getByText("Drop your Excel reports here")).toBeVisible();
  await expect(dialog.getByRole("link", { name: "View uploads" })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Upload reports", exact: true })).toBeDisabled();
  await page.screenshot({ path: info.outputPath("excel-upload.png"), fullPage: true });
  const picker = dialog.getByLabel("Choose sales Excel reports");
  await picker.setInputFiles({
    name: "report.xls",
    mimeType: "application/vnd.ms-excel",
    buffer: Buffer.from("test"),
  });
  await expect(dialog.getByText("report.xls", { exact: true })).toBeVisible();
  await dialog.getByRole("button", { name: "Remove report.xls" }).click();
  await expect(dialog.getByText("Drop your Excel reports here")).toBeVisible();
  const transfer = await page.evaluateHandle(() => {
    const data = new DataTransfer();
    data.items.add(new File(["test"], "dropped.xlsx"));
    return data;
  });
  await dialog
    .getByText("Drop your Excel reports here")
    .dispatchEvent("drop", { dataTransfer: transfer });
  await expect(dialog.getByText("dropped.xlsx", { exact: true })).toBeVisible();
  await picker.setInputFiles({
    name: "wrong.pdf",
    mimeType: "application/pdf",
    buffer: Buffer.from("test"),
  });
  await expect(dialog.getByRole("alert")).toContainText(".xls, .xlsx or .csv");
  await expect(dialog.getByText("dropped.xlsx", { exact: true })).toBeVisible();
  await picker.setInputFiles([
    {
      name: "B2B(2).csv",
      mimeType: "text/csv",
      buffer: Buffer.from("GSTIN/UIN of Recipient,Receiver Name"),
    },
    {
      name: "remove-me.xls",
      mimeType: "application/vnd.ms-excel",
      buffer: Buffer.from("remove"),
    },
  ]);
  await expect(dialog.getByText("B2B(2).csv", { exact: true })).toBeVisible();
  await expect(dialog.getByText("dropped.xlsx", { exact: true })).toBeVisible();
  await dialog.getByRole("button", { name: "Remove remove-me.xls" }).click();
  await expect(dialog.getByText("remove-me.xls", { exact: true })).toHaveCount(0);
  await expect(dialog.getByText("2 files selected")).toBeVisible();
  await dialog.getByRole("button", { name: "Upload reports", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("Test report needs correction.");
  expect(uploadBody.match(/name="files\[\]"/g)).toHaveLength(2);
  expect(uploadBody).toContain('filename="dropped.xlsx"');
  expect(uploadBody).toContain('filename="B2B(2).csv"');
  expect(uploadBody).not.toContain('filename="remove-me.xls"');
  await expect(dialog.getByText("dropped.xlsx", { exact: true })).toBeVisible();
  await expect(dialog.getByText("B2B(2).csv", { exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("excel-selected.png"), fullPage: true });
});

test("Excel issues save inline, retain the source and return to downloads", async ({
  page,
}, info) => {
  const data = { ...month(), report_count: 1, report_issue_count: 1 };
  const row = {
    source_filename: "HSN(B2B).xlsx",
    sheet: "HSN summary",
    section: "hsn_b2b",
    row: 14,
    cells: { H: "" },
    values: {
      hsn_sc: "999799",
      desc: "",
      uqc: "NA",
      qty: 0,
      rate: null as number | null,
      txval: 200,
      iamt: 0,
      camt: 18,
      samt: 18,
      csamt: 0,
    },
    suggestion: {
      values: { rate: 18 },
      message:
        "Suggested 18%: calculated from this row's taxable value and GST amounts. Confirm the applicable rate.",
    } as object | null,
  };
  let saved = 0;
  let stale = true;
  let basis = "review-1";
  const task = () => ({
    id: "hsn-rate",
    kind: "row",
    title: "HSN/SAC 999799",
    message: "GST rate is missing.",
    dump_id: 1,
    basis,
    filename: "client.xls",
    source_filename: row.source_filename,
    sheet: row.sheet,
    row: 14,
    source_ids: [],
    fields: ["rate"],
    values: row.values,
    rows: [row],
  });
  await page.route("**/api/workspace/sales/1/2026-06", (route) => route.fulfill({ json: data }));
  await page.route("**/api/workspace/sales/1/2026-06/checks", (route) =>
    route.fulfill({
      json: {
        client: { id: 1, name: "Breeze Tech", gstin: null },
        period: "2026-06",
        can_edit: true,
        lock_reason: null,
        checks: [],
      },
    }),
  );
  await page.route("**/api/workspace/sales/1/2026-06/reports", (route) => {
    if (route.request().method() === "PATCH") {
      const body = route.request().postDataJSON();
      expect(body.basis).toBe(basis);
      expect(body.values.rate).toBe(18);
      expect(body.source_filename).toBe("HSN(B2B).xlsx");
      saved++;
      if (stale) {
        stale = false;
        basis = "review-2";
        return route.fulfill({
          status: 422,
          json: { error: "This report changed. Refresh and review it again." },
        });
      }
      row.values.rate = 18;
      row.suggestion = null;
      data.report_issue_count = 0;
      return route.fulfill({ json: { ok: true } });
    }
    return route.fulfill({
      json: {
        editable: true,
        states: [{ label: "Tamil Nadu", value: "33" }],
        tasks: row.values.rate === null ? [task()] : [],
        reports: [{ dump_id: 1, filename: "client.xls", basis, rows: [row] }],
      },
    });
  });
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByText("Supplied return report", { exact: true })).toHaveCount(0);
  await page.getByRole("link", { name: "Fix 1 remaining issue" }).click();
  const issue = page.getByRole("region", { name: "HSN/SAC 999799" });
  await expect(issue.getByLabel("GST rate", { exact: true })).toHaveValue("");
  await issue.getByLabel("GST rate", { exact: true }).fill("18");
  await expect(issue.getByRole("cell").filter({ hasText: "HSN summary · 14" })).toContainText("HSN(B2B).xlsx");
  await issue.getByText("Show full row", { exact: true }).click();
  await expect(issue.getByRole("columnheader", { name: "H", exact: true })).toBeVisible();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(saved).toBe(0);
  await page.screenshot({ path: info.outputPath("report-inline-check.png"), fullPage: true });
  await issue.getByRole("button", { name: "Save", exact: true }).click();
  await expect(issue.getByRole("alert")).toContainText("This report changed");
  await expect(issue.getByRole("button", { name: "Save", exact: true })).toBeDisabled();
  expect(saved).toBe(1);
  await issue.getByRole("button", { name: "Refresh and review again" }).click();
  await expect(issue.getByLabel("GST rate", { exact: true })).toHaveValue("18");
  await issue.getByRole("button", { name: "Save", exact: true }).click();
  await expect(issue).toContainText("Saved");
  await expect(issue).toBeFocused();
  expect(saved).toBe(2);
  await expect(page.getByText("No report issues remaining.", { exact: true })).toBeVisible();
  await page.getByRole("link", { name: "Back to summary and downloads" }).click();
  await expect(page.getByRole("heading", { name: "GSTR-1 summary" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Fix 1 remaining issue" })).toHaveCount(0);
});

test("empty month retains section rows without asserting no entries or showing exports", async ({
  page,
}, info) => {
  const data = month();
  data.invoice_count = 0;
  data.rows = [];
  data.taxable = data.tax = "—";
  data.uploads = { files: 0, unfinished: false };
  const labels = [
    "B2B",
    "B2CL",
    "Exports",
    "SEZ supplies",
    "B2C (others)",
    "Exempt supplies",
    "Credit/debit notes",
    "Advances",
    "E-commerce",
    "HSN",
    "Documents issued",
  ];
  data.sections = labels.map((label, index) => ({
    id: String(index),
    label,
    count: "—",
    value: "—",
    status: "No entries",
    variant: "muted",
    path: null,
  }));
  await page.route("**/api/workspace/sales/*/*", (route) => route.fulfill({ json: data }));
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByText("No sales invoices added for June 2026 yet.")).toBeVisible();
  await expect(page.getByRole("row")).toHaveCount(12);
  await expect(page.getByText("No entries", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Exports", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Add invoices", exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("empty-sales-month.png"), fullPage: true });
  data.invoice_count = 1;
  data.rows = month().rows;
  data.sections[0] = month().sections[0];
  await page.reload();
  await expect(page.getByText("No sales invoices added for June 2026 yet.")).toHaveCount(0);
  await expect(page.getByText("No entries", { exact: true })).toHaveCount(10);
  await expect(page.getByRole("heading", { name: "Exports", exact: true })).toBeVisible();
});

test("unfinished uploads and excluded records do not become a pristine empty month", async ({
  page,
}) => {
  const data = month();
  data.invoice_count = 0;
  data.rows = [];
  data.uploads = { files: 1, unfinished: true };
  data.sections = [
    { ...data.sections[0], count: "—", value: "—", status: "No entries", path: null },
  ];
  await page.route("**/api/workspace/sales/*/*", (route) => route.fulfill({ json: data }));
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByRole("link", { name: "Check uploads", exact: true })).toBeVisible();
  await expect(
    page.getByText("Sections will populate once sales invoices are prepared."),
  ).toBeVisible();
  await expect(page.getByText("No entries", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Exports", exact: true })).toBeVisible();
  data.uploads = { files: 0, unfinished: false };
  data.rows = [{ ...month().rows[0], status: "excluded", path: null }];
  await page.reload();
  await expect(page.getByText("No sales invoices added for June 2026 yet.")).toHaveCount(0);
  await expect(page.getByText("No entries", { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Exports", exact: true })).toBeVisible();
});

test("real workspace uses server data, changes month/client and preserves register URL", async ({
  page,
}) => {
  await page.route("**/api/workspace/sales/*/*", (route) => {
    const parts = new URL(route.request().url()).pathname.split("/");
    return route.fulfill({ json: month(Number(parts[4]), parts[5]) });
  });
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByRole("heading", { name: "June 2026" })).toBeVisible();
  await expect(page.getByText("UI preview · sample data")).toHaveCount(0);
  await expect(page.getByText("Test accountant")).toBeVisible();
  await page.evaluate(() => {
    (window as any).sameDocument = true;
  });
  await page.getByRole("link", { name: "View sales register", exact: true }).click();
  await expect(page).toHaveURL(/\/app\/gst\/1\/2026-06\/sales\/register$/);
  expect(await page.evaluate(() => (window as any).sameDocument)).toBe(true);
  await expect(page.getByRole("link", { name: "REAL-101", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-06/sales/invoices/one?filter=all",
  );
  await page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" }).fill("Customer A");
  await page.reload();
  await expect(
    page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" }),
  ).toHaveValue("Customer A");
  await page.getByRole("button", { name: "Next month", exact: true }).click();
  await expect(page).toHaveURL(/\/2026-07\/sales\/register/);
  await expect(page.getByRole("link", { name: "REAL-101", exact: true })).toHaveCount(0);
  await expect(page.getByText("No sales invoices yet", { exact: true })).toBeVisible();
  await page.getByLabel("Switch client: Breeze Tech", { exact: true }).click();
  await page.getByRole("option", { name: "Second client", exact: true }).click();
  await expect(page).toHaveURL(/\/app\/gst\/2\/2026-07\/sales\/register/);
  await expect(page.getByLabel("Switch client: Second client", { exact: true })).toBeVisible();
});

test("sales rows open review while links, text selection and keyboard stay usable", async ({
  page,
}, info) => {
  const data = month();
  data.rows[0].status = "needs_review";
  data.rows[0].reason = "Check buyer name against GST records";
  await page.route("**/api/workspace/sales/*/*", (route) => route.fulfill({ json: data }));
  const register = "/app/gst/1/2026-06/sales/register?filter=needs_review&q=Customer";
  const review = /sales\/invoices\/one\?filter=needs_review&q=Customer$/;
  await page.goto(register);
  const row = page.getByRole("row").filter({ hasText: "REAL-101" });
  const link = page.getByRole("link", { name: "Review invoice REAL-101", exact: true });
  await expect(link).toBeVisible();
  await expect(row).toHaveCSS("cursor", "pointer");
  await row.hover();
  await page.screenshot({ path: info.outputPath("sales-row-review.png") });
  await row.getByText("Customer A", { exact: true }).evaluate((element) => {
    const range = document.createRange();
    range.selectNodeContents(element);
    window.getSelection()?.removeAllRanges();
    window.getSelection()?.addRange(range);
    element.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  await expect(page).toHaveURL(register);
  await page.evaluate(() => window.getSelection()?.removeAllRanges());
  await row.getByRole("cell").nth(3).click();
  await expect(page).toHaveURL(review);
  await page.goBack();
  await link.focus();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(review);
  await page.goBack();
  // Modified link clicks stay native rather than triggering same-tab row navigation.
  expect(
    await link.evaluate((element) => {
      const event = new MouseEvent("click", { bubbles: true, cancelable: true, ctrlKey: true });
      element.dispatchEvent(event);
      return event.defaultPrevented;
    }),
  ).toBe(false);
  await expect(page).toHaveURL(register);
  await link.click();
  await expect(page).toHaveURL(review);
  await page.goBack();
  await page.goBack();
  await expect(page).not.toHaveURL(review);
});

test("summary rows open available sections and leave unavailable sections inert", async ({
  page,
}) => {
  const data = month();
  data.sections.push({
    ...data.sections[0],
    id: "exports",
    label: "Exports",
    path: null,
    count: "—",
    status: "No entries",
  });
  await page.route("**/api/workspace/sales/*/*", (route) => route.fulfill({ json: data }));
  await page.goto("/app/gst/1/2026-06/sales");
  const unavailable = page.getByRole("row").filter({ hasText: "Exports" });
  await expect(unavailable).not.toHaveCSS("cursor", "pointer");
  await unavailable.getByRole("cell").first().click();
  await expect(page).toHaveURL("/app/gst/1/2026-06/sales");
  await page.getByRole("row").filter({ hasText: "B2B" }).getByRole("cell").nth(1).click();
  await expect(page).toHaveURL("/app/gst/1/2026-06/sales/sections/b2b");
});

test("loading, forbidden and expired session never masquerade as an empty register", async ({
  page,
}) => {
  let release!: () => void;
  const waiting = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/api/workspace/sales/*/*", async (route) => {
    await waiting;
    await route.fulfill({
      status: 403,
      json: { error: "You cannot access this firm." },
    });
  });
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByRole("status")).toHaveText("Loading sales…");
  release();
  await expect(page.getByRole("alert")).toHaveText("You cannot access this firm.");
  await expect(page.getByRole("heading", { name: "GSTR-1 summary" })).toHaveCount(0);
  await page.unrouteAll();
  await page.route("**/api/workspace/sales/*/*", (route) =>
    route.fulfill({ status: 401, json: { error: "Sign in to continue." } }),
  );
  await page.reload();
  await expect(page.getByRole("link", { name: "Sign in", exact: true })).toHaveAttribute(
    "href",
    "/users/log_in",
  );
});

test("month changes retain the shell and controls, hide old figures, and reuse cached months", async ({
  page,
}, testInfo) => {
  let releaseJuly!: () => void;
  const july = new Promise<void>((resolve) => {
    releaseJuly = resolve;
  });
  let holdJune = false;
  let releaseJune!: () => void;
  const june = new Promise<void>((resolve) => {
    releaseJune = resolve;
  });
  await page.route("**/api/workspace/sales/*/*", async (route) => {
    const period = new URL(route.request().url()).pathname.split("/").at(-1)!;
    if (period === "2026-07") await july;
    if (period === "2026-06" && holdJune) await june;
    return route.fulfill({ json: month(1, period) });
  });
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByRole("heading", { name: "June 2026", exact: true })).toBeVisible();
  await page
    .getByRole("complementary", { name: "Workspace navigation" })
    .evaluate((node) => node.setAttribute("data-retained", "yes"));
  await page.getByRole("button", { name: "Next month", exact: true }).click();
  await expect(page.getByRole("heading", { name: "July 2026", exact: true })).toBeVisible();
  await expect(page.getByRole("status", { name: "Loading sales" })).toBeVisible();
  await expect(page.locator('[data-slot="skeleton"]').first()).toBeVisible();
  await expect(page.getByRole("complementary", { name: "Workspace navigation" })).toHaveAttribute(
    "data-retained",
    "yes",
  );
  await expect(page.getByRole("button", { name: "Previous month", exact: true })).toBeEnabled();
  await expect(page.getByText("₹1,000.00", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Add invoices", exact: true })).toHaveCount(0);
  await page.screenshot({ path: testInfo.outputPath("sales-month-loading.png"), fullPage: true });
  releaseJuly();
  await expect(page.getByRole("status", { name: "Loading sales" })).toHaveCount(0);
  holdJune = true;
  await page.getByRole("button", { name: "Previous month", exact: true }).click();
  await expect(page.getByRole("heading", { name: "June 2026", exact: true })).toBeVisible();
  await expect(page.getByRole("status", { name: "Loading sales" })).toHaveCount(0);
  await expect(page.getByText("₹1,000.00", { exact: true }).first()).toBeVisible();
  releaseJune();
});

test("failed requests can be retried and replace the error screen", async ({ page }) => {
  let fails = true;
  await page.route("**/api/workspace/sales/*/*", (route) =>
    route.fulfill(
      fails ? { status: 500, json: { error: "Could not load sales." } } : { json: month() },
    ),
  );
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByRole("alert")).toHaveText("Could not load sales.");
  await expect(page.getByRole("link", { name: "Back to clients" })).toHaveAttribute(
    "href",
    "/app/clients",
  );
  fails = false;
  await page.getByRole("button", { name: "Try again" }).click();
  await expect(page.getByRole("heading", { name: "June 2026" })).toBeVisible();
});

test("empty filtered register can clear filters even when no invoices need review", async ({
  page,
}) => {
  await page.route("**/api/workspace/sales/*/*", (route) => route.fulfill({ json: month() }));
  await page.goto("/app/gst/1/2026-06/sales/register?filter=needs_review");
  const empty = page.locator('[data-slot="empty"]');
  await expect(empty).toContainText("No invoices match");
  await empty.getByRole("button", { name: "Clear filters" }).click();
  await expect(page.getByText("REAL-101", { exact: true })).toBeVisible();
  await expect(empty).toHaveCount(0);
});

test("excluded sources stay visible without opening a different invoice", async ({ page }) => {
  await page.route("**/api/workspace/sales/*/*", (route) => {
    const id = Number(new URL(route.request().url()).pathname.split("/")[4]);
    const data = month(id);
    data.rows.push({
      id: "excluded",
      number: "EXCLUDED-1",
      date: null,
      customer: "Customer",
      gstin: null,
      status: "excluded",
      taxable: "₹1,000.00",
      tax: "₹180.00",
      reason: null,
      path: null,
    });
    return route.fulfill({ json: data });
  });
  await page.goto("/app/gst/1/2026-06/sales/register");
  await expect(page.getByText("EXCLUDED-1", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "EXCLUDED-1" })).toHaveCount(0);
});

test("month arrows stay in place across different month name lengths", async ({ page }, info) => {
  await page.clock.install({ time: new Date("2026-09-23T12:00:00Z") });
  await page.route("**/api/workspace/sales/*/*", (route) => {
    const period = new URL(route.request().url()).pathname.split("/")[5];
    const data = month(1, period);
    data.month_label = new Intl.DateTimeFormat("en-IN", { month: "long", year: "numeric" }).format(
      new Date(`${period}-01T12:00:00Z`),
    );
    return route.fulfill({ json: data });
  });
  await page.goto("/app/gst/1/2026-07/sales");
  const next = page.getByRole("button", { name: "Next month", exact: true });
  await expect(page.getByRole("heading", { name: "July 2026", exact: true })).toBeVisible();
  await page.evaluate(() => document.fonts.ready);
  const start = await next.boundingBox();
  for (const label of ["August 2026", "September 2026"]) {
    await next.click();
    await expect(page.getByRole("heading", { name: label, exact: true })).toBeVisible();
    const position = await next.boundingBox();
    expect(position?.x).toBe(start?.x);
    expect(position?.y).toBe(start?.y);
  }
  await expect(next).toBeDisabled();
  await page.screenshot({ path: info.outputPath("stable-month-arrows.png") });
});

test("month popover selects by year, preserves register filters and respects bounds", async ({
  page,
}, info) => {
  await page.clock.install({ time: new Date("2026-09-23T12:00:00Z") });
  await page.route("**/api/workspace/sales/*/*", (route) => {
    const parts = new URL(route.request().url()).pathname.split("/");
    return route.fulfill({ json: month(Number(parts[4]), parts[5]) });
  });
  await page.goto("/app/gst/1/2026-06/sales/register?filter=all&q=Customer");
  const trigger = page.getByRole("button", { name: "Choose month", exact: true });
  await trigger.click();
  const picker = page.getByRole("dialog", { name: "Choose working month" });
  await expect(picker).toBeVisible();
  await expect(picker.getByRole("button", { name: "June 2026", exact: true })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
  await expect(picker.getByRole("button", { name: "June 2026", exact: true })).toBeFocused();
  await expect(picker.getByRole("button", { name: "October 2026", exact: true })).toBeDisabled();
  await expect(picker.getByRole("button", { name: "Next year" })).toBeDisabled();
  await page.screenshot({ path: info.outputPath("month-picker.png") });
  await picker.getByRole("button", { name: "Previous year" }).click();
  await picker.getByRole("button", { name: "December 2025", exact: true }).focus();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/2025-12\/sales\/register\?filter=all&q=Customer$/);
  await expect(picker).toBeHidden();
  await trigger.click();
  await expect(picker.getByRole("button", { name: "December 2025", exact: true })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
  await page.keyboard.press("Escape");
  await expect(trigger).toBeFocused();
  await page.goto("/app/gst/1/2017-07/sales");
  await trigger.click();
  await expect(picker.getByRole("button", { name: "Previous year" })).toBeDisabled();
  await expect(picker.getByRole("button", { name: "June 2017", exact: true })).toBeDisabled();
  await page.getByRole("heading", { name: "GSTR-1 summary" }).click();
  await expect(picker).toBeHidden();
  await expect(page).toHaveURL(/2017-07\/sales$/);
});
