import { expect, test, type Page } from "@playwright/test";
import type { SalesWorkspace } from "../src/lib/sales-api";

function workspace(client = 1): SalesWorkspace {
  const columns = [
    { key: "number", label: "Invoice", align: "left" as const },
    { key: "taxable", label: "Taxable value", align: "right" as const },
  ];
  return {
    client: { id: client, name: client === 1 ? "Breeze Tech" : "Second client" },
    clients: [
      { id: 1, name: "Breeze Tech" },
      { id: 2, name: "Second client" },
    ],
    user: { name: "Accountant", org: "Test firm" },
    period: "2026-06",
    month_label: "June 2026",
    can_upload: true,
    deadline: "2026-07-11",
    invoice_count: 1,
    review_count: 1,
    month_issue_count: 0,
    taxable: "₹7,12,393.00",
    tax: "₹1,28,230.74",
    uploads: { files: 1, unfinished: false },
    rows: [],
    sections: [
      {
        id: "b2b",
        label: "B2B",
        count: "1 invoice",
        value: "₹7,12,393.00",
        status: "Prepared",
        variant: "success",
        path: `/gst/${client}/2026-06/sales/sections/b2b`,
      },
    ],
    links: {
      upload: `/gst/${client}/2026-06/sales/upload`,
      uploads: `/gst/${client}/2026-06/sales/uploads`,
      working: `/gst/${client}/2026-06/sales`,
      purchases: `/gst/${client}/2026-06/purchases`,
    },
    details: {
      b2b: {
        title: "B2B sales",
        description: "Sales to registered customers",
        note: "Amounts follow the current GST working.",
        groups: [
          {
            id: "b2b",
            label: null,
            columns,
            rows: [
              {
                id: "one",
                cells: { number: "INV-001", taxable: "₹7,12,393.00" },
                invoice_path: `/gst/${client}/2026-06/sales/invoices/one`,
              },
            ],
          },
        ],
      },
      hsn: {
        title: "HSN summary",
        description: "Sales grouped by HSN / SAC",
        note: null,
        groups: [
          {
            id: "registered",
            label: "Registered customers",
            columns,
            rows: [
              {
                id: "hsn-1",
                cells: { number: "998719", taxable: "₹7,12,393.00" },
                invoice_path: null,
                children: [
                  {
                    id: "source-1",
                    cells: { number: "INV-001", taxable: "₹1,23,456.78" },
                    invoice_path: `/gst/${client}/2026-06/sales/invoices/one`,
                  },
                ],
              },
            ],
          },
          { id: "unregistered", label: "Unregistered customers", columns, rows: [] },
        ],
      },
    },
    exports: {
      status: "A draft working is available. Resolve checks before downloading the return.",
      items: [
        {
          id: "workings",
          label: "GST sales working",
          format: "XLSX",
          url: `/exports/${client}/workings.xlsx`,
          enabled: true,
          reason: null,
        },
        {
          id: "json",
          label: "GSTR-1 return",
          format: "JSON",
          url: `/exports/${client}/return.json`,
          enabled: false,
          reason: "1 invoice needs review.",
        },
      ],
      blockers: [
        {
          id: "review",
          message: "1 invoice needs review.",
          path: `/gst/${client}/2026-06/sales/register?filter=needs_review`,
          external: false,
        },
        {
          id: "month",
          message: "Check the month-level issue.",
          path: `/gst/${client}/2026-06/review`,
          external: true,
        },
      ],
    },
  };
}

async function setup(
  page: Page,
  transform: (value: SalesWorkspace) => SalesWorkspace = (value) => value,
) {
  await page.route("**/api/workspace/sales/*/*", (route) =>
    route.fulfill({
      json: transform(workspace(Number(new URL(route.request().url()).pathname.split("/")[4]))),
    }),
  );
}

