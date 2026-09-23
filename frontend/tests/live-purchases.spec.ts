import { expect, test, type Page } from "@playwright/test";
import type { PurchasesWorkspace } from "../src/lib/purchases-api";

test("directory keeps purchase context for sidebar, client choices and command palette", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.route(/\/api\/workspace\/clients(?:\?.*)?$/, (route) =>
    route.fulfill({
      json: {
        clients: [
          { id: 1, name: "Breeze Tech", gstin: null },
          { id: 2, name: "Second client", gstin: null },
        ],
        user: { name: "Accountant", org: "Test firm" },
        can_edit: true,
        period: "2026-06",
      },
    }),
  );
  await page.goto("/app/gst/1/2026-06/purchases");
  await page.getByRole("complementary").getByRole("link", { name: "Clients", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Clients", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Second client", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/2/2026-06/purchases",
  );
  await expect(
    page.getByRole("complementary").getByRole("link", { name: "Purchases & ITC" }),
  ).toHaveAttribute("href", "/app/gst/1/2026-06/purchases");
  await page.getByRole("button", { name: "Go to page or client" }).click();
  await page
    .getByRole("combobox", { name: "Search pages, clients or a month" })
    .fill("Second client");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/2/2026-06/purchases");
});

test("command palette keeps the GSTR-2B source when changing month", async ({ page }) => {
  await page.route("**/api/workspace/purchases/*/*?*", (route) => {
    const url = new URL(route.request().url());
    const period = url.pathname.split("/").at(-1)!;
    return route.fulfill({
      json: { ...workspace(), period, month_label: period, filter: "gstr2b" },
    });
  });
  await page.route(/\/api\/workspace\/clients(?:\?.*)?$/, (route) =>
    route.fulfill({
      json: {
        clients: [],
        user: { name: "Accountant", org: "Test firm" },
        can_edit: true,
        period: "2026-06",
      },
    }),
  );
  await page.goto("/app/gst/1/2026-06/purchases/register?source=gstr2b&q=Supplier");
  await page.getByRole("button", { name: "Go to page or client" }).click();
  await page.getByRole("combobox", { name: "Search pages, clients or a month" }).fill("May 2026");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/1/2026-05/purchases/register?source=gstr2b");
  await expect(page.getByRole("heading", { name: "GSTR-2B register" })).toBeVisible();
});

function workspace(): PurchasesWorkspace {
  const legacy = "/gst/1/2026-06/purchases";
  return {
    client: { id: 1, name: "Breeze Tech", gstin: "33AABCT3518Q1ZF" },
    clients: [{ id: 1, name: "Breeze Tech" }],
    user: { name: "Accountant", org: "Test firm" },
    period: "2026-06",
    month_label: "June 2026",
    can_edit: true,
    signed_off: false,
    lock_reason: null,
    processing: false,
    inputs: {
      books: { present: true, count: 2, tax: "₹180.00" },
      portal: { present: true, count: 1, tax: "₹180.00", fetching: false, needs_import: false },
    },
    overview: {
      complete: false,
      comparison_available: true,
      remaining: 1,
      buckets: [
        { id: "matched", label: "Matched", count: 1, books_tax: "₹180.00", portal_tax: "₹180.00" },
      ],
      itc: {
        recorded: true,
        claim: "₹120.00",
        later: "₹30.00",
        excluded: "₹10.00",
        pending: "₹20.00",
        carried_count: 1,
        stale_count: 1,
      },
    },
    filters: [
      { id: "register", label: "Purchase register" },
      { id: "gstr2b", label: "GSTR-2B" },
    ],
    filter: "register",
    q: "",
    rows: [
      {
        id: "source1",
        number: "B-001",
        date: "2026-06-10",
        vendor: "Supplier One",
        gstin: "33AABCT3518Q1ZF",
        document_type: "invoice",
        tax: "₹200.00",
        tax_paise: 20000,
        status: "Matched",
        reason: "Two source entries linked during review",
        review_url: `${legacy}/review/source1`,
      },
      {
        id: "source2",
        number: "CN-002",
        date: "2026-06-11",
        vendor: "Supplier One",
        gstin: "33AABCT3518Q1ZF",
        document_type: "credit_note",
        tax: "−₹20.00",
        tax_paise: -2000,
        status: "Matched",
        reason: null,
        review_url: `${legacy}/review/source1`,
      },
    ],
    carried: [],
    working: {
      enabled: true,
      url: `${legacy}/workings.xlsx`,
      status: "Prepared for review",
      reason: null,
    },
    links: {
      import_excel: `${legacy}/import-excel`,
      uploads: `${legacy}/uploads`,
      portal: legacy,
      review: `${legacy}/review?filter=needs_review`,
      treatment: `${legacy}/review?filter=treatment`,
      carried: `${legacy}/review?filter=carried`,
    },
    notice: "Matching does not mean ITC has been claimed.",
  };
}

