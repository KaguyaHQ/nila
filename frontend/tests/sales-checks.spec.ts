import { expect, test, type Page } from "@playwright/test";
import type { MonthlySalesChecks } from "../src/lib/sales-checks-api";
import type { SalesWorkspace } from "../src/lib/sales-api";
import { chooseSelect } from "./select-field";

function workspace(): SalesWorkspace {
  return {
    details: {},
    exports: { items: [], blockers: [], status: "No exports available." },
    client: { id: 1, name: "Breeze Tech" },
    clients: [{ id: 1, name: "Breeze Tech" }],
    user: { name: "Accountant", org: "Test firm" },
    period: "2026-06",
    month_label: "June 2026",
    can_upload: true,
    deadline: "2026-07-11",
    invoice_count: 1,
    review_count: 0,
    month_issue_count: 3,
    taxable: "₹1,000.00",
    tax: "₹180.00",
    uploads: { files: 1, unfinished: false },
    rows: [],
    sections: [],
    links: {
      upload: "/gst/1/2026-06/sales/upload",
      uploads: "/gst/1/2026-06/sales/uploads",
      working: "/gst/1/2026-06/sales",
      purchases: "/gst/1/2026-06/purchases",
    },
  };
}

function checks(): MonthlySalesChecks {
  return {
    client: { id: 1, name: "Breeze Tech", gstin: "33AABCT3518Q1ZF" },
    period: "2026-06",
    can_edit: true,
    lock_reason: null,
    checks: [
      {
        target: "sequence_gaps",
        code: "sequence_gaps",
        title: "Check invoice sequence",
        message:
          "Invoice numbers 12 and 13 are missing. Add any missing bills or correct wrongly read numbers.",
        status: "open",
        basis: "sequence-v1",
        confirm_label: "These invoice numbers were cancelled",
        confirmation_text:
          "I checked the source register. These missing invoice numbers were genuinely cancelled, not missing bills.",
        sources: [],
        action_paths: [
          { label: "Check document numbers", path: "/gst/1/2026-06/sales/sections/documents" },
          { label: "Add missing bills", path: "/gst/1/2026-06/sales/upload" },
        ],
      },
      {
        target: "pages_unaccounted:1",
        code: "pages_unaccounted",
        title: "Check unread pages",
        message: "Pages 2 and 4 could not be read. Check the original PDF for missing bills.",
        status: "open",
        basis: "pages-v1",
        confirm_label: "I checked these pages; no bill was missed",
        confirmation_text:
          "I opened pages 2 and 4 in the original PDF and checked that no sales bill was missed.",
        sources: [
          { id: 1, name: "June sales.pdf", url: "/gst/1/2026-06/original/1/0" },
          { id: 1, name: "Additional sales.pdf", url: "/gst/1/2026-06/original/1/1" },
        ],
        action_paths: [{ label: "Add missing bills", path: "/gst/1/2026-06/sales/upload" }],
      },
      {
        target: "evidence_unavailable:2",
        code: "evidence_unavailable",
        title: "Check original source",
        message: "Page images are unavailable. Compare the extracted bills with the original PDF.",
        status: "open",
        basis: "evidence-v1",
        confirm_label: "I compared the bills with the originals",
        confirmation_text:
          "I compared the extracted sales bills with the original PDF because the rendered page images are unavailable.",
        sources: [{ id: 2, name: "Other bills.pdf", url: "/gst/1/2026-06/original/2/0" }],
        action_paths: [{ label: "Review extracted bills", path: "/gst/1/2026-06/sales/register" }],
      },
    ],
  };
}

async function setup(page: Page, current: () => MonthlySalesChecks = checks) {
  await page.route("**/api/workspace/sales/1/2026-06", (route) =>
    route.fulfill({ json: workspace() }),
  );
  await page.route("**/api/workspace/sales/1/2026-06/checks", (route) =>
    route.fulfill({ json: current() }),
  );
  await page.addInitScript(() =>
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "checks-csrf";
      document.head.append(meta);
    }),
  );
}

