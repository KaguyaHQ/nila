import { expect, test, type Page } from "@playwright/test";
import type { MonthlySalesChecks } from "../src/lib/sales-checks-api";
import type { SalesWorkspace } from "../src/lib/sales-api";

function workspace(): SalesWorkspace {
  return {
    client: { id: 1, name: "Breeze Tech" }, clients: [{ id: 1, name: "Breeze Tech" }], user: { name: "Accountant", org: "Test firm" }, period: "2026-06", month_label: "June 2026", can_upload: true, deadline: "2026-07-11", invoice_count: 1, review_count: 0, month_issue_count: 3,
    taxable: "₹1,000.00", tax: "₹180.00", uploads: { files: 1, unfinished: false }, rows: [], sections: [],
    links: { upload: "/gst/1/2026-06/sales/upload", uploads: "/gst/1/2026-06/sales/uploads", working: "/gst/1/2026-06/sales", purchases: "/gst/1/2026-06/purchases" },
  };
}

function checks(): MonthlySalesChecks {
  return {
    client: { id: 1, name: "Breeze Tech", gstin: "33AABCT3518Q1ZF" }, period: "2026-06", can_edit: true, lock_reason: null,
    checks: [
      { target: "sequence_gaps", code: "sequence_gaps", title: "Check invoice sequence", message: "Invoice numbers 12 and 13 are missing. Add any missing bills or correct wrongly read numbers.", status: "open", basis: "sequence-v1", confirm_label: "These invoice numbers were cancelled", confirmation_text: "I checked the source register. These missing invoice numbers were genuinely cancelled, not missing bills.", sources: [], action_paths: [{ label: "Check document numbers", path: "/gst/1/2026-06/sales/sections/documents" }, { label: "Add missing bills", path: "/gst/1/2026-06/sales/upload" }] },
      { target: "pages_unaccounted:1", code: "pages_unaccounted", title: "Check unread pages", message: "Pages 2 and 4 could not be read. Check the original PDF for missing bills.", status: "open", basis: "pages-v1", confirm_label: "I checked these pages; no bill was missed", confirmation_text: "I opened pages 2 and 4 in the original PDF and checked that no sales bill was missed.", sources: [{ id: 1, name: "June sales.pdf", url: "/gst/1/2026-06/original/1/0" }, { id: 1, name: "Additional sales.pdf", url: "/gst/1/2026-06/original/1/1" }], action_paths: [{ label: "Add missing bills", path: "/gst/1/2026-06/sales/upload" }] },
      { target: "evidence_unavailable:2", code: "evidence_unavailable", title: "Check original source", message: "Page images are unavailable. Compare the extracted bills with the original PDF.", status: "open", basis: "evidence-v1", confirm_label: "I compared the bills with the originals", confirmation_text: "I compared the extracted sales bills with the original PDF because the rendered page images are unavailable.", sources: [{ id: 2, name: "Other bills.pdf", url: "/gst/1/2026-06/original/2/0" }], action_paths: [{ label: "Review extracted bills", path: "/gst/1/2026-06/sales/register" }] },
    ],
  };
}

async function setup(page: Page, current: () => MonthlySalesChecks = checks) {
  await page.route("**/api/workspace/sales/1/2026-06", route => route.fulfill({ json: workspace() }));
  await page.route("**/api/workspace/sales/1/2026-06/checks", route => route.fulfill({ json: current() }));
  await page.addInitScript(() => document.addEventListener("DOMContentLoaded", () => {
    const meta = document.createElement("meta"); meta.name = "csrf-token"; meta.content = "checks-csrf"; document.head.append(meta);
  }));
}

