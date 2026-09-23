import { expect, test, type Page } from "@playwright/test";
import type { PurchaseReviewData } from "../src/lib/purchase-review-api";

import { review } from "./fixtures/purchase-review";
async function setup(page: Page, data = (id: string) => review(id)) {
  await page.addInitScript(() =>
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "purchase-csrf";
      document.head.append(meta);
    }),
  );
  await page.route("**/api/workspace/purchases/1/2026-06/review**", (route) => {
    const url = new URL(route.request().url());
    const id = url.pathname.split("/review/")[1] ?? "one";
    return route.fulfill({
      json: {
        ...data(id),
        filter: url.searchParams.get("filter") ?? "needs_review",
        q: url.searchParams.get("q") ?? "",
      },
    });
  });
}

test("comparison navigation stays in React and preserves queue context", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/purchases/review/one?filter=all&q=Supplier");
  await expect(page.getByRole("heading", { name: "Purchase P-001" })).toBeVisible();
  await expect(page.getByRole("columnheader", { name: "Purchase books" })).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Open original source", exact: false }),
  ).toHaveAttribute("href", "/gst/1/2026-06/original/1/0");
  await page.evaluate(() => {
    (window as unknown as { retained: boolean }).retained = true;
  });
  await page.getByRole("radio", { name: "Claim later", exact: true }).click();
  await expect(page.getByRole("button", { name: "Correct purchase values" })).toBeDisabled();
  await expect(page).toHaveURL(/review\/one\?filter=all&q=Supplier$/);
  await page.keyboard.press("Alt+ArrowRight");
  await expect(page).toHaveURL(/review\/one\?filter=all&q=Supplier$/);
  await page.getByRole("button", { name: "Discard changes", exact: true }).click();
  await expect(page.getByRole("radio", { name: "Claim later", exact: true })).not.toBeChecked();
  await page.keyboard.press("Alt+ArrowRight");
  await expect(page).toHaveURL(/review\/two\?filter=all&q=Supplier$/);
  expect(await page.evaluate(() => (window as unknown as { retained: boolean }).retained)).toBe(
    true,
  );
  await page.screenshot({
    path: testInfo.outputPath("purchase-review-desktop.png"),
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({
    path: testInfo.outputPath("purchase-review-narrow.png"),
    fullPage: true,
  });
});