test("monthly checks retain original links and specific actions without a generic confirmation", async ({
  page,
}, testInfo) => {
  const data = checks();
  data.checks.push({
    ...data.checks[0],
    target: "unknown",
    code: "unknown_blocker",
    title: "Other check",
    confirm_label: "Acknowledge unknown check",
  });
  await setup(page, () => data);
  await page.goto("/app/gst/1/2026-06/sales?returnTask=sequence_gaps");
  await expect(page.locator("#return-review")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true }),
  ).toBeVisible();
  await chooseSelect(page
    .getByLabel("Source and document checks", { exact: true }), "pages_unaccounted:1");
  await expect(
    page.getByRole("button", { name: "I checked these pages; no bill was missed", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Acknowledge unknown check", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("link", { name: "June sales.pdf (original source, new tab)", exact: true }),
  ).toHaveAttribute("href", "/gst/1/2026-06/original/1/0");
  await expect(
    page.getByRole("link", {
      name: "Additional sales.pdf (original source, new tab)",
      exact: true,
    }),
  ).toHaveAttribute("href", "/gst/1/2026-06/original/1/1");
  await chooseSelect(page
    .getByLabel("Source and document checks", { exact: true }), "sequence_gaps");
  await expect(
    page
      .getByRole("region", { name: "Check invoice sequence", exact: true })
      .getByRole("link", { name: "Check document numbers", exact: true }),
  ).toHaveAttribute("href", "/app/gst/1/2026-06/sales/sections/documents");
  await page.screenshot({ path: testInfo.outputPath("checks-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await chooseSelect(page
    .getByLabel("Source and document checks", { exact: true }), "pages_unaccounted:1");
  await page
    .getByRole("button", { name: "I checked these pages; no bill was missed", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({ path: testInfo.outputPath("checks-narrow-dialog.png"), fullPage: true });
});

test("confirmation and undo post the opaque basis and render only saved results", async ({
  page,
}) => {
  let current = checks();
  await setup(page, () => current);
  const decisions: unknown[] = [];
  await page.route("**/checks/decision", (route) => {
    const body = route.request().postDataJSON();
    decisions.push(body);
    expect(route.request().headers()["x-csrf-token"]).toBe("checks-csrf");
    expect(body.target).toBe("sequence_gaps");
    expect(body.basis).toBe(decisions.length === 1 ? "sequence-v1" : "sequence-confirmed");
    current = {
      ...current,
      checks: current.checks.map((check) =>
        check.target === body.target
          ? {
              ...check,
              status: body.action === "confirm" ? "resolved" : "open",
              basis: body.action === "confirm" ? "sequence-confirmed" : "sequence-reopened",
            }
          : check,
      ),
    };
    return route.fulfill({ json: current });
  });
  await page.goto("/app/gst/1/2026-06/sales?returnTask=sequence_gaps");
  await page
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await expect(page.getByRole("dialog")).toContainText("genuinely cancelled, not missing bills");
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("status")).toHaveText("Confirmation saved.");
  const undo = page.getByRole("button", { name: "Undo confirmation", exact: true });
  await expect(undo).toBeFocused();
  await undo.click();
  await expect(page.getByRole("status")).toHaveText("Confirmation removed.");
  await expect(
    page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true }),
  ).toBeVisible();
  expect(decisions).toEqual([
    { target: "sequence_gaps", basis: "sequence-v1", action: "confirm" },
    { target: "sequence_gaps", basis: "sequence-confirmed", action: "reopen" },
  ]);
});

test("monthly confirmation cannot submit twice or close while the decision is pending", async ({
  page,
}) => {
  let current = checks();
  await setup(page, () => current);
  let decisions = 0;
  let release!: () => void;
  const response = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/checks/decision", async (route) => {
    decisions++;
    await response;
    current = {
      ...current,
      checks: current.checks.map((check) =>
        check.target === "sequence_gaps" ? { ...check, status: "resolved" } : check,
      ),
    };
    return route.fulfill({ json: current });
  });
  await page.goto("/app/gst/1/2026-06/sales?returnTask=sequence_gaps");
  await page
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .locator("form")
    .evaluate((form) => {
      (form as HTMLFormElement).requestSubmit();
      (form as HTMLFormElement).requestSubmit();
    });
  try {
    await expect.poll(() => decisions).toBe(1);
    await expect(
      page.getByRole("dialog").getByRole("button", { name: "Saving…", exact: true }),
    ).toBeDisabled();
    await expect(page.getByRole("button", { name: "Cancel", exact: true })).toBeDisabled();
    await expect(page.getByRole("button", { name: "Undo confirmation", exact: true })).toHaveCount(
      0,
    );
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toBeVisible();
  } finally {
    release();
  }
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Undo confirmation", exact: true })).toBeVisible();
  expect(decisions).toBe(1);
});

