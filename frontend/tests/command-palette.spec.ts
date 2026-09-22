import { expect, test, type Page } from "@playwright/test";

async function setup(page: Page) {
  const clients = [{ id: 1, name: "Breeze Tech", gstin: "33AAAAA0000A1Z1" }, { id: 2, name: "Harbour Services", gstin: "29BBBBB0000B1Z2" }];
  const user = { name: "Accountant", org: "Test firm" };
  await page.route("**/api/workspace/sales/*/*", route => {
    const parts = new URL(route.request().url()).pathname.split("/");
    const client = clients.find(client => client.id === Number(parts[4]));
    const period = parts[5];
    const base = `/gst/${client!.id}/${period}/sales`;
    return route.fulfill({ json: { client, clients, user, period, month_label: period, can_upload: true, deadline: "2026-07-11", invoice_count: 0, review_count: 0, month_issue_count: 0, taxable: "₹0.00", tax: "₹0.00", uploads: { files: 0, unfinished: false }, rows: [], sections: [], links: { upload: `${base}/upload`, uploads: `${base}/uploads`, working: base, purchases: base.replace("sales", "purchases") } } });
  });
  await page.route(/\/api\/workspace\/clients(?:\?.*)?$/, route => route.fulfill({ json: { clients: clients.map(client => ({ ...client, sales_path: `/gst/${client.id}/2026-06/sales` })), user, can_edit: true, period: "2026-06" } }));
}

test("command palette searches pages, months and GSTIN without reloading", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales");
  const trigger = page.getByRole("button", { name: "Go to page or client" });
  await expect(trigger).toBeVisible();
  await page.evaluate(() => { (window as any).sameDocument = true; });
  await page.keyboard.press("Control+k");
  const input = page.getByRole("combobox", { name: "Search pages, clients or a month" });
  await expect(input).toBeFocused();
  const selected = page.locator('[cmdk-item][data-selected="true"]');
  const unselected = page.locator('[cmdk-item][data-selected="false"]').first();
  await expect(selected).toHaveCount(1);
  expect(await selected.evaluate(node => getComputedStyle(node).backgroundColor)).not.toBe(await unselected.evaluate(node => getComputedStyle(node).backgroundColor));
  await input.fill("sales register");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/1/2026-06/sales/register");
  await trigger.click();
  await input.fill("July 2025");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/1/2025-07/sales/register");
  await trigger.click();
  await input.fill("29BBBBB");
  await expect(page.getByRole("option", { name: /Harbour Services/ })).toBeVisible();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/2/2025-07/sales/register");
  expect(await page.evaluate(() => (window as any).sameDocument)).toBe(true);
});

test("palette closes to trigger, respects editing and dialogs, and handles no results", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales/register");
  const trigger = page.getByRole("button", { name: "Go to page or client" });
  await trigger.click();
  const input = page.getByRole("combobox", { name: "Search pages, clients or a month" });
  await input.fill("zzzz missing");
  await expect(page.getByText("No results found.", { exact: true })).toBeVisible();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/1/2026-06/sales/register");
  await page.keyboard.press("Escape");
  await expect(trigger).toBeFocused();
  await page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" }).focus();
  await page.keyboard.press("Control+k");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await page.getByRole("button", { name: "Keyboard shortcuts", exact: true }).click();
  await page.keyboard.press("Control+k");
  await expect(page.getByRole("dialog")).toHaveCount(1);
  await expect(page.getByRole("dialog", { name: "Keyboard shortcuts" })).toBeVisible();
  await page.keyboard.press("Escape");
  await trigger.click();
  await input.fill("June");
  await page.screenshot({ path: "test-results/command-palette-desktop.png", animations: "disabled" });
});

test("client directory also offers the command palette", async ({ page }) => {
  await setup(page);
  await page.goto("/app/clients?period=2026-06");
  await page.getByRole("button", { name: "Go to page or client" }).click();
  await page.getByRole("combobox", { name: "Search pages, clients or a month" }).fill("Breeze");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/1/2026-06/sales");
});