async function setup(page: Page, data = workspace()) {
  await page.route("**/gstr2b", (route) =>
    route.fulfill({
      json: {
        client: data.client,
        period: data.period,
        connection: { state: "connected", username: "test" },
        permissions: { fetch: data.can_edit, connect: data.can_edit, export: true },
        statement: null,
        fetching: false,
        import: { needed: false, status: null, error: null },
        availability_hint: null,
      },
    }),
  );
  await page.route("**/api/workspace/purchases/1/2026-06?*", (route) => {
    const params = new URL(route.request().url()).searchParams;
    const q = params.get("q") ?? "";
    return route.fulfill({
      json: {
        ...data,
        filter: params.get("filter"),
        q,
        rows: data.rows.filter((row) =>
          `${row.vendor} ${row.number}`.toLowerCase().includes(q.toLowerCase()),
        ),
      },
    });
  });
}

test("purchase overview separates comparison, ITC and working with real legacy handoffs", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/purchases");
  await expect(page.getByRole("heading", { name: "Purchases & ITC", exact: true })).toBeVisible();
  await expect(page.getByText("₹20.00 tax awaiting treatment.")).toBeVisible();
  await expect(page.getByRole("link", { name: "Review purchases" })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-06/purchases/review?filter=treatment",
  );
  await expect(page.getByRole("link", { name: "Download draft working" })).toHaveAttribute(
    "href",
    "/gst/1/2026-06/purchases/workings.xlsx",
  );
  await page.screenshot({ path: testInfo.outputPath("purchases-overview.png"), fullPage: true });
  await page.evaluate(() => {
    (window as unknown as { retained: boolean }).retained = true;
  });
  await page
    .getByRole("region", { name: "Sources" })
    .getByRole("link", { name: "View register" })
    .first()
    .click();
  await expect(page).toHaveURL(/register\?source=purchases$/);
  expect(await page.evaluate(() => (window as unknown as { retained: boolean }).retained)).toBe(
    true,
  );
  await expect(page.getByRole("cell", { name: "CN-002", exact: true })).toBeVisible();
  await expect(page.getByRole("cell", { name: "−₹20.00", exact: true })).toBeVisible();
});

test("source registers keep linked originals and search submits without losing typing", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/purchases/register?source=purchases");
  const search = page.getByRole("textbox", { name: "Search source entries" });
  await expect(page.getByRole("link", { name: "Review CN-002" })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-06/purchases/review/source1",
  );
  await page.getByRole("row").filter({ hasText: "CN-002" }).getByRole("cell").first().click();
  await expect(page).toHaveURL("/app/gst/1/2026-06/purchases/review/source1");
  await page.goBack();
  await search.pressSequentially("missing", { delay: 25 });
  await expect(search).toHaveValue("missing");
  await page.getByRole("button", { name: "Search", exact: true }).click();
  await expect(page.getByText("No source entries match this search.")).toBeVisible();
  await page.getByRole("button", { name: "Clear search" }).click();
  await page
    .getByRole("navigation", { name: "Register source" })
    .getByRole("link", { name: "GSTR-2B", exact: true })
    .click();
  await expect(page).toHaveURL(/source=gstr2b$/);
  await expect(page.getByRole("heading", { name: "GSTR-2B register" })).toBeVisible();
  await expect(page.getByRole("cell", { name: "B-001", exact: true })).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({
    path: testInfo.outputPath("purchases-register-narrow.png"),
    fullPage: true,
  });
});

