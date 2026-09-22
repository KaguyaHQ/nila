import { expect, test, type Page } from "@playwright/test";
import type { SalesWorkspace } from "../src/lib/sales-api";

function workspace(client = 1): SalesWorkspace {
  return {
    client: { id: client, name: client === 1 ? "Breeze Tech" : "Second client" },
    clients: [{ id: 1, name: "Breeze Tech" }, { id: 2, name: "Second client" }],
    user: { name: "Accountant", org: "Test firm" },
    period: "2026-06", month_label: "June 2026", deadline: "2026-07-11",
    invoice_count: 0, review_count: 0, month_issue_count: 0, can_upload: true,
    taxable: null, tax: null, uploads: { files: 0, unfinished: false }, rows: [], sections: [],
    links: { upload: "/gst/1/2026-06/sales/upload", uploads: "/gst/1/2026-06/sales/uploads", working: "/gst/1/2026-06/sales", purchases: "/gst/1/2026-06/purchases" },
  };
}

const pdf = (name: string) => ({ name, mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4\nsales bill") });

async function setup(page: Page) {
  await page.route("**/api/workspace/sales/*/*", route => route.fulfill({ json: workspace(Number(new URL(route.request().url()).pathname.split("/")[4])) }));
  await page.addInitScript(() => {
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "test-csrf";
      document.head.append(meta);
    });
  });
}