test("monthly checks retain original links and specific actions without a generic confirmation", async ({ page }, testInfo) => {
  const data = checks();
  data.checks.push({ ...data.checks[0], target: "unknown", code: "unknown_blocker", title: "Other check", confirm_label: "Acknowledge unknown check" });
  await setup(page, () => data);
  await page.goto("/app/gst/1/2026-06/sales/checks");
  await expect(page.getByRole("heading", { name: "Monthly checks", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "I checked these pages; no bill was missed", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Acknowledge unknown check", exact: true })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "June sales.pdf (original source, new tab)", exact: true })).toHaveAttribute("href", "/gst/1/2026-06/original/1/0");
  await expect(page.getByRole("link", { name: "Additional sales.pdf (original source, new tab)", exact: true })).toHaveAttribute("href", "/gst/1/2026-06/original/1/1");
  await expect(page.getByRole("region", { name: "Check invoice sequence", exact: true }).getByRole("link", { name: "Check document numbers", exact: true })).toHaveAttribute("href", "/app/gst/1/2026-06/sales/sections/documents");
  await page.screenshot({ path: testInfo.outputPath("checks-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.getByRole("button", { name: "I checked these pages; no bill was missed", exact: true }).click();
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("checks-narrow-dialog.png"), fullPage: true });
});

test("confirmation and undo post the opaque basis and render only saved results", async ({ page }) => {
  let current = checks();
  await setup(page, () => current);
  const decisions: unknown[] = [];
  await page.route("**/checks/decision", route => {
    const body = route.request().postDataJSON(); decisions.push(body);
    expect(route.request().headers()["x-csrf-token"]).toBe("checks-csrf");
    expect(body.target).toBe("sequence_gaps");
    expect(body.basis).toBe(decisions.length === 1 ? "sequence-v1" : "sequence-confirmed");
    current = { ...current, checks: current.checks.map(check => check.target === body.target ? { ...check, status: body.action === "confirm" ? "resolved" : "open", basis: body.action === "confirm" ? "sequence-confirmed" : "sequence-reopened" } : check) };
    return route.fulfill({ json: current });
  });
  await page.goto("/app/gst/1/2026-06/sales/checks");
  await page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true }).click();
  await expect(page.getByRole("dialog")).toContainText("genuinely cancelled, not missing bills");
  await page.getByRole("dialog").getByRole("button", { name: "These invoice numbers were cancelled", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("status")).toHaveText("Confirmation saved.");
  const undo = page.getByRole("button", { name: "Undo confirmation", exact: true });
  await expect(undo).toBeFocused();
  await undo.click();
  await expect(page.getByRole("status")).toHaveText("Confirmation removed.");
  await expect(page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true })).toBeVisible();
  expect(decisions).toEqual([{ target: "sequence_gaps", basis: "sequence-v1", action: "confirm" }, { target: "sequence_gaps", basis: "sequence-confirmed", action: "reopen" }]);
});

test("stale basis refreshes the check and requires another inspection before confirmation", async ({ page }) => {
  let current = checks();
  await setup(page, () => current);
  const posted: string[] = [];
  await page.route("**/checks/decision", route => {
    const decision = route.request().postDataJSON(); posted.push(decision.basis);
    if (posted.length === 1) {
      current = { ...current, checks: current.checks.map(check => check.target === "sequence_gaps" ? { ...check, basis: "sequence-v2", message: "Invoice numbers 12, 13 and 20 are missing.", confirmation_text: "I checked invoice numbers 12, 13 and 20 against the register." } : check) };
      return route.fulfill({ status: 409, json: { error: "The source records changed. Review this check again." } });
    }
    current = { ...current, checks: current.checks.map(check => check.target === "sequence_gaps" ? { ...check, status: "resolved" } : check) };
    return route.fulfill({ json: current });
  });
  await page.goto("/app/gst/1/2026-06/sales/checks");
  await page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true }).click();
  await page.getByRole("dialog").getByRole("button", { name: "These invoice numbers were cancelled", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("source records changed");
  await expect(page.getByRole("dialog").getByRole("button", { name: "These invoice numbers were cancelled", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Close and review", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByText("Invoice numbers 12, 13 and 20 are missing.", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true }).click();
  await expect(page.getByRole("dialog")).toContainText("invoice numbers 12, 13 and 20");
  await page.getByRole("dialog").getByRole("button", { name: "These invoice numbers were cancelled", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Confirmation saved.");
  expect(posted).toEqual(["sequence-v1", "sequence-v2"]);
});

test("vanished checks refresh after 422 and cannot be confirmed repeatedly", async ({ page }) => {
  let current = checks(); current.checks = [current.checks[0]];
  await setup(page, () => current);
  let decisions = 0;
  await page.route("**/checks/decision", route => {
    decisions++; current = { ...current, checks: [] };
    return route.fulfill({ status: 422, json: { error: "This check no longer applies." } });
  });
  await page.goto("/app/gst/1/2026-06/sales/checks");
  await page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true }).click();
  await page.getByRole("dialog").getByRole("button", { name: "These invoice numbers were cancelled", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("This check no longer applies.");
  await expect(page.getByRole("dialog").getByRole("button", { name: "These invoice numbers were cancelled", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Close and review", exact: true }).click();
  await expect(page.getByText("No sequence or source-page checks to review.", { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Monthly checks", exact: true })).toBeFocused();
  expect(decisions).toBe(1);
});

test("filed month remains readable with disabled decisions and null historic basis", async ({ page }) => {
  const current = checks(); current.can_edit = false; current.lock_reason = "This month has been filed."; current.checks = current.checks.map(check => ({ ...check, basis: null }));
  await setup(page, () => current);
  await page.goto("/app/gst/1/2026-06/sales/checks");
  await expect(page.getByText("This month has been filed.", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "These invoice numbers were cancelled", exact: true })).toBeDisabled();
  await expect(page.getByRole("link", { name: "June sales.pdf (original source, new tab)", exact: true })).toBeVisible();
});

test("API permission errors do not appear as an empty monthly check list", async ({ page }) => {
  await setup(page);
  await page.route("**/api/workspace/sales/1/2026-06/checks", route => route.fulfill({ status: 403, json: { error: "You cannot access these checks." } }));
  await page.goto("/app/gst/1/2026-06/sales/checks");
  await expect(page.getByRole("alert")).toHaveText("You cannot access these checks.");
  await expect(page.getByText("No sequence or source-page checks to review.", { exact: true })).toHaveCount(0);
});