test("long search links use the server's supported length", async ({ page }) => {
  await setup(page);
  await page.goto(`/app/gst/1/2026-06/purchases/register?source=purchases&q=${"x".repeat(220)}`);
  await expect(page.getByRole("textbox", { name: "Search source entries" })).toHaveValue(
    "x".repeat(200),
  );
  await expect(page.getByText("No source entries match this search.")).toBeVisible();
  await expect(page.getByText("Searching source entries…")).toHaveCount(0);
});

test("register sorts signed GST, dates and vendors with compact accessible headers", async ({
  page,
}, info) => {
  const data = workspace();
  data.rows[0].vendor = "Zulu Supplies";
  data.rows[1].vendor = "Alpha Supplies";
  data.rows.push({
    ...data.rows[0],
    id: "source3",
    number: "BIG-003",
    vendor: "Middle Supplies",
    date: null,
    tax: "₹1,20,000.00",
    tax_paise: 12000000,
  });
  await setup(page, data);
  await page.goto("/app/gst/1/2026-06/purchases/register?source=gstr2b");
  const invoices = () => page.locator("tbody tr td:first-child").allTextContents();
  await expect.poll(invoices).toEqual(["B-001", "CN-002", "BIG-003"]);
  await expect(page.getByText("Two source entries linked during review")).toHaveCount(0);
  const gst = page.getByRole("button", { name: "Sort by GST", exact: true });
  await gst.click();
  await expect.poll(invoices).toEqual(["BIG-003", "B-001", "CN-002"]);
  await expect(page.getByRole("columnheader", { name: "Sort by GST" })).toHaveAttribute(
    "aria-sort",
    "descending",
  );
  await gst.focus();
  await page.keyboard.press("Enter");
  await expect.poll(invoices).toEqual(["CN-002", "B-001", "BIG-003"]);
  await gst.click();
  await expect.poll(invoices).toEqual(["B-001", "CN-002", "BIG-003"]);
  await page.getByRole("button", { name: "Sort by Date", exact: true }).click();
  await expect.poll(invoices).toEqual(["CN-002", "B-001", "BIG-003"]);
  await page.getByRole("button", { name: "Sort by Date", exact: true }).click();
  await expect.poll(invoices).toEqual(["B-001", "CN-002", "BIG-003"]);
  await page.getByRole("button", { name: "Sort by Vendor", exact: true }).click();
  await expect.poll(invoices).toEqual(["CN-002", "BIG-003", "B-001"]);
  await page.getByRole("button", { name: "Matched", exact: true }).first().hover();
  await expect(page.getByText("Two source entries linked during review")).toBeVisible();
  await page.getByRole("button", { name: "Matched", exact: true }).first().click();
  await expect(page).toHaveURL(/\/purchases\/register\?source=gstr2b$/);
  await page.getByRole("heading", { name: "GSTR-2B register" }).hover();
  await page.screenshot({ path: info.outputPath("compact-register.png"), fullPage: true });
});

test("register does not claim unmatched invoices when books are missing", async ({ page }) => {
  const data = workspace();
  data.overview.comparison_available = false;
  await setup(page, data);
  await page.goto("/app/gst/1/2026-06/purchases/register?source=gstr2b");
  await expect(page.getByRole("cell", { name: "Not compared", exact: true })).toHaveCount(2);
  await expect(page.getByText("Import both sources", { exact: false })).toBeVisible();
});

