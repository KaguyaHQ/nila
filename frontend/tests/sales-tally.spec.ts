import { expect, test, type Page } from "@playwright/test";
import type { SalesWorkspace } from "../src/lib/sales-api";
import type { SalesInvoiceReviewData } from "../src/lib/sales-review-api";
import type { TallySalesData, EnabledTallySalesData } from "../src/lib/sales-tally-api";

const month: SalesWorkspace = {
  client: { id: 1, name: "Breeze Tech" },
  clients: [{ id: 1, name: "Breeze Tech" }],
  user: { name: "Staff", org: "Firm" },
  period: "2026-08",
  month_label: "August 2026",
  can_upload: true,
  deadline: "2026-09-11",
  invoice_count: 1,
  review_count: 0,
  month_issue_count: 0,
  taxable: "₹15,000.00",
  tax: "₹2,050.00",
  uploads: { files: 1, unfinished: false },
  rows: [
    {
      id: "one",
      number: "75/2026-27",
      customer: "Philips India Ltd",
      date: "2026-08-26",
      gstin: "33AABCP9487A1ZG",
      status: "ready",
      taxable: "₹15,000.00",
      tax: "₹2,050.00",
      reason: "",
      path: "/gst/1/2026-08/sales/invoices/one",
    },
  ],
  sections: [],
  details: {},
  exports: { items: [], blockers: [], status: "" },
  links: { upload: "", uploads: "", working: "", purchases: "" },
};
const tally: EnabledTallySalesData = {
  enabled: true,
  company: { id: 7, name: "BREEZE TECH ( SERVICE ONLY )", is_open: true },
  ready_count: 1,
  ready_total: "17050.00",
  can_post: true,
  can_edit: true,
  can_refresh: true,
  sync: {
    status: "succeeded",
    run_id: 1,
    period_start: "2026-08-01",
    period_end: "2026-08-31",
    last_completed_at: "2026-10-04T06:00:00Z",
    error: null,
    covered: true,
  },
  tax_choices_by_head: { cgst: [], sgst: [], igst: [] },
  ledger_choices: [],
  party_choices: [],
  sales_ledger_choices: [],
  tax_ledger_choices: [],
  preview_token: "reviewed-preview",
  proposals: [
    {
      source_id: "one",
      number: "75/2026-27",
      date: "2026-08-26",
      status: "ready",
      party_ledger: { identity: "party", name: "Philips India Ltd" },
      sales_entries: [
        {
          line_id: "0",
          description: "AC servicing",
          ledger_identity: "sales18",
          ledger_name: "GST Labour Charges @ 18%",
          amount: "10000.00",
        },
        {
          line_id: "1",
          description: "Service charge",
          ledger_identity: "sales5",
          ledger_name: "GST Labour Charges @ 5%",
          amount: "5000.00",
        },
      ],
      sales_summary: [
        { line_ids: ["0"], ledger_identity: "sales18", ledger_name: "GST Labour Charges @ 18%", amount: "10000.00" },
        { line_ids: ["1"], ledger_identity: "sales5", ledger_name: "GST Labour Charges @ 5%", amount: "5000.00" },
      ],
      tax_entries: [
        { head: "cgst", ledger_identity: "cgst", ledger_name: "Output CGST", amount: "1025.00" },
        { head: "sgst", ledger_identity: "sgst", ledger_name: "Output SGST", amount: "1025.00" },
      ],
      grand_total: "17050.00",
      issues: [],
    },
  ],
};
async function setup(page: Page, data: TallySalesData = tally) {
  await page.route("**/api/workspace/sales/1/2026-08", (route) => route.fulfill({ json: month }));
  await page.route("**/api/workspace/sales/1/2026-08/tally", (route) =>
    route.fulfill({ json: data }),
  );
}