test("failed PUT resumes remaining PDFs and uncertain commit retries the same token", async ({ page }) => {
  await setup(page);
  let prepares = 0;
  let firstPuts = 0;
  let secondPuts = 0;
  const commits: string[] = [];
  await page.route("**/uploads/prepare", async route => {
    prepares++;
    expect(route.request().headers()["x-csrf-token"]).toBe("test-csrf");
    expect(route.request().postDataJSON().files.map((file: { name: string }) => file.name)).toEqual(["first.pdf", "second.pdf"]);
    await route.fulfill({ json: { token: "same-token", files: [{ name: "first.pdf", url: "http://127.0.0.1:5174/storage/first" }, { name: "second.pdf", url: "http://127.0.0.1:5174/storage/second" }] } });
  });
  await page.route("**/storage/*", async route => {
    expect(route.request().method()).toBe("PUT");
    expect(route.request().headers()["content-type"]).toBe("application/pdf");
    if (route.request().url().endsWith("first")) {
      firstPuts++;
      await route.fulfill({ status: 200, body: "" });
    } else {
      secondPuts++;
      await route.fulfill({ status: secondPuts === 1 ? 503 : 200, body: "" });
    }
  });
  await page.route("**/api/workspace/sales/*/*/uploads", async route => {
    if (route.request().method() === "POST") {
      expect(route.request().headers()["x-csrf-token"]).toBe("test-csrf");
      commits.push(route.request().postDataJSON().token);
      await route.fulfill(commits.length === 1 ? { status: 503, json: { error: "Connection interrupted while saving." } } : { json: { id: "batch-1" } });
    } else await route.fulfill({ json: { batches: [], processing: false } });
  });
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await page.getByLabel("Choose sales PDF files").setInputFiles([pdf("first.pdf"), pdf("second.pdf")]);
  await page.getByRole("button", { name: "Upload PDFs", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Couldn't upload second.pdf");
  await expect(page.getByRole("progressbar", { name: "Upload progress for first.pdf" })).toHaveAttribute("value", "100");
  await expect(page.getByRole("button", { name: "Choose PDFs", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Retry upload", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Connection interrupted while saving");
  await expect(page.getByRole("status")).toContainText("Retry to confirm");
  await page.getByRole("link", { name: "View uploads", exact: true }).click();
  await page.getByRole("link", { name: "Add invoices", exact: true }).click();
  await expect(page.getByRole("button", { name: "Retry upload", exact: true })).toBeVisible();
  await page.evaluate(() => { (window as unknown as { sameDocument: boolean }).sameDocument = true; });
  await page.getByRole("button", { name: "Retry upload", exact: true }).click();
  await expect(page).toHaveURL(/\/sales\/uploads$/);
  await expect(page.getByText("No uploads yet", { exact: true })).toBeVisible();
  expect(prepares).toBe(1);
  expect(firstPuts).toBe(1);
  expect(secondPuts).toBe(2);
  expect(commits).toEqual(["same-token", "same-token"]);
  expect(await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument)).toBe(true);
});

test("PDF validation prevents invalid writes and switching client clears the old selection", async ({ page }) => {
  await setup(page);
  const writes: string[] = [];
  page.on("request", request => { if (request.method() === "POST") writes.push(request.url()); });
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await page.getByLabel("Choose sales PDF files").setInputFiles([
    { name: "empty.pdf", mimeType: "application/pdf", buffer: Buffer.from("") },
    { name: "invoice.csv", mimeType: "text/csv", buffer: Buffer.from("csv") },
    pdf("sales.pdf"),
  ]);
  await expect(page.getByRole("alert")).toContainText("this file is empty");
  await expect(page.getByRole("alert")).toContainText("choose a PDF file");
  await expect(page.getByRole("heading", { name: "1 file selected" })).toBeVisible();
  await page.getByLabel("Client", { exact: true }).selectOption("2");
  await expect(page).toHaveURL(/\/gst\/2\/2026-06\/sales\/upload$/);
  await expect(page.getByText("sales.pdf", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Upload PDFs", exact: true })).toBeDisabled();
  expect(writes).toEqual([]);
});

test("history polls processing, retains failed sources and links to review and React register", async ({ page }, testInfo) => {
  await setup(page);
  let processing = true;
  await page.route("**/api/workspace/sales/*/*/uploads", route => {
    return route.fulfill({ json: {
      processing,
      batches: [{ id: "batch-1", created_at: "2026-06-15T10:00:00Z", review_url: "/gst/1/2026-06/review/sales?batch=batch-1", files: [
        { id: 1, name: "Sales invoices.pdf", state: processing ? "processing" : "done", label: processing ? "Reading" : "Read", invoice_count: processing ? 0 : 8, error: null, original_url: "/source/file-1" },
        { id: "file-2", name: "Damaged bill.pdf", state: "failed", label: "Needs attention", invoice_count: 0, error: "We couldn't read this PDF.", original_url: "/source/file-2" },
      ] }],
    } });
  });
  await page.goto("/app/gst/1/2026-06/sales/uploads");
  await expect(page.getByRole("status")).toContainText("reading your PDFs");
  processing = false;
  await expect(page.getByText("8 invoices", { exact: true })).toBeVisible({ timeout: 8000 });
  await expect(page.getByText("We couldn't read this PDF.", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Open source PDF for Damaged bill.pdf (new tab)" })).toHaveAttribute("href", "/source/file-2");
  await expect(page.getByRole("link", { name: "Review upload" })).toHaveAttribute("href", /review\/sales\?batch=/);
  await page.screenshot({ path: testInfo.outputPath("uploads-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("uploads-narrow.png"), fullPage: true });
  await page.evaluate(() => { (window as unknown as { sameDocument: boolean }).sameDocument = true; });
  await page.getByRole("link", { name: "View sales register", exact: true }).click();
  await expect(page).toHaveURL(/\/sales\/register$/);
  expect(await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument)).toBe(true);
});

test("history permission failure does not appear as an empty upload list", async ({ page }) => {
  await setup(page);
  await page.route("**/api/workspace/sales/*/*/uploads", route => route.fulfill({ status: 403, json: { error: "You cannot access these uploads." } }));
  await page.goto("/app/gst/1/2026-06/sales/uploads");
  await expect(page.getByRole("alert")).toContainText("You cannot access these uploads");
  await expect(page.getByText("No uploads yet", { exact: true })).toHaveCount(0);
});

test("expired storage URL renews the existing token and retries the PDF", async ({ page }) => {
  await setup(page);
  const preparations: unknown[] = [];
  await page.route("**/uploads/prepare", route => {
    preparations.push(route.request().postDataJSON());
    return route.fulfill({ json: { token: "existing-token", files: [{ name: "sales.pdf", url: `http://127.0.0.1:5174/storage/${preparations.length === 1 ? "expired" : "renewed"}` }] } });
  });
  await page.route("**/storage/*", route => route.fulfill({ status: route.request().url().endsWith("expired") ? 403 : 200, body: "" }));
  await page.route("**/api/workspace/sales/*/*/uploads", route => {
    if (route.request().method() === "POST") {
      expect(route.request().postDataJSON()).toEqual({ token: "existing-token" });
      return route.fulfill({ json: { ok: true } });
    }
    return route.fulfill({ json: { batches: [], processing: false } });
  });
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await page.getByLabel("Choose sales PDF files").setInputFiles(pdf("sales.pdf"));
  await page.getByRole("button", { name: "Upload PDFs", exact: true }).click();
  await expect(page).toHaveURL(/\/sales\/uploads$/);
  expect(preparations).toHaveLength(2);
  expect(preparations[1]).toEqual({ token: "existing-token" });
});

test("rejected upload unlocks file replacement before a new preparation", async ({ page }) => {
  await setup(page);
  let prepares = 0;
  let commits = 0;
  await page.route("**/uploads/prepare", route => {
    prepares++;
    return route.fulfill({ json: { token: `token-${prepares}`, files: [{ name: "sales.pdf", url: "http://127.0.0.1:5174/storage/pdf" }] } });
  });
  await page.route("**/storage/*", route => route.fulfill({ status: 200, body: "" }));
  await page.route("**/api/workspace/sales/*/*/uploads", route => {
    if (route.request().method() === "POST") {
      commits++;
      expect(route.request().postDataJSON()).toEqual({ token: `token-${commits}` });
      return route.fulfill(commits === 1 ? { status: 422, json: { error: "Upload expired." } } : { json: { ok: true } });
    }
    return route.fulfill({ json: { batches: [], processing: false } });
  });
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await page.getByLabel("Choose sales PDF files").setInputFiles(pdf("sales.pdf"));
  await page.getByRole("button", { name: "Upload PDFs", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Upload expired.");
  expect(prepares).toBe(1);
  await expect(page.getByRole("button", { name: "Choose PDFs", exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "Remove sales.pdf", exact: true }).click();
  await expect(page.getByRole("button", { name: "Upload PDFs", exact: true })).toBeDisabled();
  await page.getByLabel("Choose sales PDF files").setInputFiles(pdf("sales.pdf"));
  await page.getByRole("button", { name: "Upload PDFs", exact: true }).click();
  await expect(page).toHaveURL(/\/sales\/uploads$/);
  expect(prepares).toBe(2);
});

test("view-only role cannot select or upload PDFs", async ({ page }) => {
  await setup(page);
  await page.route("**/api/workspace/sales/*/*", route => route.fulfill({ json: { ...workspace(), can_upload: false } }));
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await expect(page.getByRole("status")).toHaveText("Your role allows viewing, not uploading.");
  await expect(page.getByRole("button", { name: "Choose PDFs", exact: true })).toBeDisabled();
  await expect(page.getByLabel("Choose sales PDF files")).toBeDisabled();
  await expect(page.getByRole("button", { name: "Upload PDFs", exact: true })).toBeDisabled();
  await expect(page.getByRole("link", { name: "View uploads", exact: true })).toBeVisible();
});

test("selection enforces 50 files and exact 50 MB per-file limit", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales/upload");
  const transfer = await page.evaluateHandle(() => {
    const data = new DataTransfer();
    data.items.add(new File([new Uint8Array(50_000_001)], "too-large.pdf", { type: "application/pdf" }));
    for (let index = 0; index < 51; index++) data.items.add(new File(["%PDF"], `sales-${index}.pdf`, { type: "application/pdf" }));
    return data;
  });
  await page.getByRole("heading", { name: "Drop your sales PDFs here", exact: true }).dispatchEvent("drop", { dataTransfer: transfer });
  await expect(page.getByRole("alert")).toContainText("too-large.pdf: the limit is 50 MB per PDF.");
  await expect(page.getByRole("alert")).toContainText("Choose up to 50 PDFs at a time.");
  await expect(page.getByRole("heading", { name: "50 files selected", exact: true })).toBeVisible();
});