test("GSTR-2B treatment stays available without purchase books", async ({ page }, testInfo) => {
  const data = workspace();
  data.inputs.books = { present: false, count: 0, tax: "₹0.00" };
  data.overview.comparison_available = false;
  data.overview.itc.recorded = false;
  data.working.status = "Draft working";
  await setup(page, data);
  await page.goto("/app/gst/1/2026-06/purchases");
  await expect(
    page.getByText("Review GSTR-2B to record ITC decisions.", { exact: false }),
  ).toBeVisible();
  await expect(page.getByRole("link", { name: "Review purchases" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Open reconciliation" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Import purchase Excel" })).toHaveAttribute(
    "href",
    data.links.import_excel,
  );
  await expect(page.getByRole("link", { name: "View register" })).toHaveCount(1);
  await expect(page.getByRole("link", { name: "View register" })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-06/purchases/register?source=gstr2b",
  );
  await expect(page.getByRole("link", { name: "Download draft working" })).toBeVisible();
  await expect(
    page.getByText("Purchase register not imported. Reconciliation is pending."),
  ).toBeVisible();
  await expect(
    page.getByRole("region", { name: "Sources" }).getByText("GST", { exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("columnheader", { name: "Books tax" })).toHaveCount(0);
  await expect(page.getByText("Claim", { exact: true })).toHaveCount(0);
  await page.screenshot({ path: testInfo.outputPath("portal-only-overview.png"), fullPage: true });
  await page.getByRole("link", { name: "Review purchases" }).click();
  await expect(page).toHaveURL("/app/gst/1/2026-06/purchases/review?filter=treatment");
});

test("empty overview offers imports without empty review or register links", async ({ page }) => {
  const data = workspace();
  data.inputs.books = { present: false, count: 0, tax: "₹0.00" };
  data.inputs.portal = { ...data.inputs.portal, present: false, count: 0 };
  data.overview.comparison_available = false;
  data.overview.itc.carried_count = 0;
  await setup(page, data);
  await page.goto("/app/gst/1/2026-06/purchases");
  await expect(page.getByRole("heading", { name: "Purchases & ITC", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Review purchases" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "View register" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Open reconciliation" })).toHaveCount(0);
});

test("month controls preserve source and search", async ({ page }) => {
  await page.route("**/api/workspace/purchases/1/*?*", (route) => {
    const url = new URL(route.request().url());
    const period = url.pathname.split("/").at(-1)!;
    return route.fulfill({
      json: {
        ...workspace(),
        period,
        q: url.searchParams.get("q") ?? "",
        month_label: period,
        filter: "gstr2b",
      },
    });
  });
  await page.goto("/app/gst/1/2026-06/purchases/register?source=gstr2b&q=Supplier");
  await page.getByRole("button", { name: "Previous month" }).click();
  await expect(page).toHaveURL(/2026-05\/purchases\/register\?source=gstr2b&q=Supplier$/);
  await page.getByRole("button", { name: "Choose month" }).click();
  await page.getByRole("button", { name: "July 2026", exact: true }).click();
  await expect(page).toHaveURL(/2026-07\/purchases\/register\?source=gstr2b&q=Supplier$/);
});

test("read-only and unavailable working reasons remain visible", async ({ page }) => {
  const data = workspace();
  data.can_edit = false;
  data.signed_off = true;
  data.lock_reason = "This month is signed off. Review is read-only.";
  data.working.enabled = false;
  data.working.reason = "Your role cannot download workings.";
  await setup(page, data);
  await page.goto("/app/gst/1/2026-06/purchases");
  await expect(page.getByText(data.lock_reason)).toBeVisible();
  await expect(page.getByRole("button", { name: "Import Excel" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Download working" })).toBeDisabled();
  await expect(page.getByText(data.working.reason)).toBeVisible();
});

test("API access errors do not look like empty books", async ({ page }) => {
  await page.route("**/api/workspace/purchases/**", (route) =>
    route.fulfill({ status: 403, json: { error: "You cannot view this client." } }),
  );
  await page.goto("/app/gst/1/2026-06/purchases");
  await expect(page.getByRole("alert")).toHaveText("You cannot view this client.");
  await expect(page.getByText("No source documents yet")).toHaveCount(0);
});