test("switching keeps the queue mounted and hides the previous invoice while loading", async ({
  page,
}) => {
  await setup(page);
  let release!: () => void;
  const pending = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/review/two?*", async (route) => {
    await pending;
    await route.fulfill({ json: review("two") });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await expect(page.getByRole("heading", { name: "Purchase P-001" })).toBeVisible();
  await page.getByRole("navigation", { name: "Purchase invoices" }).evaluate((element) => {
    (window as any).queueElement = element;
  });
  await page.getByRole("button", { name: "Next purchase", exact: true }).click();
  await expect(page.getByRole("status", { name: "Loading purchase" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Purchase P-001" })).toHaveCount(0);
  await expect(page.getByRole("radio", { name: "Claim this month", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /P-002/ })).toHaveAttribute("aria-current", "page");
  expect(
    await page
      .getByRole("navigation", { name: "Purchase invoices" })
      .evaluate((element) => element === (window as any).queueElement),
  ).toBe(true);
  release();
  await expect(page.getByRole("heading", { name: "Purchase P-002" })).toBeVisible();
  const search = page.getByRole("textbox", { name: "Search review queue" });
  await search.fill("Supplier Two");
  await expect(page).toHaveURL(/q=Supplier\+Two$/);
  await expect(search).toHaveValue("Supplier Two");
  await expect(page.getByRole("button", { name: "Search", exact: true })).toHaveCount(0);
});

test("2B without books shows a single source and unconfirmed possession", async ({
  page,
}, info) => {
  const data = review();
  data.books_available = false;
  data.item!.status = "Not compared";
  data.item!.reason =
    "Purchase register not imported. This entry has not been compared with books.";
  data.item!.comparisons[0].has_books = false;
  data.item!.comparisons[0].books_id = null;
  data.item!.comparisons[0].correction = null;
  data.item!.comparisons[0].facts.forEach((fact) => {
    fact.books = "—";
  });
  data.cases[0].document_state = "unknown";
  data.cases[0].claimable = false;
  data.cases[0].can_record_document = true;
  await setup(page, () => data);
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await expect(page.getByRole("heading", { name: "GSTR-2B invoice" })).toBeVisible();
  await expect(page.getByRole("columnheader", { name: "Purchase books" })).toHaveCount(0);
  await expect(page.getByText("Invoice possession not confirmed")).toBeVisible();
  await expect(page.getByRole("radio", { name: "Claim this month", exact: true })).toBeDisabled();
  await expect(page.getByRole("radio", { name: "Do not claim", exact: true })).toBeEnabled();
  await page.screenshot({ path: info.outputPath("purchase-single-source.png") });
});

test("save and next posts explicit case basis and real server result", async ({ page }) => {
  await setup(page);
  let posted: unknown;
  await page.route("**/review/one/treatment?*", (route) => {
    posted = route.request().postDataJSON();
    expect(route.request().headers()["x-csrf-token"]).toBe("purchase-csrf");
    const fresh = review();
    fresh.cases[0].values.choice = "later";
    return route.fulfill({ json: fresh });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("radio", { name: "Claim later", exact: true }).click();
  await page.getByLabel("Why claim later?").selectOption("other");
  await page.getByLabel("Note", { exact: true }).fill("Awaiting goods receipt");
  await page.keyboard.press("Control+Enter");
  await expect(page.getByRole("heading", { name: "Purchase P-002" })).toBeVisible();
  expect(posted).toMatchObject({
    case_ids: [1],
    basis: { "1": "basis-1" },
    values: { choice: "later", later_reason: "other", note: "Awaiting goods receipt" },
  });
});

test("split decimal strings reach server and validation errors keep edits", async ({ page }) => {
  await setup(page);
  await page.route("**/review/one/treatment?*", (route) => {
    expect(route.request().postDataJSON().values.split.claim.cgst).toBe("45.25");
    return route.fulfill({
      status: 422,
      json: { error: "Each tax head must add up to its available amount.", code: "invalid_split" },
    });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Split treatment", exact: true }).click();
  await page.getByLabel("CGST claim", { exact: true }).fill("45.25");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "Each tax head must add up to its available amount.",
  );
  await expect(page.getByLabel("CGST claim", { exact: true })).toHaveValue("45.25");
});

test("stale save refreshes evidence and preserves read-only rules", async ({ page }) => {
  let current = review();
  await setup(page, () => current);
  await page.route("**/review/one/treatment?*", (route) => {
    current = { ...review(), can_edit: false, lock_reason: "This month was signed off." };
    return route.fulfill({
      status: 409,
      json: { error: "The source changed. Review it again.", code: "stale_basis" },
    });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("radio", { name: "Claim this month", exact: true }).click();
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByText("This month was signed off.")).toBeVisible();
  await expect(page.getByRole("radio", { name: "Claim this month", exact: true })).toBeDisabled();
});

test("document possession must be recorded before claim becomes available", async ({ page }) => {
  const current = review();
  current.cases[0].document_state = "unknown";
  current.cases[0].claimable = false;
  current.cases[0].can_record_document = true;
  current.cases[0].claim_block_reason = "Confirm that you hold the invoice.";
  await setup(page, () => current);
  await page.route("**/review/one/document?*", (route) => {
    expect(route.request().postDataJSON()).toEqual({ case_ids: [1], basis: { "1": "basis-1" } });
    return route.fulfill({ json: review() });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await expect(page.getByRole("radio", { name: "Claim this month", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Discard changes", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await page.getByRole("button", { name: "I have this invoice" }).click();
  await expect(page.getByRole("status")).toHaveText(
    "Invoice possession recorded. Review the available ITC choices.",
  );
  await expect(page.getByRole("radio", { name: "Claim this month", exact: true })).toBeEnabled();
});

test("uncertain pairing blocks treatment without a legacy handoff", async ({ page }) => {
  const current = review();
  current.item!.pairing_pending = true;
  await setup(page, () => current);
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await expect(page.getByRole("radio", { name: "Claim this month", exact: true })).toBeDisabled();
  await expect(
    page.getByText("Resolve the uncertain pairing before setting ITC treatment."),
  ).toBeVisible();
  await expect(page.getByRole("link", { name: "Open source corrections and pairing" })).toHaveCount(
    0,
  );
});

test("stale evidence requires a fresh choice and sends the new basis", async ({ page }) => {
  let current = review();
  await setup(page, () => current);
  let writes = 0;
  await page.route("**/review/one/treatment?*", (route) => {
    writes++;
    if (writes === 1) {
      current = review();
      current.cases[0].basis = "new-basis";
      return route.fulfill({
        status: 409,
        json: { error: "The source changed. Review it again.", code: "stale_basis" },
      });
    }
    expect(route.request().postDataJSON().basis).toEqual({ "1": "new-basis" });
    return route.fulfill({ json: current });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("radio", { name: "Claim this month", exact: true }).check();
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("The source changed");
  await expect(page.getByRole("button", { name: "Save", exact: true })).toBeDisabled();
  await page.getByRole("radio", { name: "Claim this month", exact: true }).check();
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("ITC treatment saved.");
  expect(writes).toBe(2);
});

test("saving blocks duplicate writes and navigation until Phoenix confirms", async ({ page }) => {
  await setup(page);
  let release!: () => void;
  const pending = new Promise<void>((resolve) => {
    release = resolve;
  });
  let writes = 0;
  await page.route("**/review/one/treatment?*", async (route) => {
    writes++;
    await pending;
    const fresh = review();
    fresh.cases[0].values.choice = "claim";
    fresh.queue = fresh.queue.filter((row) => row.id !== "one");
    await route.fulfill({ json: fresh });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("radio", { name: "Claim this month", exact: true }).check();
  await page.getByRole("button", { name: "Save and next", exact: true }).click();
  await expect(page.getByRole("button", { name: "Next purchase", exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Save and next", exact: true })).toBeDisabled();
  await expect(page.getByText("ITC treatment saved.", { exact: true })).toHaveCount(0);
  release();
  await expect(page.getByRole("heading", { name: "Purchase P-002" })).toBeVisible();
  expect(writes).toBe(1);
});

test("ITC radio choices support arrows and preserve multiline notes", async ({
  page,
}, testInfo) => {
  await setup(page);
  let posted: unknown;
  await page.route("**/review/one/treatment?*", (route) => {
    posted = route.request().postDataJSON();
    return route.fulfill({ json: review() });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  const claim = page.getByRole("radio", { name: "Claim this month", exact: true });
  await claim.check();
  await page.keyboard.press("ArrowRight");
  await expect(page.getByRole("radio", { name: "Claim later", exact: true })).toBeChecked();
  await expect(page).toHaveURL(/review\/one$/);
  await page.getByLabel("Why claim later?").selectOption("other");
  const note = page.getByLabel("Note", { exact: true });
  await expect(note).toHaveJSProperty("tagName", "TEXTAREA");
  await note.fill("Awaiting goods receipt\nSupplier called on Monday.");
  await page.screenshot({ path: testInfo.outputPath("itc-controls-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({ path: testInfo.outputPath("itc-controls-narrow.png"), fullPage: true });
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(posted).toMatchObject({
    values: { choice: "later", note: "Awaiting goods receipt\nSupplier called on Monday." },
  });
});

test("correcting source values stays in React and sends the evidence basis", async ({
  page,
}, info) => {
  await setup(page);
  let posted: unknown;
  await page.route("**/review/one/source?*", (route) => {
    posted = route.request().postDataJSON();
    return route.fulfill({ json: review() });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Correct purchase values" }).click();
  await page.getByLabel("Taxable value", { exact: true }).fill("1100.00");
  await page.getByLabel("Invoice total", { exact: true }).fill("1280.00");
  await page.getByLabel("Reason for correction").fill("Checked original bill");
  await page.screenshot({
    path: info.outputPath("purchase-correction.png"),
    animations: "disabled",
  });
  await page.getByRole("button", { name: "Save correction", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(posted).toMatchObject({
    action: "correct",
    books_id: "book1",
    source_basis: "source-basis",
    reason: "Checked original bill",
    amounts: { taxable_paise: "1100.00" },
  });
  await expect(page).toHaveURL(/\/app\/gst\/1\/2026-06\/purchases\/review\/one/);
});

test("suggested match requires explicit confirmation before sending a pairing decision", async ({
  page,
}) => {
  const data = review();
  data.item!.pairing_pending = true;
  data.item!.comparisons[0].can_pair = true;
  await setup(page, () => data);
  let writes = 0;
  await page.route("**/review/one/source?*", (route) => {
    writes++;
    expect(route.request().postDataJSON()).toMatchObject({
      action: "reject_pair",
      books_id: "book1",
      portal_ref: "portal1",
      source_basis: "source-basis",
    });
    return route.fulfill({ json: review() });
  });
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Different invoices", exact: true }).click();
  expect(writes).toBe(0);
  await page.getByRole("button", { name: "Confirm decision", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(writes).toBe(1);
});

test("source validation errors keep amounts editable for correction", async ({ page }) => {
  await setup(page);
  await page.route("**/review/one/source?*", (route) =>
    route.fulfill({
      status: 422,
      json: { error: "Total must equal taxable value plus GST.", code: "invalid" },
    }),
  );
  await page.goto("/app/gst/1/2026-06/purchases/review/one");
  await page.getByRole("button", { name: "Correct purchase values" }).click();
  await page.getByLabel("Taxable value", { exact: true }).fill("2000.00");
  await page.getByLabel("Reason for correction").fill("Original bill checked");
  await page.getByRole("button", { name: "Save correction", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Total must equal");
  await expect(page.getByLabel("Taxable value", { exact: true })).toHaveValue("2000.00");
  await page.getByLabel("Invoice total", { exact: true }).fill("2180.00");
  await expect(page.getByRole("button", { name: "Save correction", exact: true })).toBeEnabled();
});