test("searching one customer keeps the all-ready posting scope explicit", async ({ page }) => {
  const data = structuredClone(tally);
  data.proposals.push({ ...structuredClone(data.proposals[0]), source_id: "two", number: "76/2026-27", party_ledger: { identity: "other-party", name: "Different Ltd" } });
  data.ready_count = 2;
  data.ready_total = "34100.00";
  await setup(page, data);
  await page.route("**/api/workspace/sales/1/2026-08", route => route.fulfill({ json: {
    ...month, rows: [...month.rows, { ...month.rows[0], id: "two", number: "76/2026-27", customer: "Different Ltd" }],
  } }));
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries&selected=one&q=Philips");
  await expect(page.getByText("Showing 1 of 2 invoices", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Post all 2 ready entries", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("All 2 ready entries for August 2026");
  await expect(dialog).toContainText("Includes entries hidden by search or filters.");
  await expect(dialog.getByText("Different Ltd", { exact: true })).toBeVisible();
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
});

test("register groups repeated ledger allocations without hiding the tax rows", async ({ page }) => {
  const data = structuredClone(tally);
  const longLedger = "GST SERVICES LABOURS @ 18 % ( 29033990)";
  data.proposals[0].sales_summary = [{ ledger_identity: "sales18", ledger_name: longLedger, line_ids: ["0", "1"], amount: "15000.00" }];
  data.sales_ledger_choices = [{ identity: "sales18", name: longLedger }, { identity: "replacement", name: "Other service sales" }];
  await setup(page, data);
  const writes: unknown[] = [];
  await page.route("**/api/workspace/sales/1/2026-08/invoices/one/tally", async (route) => {
    writes.push(route.request().postDataJSON());
    await route.fulfill({ json: data });
  });
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries&selected=one");
  const entry = page.getByRole("region", { name: "Proposed Tally entry", exact: true });
  await expect(entry.getByText("2 bill lines", { exact: true })).toBeVisible();
  await expect(entry.getByText("₹15,000.00", { exact: true })).toBeVisible();
  await expect(entry.getByText("Output CGST", { exact: true })).toBeVisible();
  await expect(entry.getByRole("link", { name: "Check against bill", exact: true })).toBeVisible();
  await expect(entry.getByText("75/2026-27", { exact: true })).toHaveCount(0);
  await entry.getByRole("button", { name: "Change Sales ledger for all 2 bill lines", exact: true }).click();
  const bounds = await entry.evaluate((node) => {
    const table = node.querySelector('[data-slot="table-container"]')!;
    const row = node.querySelector('tbody tr')!;
    const cell = row.querySelector('td')!.getBoundingClientRect();
    const cancel = [...row.querySelectorAll('button')].find(button => button.textContent === 'Cancel')!.getBoundingClientRect();
    const amount = row.querySelectorAll('td')[1].getBoundingClientRect();
    return { scroll: table.scrollWidth, width: table.clientWidth, cancelRight: cancel.right, cellRight: cell.right, amountRight: amount.right, tableRight: table.getBoundingClientRect().right };
  });
  expect(bounds.scroll).toBeLessThanOrEqual(bounds.width + 1);
  expect(bounds.cancelRight).toBeLessThanOrEqual(bounds.cellRight);
  expect(bounds.amountRight).toBeLessThanOrEqual(bounds.tableRight + 1);
  await page.getByRole("option", { name: "Other service sales", exact: true }).click();
  await expect(entry.getByText("Ledger choice saved.", { exact: true })).toBeVisible();
  expect(writes).toEqual([{ line_sales_ledger_identities: { "0": "replacement", "1": "replacement" }, preview_token: "reviewed-preview" }]);
});

test("suggested ledger needs explicit confirmation and inline changes survive bill review", async ({
  page,
}, info) => {
  let data: EnabledTallySalesData = structuredClone(tally);
  data.can_post = false;
  data.ready_count = 0;
  data.sales_ledger_choices = [
    { identity: "suggested", name: "Service Charges 18%" },
    { identity: "other", name: "Other Sales 18%" },
  ];
  const first = data.proposals[0].sales_entries[0];
  first.ledger_identity = null;
  first.ledger_name = null;
  first.suggested_ledger_identity = "suggested";
  first.suggested_ledger_name = "Service Charges 18%";
  first.basis =
    "This ledger matches the bill's HSN and tax rate. Confirm its use for this customer.";
  data.proposals[0].status = "needs_input";
  data.proposals[0].issues = ["Confirm the suggested sales ledger."];
  await setup(page, data);
  const writes: unknown[] = [];
  await page.route("**/api/workspace/sales/1/2026-08/tally", (route) =>
    route.fulfill({ json: data }),
  );
  await page.route("**/api/workspace/sales/1/2026-08/invoices/one/tally", (route) => {
    const changes = route.request().postDataJSON();
    writes.push(changes);
    const identity = changes.line_sales_ledger_identities["0"];
    data = structuredClone(data);
    data.proposals[0].sales_entries[0].ledger_identity = identity;
    data.proposals[0].sales_entries[0].ledger_name = data.sales_ledger_choices.find(
      (choice) => choice.identity === identity,
    )!.name;
    data.proposals[0].status = "ready";
    data.proposals[0].issues = [];
    data.ready_count = 1;
    data.can_post = true;
    return route.fulfill({ json: data });
  });
  const review: SalesInvoiceReviewData = {
    client: month.client,
    period: month.period,
    invoice: {
      id: "one",
      number: "75/2026-27",
      date: "2026-08-26",
      buyer_name: "Philips India Ltd",
      buyer_gstin: "33AABCP9487A1ZG",
      place_of_supply: "Tamil Nadu",
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
      {
        id: "one",
        number: "75/2026-27",
        customer: "Philips India Ltd",
        status: "ready",
        issue_codes: [],
      },
    ],
    can_edit: true,
    lock_reason: null,
    editable_fields: { facts: [], line: [], totals: [] },
  };
  await page.route("**/api/workspace/sales/1/2026-08/invoices/one?*", (route) =>
    route.fulfill({ json: review }),
  );
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries&selected=one");
  await expect(page.getByText("Suggested: Service Charges 18%", { exact: true })).toBeVisible();
  expect(writes).toEqual([]);
  await page
    .getByRole("button", { name: "Confirm Sales ledger for AC servicing", exact: true })
    .click();
  await expect(page.getByText("Ledger choice saved.", { exact: true })).toBeVisible();
  expect(writes).toEqual([
    { line_sales_ledger_identities: { "0": "suggested" }, preview_token: "reviewed-preview" },
  ]);
  await page
    .getByRole("button", { name: "Change Sales ledger for AC servicing", exact: true })
    .click();
  const search = page.getByRole("combobox", { name: "Search sales ledger for ac servicing", exact: true });
  await search.fill("no matching ledger");
  await expect(page.getByText("No ledgers found.", { exact: true })).toBeVisible();
  await search.press("Escape");
  expect(writes).toHaveLength(1);
  await page.getByLabel("Sales ledger for AC servicing", { exact: true }).click();
  await expect(search).toHaveValue("");
  await search.fill("other");
  await expect(page.getByRole("option", { name: "Service Charges 18%", exact: true })).toHaveCount(0);
  await search.press("ArrowDown");
  await search.press("Enter");
  await expect(page.getByText("Other Sales 18%", { exact: true })).toBeVisible();
  expect(writes).toHaveLength(2);
  await page.getByRole("link", { name: "Check against bill", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Bill details", exact: true })).toHaveCount(0);
  await expect(page.getByText("Ready to post", { exact: true })).toHaveCount(1);
  await expect(page.getByRole("button", { name: "Previous invoice", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Next invoice", exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("tally-inline-ledgers.png"), fullPage: true });
  await page.getByRole("link", { name: /Back to register/ }).click();
  await expect(page.getByText("Other Sales 18%", { exact: true })).toBeVisible();
  expect(writes).toHaveLength(2);
});

test("stale suggestion refreshes its evidence and requires another explicit confirmation", async ({
  page,
}) => {
  let data: EnabledTallySalesData = structuredClone(tally);
  data.proposals[0].status = "needs_input";
  const entry = data.proposals[0].sales_entries[0];
  entry.ledger_identity = null;
  entry.ledger_name = null;
  entry.suggested_ledger_identity = "suggested";
  entry.suggested_ledger_name = "Service Charges 18%";
  await setup(page, data);
  const writes: { preview_token: string }[] = [];
  await page.route("**/api/workspace/sales/1/2026-08/tally", (route) =>
    route.fulfill({ json: data }),
  );
  await page.route("**/api/workspace/sales/1/2026-08/invoices/one/tally", (route) => {
    writes.push(route.request().postDataJSON());
    if (writes.length === 1) {
      data = structuredClone(data);
      data.preview_token = "fresh-preview";
      data.proposals[0].sales_entries[0].suggested_ledger_name = "Revised Service Charges 18%";
      return route.fulfill({ status: 409, json: { error: "invalid_mapping" } });
    }
    data = structuredClone(data);
    data.proposals[0].sales_entries[0].ledger_identity = "suggested";
    data.proposals[0].sales_entries[0].ledger_name = "Revised Service Charges 18%";
    data.proposals[0].status = "ready";
    return route.fulfill({ json: data });
  });
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries&selected=one");
  const confirm = page.getByRole("button", {
    name: "Confirm Sales ledger for AC servicing",
    exact: true,
  });
  await confirm.click();
  await expect(page.getByRole("alert")).toContainText("Review the refreshed entry");
  await expect(
    page.getByText("Suggested: Revised Service Charges 18%", { exact: true }),
  ).toBeVisible();
  expect(writes.map((item) => item.preview_token)).toEqual(["reviewed-preview"]);
  await confirm.click();
  await expect(page.getByText("Ledger choice saved.", { exact: true })).toBeVisible();
  expect(writes.map((item) => item.preview_token)).toEqual(["reviewed-preview", "fresh-preview"]);
});

test("Refresh from Tally requests the selected month and waits for completed snapshot", async ({
  page,
}, info) => {
  await setup(page);
  const before: EnabledTallySalesData = {
    ...tally,
    ready_count: 0,
    can_post: false,
    proposals: tally.proposals.map((item) => ({
      ...item,
      status: "needs_input",
      issues: ["This invoice already exists in Tally."],
    })),
  };
  const running: EnabledTallySalesData = {
    ...before,
    can_refresh: false,
    sync: { ...before.sync, status: "running", run_id: 2, covered: false },
  };
  const completed: EnabledTallySalesData = {
    ...tally,
    sync: { ...tally.sync, period_start: "2025-08-01", run_id: 2, last_completed_at: "2026-10-04T07:00:00Z" },
  };
  const calls: string[] = [];
  let started = false;
  let finished = false;
  await page.route("**/api/workspace/sales/1/2026-08/tally", (route) =>
    route.fulfill({ json: started ? (finished ? completed : running) : before }),
  );
  await page.route("**/api/workspace/sales/1/2026-08/tally/sync", (route) => {
    calls.push(`${route.request().method()} ${new URL(route.request().url()).pathname}`);
    expect(route.request().postData()).toBeNull();
    started = true;
    return route.fulfill({ json: running });
  });
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries&selected=one");
  await expect(
    page.getByText("This invoice already exists in Tally.", { exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Refresh from Tally", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Refreshing from Tally…", exact: true }),
  ).toBeDisabled();
  await expect(page.getByRole("button", { name: "Post all 0 ready entries", exact: true })).toBeDisabled();
  await expect(
    page.getByText("This invoice already exists in Tally.", { exact: true }),
  ).toBeVisible();
  expect(calls).toEqual(["POST /api/workspace/sales/1/2026-08/tally/sync"]);
  finished = true;
  await expect(page.getByRole("button", { name: "Post all 1 ready entries", exact: true })).toBeEnabled();
  await expect(
    page.getByText("This invoice already exists in Tally.", { exact: true }),
  ).toHaveCount(0);
  await expect(page.getByText(/Books 1 Aug 2025–31 Aug 2026/)).not.toBeVisible();
  await page.getByRole("button", { name: "Tally sync details", exact: true }).click();
  await expect(page.getByText(/Books 1 Aug 2025–31 Aug 2026/)).toBeVisible();
  await expect(page.getByText(/Updated 4 Oct 2026/)).toBeVisible();
  await page.screenshot({ path: info.outputPath("tally-refresh-completed.png"), fullPage: true });
});

test("Refresh from Tally explains offline and failed requests", async ({ page }) => {
  await setup(page, { ...tally, can_refresh: false, sync: { ...tally.sync, status: "offline" } });
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries");
  await expect(
    page.getByRole("button", { name: "Refresh from Tally", exact: true }),
  ).toBeDisabled();
  await expect(page.getByText(/Nila Connector is offline/)).toBeVisible();
  await page.route("**/api/workspace/sales/1/2026-08/tally", (route) =>
    route.fulfill({ json: tally }),
  );
  await page.route("**/api/workspace/sales/1/2026-08/tally/sync", (route) =>
    route.fulfill({
      status: 503,
      json: { error: "The connector stopped before the refresh could start." },
    }),
  );
  await page.reload();
  await page.getByRole("button", { name: "Refresh from Tally", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "The connector stopped before the refresh could start.",
  );
  await page.getByRole("button", { name: "Tally sync details", exact: true }).click();
  await expect(page.getByText(/Books 1 Aug 2026–31 Aug 2026/)).toBeVisible();
});

test("shows every ledger allocation and posts only after explicit confirmation", async ({
  page,
}, info) => {
  await setup(page);
  const writes: unknown[] = [];
  let completed = false;
  await page.route("**/api/workspace/sales/1/2026-08/tally", (route) => {
    if (route.request().method() === "POST") {
      writes.push(route.request().postDataJSON());
      return route.fulfill({
        json: {
          queued_count: 1,
          tally: {
            ...tally,
            ready_count: 0,
            ready_total: "0.00",
            can_post: false,
            proposals: tally.proposals.map((item) => ({ ...item, status: "pending" })),
          },
        },
      });
    }
    return route.fulfill({ json: completed ? {
      ...tally, ready_count: 0, ready_total: "0.00", can_post: false,
      proposals: tally.proposals.map(item => ({ ...item, status: "posted" })),
    } : tally });
  });
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries&selected=one");
  const entry = page.getByRole("region", { name: "Proposed Tally entry" });
  await expect(entry.getByText("GST Labour Charges @ 18%", { exact: true })).toBeVisible();
  await expect(entry.getByText("GST Labour Charges @ 5%", { exact: true })).toBeVisible();
  await expect(entry.getByText("Output CGST", { exact: true })).toBeVisible();
  expect(writes).toHaveLength(0);
  await page.screenshot({ path: info.outputPath("tally-register.png"), fullPage: true });
  await page.getByRole("button", { name: "Post all 1 ready entries", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("BREEZE TECH ( SERVICE ONLY )", { exact: false })).toBeVisible();
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
  expect(writes).toHaveLength(0);
  await page.getByRole("button", { name: "Post all 1 ready entries", exact: true }).click();
  await dialog.getByRole("button", { name: "Confirm posting", exact: true }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "Posting to Tally… 0 posted, 1 remaining." }),
  ).toBeVisible();
  expect(writes).toEqual([
    { company_id: 7, invoice_ids: ["one"], preview_token: "reviewed-preview" },
  ]);
  completed = true;
  await expect(page.getByRole("status").filter({ hasText: "1 entry posted to Tally." })).toBeVisible();
  const completionToast = page.locator('[data-slot="toast"]');
  await expect(completionToast).toHaveCount(1);
  await expect(completionToast).toContainText("1 entry posted to Tally");
  await page.screenshot({ path: info.outputPath("posting-success-toast.png"), animations: "disabled" });
  await completionToast.locator('[data-slot="toast-close"]').click();
  await expect(page.getByRole("button", { name: "Post all 0 ready entries", exact: true })).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("status").filter({ hasText: "1 entry posted to Tally." })).toBeVisible();
  await expect(page.locator('[data-slot="toast"]')).toHaveCount(0);
});

test("partial posting shows a warning toast and keeps the failure visible", async ({ page }) => {
  const data = structuredClone(tally);
  data.proposals.push({ ...structuredClone(data.proposals[0]), source_id: "two", number: "76/2026-27" });
  data.ready_count = 2;
  await setup(page, data);
  await page.route("**/api/workspace/sales/1/2026-08/tally", route => route.fulfill({ json: route.request().method() === "POST" ? {
    queued_count: 2,
    tally: { ...data, ready_count: 0, ready_total: "0.00", can_post: false,
      proposals: data.proposals.map((item, index) => ({ ...item, status: index ? "failed" : "posted" })),
    },
  } : data }));
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries");
  await page.getByRole("button", { name: "Post all 2 ready entries", exact: true }).click();
  await page.getByRole("button", { name: "Confirm posting", exact: true }).click();
  await expect(page.locator('[data-slot="toast"]')).toContainText("1 posted · 1 need attention");
  await expect(page.getByRole("alert").filter({ hasText: "1 failed." })).toBeVisible();
  await expect(page.locator('[data-slot="toast"]').getByText("2 entries posted to Tally", { exact: true })).toHaveCount(0);
});

test("GST-only clients have no Tally workflow controls", async ({ page }) => {
  await setup(page, { enabled: false });
  await page.goto("/app/gst/1/2026-08/sales/register");
  await expect(page.getByRole("heading", { name: "Sales register", exact: true })).toBeVisible();
  await expect(page.getByRole("group", { name: "Sales review task" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /Post .* to Tally/ })).toHaveCount(0);
});

test("Tally entry queue excludes existing books-only rows while GST retains them", async ({
  page,
}) => {
  await setup(page);
  await page.route("**/api/workspace/sales/1/2026-08", (route) =>
    route.fulfill({
      json: {
        ...month,
        invoice_count: 2,
        rows: [
          ...month.rows,
          { ...month.rows[0], id: "books-only", number: "EXISTING-BOOKS-ENTRY", path: null },
        ],
      },
    }),
  );
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries");
  await expect(page.getByText("Showing 1 of 1 invoices", { exact: true })).toBeVisible();
  await expect(page.getByText("EXISTING-BOOKS-ENTRY", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "GST review", exact: true }).click();
  await expect(page.getByText("EXISTING-BOOKS-ENTRY", { exact: true })).toBeVisible();
  await expect(page.getByText("Showing 2 of 2 invoices", { exact: true })).toBeVisible();
});

test("uncertain posting is verified without posting another voucher", async ({ page }) => {
  await setup(page, {
    ...tally,
    ready_count: 0,
    ready_total: "0.00",
    can_post: false,
    proposals: tally.proposals.map((item) => ({ ...item, status: "unknown" })),
  });
  let verified = 0;
  const posts: unknown[] = [];
  await page.route("**/api/workspace/sales/1/2026-08/tally", (route) => {
    if (route.request().method() === "POST") posts.push(route.request().postDataJSON());
    return route.fulfill({
      json: {
        ...tally,
        ready_count: 0,
        ready_total: "0.00",
        can_post: false,
        proposals: tally.proposals.map((item) => ({ ...item, status: "unknown" })),
      },
    });
  });
  await page.route("**/api/workspace/sales/1/2026-08/tally/verify", (route) => {
    verified += 1;
    return route.fulfill({
      json: {
        queued_count: 1,
        tally: {
          ...tally,
          ready_count: 0,
          can_post: false,
          proposals: tally.proposals.map((item) => ({ ...item, status: "pending" })),
        },
      },
    });
  });
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries&selected=one");
  await expect(page.getByRole("button", { name: "Post all 0 ready entries", exact: true })).toHaveCount(0);
  await expect(page.getByRole("alert")).toContainText("1 need their posting result checked.");
  await page.getByRole("button", { name: "Verify entries in Tally", exact: true }).click();
  await expect(
    page
      .getByLabel("Selected Tally invoice", { exact: true })
      .getByText("Posting", { exact: true }),
  ).toBeVisible();
  expect(verified).toBe(1);
  expect(posts).toEqual([]);
});

test("missing ledgers are resolved beside the bill with evidence and explicit saves", async ({ page }, info) => {
  const data = structuredClone(tally);
  const proposal = data.proposals[0];
  const entry = proposal.sales_entries[0];
  proposal.status = "needs_input";
  proposal.issues = ["Choose a sales ledger for each invoice line."];
  entry.ledger_identity = null;
  entry.ledger_name = null;
  entry.hsn_sac = "998719";
  entry.tax_rates = [{head: "cgst", rate: "9"}, {head: "sgst", rate: "9"}];
  entry.candidates = [
    {identity: "sales18", name: "Labour A", history_count: 3, party_history_count: 0},
    {identity: "other18", name: "Labour B", history_count: 1, party_history_count: 0},
  ];
  data.sales_ledger_choices = [...entry.candidates, {identity: "unrelated", name: "Unrelated ledger"}];
  data.ready_count = 0;
  data.can_post = false;
  await setup(page, data);
  const review: SalesInvoiceReviewData = {
    client: month.client, period: month.period,
    invoice: {id: "one", number: proposal.number!, date: proposal.date!, buyer_name: "Philips India Ltd", buyer_gstin: "33AABCP9487A1ZG", place_of_supply: "Tamil Nadu"},
    facts: {}, printed_totals: {}, totals: [], checks: [], issues: [], states: [], source: null,
    lines: [{index: 0, values: {description: "", taxable_value: "10000"}, display: {}}],
    queue: [{id: "one", number: proposal.number!, customer: "Philips India Ltd", buyer_gstin: "33AABCP9487A1ZG", status: "ready", issue_codes: []}],
    can_edit: true, lock_reason: null, editable_fields: {facts: [], line: [], totals: []},
  };
  await page.route("**/api/workspace/sales/1/2026-08/invoices/one?*", route => route.fulfill({json: review}));
  const writes: unknown[] = [];
  await page.route("**/api/workspace/sales/1/2026-08/invoices/one/tally", route => {
    writes.push(route.request().postDataJSON());
    entry.ledger_identity = "sales18";
    entry.ledger_name = "Labour A";
    proposal.status = "ready";
    proposal.issues = [];
    data.preview_token = "saved-preview";
    data.ready_count = 1;
    data.can_post = true;
    return route.fulfill({json: data});
  });
  await page.goto("/app/gst/1/2026-08/sales/invoices/one?tally=entries");
  const question = page.getByRole("group", {name: "Ledger choice for AC servicing", exact: true});
  await expect(question).toContainText("2 ledgers match");
  await expect(question).toContainText("HSN/SAC 998719 · CGST 9% · SGST 9%");
  await expect(question).toContainText("3 earlier CGST + SGST sales · 0 for this customer");
  await expect(question.getByText("Unrelated ledger", {exact:true})).toHaveCount(0);
  await question.getByRole("button", {name: "Search all ledgers", exact:true}).click();
  await question.getByLabel("Search all sales ledgers for AC servicing", {exact:true}).click();
  await expect(page.getByRole("option", {name:"Unrelated ledger",exact:true})).toBeVisible();
  await page.keyboard.press("Escape");
  await page.getByRole("button", {name: "Edit entry", exact: true}).click();
  await expect(page.getByLabel("Line 1 description", {exact:true})).toHaveValue("AC servicing");
  await expect(page.getByRole("button", {name:"Save changes",exact:true})).toBeDisabled();
  await page.getByRole("button", {name:"Cancel",exact:true}).click();
  expect(writes).toEqual([]);
  await page.screenshot({path: info.outputPath("ledger-question.png"), animations:"disabled"});
  await question.getByRole("button", {name: "Use Labour A for AC servicing", exact:true}).click();
  await expect(question).toHaveCount(0);
  await expect(page.getByRole("status").filter({hasText:"Changes saved. Entry recalculated."})).toBeVisible();
  await expect(page.getByText("Ready to post", {exact:true})).toBeVisible();
  expect(writes).toEqual([{line_sales_ledger_identities:{"0":"sales18"},preview_token:"reviewed-preview"}]);
  await expect(page.getByRole("form", {name:"Edit Tally entry"})).toHaveCount(0);
});

test("bill comparison returns to the same selected Tally entry", async ({ page }, info) => {
  await setup(page, {
    ...tally,
    ready_count: 0,
    ready_total: "0.00",
    can_post: false,
    proposals: tally.proposals.map((item) => ({
      ...item,
      status: "needs_input",
      issues: ["Choose the sales ledger."],
    })),
  });
  const review: SalesInvoiceReviewData = {
    client: month.client,
    period: month.period,
    invoice: {
      id: "one",
      number: "75/2026-27",
      date: "2026-08-26",
      buyer_name: "Philips India Ltd",
      buyer_gstin: "33AABCP9487A1ZG",
      place_of_supply: "Tamil Nadu",
    },
    facts: { invoice_number: "75/2026-27" },
    lines: [{ index: 0, values: { description: "AC servicing", taxable_value: "10000", cgst_rate: "9", cgst_amount: "900", sgst_rate: "9", sgst_amount: "900" }, display: {} }],
    totals: [],
    printed_totals: {},
    checks: [],
    issues: [],
    source: null,
    states: [],
    queue: [
      {
        id: "one",
        number: "75/2026-27",
        status: "ready",
        customer: "Philips India Ltd",
        buyer_gstin: "33AABCP9487A1ZG",
        issue_codes: [],
      },
    ],
    can_edit: true,
    lock_reason: null,
    editable_fields: { facts: ["invoice_number"], line: [], totals: [] },
  };
  const requests: { method: string; basis: string | null }[] = [];
  await page.route("**/api/workspace/sales/1/2026-08/invoices/one*", (route) => {
    requests.push({
      method: route.request().method(),
      basis: new URL(route.request().url()).searchParams.get("tally"),
    });
    return route.fulfill({ json: review });
  });
  const writes: unknown[] = [];
  await page.route("**/api/workspace/sales/1/2026-08/invoices/one/tally", route => {
    writes.push(route.request().postDataJSON());
    return route.fulfill({ json: tally });
  });
  await page.goto("/app/gst/1/2026-08/sales/register?tally=entries&selected=one&q=Philips");
  await page.getByRole("link", { name: "Check against bill", exact: true }).click();
  await expect(page.getByRole("region", { name: "Proposed Tally entry" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Needs review 1", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Edit entry", exact: true }).click();
  await page.getByRole("button", { name: "Bill details", exact: true }).click();
  await page.getByLabel("Invoice number", { exact: true }).fill("75-CORRECTED");
  await page.getByLabel("Invoice number", { exact: true }).press("Escape");
  await expect(page.getByRole("button", { name: "Next invoice", exact: true })).toBeHidden();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  expect(writes).toEqual([]);
  await page.getByRole("button", { name: "Edit entry", exact: true }).click();
  await page.getByRole("button", { name: "Bill details", exact: true }).click();
  await expect(page.getByLabel("Invoice number", { exact: true })).toHaveValue("75/2026-27");
  await page.getByLabel("Invoice number", { exact: true }).press("Escape");
  await page.getByRole("button", { name: "Bill details", exact: true }).click();
  await page.getByLabel("Invoice number", { exact: true }).fill("75-CORRECTED");
  await page.getByLabel("Invoice number", { exact: true }).press("Escape");
  await page.getByLabel("Line 1 taxable amount", { exact: true }).fill("16000");
  await page.getByRole("button", { name: "Tax details for line 1", exact: true }).click();
  await page.getByLabel("Line 1 CGST amount", { exact: true }).fill("1440");
  await page.getByLabel("Line 1 SGST amount", { exact: true }).fill("1440");
  await page.getByLabel("Line 1 SGST amount", { exact: true }).press("Escape");
  await expect(page.getByRole("form", { name: "Edit Tally entry" })).toBeVisible();
  expect(writes).toEqual([]);
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "Changes saved." })).toBeVisible();
  expect(requests).toContainEqual({ method: "GET", basis: "entries" });
  expect(writes).toEqual([{ source_changes: { invoice_number: "75-CORRECTED", "line_items[0].taxable_value": "16000", "line_items[0].cgst_amount": "1440", "line_items[0].sgst_amount": "1440" }, preview_token: "reviewed-preview" }]);
  expect(requests.every(request => request.method === "GET")).toBe(true);
  await page.screenshot({ path: info.outputPath("tally-source-comparison.png"), fullPage: true });
  await page.getByRole("link", { name: /Back to register/ }).click();
  await expect(page).toHaveURL(/tally=entries/);
  await expect(page).toHaveURL(/selected=one/);
  await expect(page.getByRole("region", { name: "Proposed Tally entry" })).toBeVisible();
});