test("stale basis refreshes the check and requires another inspection before confirmation", async ({
  page,
}) => {
  let current = checks();
  await setup(page, () => current);
  const posted: string[] = [];
  await page.route("**/checks/decision", (route) => {
    const decision = route.request().postDataJSON();
    posted.push(decision.basis);
    if (posted.length === 1) {
      current = {
        ...current,
        checks: current.checks.map((check) =>
          check.target === "sequence_gaps"
            ? {
                ...check,
                basis: "sequence-v2",
                message: "Invoice numbers 12, 13 and 20 are missing.",
                confirmation_text: "I checked invoice numbers 12, 13 and 20 against the register.",
              }
            : check,
        ),
      };
      return route.fulfill({
        status: 409,
        json: { error: "The source records changed. Review this check again." },
      });
    }
    current = {
      ...current,
      checks: current.checks.map((check) =>
        check.target === "sequence_gaps" ? { ...check, status: "resolved" } : check,
      ),
    };
    return route.fulfill({ json: current });
  });
  await page.goto("/app/gst/1/2026-06/sales?returnTask=sequence_gaps");
  await page
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await expect(page.getByRole("alert")).toContainText("source records changed");
  await expect(
    page
      .getByRole("dialog")
      .getByRole("button", { name: "These invoice numbers were cancelled", exact: true }),
  ).toBeDisabled();
  await page.getByRole("button", { name: "Close and review", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(
    page.getByText("Invoice numbers 12, 13 and 20 are missing.", { exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await expect(page.getByRole("dialog")).toContainText("invoice numbers 12, 13 and 20");
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await expect(page.getByRole("status")).toHaveText("Confirmation saved.");
  expect(posted).toEqual(["sequence-v1", "sequence-v2"]);
});

test("vanished checks refresh after 422 and cannot be confirmed repeatedly", async ({ page }) => {
  let current = checks();
  current.checks = [current.checks[0]];
  await setup(page, () => current);
  let decisions = 0;
  await page.route("**/checks/decision", (route) => {
    decisions++;
    current = { ...current, checks: [] };
    return route.fulfill({ status: 422, json: { error: "This check no longer applies." } });
  });
  await page.goto("/app/gst/1/2026-06/sales?returnTask=sequence_gaps");
  await page
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "These invoice numbers were cancelled", exact: true })
    .click();
  await expect(page.getByRole("alert")).toHaveText("This check no longer applies.");
  await expect(
    page
      .getByRole("dialog")
      .getByRole("button", { name: "These invoice numbers were cancelled", exact: true }),
  ).toBeDisabled();
  await page.getByRole("button", { name: "Close and review", exact: true }).click();
  await expect(
    page.getByText("No sequence or source-page checks to review.", { exact: true }),
  ).toBeVisible();
  await expect(page.locator("#return-review")).toBeFocused();
  expect(decisions).toBe(1);
});

test("filed month remains readable with disabled decisions and null historic basis", async ({
  page,
}) => {
  const current = checks();
  current.can_edit = false;
  current.lock_reason = "This month has been filed.";
  current.checks = current.checks.map((check) => ({ ...check, basis: null }));
  await setup(page, () => current);
  await page.goto("/app/gst/1/2026-06/sales?returnTask=sequence_gaps");
  await expect(page.getByText("This month has been filed.", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true }),
  ).toBeDisabled();
  await chooseSelect(page
    .getByLabel("Source and document checks", { exact: true }), "pages_unaccounted:1");
  await expect(
    page.getByRole("link", { name: "June sales.pdf (original source, new tab)", exact: true }),
  ).toBeVisible();
});

test("API permission errors do not appear as an empty monthly check list", async ({ page }) => {
  await setup(page);
  await page.route("**/api/workspace/sales/1/2026-06/checks", (route) =>
    route.fulfill({ status: 403, json: { error: "You cannot access these checks." } }),
  );
  await page.goto("/app/gst/1/2026-06/sales?returnTask=sequence_gaps");
  await expect(page.getByRole("alert")).toHaveText("You cannot access these checks.");
  await expect(
    page.getByText("No sequence or source-page checks to review.", { exact: true }),
  ).toHaveCount(0);
});

test("B2CS coverage is resolved beside its supplied summary and connected notes", async ({
  page,
}, info) => {
  const data = { ...workspace(), report_count: 1, report_issue_count: 2 };
  await setup(page, () => ({ ...checks(), checks: [] }));
  await page.route("**/api/workspace/sales/1/2026-06", (route) => route.fulfill({ json: data }));
  let saved = false;
  await page.route("**/api/workspace/sales/1/2026-06/reports", (route) => {
    if (route.request().method() === "PATCH") {
      expect(route.request().postDataJSON()).toMatchObject({
        dump_id: 41,
        basis: "coverage-v1",
        values: { b2cs_before_notes: false },
      });
      saved = true;
      return route.fulfill({ json: { ok: true } });
    }
    return route.fulfill({
      json: {
        editable: true,
        reports: [],
        states: [],
        tasks: saved
          ? []
          : [
              {
                id: "note-treatment",
                kind: "notes",
                title: "Classify notes",
                message: "Review notes",
                dump_id: 41,
                basis: "notes-v1",
                filename: "packet",
                sheet: "CDNUR",
                row: 0,
                source_ids: ["note-1"],
                fields: [],
                values: {},
                rows: [],
              },
              {
                id: "coverage",
                kind: "basis",
                title: "Do B2CS totals already include these notes?",
                message: "Choose whether to deduct the notes from the supplied sales totals.",
                dump_id: 41,
                basis: "coverage-v1",
                filename: "packet",
                sheet: "report",
                row: 0,
                source_ids: [],
                fields: ["b2cs_before_notes"],
                values: {},
                amounts: { before: 1000, notes: 100, after: 900 },
                rows: [
                  {
                    section: "b2cs",
                    source_filename: "B2CS.xlsx",
                    sheet: "B2CS",
                    row: 2,
                    values: { txval: 1000, rate: 18 },
                  },
                  {
                    section: "cdnur",
                    source_filename: "CDNUR.xlsx",
                    sheet: "CDNUR",
                    row: 4,
                    values: { number: "CN-14", txval: 100 },
                  },
                ],
              },
            ],
      },
    });
  });
  await page.goto("/app/gst/1/2026-06/sales?returnTask=coverage");
  const review = page.getByRole("region", {
    name: "Do B2CS totals already include these notes?",
    exact: true,
  });
  await expect(review).toBeVisible();
  await expect(page.getByRole("region", { name: "Classify notes", exact: true })).toHaveCount(0);
  await expect(review).toContainText("B2CS.xlsx");
  await expect(review).toContainText("CDNUR.xlsx");
  await chooseSelect(review.getByLabel("B2CS totals in the file"), "false");
  await page.screenshot({ path: info.outputPath("return-b2cs-coverage.png"), fullPage: true });
  await review.getByRole("button", { name: "Save", exact: true }).click();
  await expect(review).toContainText("Saved");
  expect(saved).toBe(true);
});

test("a source check link selects its evidence without opening confirmation", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales?returnTask=pages_unaccounted%3A1");
  await expect(page.getByRole("region", { name: "Check unread pages", exact: true })).toBeVisible();
  await expect(
    page.getByRole("region", { name: "Check invoice sequence", exact: true }),
  ).toHaveCount(0);
  await expect(page.getByRole("dialog")).toHaveCount(0);
});

test("return task switching preserves edits and warns before leaving", async ({ page }) => {
  await setup(page, () => ({ ...checks(), checks: [] }));
  await page.route("**/api/workspace/sales/1/2026-06", (route) =>
    route.fulfill({ json: { ...workspace(), report_count: 1 } }),
  );
  await page.route("**/api/workspace/sales/1/2026-06/reports", (route) =>
    route.fulfill({
      json: {
        editable: true,
        reports: [],
        states: [],
        tasks: ["A", "B"].map((id) => ({
          id,
          kind: "row",
          title: `HSN ${id}`,
          message: "Confirm rate",
          dump_id: 41,
          basis: "v1",
          filename: "HSN.xlsx",
          sheet: "HSN",
          row: id === "A" ? 2 : 3,
          source_ids: [],
          fields: ["rate"],
          values: { rate: 5 },
          rows: [],
        })),
      },
    }),
  );
  await page.goto("/app/gst/1/2026-06/sales?returnTask=A");
  await page
    .getByRole("region", { name: "HSN A", exact: true })
    .getByLabel("GST rate", { exact: true })
    .fill("18");
  await chooseSelect(page
    .getByRole("combobox", { name: "Review return section", exact: true }), "B");
  await expect(page.getByRole("region", { name: "HSN A", exact: true })).toHaveCount(0);
  await chooseSelect(page
    .getByRole("combobox", { name: "Review return section", exact: true }), "A");
  await expect(
    page
      .getByRole("region", { name: "HSN A", exact: true })
      .getByLabel("GST rate", { exact: true }),
  ).toHaveValue("18");
  page.once("dialog", async (dialog) => {
    expect(dialog.message()).toContain("unsaved report");
    await dialog.dismiss();
  });
  await page
    .getByRole("link", { name: /sales workspace|sales register/i })
    .first()
    .click();
  await expect(page).toHaveURL(/sales\?returnTask=A$/);
});

test("section source link returns to that same return section", async ({ page }) => {
  const data = workspace();
  data.details = {
    b2b: {
      title: "B2B sales",
      description: "",
      note: null,
      groups: [
        {
          id: "sales",
          label: null,
          columns: [{ key: "number", label: "Invoice", align: "left" }],
          rows: [
            {
              id: "one",
              cells: { number: "INV-001" },
              invoice_path: "/gst/1/2026-06/sales/invoices/one",
              children: [],
            },
          ],
        },
      ],
    },
  };
  await setup(page, () => ({ ...checks(), checks: [] }));
  await page.route("**/api/workspace/sales/1/2026-06", (route) => route.fulfill({ json: data }));
  await page.route("**/api/workspace/sales/1/2026-06/invoices/one", (route) =>
    route.fulfill({ status: 404, json: { error: "Invoice unavailable" } }),
  );
  await page.goto("/app/gst/1/2026-06/sales/sections/b2b");
  await page.getByRole("link", { name: "Review source invoice INV-001", exact: true }).click();
  await expect(page).toHaveURL(/invoices\/one\?origin=return&returnSection=b2b$/);
  await page.getByRole("link", { name: "Back to return", exact: true }).click();
  await expect(page).toHaveURL(/sales\/sections\/b2b/);
  await expect(page.getByRole("heading", { name: "B2B sales", exact: true })).toBeVisible();
});
