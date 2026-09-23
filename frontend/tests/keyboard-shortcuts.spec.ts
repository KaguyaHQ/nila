import { expect, test, type Page } from "@playwright/test";
import type { SalesWorkspace } from "../src/lib/sales-api";
import type { PurchasesWorkspace } from "../src/lib/purchases-api";
import type { SalesInvoiceReviewData } from "../src/lib/sales-review-api";

const client = { id: 2, name: "Harbour Services" };
const user = { name: "Accountant", org: "Test firm" };
function sales(period: string): SalesWorkspace {
  const base = `/gst/2/${period}/sales`;
  return {
    details: {},
    exports: { items: [], blockers: [], status: "No exports available." },
    client,
    clients: [client],
    user,
    period,
    month_label: period,
    can_upload: true,
    deadline: "2026-07-11",
    invoice_count: 0,
    review_count: 0,
    month_issue_count: 0,
    taxable: "₹0.00",
    tax: "₹0.00",
    uploads: { files: 0, unfinished: false },
    rows: [],
    sections: [],
    links: {
      upload: `${base}/upload`,
      uploads: `${base}/uploads`,
      working: base,
      purchases: `/gst/2/${period}/purchases`,
    },
  };
}
function purchases(period: string, q: string): PurchasesWorkspace {
  const base = `/gst/2/${period}/purchases`;
  return {
    client: { ...client, gstin: null },
    clients: [client],
    user,
    period,
    month_label: period,
    can_edit: true,
    signed_off: false,
    lock_reason: null,
    processing: false,
    inputs: {
      books: { present: false, count: 0, tax: "₹0.00" },
      portal: { present: false, count: 0, tax: "₹0.00", fetching: false, needs_import: false },
    },
    overview: {
      complete: false,
      comparison_available: false,
      remaining: 0,
      buckets: [],
      itc: {
        recorded: false,
        claim: "₹0.00",
        later: "₹0.00",
        excluded: "₹0.00",
        pending: "₹0.00",
        carried_count: 0,
        stale_count: 0,
      },
    },
    filters: [],
    filter: "register",
    q,
    rows: [],
    carried: [],
    working: {
      enabled: false,
      url: `${base}/workings.xlsx`,
      status: "Draft working",
      reason: "No sources yet",
    },
    links: {
      import_excel: `${base}/import-excel`,
      uploads: `${base}/uploads`,
      portal: base,
      review: `${base}/review`,
      treatment: `${base}/review?filter=treatment`,
      carried: `${base}/review?filter=carried`,
    },
    notice: "",
  };
}
function invoice(id: string): SalesInvoiceReviewData {
  return {
    client,
    period: "2026-06",
    invoice: {
      id,
      number: id,
      date: "2026-06-10",
      buyer_name: "Customer",
      buyer_gstin: "",
      place_of_supply: "Not determined",
    },
    facts: {},
    lines: [],
    totals: [],
    printed_totals: {},
    checks: [],
    issues: [],
    source: null,
    states: [],
    queue: [
      { id: "one", number: "one", status: "needs_review" },
      { id: "two", number: "two", status: "needs_review" },
    ],
    can_edit: true,
    lock_reason: null,
    editable_fields: { facts: [], line: [], totals: [] },
  };
}
async function setup(page: Page) {
  await page.route("**/api/workspace/sales/2/**", (route) => {
    const parts = new URL(route.request().url()).pathname.split("/");
    return route.fulfill({ json: parts[6] === "invoices" ? invoice(parts[7]) : sales(parts[5]) });
  });
  await page.route("**/api/workspace/purchases/2/**", (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith("/gstr2b"))
      return route.fulfill({
        json: {
          client: { ...client, gstin: null },
          period: url.pathname.split("/")[5],
          connection: { state: "missing_gstin", username: null },
          permissions: { fetch: false, connect: false, export: true },
          statement: null,
          fetching: false,
          import: { needed: false, status: null, error: null },
          availability_hint: null,
        },
      });
    return route.fulfill({
      json: purchases(url.pathname.split("/")[5], url.searchParams.get("q") ?? ""),
    });
  });
  await page.route(/\/api\/workspace\/clients(?:\?.*)?$/, (route) =>
    route.fulfill({
      json: {
        clients: [{ ...client, gstin: null, sales_path: "/gst/2/2026-06/sales" }],
        user,
        can_edit: true,
        period: "2026-06",
      },
    }),
  );
}
async function ready(page: Page) {
  await expect(page.getByRole("button", { name: "Keyboard shortcuts", exact: true })).toBeVisible();
  await page.locator("body").click({ position: { x: 1, y: 1 } });
}
async function pressSequence(page: Page, second: string) {
  await page.keyboard.press("g");
  await page.keyboard.press(second);
}

