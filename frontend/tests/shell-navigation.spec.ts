import { expect, test, type Page } from "@playwright/test";

const clients = [{ id: 2, name: "Harbour Services", gstin: "33AAAAA1234A1Z5" }, { id: 3, name: "Orchard Trading", gstin: "29BBBBB1234B1Z5" }];
const user = { name: "Accountant", org: "Test firm" };
async function setup(page: Page) {
  await page.route("**/api/workspace/sales/*/*", route => {
    const parts = new URL(route.request().url()).pathname.split("/");
    const client = clients.find(item => item.id === Number(parts[4]))!;
    const period = parts[5]; const base = `/gst/${client.id}/${period}/sales`;
    return route.fulfill({ json: { client, clients, user, period, month_label: period, can_upload: true, deadline: "2026-07-11", invoice_count: 0, review_count: 0, month_issue_count: 0, taxable: "₹0.00", tax: "₹0.00", uploads: { files: 0, unfinished: false }, rows: [], sections: [], links: { upload: `${base}/upload`, uploads: `${base}/uploads`, working: base, purchases: `/gst/${client.id}/${period}/purchases` } } });
  });
  await page.route(/\/api\/workspace\/clients(?:\?.*)?$/, route => route.fulfill({ json: { clients, user, can_edit: true, period: "2026-06" } }));
}

test("client switch searches GSTIN, preserves period and drops another client's search", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales/register?q=private&filter=ready");
  await page.getByLabel("Switch client: Harbour Services", { exact: true }).click();
  await page.getByRole("combobox", { name: "Search clients" }).fill("29BBBBB");
  await expect(page.getByRole("option", { name: /Orchard Trading/ })).toBeVisible();
  await expect(page.getByRole("option", { name: /Harbour Services/ })).toHaveCount(0);
  await page.getByRole("combobox", { name: "Search clients" }).press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/3/2026-06/sales/register?filter=ready");
});

test("collapsed sidebar retains client access and survives refresh", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales");
  await page.getByRole("button", { name: "Collapse sidebar" }).click();
  await page.reload();
  await expect(page.getByRole("button", { name: "Expand sidebar" })).toBeVisible();
  await page.getByLabel("Switch client: Harbour Services", { exact: true }).click();
  await expect(page.getByRole("combobox", { name: "Search clients" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByLabel("Switch client: Harbour Services", { exact: true })).toBeFocused();
});

test("sign out submits Phoenix method override and CSRF", async ({ page }) => {
  await setup(page);
  await page.addInitScript(() => document.addEventListener("DOMContentLoaded", () => {
    const meta = document.createElement("meta"); meta.name = "csrf-token"; meta.content = "csrf-proof"; document.head.append(meta);
  }));
  await page.goto("/app/gst/2/2026-06/sales");
  await page.route("**/users/log_out", route => route.fulfill({ contentType: "text/html", body: "Signed out" }));
  await page.getByRole("button", { name: "Open account menu" }).click();
  const request = page.waitForRequest("**/users/log_out");
  await page.getByRole("menuitem", { name: "Sign out" }).click();
  const sent = await request;
  expect(sent.method()).toBe("POST");
  expect(new URLSearchParams(sent.postData()!).get("_method")).toBe("delete");
  expect(new URLSearchParams(sent.postData()!).get("_csrf_token")).toBe("csrf-proof");
});
