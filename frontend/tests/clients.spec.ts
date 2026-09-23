import { expect, test, type Page } from "@playwright/test";
import type { ClientsDirectory, ImportRow } from "../src/lib/clients-api";

function directory(period = "2026-06", canEdit = true): ClientsDirectory {
  return {
    clients: [
      { id: 1, name: "Breeze Tech", gstin: "33AABCT3518Q1ZF", sales_path: `/gst/1/${period}/sales` },
      { id: 2, name: "Harbour Services", gstin: null, sales_path: `/gst/2/${period}/sales` },
    ],
    user: { name: "Accountant", org: "Test firm" }, can_edit: canEdit, period,
  };
}
const rootApi = /\/api\/workspace\/clients(?:\?.*)?$/;
async function setup(page: Page, canEdit = true) {
  await page.route(rootApi, route => route.fulfill({ json: directory(new URL(route.request().url()).searchParams.get("period") ?? "2026-06", canEdit) }));
  await page.addInitScript(() => document.addEventListener("DOMContentLoaded", () => {
    const meta = document.createElement("meta");
    meta.name = "csrf-token";
    meta.content = "clients-csrf";
    document.head.append(meta);
  }));
}

test("directory search preserves URL and period; slash focuses search without hijacking typing", async ({ page }, testInfo) => {
  await setup(page);
  await page.goto("/app/clients?period=2026-04");
  await expect(page.getByRole("heading", { name: "Clients", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Breeze Tech", exact: true })).toHaveAttribute("href", "/app/gst/1/2026-04/sales");
  await expect(page.getByRole("link", { name: "Add client", exact: true })).toHaveAttribute("href", "/app/clients/new?period=2026-04");
  await page.keyboard.press("/");
  await expect(page.getByRole("textbox", { name: "Search clients" })).toBeFocused();
  await page.getByRole("textbox", { name: "Search clients" }).fill("Breeze");
  await expect(page.getByRole("status")).toHaveText("Showing 1 of 2 clients");
  await page.reload();
  await expect(page.getByRole("textbox", { name: "Search clients" })).toHaveValue("Breeze");
  await page.getByRole("textbox", { name: "Search clients" }).press("End");
  await page.getByRole("textbox", { name: "Search clients" }).press("/");
  await expect(page.getByRole("textbox", { name: "Search clients" })).toHaveValue("Breeze/");
  await expect(page.getByText("No clients match", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Clear search", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Showing 2 of 2 clients");
  await page.screenshot({ path: testInfo.outputPath("clients-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("clients-narrow.png"), fullPage: true });
  await page.evaluate(() => { (window as unknown as { sameDocument: boolean }).sameDocument = true; });
  await page.getByRole("link", { name: "Edit Breeze Tech", exact: true }).click();
  await expect(page).toHaveURL(/\/clients\/1\/edit\?period=2026-04$/);
  expect(await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument)).toBe(true);
});

test("add form retains server validation errors and sends only client identity with CSRF", async ({ page }) => {
  await setup(page);
  let writes = 0;
  await page.route(rootApi, async route => {
    if (route.request().method() === "GET") return route.fallback();
    writes++;
    expect(route.request().headers()["x-csrf-token"]).toBe("clients-csrf");
    const body = route.request().postDataJSON();
    expect(Object.keys(body.client).sort()).toEqual(["gstin", "name"]);
    await route.fulfill(writes === 1 ? { status: 422, json: { error: "Check the client details.", errors: { gstin: ["is invalid"] } } } : { status: 201, json: { client: { id: 3, ...body.client }, can_edit: true } });
  });
  await page.goto("/app/clients/new?period=2026-06");
  await page.getByLabel("Client name", { exact: true }).fill("New client");
  await page.getByLabel("GSTIN (optional)").fill("bad");
  await page.getByRole("button", { name: "Add client", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Check the client details.");
  await expect(page.getByLabel("GSTIN (optional)")).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByText("is invalid", { exact: true })).toBeVisible();
  await expect(page.getByLabel("Client name", { exact: true })).toHaveValue("New client");
  await page.getByLabel("GSTIN (optional)").fill("");
  await page.getByRole("button", { name: "Add client", exact: true }).click();
  await expect(page).toHaveURL(/\/clients\?period=2026-06$/);
  expect(writes).toBe(2);
});

test("edit loads real identity and preserves the separate GST/Tally destination", async ({ page }) => {
  await setup(page);
  let writes = 0;
  let nextRead: Promise<void> | null = null;
  let releaseRead: (() => void) | undefined;
  await page.route("**/api/workspace/clients/1", async route => {
    if (route.request().method() === "PATCH") {
      writes++;
      expect(route.request().postDataJSON()).toEqual({ client: { name: "Breeze Technology", gstin: "33AABCT3518Q1ZF" } });
      return route.fulfill({ json: { client: { id: 1, name: "Breeze Technology", gstin: "33AABCT3518Q1ZF" }, can_edit: true } });
    }
    if (nextRead) await nextRead;
    return route.fulfill({ json: { client: { ...directory().clients[0], name: writes ? "Changed elsewhere" : "Breeze Tech" }, can_edit: true } });
  });
  await page.goto("/app/clients/1/edit?period=2026-06");
  await expect(page.getByLabel("Client name", { exact: true })).toHaveValue("Breeze Tech");
  await expect(page.getByRole("link", { name: "GST and Tally connections" })).toHaveAttribute("href", "/clients/1/edit");
  await page.getByLabel("Client name", { exact: true }).fill("Breeze Technology");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page).toHaveURL(/\/clients\?period=2026-06$/);
  expect(writes).toBe(1);
  nextRead = new Promise<void>(resolve => { releaseRead = resolve; });
  await page.getByRole("link", { name: "Edit Breeze Tech", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Loading client…");
  await expect(page.getByLabel("Client name", { exact: true })).toHaveCount(0);
  releaseRead!();
  await expect(page.getByLabel("Client name", { exact: true })).toHaveValue("Changed elsewhere");
});

test("Excel import keeps skipped and invalid rows visible and reports only confirmed save results", async ({ page }) => {
  await setup(page);
  const rows: ImportRow[] = [
    { row: 2, name: "New client", gstin: "33AABCT3518Q1ZF", gst_username: "newclient", status: "ready", message: "Ready to add" },
    { row: 3, name: "Breeze Tech", gstin: null, status: "skip", message: "Client name already exists. Check the existing client." },
    { row: 4, name: "Broken GSTIN", gstin: "INVALID", status: "invalid", message: "GSTIN is invalid." },
  ];
  await page.route("**/api/workspace/clients/import/preview", route => {
    expect(route.request().headers()["x-csrf-token"]).toBe("clients-csrf");
    expect(route.request().headers()["content-type"]).toContain("multipart/form-data; boundary=");
    expect(route.request().postData()).toContain('name="file"; filename="clients.xlsx"');
    return route.fulfill({ json: { rows, token: "preview-token", ready_count: 1 } });
  });
  let commits = 0;
  await page.route("**/api/workspace/clients/import", route => {
    expect(route.request().postDataJSON()).toEqual({ token: "preview-token" });
    commits++;
    return route.fulfill(commits === 1 ? { status: 503, json: { error: "Could not confirm this import. Try again." } } : { json: { rows: [{ ...rows[0], status: "added", message: "Added" }, ...rows.slice(1)], added_count: 1, skipped_count: 1, invalid_count: 1 } });
  });
  await page.goto("/app/clients/import?period=2026-06");
  await expect(page.getByRole("link", { name: "Download template" })).toHaveAttribute("href", "/clients/import-template.xlsx");
  await page.getByLabel("Client list (.xlsx)").setInputFiles({ name: "clients.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", buffer: Buffer.from("workbook fixture") });
  await page.getByRole("button", { name: "Preview clients", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("1 ready to add · 1 skipped · 1 invalid");
  await expect(page.getByRole("columnheader", { name: "GST username" })).toBeVisible();
  await expect(page.getByText("newclient", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Add 1 client", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Could not confirm this import. Try again.");
  await expect(page.getByRole("heading", { name: "Import results", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Add 1 client", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Import results", exact: true })).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("1 added · 1 skipped · 1 invalid");
  await expect(page.getByText("GSTIN is invalid.", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Add 1 client", exact: true })).toHaveCount(0);
});

test("view-only role cannot add or import and permission failures never look empty", async ({ page }) => {
  await setup(page, false);
  await page.goto("/app/clients?period=2026-06");
  await expect(page.getByRole("button", { name: "Add client", exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Import Excel", exact: true })).toBeDisabled();
  await page.goto("/app/clients/new?period=2026-06");
  await expect(page.getByLabel("Client name", { exact: true })).toBeDisabled();
  await page.goto("/app/clients/import?period=2026-06");
  await expect(page.getByLabel("Client list (.xlsx)")).toBeDisabled();
  await page.route(rootApi, route => route.fulfill({ status: 403, json: { error: "You cannot access these clients." } }));
  await page.reload();
  await expect(page.getByRole("alert")).toHaveText("You cannot access these clients.");
  await expect(page.getByText("No clients yet", { exact: true })).toHaveCount(0);
});


test("choosing another workbook clears a failed preview before retrying", async ({ page }) => {
  await setup(page);
  let previews = 0;
  await page.route("**/api/workspace/clients/import/preview", route => {
    previews++;
    return route.fulfill(previews === 1
      ? { status: 422, json: { error: "Cannot read this workbook." } }
      : { json: { rows: [], token: "replacement-token", ready_count: 0 } });
  });
  await page.goto("/app/clients/import?period=2026-06");
  const picker = page.getByLabel("Client list (.xlsx)");
  await picker.setInputFiles({ name: "broken.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", buffer: Buffer.from("broken") });
  await page.getByRole("button", { name: "Preview clients", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Cannot read this workbook.");
  await expect(picker).toBeEnabled();
  await picker.setInputFiles({ name: "replacement.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", buffer: Buffer.from("replacement") });
  await expect(page.getByRole("alert")).toHaveCount(0);
  await page.getByRole("button", { name: "Preview clients", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Preview", exact: true })).toBeVisible();
  expect(previews).toBe(2);
});