for (const area of ["sales", "purchases"] as const) {
  test(`${area} month shortcuts preserve client, register and search within bounds`, async ({
    page,
  }) => {
    await setup(page);
    const search = area === "sales" ? "q=Supplier&filter=ready" : "source=gstr2b&q=Supplier";
    await page.goto(`/app/gst/2/2026-06/${area}/register?${search}`);
    await ready(page);
    await page.evaluate(() => {
      (window as unknown as { shortcutDocument: boolean }).shortcutDocument = true;
    });
    await page.keyboard.press("[");
    await expect(page).toHaveURL(`/app/gst/2/2026-05/${area}/register?${search}`);
    await ready(page);
    await page.keyboard.press("]");
    await expect(page).toHaveURL(`/app/gst/2/2026-06/${area}/register?${search}`);
    expect(
      await page.evaluate(
        () => (window as unknown as { shortcutDocument: boolean }).shortcutDocument,
      ),
    ).toBe(true);
    await page.goto(`/app/gst/2/2017-07/${area}`);
    await ready(page);
    await page.keyboard.press("[");
    await expect(page).toHaveURL(`/app/gst/2/2017-07/${area}`);
    const current = new Date().toISOString().slice(0, 7);
    await page.goto(`/app/gst/2/${current}/${area}`);
    await ready(page);
    await page.keyboard.press("]");
    await expect(page).toHaveURL(`/app/gst/2/${current}/${area}`);
  });
}

test("g s and g p switch workspace without losing client or month", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales/register?q=Supplier");
  await ready(page);
  await page.evaluate(() => {
    (window as unknown as { shortcutDocument: boolean }).shortcutDocument = true;
  });
  await pressSequence(page, "p");
  await expect(page).toHaveURL("/app/gst/2/2026-06/purchases");
  await ready(page);
  await pressSequence(page, "s");
  await expect(page).toHaveURL("/app/gst/2/2026-06/sales");
  expect(
    await page.evaluate(
      () => (window as unknown as { shortcutDocument: boolean }).shortcutDocument,
    ),
  ).toBe(true);
  // A stale first key must not turn a later ordinary letter into navigation.
  await page.keyboard.press("g");
  await page.waitForTimeout(1100);
  await page.keyboard.press("p");
  await expect(page).toHaveURL("/app/gst/2/2026-06/sales");
});

test("slash focuses each search and shortcuts leave typing and special key events alone", async ({
  page,
}) => {
  await setup(page);
  for (const [path, label] of [
    ["/app/gst/2/2026-06/sales/register", "Search customer, invoice or GSTIN"],
    ["/app/gst/2/2026-06/purchases/register?source=purchases", "Search source entries"],
    ["/app/clients", "Search clients"],
  ]) {
    await page.goto(path);
    await ready(page);
    await page.keyboard.press("/");
    const search = page.getByRole("textbox", { name: label });
    await expect(search).toBeFocused();
    await search.pressSequentially("[]gp?/");
    await expect(page.getByRole("dialog")).toHaveCount(0);
    expect(new URL(page.url()).pathname).toBe(path.split("?")[0]);
  }
  await page.goto("/app/gst/2/2026-06/sales");
  await ready(page);
  await page.evaluate(() => {
    for (const details of [
      { repeat: true },
      { isComposing: true },
      { ctrlKey: true },
      { metaKey: true },
      { altKey: true },
    ]) {
      document.body.dispatchEvent(
        new KeyboardEvent("keydown", { key: "]", bubbles: true, ...details }),
      );
    }
    const editor = document.createElement("div");
    editor.contentEditable = "true";
    editor.id = "shortcut-editable";
    document.body.append(editor);
    editor.focus();
    editor.dispatchEvent(new KeyboardEvent("keydown", { key: "]", bubbles: true }));
  });
  await expect(page).toHaveURL("/app/gst/2/2026-06/sales");
  await page.getByLabel("Switch client: Harbour Services", { exact: true }).focus();
  await page.keyboard.press("]");
  await expect(page).toHaveURL("/app/gst/2/2026-06/sales");
});

test("compact help blocks navigation and ignores the retired disable preference", async ({
  page,
}) => {
  await setup(page);
  await page.addInitScript(() => localStorage.setItem("nila-shortcuts-enabled", "false"));
  await page.goto("/app/gst/2/2026-06/sales");
  await ready(page);
  await page.keyboard.press("?");
  const dialog = page.getByRole("dialog", { name: "Keyboard shortcuts" });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("checkbox")).toHaveCount(0);
  await expect(dialog.locator('[data-slot="kbd"]')).toHaveCount(14);
  await page.keyboard.press("]");
  await pressSequence(page, "p");
  await expect(page).toHaveURL("/app/gst/2/2026-06/sales");
  await page.screenshot({ path: "test-results/shortcuts-desktop.png", animations: "disabled" });
  await page.setViewportSize({ width: 390, height: 700 });
  await expect(dialog).toBeInViewport();
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
  ).toBeTruthy();
  await page.screenshot({ path: "test-results/shortcuts-mobile.png", animations: "disabled" });
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await ready(page);
  await page.keyboard.press("]");
  await expect(page).toHaveURL("/app/gst/2/2026-07/sales");
});

test("invoice Alt arrows pause in help and resume after closing", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales/invoices/one");
  await ready(page);
  await page.keyboard.press("Alt+ArrowRight");
  await expect(page).toHaveURL(/\/invoices\/two$/);
  await ready(page);
  await page.keyboard.press("?");
  const dialog = page.getByRole("dialog", { name: "Keyboard shortcuts" });
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Alt+ArrowLeft");
  await expect(page).toHaveURL(/\/invoices\/two$/);
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await ready(page);
  await page.keyboard.press("Alt+ArrowLeft");
  await expect(page).toHaveURL(/\/invoices\/one$/);
});