test("section uses projected values and source links; HSN contributors expand without computing totals", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales/sections/hsn");
  await expect(page.getByRole("heading", { name: "HSN summary", exact: true })).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Registered customers", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("Unregistered customers: no entries.", { exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("cell", { name: "₹7,12,393.00", exact: true })).toBeVisible();
  await expect(page.getByText("INV-001", { exact: true })).toHaveCount(0);
  await page
    .getByRole("button", { name: "Show contributing invoices for 998719", exact: true })
    .click();
  await expect(page.getByRole("cell", { name: "₹1,23,456.78", exact: true })).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Review source invoice INV-001", exact: true }),
  ).toHaveAttribute("href", "/app/gst/1/2026-06/sales/invoices/one");
  await expect(
    page.getByRole("button", { name: "GSTR-1 return JSON", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("link", { name: "1 invoice needs review.", exact: true }),
  ).not.toBeVisible();
  await page.getByText("Before GSTR-1 JSON (2)", { exact: true }).click();
  await expect(
    page.getByRole("link", { name: "1 invoice needs review.", exact: true }),
  ).toHaveAttribute("href", "/app/gst/1/2026-06/sales/register?filter=needs_review");
  await expect(
    page.getByRole("link", { name: "Check the month-level issue.", exact: true }),
  ).toHaveAttribute("href", "/gst/1/2026-06/review");
  await page.screenshot({ path: testInfo.outputPath("section-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({ path: testInfo.outputPath("section-narrow.png"), fullPage: true });
  await page.evaluate(() => {
    (window as unknown as { sameDocument: boolean }).sameDocument = true;
  });
  await page.getByRole("link", { name: "Sales summary", exact: true }).click();
  await expect(page).toHaveURL(/\/gst\/1\/2026-06\/sales$/);
  expect(
    await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument),
  ).toBe(true);
});

test("both downloads keep the page open and use the server's filenames", async ({ page }) => {
  await setup(page, (data) => {
    data.exports!.items[1].enabled = true;
    data.exports!.items[1].reason = null;
    data.exports!.blockers = [];
    return data;
  });
  await page.route("**/exports/1/workings.xlsx", (route) => {
    expect(route.request().headers().accept).toBe("*/*");
    return route.fulfill({
      status: 200,
      contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      headers: { "Content-Disposition": "attachment; filename*=UTF-8''June%20GST%20working.xlsx" },
      body: "mock workbook bytes",
    });
  });
  await page.route("**/exports/1/return.json", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "Content-Disposition": 'attachment; filename="june-return.json"' },
      body: '{"gstin":"33AABCT3518Q1ZF"}',
    }),
  );
  await page.goto("/app/gst/1/2026-06/sales/sections/b2b");
  await page.evaluate(() => {
    (window as unknown as { sameDocument: boolean }).sameDocument = true;
  });
  for (const [button, filename] of [
    ["GST sales working XLSX", "June GST working.xlsx"],
    ["GSTR-1 return JSON", "june-return.json"],
  ]) {
    const downloading = page.waitForEvent("download");
    await page.getByRole("button", { name: button, exact: true }).click();
    const download = await downloading;
    expect(download.suggestedFilename()).toBe(filename);
    expect(await download.failure()).toBeNull();
  }
  await expect(page).toHaveURL(/\/sales\/sections\/b2b$/);
  expect(
    await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument),
  ).toBe(true);
});

test("readiness changing during download shows the plain-text server reason in place", async ({
  page,
}) => {
  await setup(page);
  let downloads = 0;
  page.on("download", () => {
    downloads++;
  });
  await page.route("**/exports/1/workings.xlsx", (route) =>
    route.fulfill({
      status: 422,
      contentType: "text/plain; charset=utf-8",
      body: "Finish reading the uploaded PDFs before downloading.",
    }),
  );
  await page.goto("/app/gst/1/2026-06/sales/sections/b2b");
  await page.getByRole("button", { name: "GST sales working XLSX", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "Finish reading the uploaded PDFs before downloading.",
  );
  await expect(page.getByRole("heading", { name: "B2B sales", exact: true })).toBeVisible();
  await expect(page).toHaveURL(/\/sales\/sections\/b2b$/);
  expect(downloads).toBe(0);
});

test("expired session HTML is not downloaded as an Excel file", async ({ page }) => {
  await setup(page);
  let downloads = 0;
  page.on("download", () => {
    downloads++;
  });
  await page.route("**/exports/1/workings.xlsx", (route) =>
    route.fulfill({
      status: 200,
      contentType: "text/html",
      body: "<html><body>Sign in</body></html>",
    }),
  );
  await page.goto("/app/gst/1/2026-06/sales/sections/b2b");
  await page.getByRole("button", { name: "GST sales working XLSX", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("session may have expired");
  expect(downloads).toBe(0);
});

test("switching clients aborts an in-flight download and clears its state", async ({ page }) => {
  await setup(page, (data) => {
    if (data.client.id === 2) {
      data.exports!.items[0].enabled = false;
      data.exports!.items[0].reason = "No invoices in this client month.";
    }
    return data;
  });
  let release!: () => void;
  const waiting = new Promise<void>((resolve) => {
    release = resolve;
  });
  let started!: () => void;
  const start = new Promise<void>((resolve) => {
    started = resolve;
  });
  await page.route("**/exports/1/workings.xlsx", async (route) => {
    started();
    await waiting;
    await route.fulfill({
      status: 200,
      contentType: "application/octet-stream",
      headers: { "Content-Disposition": 'attachment; filename="old-client.xlsx"' },
      body: "old data",
    });
  });
  let downloads = 0;
  page.on("download", () => {
    downloads++;
  });
  await page.goto("/app/gst/1/2026-06/sales/sections/b2b");
  await page.getByRole("button", { name: "GST sales working XLSX", exact: true }).click();
  await start;
  const aborted = page.waitForEvent("requestfailed", {
    predicate: (request) => request.url().endsWith("/exports/1/workings.xlsx"),
  });
  await page.getByLabel("Switch client: Breeze Tech", { exact: true }).click();
  await page.getByRole("option", { name: "Second client", exact: true }).click();
  await aborted;
  release();
  await expect(page).toHaveURL(/\/gst\/2\/2026-06\/sales\/sections\/b2b$/);
  await expect(page.getByText("No invoices in this client month.", { exact: true })).toBeVisible();
  await expect(page.getByText("Preparing download…", { exact: true })).toHaveCount(0);
  expect(downloads).toBe(0);
});

test("unknown sections do not silently display another section", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales/sections/not-a-section");
  await expect(
    page.getByRole("heading", { name: "Section unavailable", exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("heading", { name: "B2B sales", exact: true })).toHaveCount(0);
  await expect(
    page.getByRole("link", { name: "Back to sales summary", exact: true }),
  ).toBeVisible();
});
